defmodule Sorrel.ConnTest do
  use ExUnit.Case, async: true

  alias Sorrel.Conn
  alias Sorrel.Endpoint
  alias Sorrel.Transport

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp tmp_socket_path do
    Path.join(
      System.tmp_dir!(),
      "docker-minty-conn-test-#{System.unique_integer([:positive])}.sock"
    )
  end

  defp start_unix_server(socket_path, responder) do
    {:ok, server} =
      FakeHttpServer.start(
        transport: :unix,
        socket_path: socket_path,
        responder: responder
      )

    on_exit(fn -> FakeHttpServer.stop(server) end)
    server
  end

  defp start_tcp_server(responder) do
    {:ok, server} =
      FakeHttpServer.start(
        transport: :tcp,
        ip: {127, 0, 0, 1},
        port: 0,
        responder: responder
      )

    on_exit(fn -> FakeHttpServer.stop(server) end)
    {:ok, port} = FakeHttpServer.port(server)
    {server, port}
  end

  defp unix_endpoint(path) do
    %Endpoint{transport: :unix, socket_path: path}
  end

  defp tcp_endpoint(port) do
    %Endpoint{
      transport: :tcp,
      scheme: :http,
      host: "127.0.0.1",
      port: port
    }
  end

  defp connect_unix(socket_path) do
    {:ok, conn} = socket_path |> unix_endpoint() |> Transport.connect()
    conn
  end

  defp connect_tcp(port) do
    {:ok, conn} = port |> tcp_endpoint() |> Transport.connect()
    conn
  end

  defp ok_responder(body) do
    fn _req ->
      [
        "HTTP/1.1 200 OK\r\n",
        "Content-Type: text/plain\r\n",
        "Content-Length: #{byte_size(body)}\r\n",
        "\r\n",
        body
      ]
    end
  end

  defp chunked_responder(chunks) do
    fn _req ->
      head = [
        "HTTP/1.1 200 OK\r\n",
        "Content-Type: text/plain\r\n",
        "Transfer-Encoding: chunked\r\n",
        "\r\n"
      ]

      body =
        Enum.map(chunks, fn chunk ->
          size_hex = Integer.to_string(byte_size(chunk), 16)
          [size_hex, "\r\n", chunk, "\r\n"]
        end)

      [head, body, "0\r\n\r\n"]
    end
  end

  defp not_found_responder(body) do
    fn _req ->
      [
        "HTTP/1.1 404 Not Found\r\n",
        "Content-Type: text/plain\r\n",
        "Content-Length: #{byte_size(body)}\r\n",
        "\r\n",
        body
      ]
    end
  end

  # Sends headers promising a body, then closes the socket before sending it.
  defp truncated_responder do
    fn _req ->
      {:close_after,
       [
         "HTTP/1.1 200 OK\r\n",
         "Content-Type: text/plain\r\n",
         "Content-Length: 100\r\n",
         "\r\n",
         "only-a-few-bytes"
       ]}
    end
  end

  # Accept the request but never write a response. The caller's recv times out.
  defp silent_responder do
    fn _req ->
      Process.sleep(60_000)
      ""
    end
  end

  # ---------------------------------------------------------------------------
  # Success — buffered 200 with Content-Length body, over Unix
  # ---------------------------------------------------------------------------

  describe "request/6 success (Unix)" do
    test "returns {:ok, response, conn} with status, headers, and body" do
      socket_path = tmp_socket_path()
      _server = start_unix_server(socket_path, ok_responder("OK"))
      conn = connect_unix(socket_path)

      assert {:ok, response, conn} =
               Conn.request(conn, "GET", "/_ping", [{"host", "localhost"}], "")

      assert response.status === 200
      assert response.body === "OK"
      assert is_list(response.headers)

      assert Enum.any?(response.headers, fn {name, value} ->
               String.downcase(name) === "content-type" and value === "text/plain"
             end)

      assert Mint.HTTP.open?(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # Success — buffered 200 with Content-Length body, over TCP
  # ---------------------------------------------------------------------------

  describe "request/6 success (TCP)" do
    test "returns {:ok, response, conn} with status, headers, and body" do
      {_server, port} = start_tcp_server(ok_responder("HELLO"))
      conn = connect_tcp(port)

      assert {:ok, response, conn} =
               Conn.request(conn, "GET", "/_ping", [{"host", "localhost"}], "")

      assert response.status === 200
      assert response.body === "HELLO"
      assert Mint.HTTP.open?(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # Success — chunked transfer encoding (Unix)
  # ---------------------------------------------------------------------------

  describe "request/6 with chunked transfer-encoding" do
    test "concatenates dechunked payload into response.body" do
      socket_path = tmp_socket_path()
      chunks = ["hello ", "chunked ", "world"]
      _server = start_unix_server(socket_path, chunked_responder(chunks))
      conn = connect_unix(socket_path)

      assert {:ok, response, _conn} =
               Conn.request(conn, "GET", "/_ping", [{"host", "localhost"}], "")

      assert response.status === 200
      assert response.body === "hello chunked world"
    end
  end

  # ---------------------------------------------------------------------------
  # Non-2xx is NOT an error at this layer
  # ---------------------------------------------------------------------------

  describe "request/6 with non-2xx response" do
    test "404 returns {:ok, %{status: 404, body: ...}, conn} — not {:error, _, _}" do
      socket_path = tmp_socket_path()
      _server = start_unix_server(socket_path, not_found_responder("missing"))
      conn = connect_unix(socket_path)

      assert {:ok, response, conn} =
               Conn.request(conn, "GET", "/missing", [{"host", "localhost"}], "")

      assert response.status === 404
      assert response.body === "missing"
      assert Mint.HTTP.open?(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # Server closes mid-response
  # ---------------------------------------------------------------------------

  describe "request/6 when server closes mid-response" do
    test "returns {:error, reason, conn}" do
      socket_path = tmp_socket_path()
      _server = start_unix_server(socket_path, truncated_responder())
      conn = connect_unix(socket_path)

      assert {:error, _reason, _conn} =
               Conn.request(conn, "GET", "/short", [{"host", "localhost"}], "")
    end
  end

  # ---------------------------------------------------------------------------
  # Receive timeout
  # ---------------------------------------------------------------------------

  describe "request/6 receive timeout" do
    test "surfaces Mint.TransportError{reason: :timeout} as {:error, ..., conn}" do
      socket_path = tmp_socket_path()
      _server = start_unix_server(socket_path, silent_responder())
      conn = connect_unix(socket_path)

      assert {:error, %Mint.TransportError{reason: :timeout}, _conn} =
               Conn.request(conn, "GET", "/wait", [{"host", "localhost"}], "",
                 receive_timeout: 100
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Conn reusability — two consecutive requests on the same conn (the verification
  # criterion for Task 8). FakeHttpServer's responder loop keeps the TCP/UDS
  # socket open between requests when the responder returns iodata (not
  # `{:close_after, _}`), so a single fake server instance suffices.
  # ---------------------------------------------------------------------------

  describe "request/6 reusing the same conn" do
    test "two consecutive requests on the same conn both succeed (Unix)" do
      socket_path = tmp_socket_path()
      _server = start_unix_server(socket_path, ok_responder("OK"))
      conn = connect_unix(socket_path)

      assert {:ok, response1, conn} =
               Conn.request(conn, "GET", "/first", [{"host", "localhost"}], "")

      assert response1.status === 200
      assert response1.body === "OK"
      assert Mint.HTTP.open?(conn)

      assert {:ok, response2, conn} =
               Conn.request(conn, "GET", "/second", [{"host", "localhost"}], "")

      assert response2.status === 200
      assert response2.body === "OK"
      assert Mint.HTTP.open?(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # open_and_send/6 — open a fresh conn and send one request in one call.
  # ---------------------------------------------------------------------------

  describe "open_and_send/6 success (Unix)" do
    test "returns {:ok, conn, ref} with a live conn and a request reference" do
      socket_path = tmp_socket_path()
      _server = start_unix_server(socket_path, ok_responder("OK"))

      assert {:ok, conn, ref} =
               Conn.open_and_send(
                 unix_endpoint(socket_path),
                 "GET",
                 "/_ping",
                 [{"host", "localhost"}],
                 ""
               )

      assert Mint.HTTP.open?(conn)
      assert is_reference(ref)

      # Caller drives recv itself — round-trip the response so the test
      # observes that the request is actually in flight on the wire.
      assert {:ok, _conn, responses} = Mint.HTTP.recv(conn, 0, 1_000)
      assert Enum.any?(responses, &match?({:status, ^ref, 200}, &1))
    end
  end

  describe "open_and_send/6 success (TCP)" do
    test "returns {:ok, conn, ref} with a live conn over TCP" do
      {_server, port} = start_tcp_server(ok_responder("HELLO"))

      assert {:ok, conn, ref} =
               Conn.open_and_send(
                 tcp_endpoint(port),
                 "GET",
                 "/_ping",
                 [{"host", "localhost"}],
                 ""
               )

      assert Mint.HTTP.open?(conn)
      assert is_reference(ref)
    end
  end

  describe "open_and_send/6 transport connect failure" do
    test "returns {:error, reason} verbatim when the unix socket is missing" do
      socket_path = tmp_socket_path()
      _removed = File.rm(socket_path)

      # Whatever Transport.Unix surfaces, open_and_send must forward
      # verbatim — no wrapping, no rewrapping, no spurious conn.
      assert {:error, reason} =
               Conn.open_and_send(
                 unix_endpoint(socket_path),
                 "GET",
                 "/_ping",
                 [{"host", "localhost"}],
                 ""
               )

      # Sanity: the underlying cause is :enoent, however Mint chose to
      # surface it.
      assert match?(%Mint.TransportError{reason: :enoent}, reason) or
               reason === :enoent
    end
  end

  describe "open_and_send/6 forwards opts to Transport.connect" do
    test "honours :connect_timeout for unreachable TCP endpoints" do
      # 198.51.100.0/24 is TEST-NET-2 (RFC 5737), reserved for documentation
      # and not routable. A connect to it will hang until the supplied timeout.
      unreachable = %Endpoint{
        transport: :tcp,
        scheme: :http,
        host: "198.51.100.1",
        port: 1
      }

      assert {:error, _reason} =
               Conn.open_and_send(
                 unreachable,
                 "GET",
                 "/_ping",
                 [{"host", "localhost"}],
                 "",
                 connect_timeout: 50
               )
    end
  end
end

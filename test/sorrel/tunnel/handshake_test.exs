defmodule Sorrel.Tunnel.HandshakeTest do
  use ExUnit.Case, async: true

  alias Sorrel.Endpoint
  alias Sorrel.Tunnel.Handshake

  defp unix_socket_path do
    Path.join(
      System.tmp_dir!(),
      "docker-streaming-handshake-#{System.unique_integer([:positive])}.sock"
    )
  end

  defp unix_endpoint(socket_path) do
    %Endpoint{transport: :unix, socket_path: socket_path}
  end

  defp tcp_endpoint(host, port) do
    %Endpoint{
      transport: :tcp,
      scheme: :http,
      host: host,
      port: port
    }
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

  describe "upgrade/4 over unix transport" do
    test "returns the upgraded socket and any leftover bytes on 101" do
      socket_path = unix_socket_path()

      _server =
        start_unix_server(socket_path, fn _request ->
          {:close_after, "HTTP/1.1 101 Switching Protocols\r\n\r\nLEFT"}
        end)

      assert {:ok, socket, "LEFT"} =
               Handshake.upgrade(:post, "/v1.45/containers/x/attach", "",
                 endpoint: unix_endpoint(socket_path)
               )

      assert is_port(socket)
      :ok = :gen_tcp.close(socket)
    end

    test "returns the upgraded socket and any leftover bytes on 200" do
      socket_path = unix_socket_path()

      _server =
        start_unix_server(socket_path, fn _request ->
          {:close_after, "HTTP/1.1 200 OK\r\n\r\nLEFT200"}
        end)

      assert {:ok, socket, "LEFT200"} =
               Handshake.upgrade(:post, "/v1.45/exec/x/start", "{}",
                 endpoint: unix_endpoint(socket_path)
               )

      assert is_port(socket)
      :ok = :gen_tcp.close(socket)
    end

    test "returns an error tuple for non-101/200 status" do
      socket_path = unix_socket_path()

      _server =
        start_unix_server(socket_path, fn _request ->
          {:close_after, "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nno such x"}
        end)

      assert {:error, %{status: 404}} =
               Handshake.upgrade(:post, "/v1.45/containers/missing/attach", "",
                 endpoint: unix_endpoint(socket_path)
               )
    end

    test "returns an error when the socket path does not exist" do
      socket_path = unix_socket_path()
      _removed = File.rm(socket_path)

      assert {:error, _reason} =
               Handshake.upgrade(:post, "/v1.45/containers/x/attach", "",
                 endpoint: unix_endpoint(socket_path)
               )
    end
  end

  describe "upgrade/4 over tcp transport" do
    test "returns the upgraded socket and any leftover bytes on 101" do
      {_server, port} =
        start_tcp_server(fn _request ->
          {:close_after, "HTTP/1.1 101 Switching Protocols\r\n\r\nTCPLEFT"}
        end)

      assert {:ok, socket, "TCPLEFT"} =
               Handshake.upgrade(:post, "/v1.45/containers/x/attach", "",
                 endpoint: tcp_endpoint("127.0.0.1", port)
               )

      assert is_port(socket)
      :ok = :gen_tcp.close(socket)
    end

    test "returns an error tuple for non-101/200 status over tcp" do
      {_server, port} =
        start_tcp_server(fn _request ->
          {:close_after, "HTTP/1.1 500 Internal\r\nContent-Length: 4\r\n\r\nboom"}
        end)

      assert {:error, %{status: 500}} =
               Handshake.upgrade(:post, "/v1.45/containers/x/attach", "",
                 endpoint: tcp_endpoint("127.0.0.1", port)
               )
    end
  end

  describe "upgrade/4 input validation" do
    test "returns an error when no endpoint option is supplied" do
      assert {:error, :endpoint_required} =
               Handshake.upgrade(:post, "/v1.45/containers/x/attach", "", [])
    end
  end
end

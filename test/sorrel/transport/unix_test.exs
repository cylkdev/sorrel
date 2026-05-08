defmodule Sorrel.Transport.UnixTest do
  use ExUnit.Case, async: true

  alias Sorrel.Endpoint
  alias Sorrel.Transport
  alias Sorrel.Transport.Unix, as: UnixTransport

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp tmp_socket_path do
    Path.join(
      System.tmp_dir!(),
      "docker-transport-unix-test-#{System.unique_integer([:positive])}.sock"
    )
  end

  defp ping_responder do
    fn _req ->
      {:close_after,
       "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 4\r\nConnection: close\r\n\r\nOK\r\n"}
    end
  end

  defp start_unix_server(socket_path, responder \\ nil) do
    responder = responder || ping_responder()

    {:ok, server} =
      FakeHttpServer.start(
        transport: :unix,
        socket_path: socket_path,
        responder: responder
      )

    on_exit(fn -> FakeHttpServer.stop(server) end)
    server
  end

  defp endpoint(path) do
    %Endpoint{transport: :unix, socket_path: path}
  end

  defp recv_full_response(conn, ref, acc \\ %{status: nil, body: ""}) do
    case Mint.HTTP.recv(conn, 0, 5_000) do
      {:ok, conn, responses} ->
        {acc2, done?} = absorb(responses, ref, acc)

        if done? do
          {:ok, conn, acc2}
        else
          recv_full_response(conn, ref, acc2)
        end

      {:error, conn, reason, _responses} ->
        {:error, conn, reason}
    end
  end

  defp absorb(responses, ref, acc) do
    Enum.reduce(responses, {acc, false}, fn
      {:status, ^ref, status}, {a, _} -> {%{a | status: status}, false}
      {:headers, ^ref, _}, {a, _} -> {a, false}
      {:data, ^ref, data}, {a, _} -> {%{a | body: a.body <> data}, false}
      {:done, ^ref}, {a, _} -> {a, true}
      _, acc_done -> acc_done
    end)
  end

  # ---------------------------------------------------------------------------
  # Success: round trip a real HTTP/1.1 request through the unix socket.
  # ---------------------------------------------------------------------------

  describe "connect/2 success" do
    test "returns {:ok, %Mint.HTTP1{}} and round-trips a request" do
      socket_path = tmp_socket_path()
      _server = start_unix_server(socket_path)
      ep = endpoint(socket_path)

      assert {:ok, conn} = UnixTransport.connect(ep)
      # The handle is a Mint.HTTP1 connection record.
      assert is_struct(conn, Mint.HTTP1)

      assert {:ok, conn, ref} =
               Mint.HTTP.request(conn, "GET", "/_ping", [{"host", "localhost"}], "")

      assert {:ok, _conn, %{status: 200, body: "OK\r\n"}} = recv_full_response(conn, ref)
    end

    test "honours :connect_timeout option" do
      socket_path = tmp_socket_path()
      _server = start_unix_server(socket_path)
      ep = endpoint(socket_path)

      assert {:ok, _conn} = UnixTransport.connect(ep, connect_timeout: 5_000)
    end
  end

  # ---------------------------------------------------------------------------
  # Failure: socket file missing.
  # ---------------------------------------------------------------------------

  describe "connect/2 failures" do
    test "returns {:error, :enoent} when the socket file does not exist" do
      missing_path =
        Path.join(System.tmp_dir!(), "docker-no-such-#{System.unique_integer([:positive])}.sock")

      refute File.exists?(missing_path)
      ep = endpoint(missing_path)

      assert {:error, %Mint.TransportError{reason: :enoent}} = UnixTransport.connect(ep)
    end

    # NOTE on :eacces and :timeout (both documented in @doc):
    #
    #   :eacces — surfaces from the OS when the calling user lacks permission
    #   to connect to the socket inode. Reproducing this deterministically in
    #   a unit test would require chmod-ing a socket and dropping privileges,
    #   which is environment-dependent and brittle on CI/macOS. The doc
    #   mentions :eacces because it is a real OS-level outcome; we omit a
    #   test rather than fake-pass one.
    #
    #   :timeout — :gen_tcp's connect against a missing AF_UNIX path returns
    #   :enoent immediately (faster than any wall-clock timeout we could set),
    #   and there is no analogue of "saturating the listen backlog" for
    #   AF_UNIX that surfaces as :timeout from connect/4 in any portable way.
    #   The doc still mentions :timeout because Mint's connect_timeout WILL
    #   fire if a slow filesystem call (e.g. autofs) blocks the connect
    #   syscall — we just cannot reproduce that condition deterministically.
  end

  # ---------------------------------------------------------------------------
  # Dispatcher: Sorrel.Transport.connect/2 routes :unix endpoints here.
  # ---------------------------------------------------------------------------

  describe "Sorrel.Transport.connect/2 dispatch" do
    test "routes a :unix endpoint to Sorrel.Transport.Unix" do
      socket_path = tmp_socket_path()
      _server = start_unix_server(socket_path)
      ep = endpoint(socket_path)

      assert {:ok, conn} = Transport.connect(ep)
      assert is_struct(conn, Mint.HTTP1)
    end

    test "raises FunctionClauseError on a corrupted endpoint struct" do
      bad = %Endpoint{transport: :bogus, socket_path: nil}

      assert_raise FunctionClauseError, fn ->
        Transport.connect(bad)
      end
    end

    test "forwards opts (e.g. :connect_timeout) to the unix implementation" do
      socket_path = tmp_socket_path()
      _server = start_unix_server(socket_path)
      ep = endpoint(socket_path)

      assert {:ok, _conn} = Transport.connect(ep, connect_timeout: 2_000)
    end
  end
end

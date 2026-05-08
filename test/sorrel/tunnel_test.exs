defmodule Sorrel.TunnelTest do
  use ExUnit.Case, async: true

  alias Sorrel.Endpoint
  alias Sorrel.Tunnel

  defp unix_socket_path do
    Path.join(
      System.tmp_dir!(),
      "docker-streaming-tunnel-#{System.unique_integer([:positive])}.sock"
    )
  end

  defp unix_endpoint(socket_path) do
    %Endpoint{transport: :unix, socket_path: socket_path}
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

  describe "public surface" do
    test "exports upgrade/4, send/2, recv/3, close/1" do
      assert function_exported?(Tunnel, :upgrade, 4)
      assert function_exported?(Tunnel, :send, 2)
      assert function_exported?(Tunnel, :recv, 3)
      assert function_exported?(Tunnel, :close, 1)
    end
  end

  describe "upgrade/4" do
    test "returns {:error, :endpoint_required} when no endpoint option is supplied" do
      assert {:error, :endpoint_required} =
               Tunnel.upgrade(:post, "/x", "", [])
    end

    test "returns the upgraded socket and any leftover bytes on 101" do
      socket_path = unix_socket_path()

      _server =
        start_unix_server(socket_path, fn _request ->
          {:close_after, "HTTP/1.1 101 Switching Protocols\r\n\r\nLEFT"}
        end)

      assert {:ok, socket, "LEFT"} =
               Tunnel.upgrade(:post, "/v1.45/containers/x/attach", "",
                 endpoint: unix_endpoint(socket_path)
               )

      assert is_port(socket)
      :ok = Tunnel.close(socket)
    end

    test "surfaces non-101/200 status as {:error, %{status: ...}}" do
      socket_path = unix_socket_path()

      _server =
        start_unix_server(socket_path, fn _request ->
          {:close_after, "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nno such x"}
        end)

      assert {:error, %{status: 404}} =
               Tunnel.upgrade(:post, "/v1.45/containers/missing/attach", "",
                 endpoint: unix_endpoint(socket_path)
               )
    end
  end

  describe "recv/3 + close/1 over the upgraded socket" do
    test "recv/3 returns the leftover bytes the server sent post-upgrade" do
      socket_path = unix_socket_path()

      _server =
        start_unix_server(socket_path, fn _request ->
          {:close_after, "HTTP/1.1 101 Switching Protocols\r\n\r\nPOST_UPGRADE_BYTES"}
        end)

      assert {:ok, socket, "POST_UPGRADE_BYTES"} =
               Tunnel.upgrade(:post, "/v1.45/containers/x/attach", "",
                 endpoint: unix_endpoint(socket_path)
               )

      # Peer closed cleanly after sending the leftover; recv surfaces :closed.
      assert {:error, :closed} = Tunnel.recv(socket, 0, 200)
      assert :ok = Tunnel.close(socket)
    end

    test "send/2 surfaces transport errors after the peer has closed" do
      socket_path = unix_socket_path()

      _server =
        start_unix_server(socket_path, fn _request ->
          {:close_after, "HTTP/1.1 101 Switching Protocols\r\n\r\n"}
        end)

      assert {:ok, socket, ""} =
               Tunnel.upgrade(:post, "/v1.45/containers/x/attach", "",
                 endpoint: unix_endpoint(socket_path)
               )

      # Drain the close so the kernel marks the socket closed for us.
      _ = Tunnel.recv(socket, 0, 200)
      assert {:error, _reason} = Tunnel.send(socket, "after-close\n")
    end

    test "close/1 is idempotent" do
      socket_path = unix_socket_path()

      _server =
        start_unix_server(socket_path, fn _request ->
          {:close_after, "HTTP/1.1 101 Switching Protocols\r\n\r\n"}
        end)

      assert {:ok, socket, ""} =
               Tunnel.upgrade(:post, "/v1.45/containers/x/attach", "",
                 endpoint: unix_endpoint(socket_path)
               )

      assert :ok = Tunnel.close(socket)
      assert :ok = Tunnel.close(socket)
    end
  end
end

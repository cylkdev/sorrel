defmodule Sorrel.Tunnel.SocketTest do
  use ExUnit.Case, async: true

  alias Sorrel.Tunnel.Socket

  setup do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw])
    {:ok, port} = :inet.port(listener)
    {:ok, listener: listener, port: port}
  end

  test "send/2 then recv/3 round-trips bytes", %{listener: listener, port: port} do
    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
    {:ok, server} = :gen_tcp.accept(listener)

    assert :ok = Socket.send(client, "hello")
    assert {:ok, "hello"} = Socket.recv(server, 5, 1_000)
  end

  test "recv/3 returns {:error, :timeout} when nothing arrives", %{listener: listener, port: port} do
    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
    {:ok, _server} = :gen_tcp.accept(listener)

    assert {:error, :timeout} = Socket.recv(client, 0, 50)
  end

  test "send/2 returns {:error, :closed} after peer close", %{listener: listener, port: port} do
    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
    {:ok, server} = :gen_tcp.accept(listener)

    :ok = :gen_tcp.close(server)
    # After peer close, the FIN may take a moment to propagate on the
    # local TCP stack. Send repeatedly until we observe the error.
    result =
      Enum.reduce_while(1..50, :ok, fn _, _ ->
        case Socket.send(client, "x") do
          :ok ->
            Process.sleep(10)
            {:cont, :ok}

          {:error, _} = err ->
            {:halt, err}
        end
      end)

    assert {:error, _} = result
  end

  test "close/1 is idempotent", %{listener: listener, port: port} do
    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
    {:ok, _server} = :gen_tcp.accept(listener)

    assert :ok = Socket.close(client)
    assert :ok = Socket.close(client)
  end
end

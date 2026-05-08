defmodule Sorrel.Transport.SSH.BridgeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Sorrel.Transport.SSH.Bridge

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # The bridge takes opaque values for `ssh_conn` and `channel_id`; in
  # these tests we use sentinel atoms/integers and inject test functions
  # for the SSH-side operations that report back to the test process.
  @fake_ssh_conn :fake_ssh_conn
  @fake_channel_id 0

  defp start_bridge(overrides \\ []) do
    test_pid = self()

    defaults = [
      ssh_conn: @fake_ssh_conn,
      channel_id: @fake_channel_id,
      owner: test_pid,
      accept_timeout: 1_000,
      ssh_send_fun: fn ssh_conn, channel_id, data ->
        send(test_pid, {:ssh_send, ssh_conn, channel_id, IO.iodata_to_binary(data)})
        :ok
      end,
      ssh_close_fun: fn ssh_conn, channel_id ->
        send(test_pid, {:ssh_close, ssh_conn, channel_id})
        :ok
      end,
      ssh_conn_close_fun: fn ssh_conn ->
        send(test_pid, {:ssh_conn_close, ssh_conn})
        :ok
      end
    ]

    opts = Keyword.merge(defaults, overrides)
    Bridge.start_link(opts)
  end

  # Connects a client to the bridge's loopback listener so the bridge
  # transitions out of accept-wait state.
  defp connect_client(port) do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 1_000)

    # Give the bridge a moment to take controlling-process ownership and
    # activate the socket. A tiny sleep is the simplest signal here;
    # the only other option (peeking at the bridge's state) is more
    # invasive than it's worth for a test.
    Process.sleep(20)
    sock
  end

  # ---------------------------------------------------------------------------
  # start_link/1: listener bound, port returned, byte-pumping loopback → SSH.
  # ---------------------------------------------------------------------------

  describe "start_link/1 success" do
    test "returns a port that a client can connect to and forwards bytes to the SSH side" do
      assert {:ok, %{port: port, bridge: bridge}} = start_bridge()
      assert is_integer(port) and port > 0
      assert is_pid(bridge) and Process.alive?(bridge)

      client = connect_client(port)
      :ok = :gen_tcp.send(client, "hello-from-mint")

      assert_receive {:ssh_send, @fake_ssh_conn, @fake_channel_id, "hello-from-mint"}, 500

      :gen_tcp.close(client)
    end
  end

  # ---------------------------------------------------------------------------
  # SSH → loopback: an injected {:ssh_cm, ..., {:data, ...}} reaches the
  # connected client over the loopback socket.
  # ---------------------------------------------------------------------------

  describe "SSH → loopback pumping" do
    test "writes bytes received from the SSH channel to the connected client" do
      assert {:ok, %{port: port, bridge: bridge}} = start_bridge()
      client = connect_client(port)

      send(bridge, {:ssh_cm, @fake_ssh_conn, {:data, @fake_channel_id, 0, "hello-from-remote"}})

      assert {:ok, "hello-from-remote"} = :gen_tcp.recv(client, 17, 1_000)

      :gen_tcp.close(client)
    end
  end

  # ---------------------------------------------------------------------------
  # Half-close semantics: loopback close → bridge exits :normal and SSH
  # close hooks fire.
  # ---------------------------------------------------------------------------

  describe "loopback close" do
    test "closing the client socket causes the bridge to exit :normal and close SSH" do
      assert {:ok, %{port: port, bridge: bridge}} = start_bridge()
      ref = Process.monitor(bridge)
      client = connect_client(port)

      :ok = :gen_tcp.close(client)

      assert_receive {:DOWN, ^ref, :process, ^bridge, :normal}, 1_000
      assert_receive {:ssh_close, @fake_ssh_conn, @fake_channel_id}, 500
      assert_receive {:ssh_conn_close, @fake_ssh_conn}, 500
    end
  end

  # ---------------------------------------------------------------------------
  # Half-close: SSH-side close → loopback socket gets closed.
  # ---------------------------------------------------------------------------

  describe "SSH close" do
    test "an {:ssh_cm, _, {:closed, chan}} message closes the loopback client socket" do
      assert {:ok, %{port: port, bridge: bridge}} = start_bridge()
      ref = Process.monitor(bridge)
      client = connect_client(port)

      send(bridge, {:ssh_cm, @fake_ssh_conn, {:closed, @fake_channel_id}})

      # The client should observe the loopback socket closing.
      assert {:error, :closed} = :gen_tcp.recv(client, 0, 1_000)
      assert_receive {:DOWN, ^ref, :process, ^bridge, :normal}, 1_000

      # On peer-driven channel close, the bridge skips ssh_close_fun
      # (the channel is already gone) but still closes the connection.
      assert_receive {:ssh_conn_close, @fake_ssh_conn}, 500
      refute_receive {:ssh_close, @fake_ssh_conn, @fake_channel_id}, 50
    end
  end

  # ---------------------------------------------------------------------------
  # Accept timeout: no client → bridge exits {:shutdown, :accept_timeout}.
  # ---------------------------------------------------------------------------

  describe "accept timeout" do
    test "exits {:shutdown, :accept_timeout} when nothing connects in time" do
      # Trap exits because the bridge links to `owner` (this test pid),
      # so the bridge's exit otherwise propagates here as a kill.
      Process.flag(:trap_exit, true)

      assert {:ok, %{port: _port, bridge: bridge}} = start_bridge(accept_timeout: 100)
      ref = Process.monitor(bridge)

      assert_receive {:DOWN, ^ref, :process, ^bridge, {:shutdown, :accept_timeout}}, 1_000
      assert_receive {:ssh_close, @fake_ssh_conn, @fake_channel_id}, 500
      assert_receive {:ssh_conn_close, @fake_ssh_conn}, 500
    end
  end

  # ---------------------------------------------------------------------------
  # Owner-death tear-down.
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Remote exec failure surfacing.
  #
  # When a remote `exec` request runs a command that does not exist or
  # exits non-zero BEFORE producing any response bytes, the bridge must
  # surface that as a typed `{:shutdown, {:ssh_exec_failed, _}}` reason
  # rather than a clean `:normal` exit. The boundary is whether ANY
  # bytes have already been forwarded toward Mint: once bytes have left
  # the bridge, Mint may have parsed an HTTP response and we cannot
  # invent an error without corrupting the caller's view.
  # ---------------------------------------------------------------------------

  describe "exec failure surfacing — pre-connect" do
    test "non-zero exit_status followed by close before client connects → :ssh_exec_failed" do
      Process.flag(:trap_exit, true)

      assert {:ok, %{port: port, bridge: bridge}} = start_bridge()
      ref = Process.monitor(bridge)

      # Inject an exec failure: program ran, exited 127, channel closed.
      # The bridge must capture the exit_status, defer until the client
      # connects (so the listener is still bound and Mint can see a
      # connect-success), then poison the accept by closing the just-
      # accepted socket and stopping with a typed shutdown reason.
      send(bridge, {:ssh_cm, @fake_ssh_conn, {:exit_status, @fake_channel_id, 127}})
      send(bridge, {:ssh_cm, @fake_ssh_conn, {:closed, @fake_channel_id}})

      # Connect a client to trigger the accept-time poisoning branch.
      # The connect itself may succeed, but the bridge will close the
      # socket immediately and exit with the typed reason.
      _ = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)

      assert_receive {:DOWN, ^ref, :process, ^bridge,
                      {:shutdown, {:ssh_exec_failed, {:status, 127}}}},
                     1_000
    end

    test "exit_signal followed by close before client connects → :ssh_exec_failed (signal)" do
      Process.flag(:trap_exit, true)

      assert {:ok, %{port: port, bridge: bridge}} = start_bridge()
      ref = Process.monitor(bridge)

      send(
        bridge,
        {:ssh_cm, @fake_ssh_conn, {:exit_signal, @fake_channel_id, ~c"TERM", ~c"", ~c""}}
      )

      send(bridge, {:ssh_cm, @fake_ssh_conn, {:closed, @fake_channel_id}})

      _ = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)

      assert_receive {:DOWN, ^ref, :process, ^bridge,
                      {:shutdown, {:ssh_exec_failed, {:signal, "TERM"}}}},
                     1_000
    end

    test "exit_status 0 followed by close before client connects → :normal (no error)" do
      Process.flag(:trap_exit, true)

      assert {:ok, %{port: port, bridge: bridge}} = start_bridge()
      ref = Process.monitor(bridge)

      # Exit code 0 is a clean finish — the program ran and succeeded
      # but produced no body. This is unusual but not an error.
      send(bridge, {:ssh_cm, @fake_ssh_conn, {:exit_status, @fake_channel_id, 0}})
      send(bridge, {:ssh_cm, @fake_ssh_conn, {:closed, @fake_channel_id}})

      _ = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)

      assert_receive {:DOWN, ^ref, :process, ^bridge, :normal}, 1_000
    end

    test "no exit_status, just close before client connects → :normal (legacy path)" do
      Process.flag(:trap_exit, true)

      assert {:ok, %{port: port, bridge: bridge}} = start_bridge()
      ref = Process.monitor(bridge)

      # No exit_status was emitted: the channel just closed (e.g. peer
      # forcibly tore it down). Treat as :normal to preserve the
      # existing behaviour for non-exec channel types (direct-tcpip,
      # direct-streamlocal) which never emit exit_status.
      send(bridge, {:ssh_cm, @fake_ssh_conn, {:closed, @fake_channel_id}})

      _ = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)

      assert_receive {:DOWN, ^ref, :process, ^bridge, :normal}, 1_000
    end
  end

  describe "exec failure surfacing — bytes already forwarded" do
    test "bytes flushed to Mint then non-zero exit → :normal (intentional tradeoff)" do
      # If a response has already been delivered to Mint, surfacing a
      # late exit_status would corrupt the caller's view: Mint has
      # parsed the response and acted on it. We deliberately keep
      # mid-stream exit failures invisible — see the comment in
      # bridge.ex on `bytes_forwarded?`.
      Process.flag(:trap_exit, true)

      assert {:ok, %{port: port, bridge: bridge}} = start_bridge()
      ref = Process.monitor(bridge)
      client = connect_client(port)

      # Bytes flow through to the connected client.
      send(bridge, {:ssh_cm, @fake_ssh_conn, {:data, @fake_channel_id, 0, "HTTP/1.1 200 OK\r\n"}})
      assert {:ok, "HTTP/1.1 200 OK\r\n"} = :gen_tcp.recv(client, 17, 1_000)

      # Now inject a non-zero exit and close. Because bytes have already
      # been forwarded, the bridge must still exit :normal.
      send(bridge, {:ssh_cm, @fake_ssh_conn, {:exit_status, @fake_channel_id, 1}})
      send(bridge, {:ssh_cm, @fake_ssh_conn, {:closed, @fake_channel_id}})

      assert_receive {:DOWN, ^ref, :process, ^bridge, :normal}, 1_000

      :gen_tcp.close(client)
    end

    test "buffered SSH bytes flushed at accept-time count as 'forwarded'" do
      # If SSH-side bytes arrived before the client connected, the
      # bridge buffered them in `pending_ssh_data` and flushes them on
      # accept. Those bytes have crossed the boundary toward Mint, so a
      # subsequent non-zero exit must NOT be surfaced as a typed error.
      Process.flag(:trap_exit, true)

      assert {:ok, %{port: port, bridge: bridge}} = start_bridge()
      ref = Process.monitor(bridge)

      # Buffer a response, then signal a non-zero exit, then close.
      send(bridge, {:ssh_cm, @fake_ssh_conn, {:data, @fake_channel_id, 0, "HTTP/1.1 200 OK\r\n"}})
      send(bridge, {:ssh_cm, @fake_ssh_conn, {:exit_status, @fake_channel_id, 1}})
      send(bridge, {:ssh_cm, @fake_ssh_conn, {:closed, @fake_channel_id}})

      # Connect AFTER the buffered bytes and the close were queued.
      # The bridge will flush, then close the socket. Because bytes
      # were forwarded, exit reason must be :normal.
      {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)
      _ = :gen_tcp.recv(client, 0, 200)

      assert_receive {:DOWN, ^ref, :process, ^bridge, :normal}, 1_000
      :gen_tcp.close(client)
    end
  end

  describe "exec failure surfacing — post-connect, pre-bytes" do
    test "non-zero exit AFTER client connects but before any bytes flow → :ssh_exec_failed" do
      # The variant where the client wins the race: it connected to
      # the loopback BEFORE the remote exec failed. No bytes have
      # crossed yet, so the typed error is still safe to surface.
      Process.flag(:trap_exit, true)

      assert {:ok, %{port: port, bridge: bridge}} = start_bridge()
      ref = Process.monitor(bridge)
      _client = connect_client(port)

      send(bridge, {:ssh_cm, @fake_ssh_conn, {:exit_status, @fake_channel_id, 127}})
      send(bridge, {:ssh_cm, @fake_ssh_conn, {:closed, @fake_channel_id}})

      assert_receive {:DOWN, ^ref, :process, ^bridge,
                      {:shutdown, {:ssh_exec_failed, {:status, 127}}}},
                     1_000
    end
  end

  describe "owner death" do
    test "owner exit tears down the bridge and triggers SSH cleanup" do
      test_pid = self()

      # The bridge's GenServer logs an [error] when its linked owner
      # exits abnormally; that's the behaviour we're testing, so capture
      # the log to keep the test output clean.
      capture_log(fn ->
        # Run the start in a dedicated process whose death we can drive.
        owner_starter =
          spawn(fn ->
            {:ok, %{bridge: bridge}} =
              Bridge.start_link(
                ssh_conn: @fake_ssh_conn,
                channel_id: @fake_channel_id,
                owner: self(),
                accept_timeout: 5_000,
                ssh_send_fun: fn _, _, _ -> :ok end,
                ssh_close_fun: fn ssh_conn, channel_id ->
                  send(test_pid, {:ssh_close, ssh_conn, channel_id})
                  :ok
                end,
                ssh_conn_close_fun: fn ssh_conn ->
                  send(test_pid, {:ssh_conn_close, ssh_conn})
                  :ok
                end
              )

            send(test_pid, {:bridge, bridge})

            receive do
              :die -> exit(:owner_requested_shutdown)
            end
          end)

        assert_receive {:bridge, bridge}, 1_000
        ref = Process.monitor(bridge)

        send(owner_starter, :die)

        assert_receive {:DOWN, ^ref, :process, ^bridge, _reason}, 1_000
        assert_receive {:ssh_close, @fake_ssh_conn, @fake_channel_id}, 500
        assert_receive {:ssh_conn_close, @fake_ssh_conn}, 500
      end)
    end
  end
end

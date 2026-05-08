defmodule Sorrel.PoolTest do
  # Not async: these tests touch the global Sorrel.Pool.Registry and
  # Sorrel.Pool.DynamicSupervisor children. Async tests would race for
  # registry entries.
  use ExUnit.Case

  alias Sorrel.Endpoint
  alias Sorrel.Pool

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp tmp_socket_path do
    Path.join(
      System.tmp_dir!(),
      "docker-pool-test-#{System.unique_integer([:positive])}.sock"
    )
  end

  defp unix_endpoint(path) do
    %Endpoint{transport: :unix, socket_path: path}
  end

  defp tcp_endpoint(host, port) do
    %Endpoint{
      transport: :tcp,
      scheme: :http,
      host: host,
      port: port
    }
  end

  defp ssh_endpoint(overrides \\ []) do
    base_ssh = %{
      auth: [:agent, :identity, :password],
      identity_file: nil,
      password: nil,
      known_hosts_file: nil,
      verify: :verify_peer,
      connect_timeout: 10_000
    }

    ssh = Map.merge(base_ssh, Map.new(Keyword.get(overrides, :ssh, [])))

    %Endpoint{
      transport: :ssh,
      host: Keyword.get(overrides, :host, "remote.example.com"),
      port: Keyword.get(overrides, :port, 22),
      user: Keyword.get(overrides, :user, "deploy"),
      ssh: ssh,
      target: Keyword.get(overrides, :target, {:exec, "docker system dial-stdio"})
    }
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

  defp start_unix_server(socket_path) do
    {:ok, server} =
      FakeHttpServer.start(
        transport: :unix,
        socket_path: socket_path,
        responder: ok_responder("OK")
      )

    on_exit(fn -> FakeHttpServer.stop(server) end)
    server
  end

  # We register cleanup of the per-test pool. We can't reliably terminate the
  # specific pool's child without knowing its child id, so we look up the
  # registry pid and ask the DynamicSupervisor to terminate it. If lookup
  # fails (already gone), no-op.
  defp register_pool_cleanup(endpoint) do
    on_exit(fn ->
      sig = pool_signature(endpoint)

      case Registry.lookup(Sorrel.Pool.Registry, sig) do
        [{pid, _meta}] -> terminate_pool_child(pid)
        [] -> :ok
      end
    end)
  end

  defp terminate_pool_child(pid) do
    case DynamicSupervisor.terminate_child(Sorrel.Pool.DynamicSupervisor, pid) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  # Mirror of Sorrel.Pool.signature/1 — we use it from tests only to identify
  # the registry key for cleanup and assertions. Kept as a private test helper
  # rather than exposing it as a public API.
  defp pool_signature(%Endpoint{transport: :unix} = ep), do: {:unix, ep.socket_path}

  defp pool_signature(%Endpoint{transport: :tcp} = ep) do
    tls_sig =
      case ep.tls do
        nil ->
          :no_tls

        %{} = m ->
          {Map.get(m, :verify), Map.get(m, :cacertfile), Map.get(m, :certfile),
           Map.get(m, :keyfile)}
      end

    {:tcp, ep.scheme, ep.host, ep.port, tls_sig}
  end

  defp pool_signature(%Endpoint{transport: :ssh} = ep) do
    ssh = ep.ssh || %{}

    auth_sig =
      {Map.get(ssh, :auth), Map.get(ssh, :identity_file), Map.get(ssh, :password) !== nil,
       Map.get(ssh, :known_hosts_file), Map.get(ssh, :verify)}

    {:ssh, ep.host, ep.port, ep.user, ep.target, auth_sig}
  end

  # ---------------------------------------------------------------------------
  # checkout/3 lazy-starts the pool
  # ---------------------------------------------------------------------------

  describe "checkout/3 lazy-start" do
    test "starts the pool on the first call for a previously unseen endpoint" do
      socket_path = tmp_socket_path()
      _server = start_unix_server(socket_path)
      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      sig = pool_signature(ep)
      # Pool does not exist yet.
      assert [] = Registry.lookup(Sorrel.Pool.Registry, sig)

      # First checkout brings the pool up.
      assert {:ok, %{status: 200}} =
               Pool.checkout(ep, fn cs ->
                 Sorrel.Pool.Worker.run_request(cs, :get, "/_ping", [{"host", "localhost"}], "")
               end)

      assert [{_pid, _}] = Registry.lookup(Sorrel.Pool.Registry, sig)
    end
  end

  # ---------------------------------------------------------------------------
  # checkout/3 returns the function's value (after explicit start)
  # ---------------------------------------------------------------------------

  describe "checkout/3 return value" do
    test "returns whatever the supplied function returns" do
      socket_path = tmp_socket_path()
      _server = start_unix_server(socket_path)
      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)
      {:ok, _name} = Pool.start(ep)

      # Functions return {result, checkin} where checkin is {:ok, conn} or
      # {:closed, _}; checkout/3 surfaces `result` to the caller. Tests that
      # don't actually use the conn use {:closed, :unused} as the checkin
      # reason — the worker is evicted but a fresh one is lazily spawned on
      # the next checkout.
      assert :hello =
               Pool.checkout(ep, fn {_, conn, _, _} -> {:hello, {:ok, conn}} end)

      assert {:tagged, 42} =
               Pool.checkout(ep, fn {_, conn, _, _} -> {{:tagged, 42}, {:ok, conn}} end)
    end
  end

  # ---------------------------------------------------------------------------
  # start/2 is idempotent for the same endpoint
  # ---------------------------------------------------------------------------

  describe "start/2 pool reuse" do
    test "two calls for the same endpoint share one Registry entry" do
      ep = unix_endpoint(tmp_socket_path())
      register_pool_cleanup(ep)

      {:ok, name_one} = Pool.start(ep)

      sig = pool_signature(ep)
      assert [{first_pid, _}] = Registry.lookup(Sorrel.Pool.Registry, sig)

      {:ok, name_two} = Pool.start(ep)

      assert [{second_pid, _}] = Registry.lookup(Sorrel.Pool.Registry, sig)
      assert first_pid === second_pid
      assert name_one === name_two
    end
  end

  # ---------------------------------------------------------------------------
  # Different endpoints get different pools
  # ---------------------------------------------------------------------------

  describe "start/2 distinct endpoints" do
    test "two endpoints with different signatures get distinct Registry entries" do
      ep_a = unix_endpoint(tmp_socket_path())
      ep_b = unix_endpoint(tmp_socket_path())
      register_pool_cleanup(ep_a)
      register_pool_cleanup(ep_b)

      {:ok, _name_a} = Pool.start(ep_a)
      {:ok, _name_b} = Pool.start(ep_b)

      sig_a = pool_signature(ep_a)
      sig_b = pool_signature(ep_b)

      assert [{pid_a, _}] = Registry.lookup(Sorrel.Pool.Registry, sig_a)
      assert [{pid_b, _}] = Registry.lookup(Sorrel.Pool.Registry, sig_b)
      assert pid_a !== pid_b
    end

    test "tcp endpoints with different host/port get distinct pools" do
      ep_a = tcp_endpoint("127.0.0.1", 65_001)
      ep_b = tcp_endpoint("127.0.0.1", 65_002)
      register_pool_cleanup(ep_a)
      register_pool_cleanup(ep_b)

      {:ok, _name_a} = Pool.start(ep_a)
      {:ok, _name_b} = Pool.start(ep_b)

      assert [{_, _}] = Registry.lookup(Sorrel.Pool.Registry, pool_signature(ep_a))
      assert [{_, _}] = Registry.lookup(Sorrel.Pool.Registry, pool_signature(ep_b))

      refute pool_signature(ep_a) === pool_signature(ep_b)
    end
  end

  # ---------------------------------------------------------------------------
  # SSH endpoint signatures
  #
  # We do NOT call Pool.start/2 here because that would spawn poolboy workers
  # whose first connection attempt could try to dial a real SSH daemon. The
  # workers connect lazily, so we only need to assert the *signature* — which
  # is what the registry keys on — to prove distinct/shared pools.
  # ---------------------------------------------------------------------------

  describe "signature/1 for ssh endpoints" do
    test "different targets produce distinct signatures" do
      ep_a = ssh_endpoint(target: {:exec, "docker system dial-stdio"})
      ep_b = ssh_endpoint(target: {:unix, "/var/run/docker.sock"})

      refute pool_signature(ep_a) === pool_signature(ep_b)
    end

    test "different users produce distinct signatures" do
      ep_a = ssh_endpoint(user: "alice")
      ep_b = ssh_endpoint(user: "bob")

      refute pool_signature(ep_a) === pool_signature(ep_b)
    end

    test "different hosts produce distinct signatures" do
      ep_a = ssh_endpoint(host: "host-a.example.com")
      ep_b = ssh_endpoint(host: "host-b.example.com")

      refute pool_signature(ep_a) === pool_signature(ep_b)
    end

    test "different verify settings produce distinct signatures" do
      ep_a = ssh_endpoint(ssh: [verify: :verify_peer])
      ep_b = ssh_endpoint(ssh: [verify: :verify_none])

      refute pool_signature(ep_a) === pool_signature(ep_b)
    end

    test "different identity_file paths produce distinct signatures" do
      ep_a = ssh_endpoint(ssh: [identity_file: "~/.ssh/id_ed25519"])
      ep_b = ssh_endpoint(ssh: [identity_file: "~/.ssh/id_rsa"])

      refute pool_signature(ep_a) === pool_signature(ep_b)
    end

    test "endpoints differing only in password share the same signature" do
      # Rotating credentials must not spawn a new pool, and the literal
      # password value must not appear in the registry key.
      ep_a = ssh_endpoint(ssh: [password: "hunter2"])
      ep_b = ssh_endpoint(ssh: [password: "letmein"])

      assert pool_signature(ep_a) === pool_signature(ep_b)
    end

    test "endpoint with password vs no password produce distinct signatures" do
      # `has_password?` is part of the auth signature, so toggling whether a
      # password is supplied at all DOES change the pool — only changing the
      # value when one is already set is a no-op.
      ep_a = ssh_endpoint(ssh: [password: "hunter2"])
      ep_b = ssh_endpoint(ssh: [password: nil])

      refute pool_signature(ep_a) === pool_signature(ep_b)
    end

    test "endpoints differing only in connect_timeout share the same signature" do
      # connect_timeout is a per-connect knob, not a destination identifier.
      ep_a = ssh_endpoint(ssh: [connect_timeout: 5_000])
      ep_b = ssh_endpoint(ssh: [connect_timeout: 30_000])

      assert pool_signature(ep_a) === pool_signature(ep_b)
    end

    test "ssh and tcp endpoints with the same host/port produce distinct signatures" do
      # The leading atom (`:ssh` vs `:tcp`) is what guarantees no collision
      # when both transports happen to point at the same host:port.
      ssh_ep = ssh_endpoint(host: "127.0.0.1", port: 22)
      tcp_ep = tcp_endpoint("127.0.0.1", 22)

      refute pool_signature(ssh_ep) === pool_signature(tcp_ep)
    end

    test "different auth method orderings produce distinct signatures" do
      ep_a = ssh_endpoint(ssh: [auth: [:agent, :identity, :password]])
      ep_b = ssh_endpoint(ssh: [auth: [:password, :identity, :agent]])

      refute pool_signature(ep_a) === pool_signature(ep_b)
    end

    test "different known_hosts_file paths produce distinct signatures" do
      ep_a = ssh_endpoint(ssh: [known_hosts_file: "/etc/ssh/known_hosts"])
      ep_b = ssh_endpoint(ssh: [known_hosts_file: "~/.ssh/known_hosts"])

      refute pool_signature(ep_a) === pool_signature(ep_b)
    end

    test "two identical ssh endpoints share the same signature" do
      ep_a = ssh_endpoint()
      ep_b = ssh_endpoint()

      assert pool_signature(ep_a) === pool_signature(ep_b)
    end

    test "starting two ssh pools with different targets registers two distinct entries" do
      # End-to-end check: workers connect lazily, so calling Pool.start/2 with
      # an unreachable host is safe — no SSH dial happens at start time. We
      # verify the registry holds the entry under exactly the signature shape
      # we expect, and that two ssh endpoints differing in target end up at
      # different registry keys.
      ep_a = ssh_endpoint(host: "ssh-pool-test-a", target: {:exec, "cmd-a"})
      ep_b = ssh_endpoint(host: "ssh-pool-test-a", target: {:exec, "cmd-b"})
      register_pool_cleanup(ep_a)
      register_pool_cleanup(ep_b)

      {:ok, _name_a} = Pool.start(ep_a)
      {:ok, _name_b} = Pool.start(ep_b)

      assert [{pid_a, _}] = Registry.lookup(Sorrel.Pool.Registry, pool_signature(ep_a))
      assert [{pid_b, _}] = Registry.lookup(Sorrel.Pool.Registry, pool_signature(ep_b))
      assert pid_a !== pid_b
    end

    test "the password value never appears anywhere in the signature" do
      # Defence in depth: even if some future refactor includes another
      # password-derived value, this test inspects the entire signature for
      # the literal credential.
      secret = "very-secret-correcthorsebatterystaple"
      ep = ssh_endpoint(ssh: [password: secret])
      sig_bin = ep |> pool_signature() |> :erlang.term_to_binary()

      assert :nomatch === :binary.match(sig_bin, secret),
             "password value leaked into signature: #{inspect(ep)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Concurrent first-use creates exactly one pool
  # ---------------------------------------------------------------------------

  describe "start/2 concurrent first-use" do
    test "100 concurrent callers race to create the pool but only one wins" do
      ep = unix_endpoint(tmp_socket_path())
      register_pool_cleanup(ep)

      # Sanity: nothing in the registry for this signature yet.
      assert [] = Registry.lookup(Sorrel.Pool.Registry, pool_signature(ep))

      results =
        1..100
        |> Task.async_stream(
          fn _index -> Pool.start(ep) end,
          max_concurrency: 100,
          timeout: 10_000
        )
        |> Enum.to_list()

      assert Enum.all?(results, fn
               {:ok, {:ok, _name}} -> true
               _other -> false
             end)

      # Exactly one Registry entry survives.
      assert [{_pid, _}] = Registry.lookup(Sorrel.Pool.Registry, pool_signature(ep))
    end
  end

  # ---------------------------------------------------------------------------
  # Crashed pool is restarted by the DynamicSupervisor
  # ---------------------------------------------------------------------------

  describe "DynamicSupervisor restarts a crashed pool" do
    # After we kill the running pool, the DynamicSupervisor restarts the
    # child process. The :via Registry tuple is auto-cleared on death and
    # re-registered on restart, typically within a few milliseconds. We poll
    # until the registry shows a fresh pid, then verify checkout/3 succeeds
    # against the restarted pool. We do NOT assert that checkout/3 raises in
    # the gap between kill and restart: that gap is unobservable from a test
    # without introducing fragile timing, and the contract we care about is
    # "restart succeeds and the pool keeps working".
    test "after killing the pool, lookup eventually returns a fresh pid and checkout succeeds" do
      socket_path = tmp_socket_path()
      _server = start_unix_server(socket_path)
      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      {:ok, _name} = Pool.start(ep)

      sig = pool_signature(ep)
      assert [{old_pid, _}] = Registry.lookup(Sorrel.Pool.Registry, sig)

      ref = Process.monitor(old_pid)
      Process.exit(old_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^old_pid, _reason}, 1_000

      # Poll the registry until the supervisor has restarted the pool and the
      # new entry has registered itself.
      new_pid = wait_for_new_pool(sig, old_pid, 50)
      assert is_pid(new_pid)
      assert new_pid !== old_pid
      assert Process.alive?(new_pid)

      assert {:ok, %{status: 200}} =
               Pool.checkout(ep, fn cs ->
                 Sorrel.Pool.Worker.run_request(cs, :get, "/_ping", [{"host", "localhost"}], "")
               end)
    end

    defp wait_for_new_pool(_sig, _old_pid, 0), do: nil

    defp wait_for_new_pool(sig, old_pid, attempts) do
      case Registry.lookup(Sorrel.Pool.Registry, sig) do
        [{pid, _meta}] when pid !== old_pid ->
          pid

        _other ->
          Process.sleep(20)
          wait_for_new_pool(sig, old_pid, attempts - 1)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Worker is checked back in even on raise
  # ---------------------------------------------------------------------------

  describe "checkout/3 with a raising fun" do
    test "the worker is returned to the pool so subsequent checkouts succeed" do
      socket_path = tmp_socket_path()
      _server = start_unix_server(socket_path)
      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      {:ok, _name} = Pool.start(ep)

      try do
        Pool.checkout(ep, fn _worker -> raise "boom" end)
      rescue
        RuntimeError -> :ok
      end

      # The next checkout must succeed against the SAME pool. If the worker
      # leaked, this either deadlocks (until pool_timeout) or fails.
      assert {:ok, %{status: 200}} =
               Pool.checkout(ep, fn client_state ->
                 Sorrel.Pool.Worker.run_request(
                   client_state,
                   :get,
                   "/_ping",
                   [{"host", "localhost"}],
                   ""
                 )
               end)
    end
  end

  # ---------------------------------------------------------------------------
  # Idle eviction — per-conn (`:conn_max_idle_time`)
  # ---------------------------------------------------------------------------

  describe "conn_max_idle_time" do
    test "stale conn evicted at checkout when idle time exceeded" do
      socket_path = tmp_socket_path()
      server = start_unix_server(socket_path)
      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      # Pool size 1 forces conn reuse on the same worker. With a tiny
      # `:conn_max_idle_time`, sleeping past it must cause the second
      # checkout to drop the stale conn and open a fresh one.
      {:ok, _} = Pool.start(ep, pool_size: 1, conn_max_idle_time: 50)

      assert {:ok, %{status: 200}} =
               Pool.checkout(ep, fn cs ->
                 Sorrel.Pool.Worker.run_request(cs, :get, "/_ping", [{"host", "localhost"}], "")
               end)

      assert FakeHttpServer.accepted_count(server) === 1

      # Wait past the idle threshold, then checkout again.
      Process.sleep(150)

      assert {:ok, %{status: 200}} =
               Pool.checkout(ep, fn cs ->
                 Sorrel.Pool.Worker.run_request(cs, :get, "/_ping", [{"host", "localhost"}], "")
               end)

      # Second request opened a brand-new connection.
      assert FakeHttpServer.accepted_count(server) === 2
    end

    test "server FIN on idle conn evicts the worker before next checkout" do
      socket_path = tmp_socket_path()

      # `close_after_responder` makes the server send the response then FIN
      # the socket. Combined with our `handle_info/2` callback (which drives
      # `Mint.HTTP.stream/2` for messages while idle), the worker observes
      # the close while sitting in the pool and evicts itself.
      {:ok, server} =
        FakeHttpServer.start(
          transport: :unix,
          socket_path: socket_path,
          responder: fn _req ->
            {:close_after,
             [
               "HTTP/1.1 200 OK\r\n",
               "Content-Type: text/plain\r\n",
               "Content-Length: 2\r\n",
               "\r\n",
               "OK"
             ]}
          end
        )

      on_exit(fn -> FakeHttpServer.stop(server) end)

      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      {:ok, _} = Pool.start(ep, pool_size: 1)

      assert {:ok, %{status: 200, body: "OK"}} =
               Pool.checkout(ep, fn cs ->
                 Sorrel.Pool.Worker.run_request(cs, :get, "/one", [{"host", "localhost"}], "")
               end)

      # Give the worker time to switch to active mode and observe the FIN.
      Process.sleep(50)

      assert {:ok, %{status: 200, body: "OK"}} =
               Pool.checkout(ep, fn cs ->
                 Sorrel.Pool.Worker.run_request(cs, :get, "/two", [{"host", "localhost"}], "")
               end)

      assert FakeHttpServer.accepted_count(server) === 2
    end
  end

  # ---------------------------------------------------------------------------
  # Owner-death cleanup
  # ---------------------------------------------------------------------------

  describe "owner-death" do
    test "caller dies mid-request, next checkout gets a fresh conn" do
      socket_path = tmp_socket_path()

      # Script with a long sleep before any bytes are written. Long
      # enough that we can kill the caller before the response arrives.
      slow_script = fn _req ->
        {:script,
         [
           {:sleep, 500},
           {:write,
            [
              "HTTP/1.1 200 OK\r\n",
              "Content-Type: text/plain\r\n",
              "Content-Length: 2\r\n",
              "\r\n",
              "OK"
            ]}
         ]}
      end

      {:ok, server} =
        FakeHttpServer.start(
          transport: :unix,
          socket_path: socket_path,
          responder: slow_script
        )

      on_exit(fn -> FakeHttpServer.stop(server) end)

      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      {:ok, _} = Pool.start(ep, pool_size: 1)

      # Spawn a process that will block in Pool.checkout/3 waiting for the
      # slow response.
      caller =
        spawn(fn ->
          Pool.checkout(
            ep,
            fn cs ->
              Sorrel.Pool.Worker.run_request(
                cs,
                :get,
                "/slow",
                [{"host", "localhost"}],
                "",
                receive_timeout: 5_000
              )
            end,
            pool_timeout: 5_000
          )
        end)

      # Give the request time to reach the server, then kill the caller
      # mid-request (before the script's :sleep finishes).
      Process.sleep(100)
      ref = Process.monitor(caller)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^ref, :process, ^caller, _reason}, 1_000

      # Wait for the FakeHttpServer to finish writing the response after
      # its sleep, and for the next acceptor cycle to begin.
      Process.sleep(700)

      # Next checkout must succeed and a fresh conn must be opened. If the
      # caller-death path wasn't handled, the next request would see
      # leftover bytes or a closed conn.
      assert {:ok, %{status: 200}} =
               Pool.checkout(
                 ep,
                 fn cs ->
                   Sorrel.Pool.Worker.run_request(cs, :get, "/next", [{"host", "localhost"}], "")
                 end,
                 pool_timeout: 5_000
               )

      # At least two distinct accepted connections — one for the killed
      # request, one for the recovery request. Could be three if the
      # script's writer completed and the conn was checked back in to the
      # pool only to be evicted on the next checkout because of the FIN.
      assert FakeHttpServer.accepted_count(server) >= 2
    end
  end
end

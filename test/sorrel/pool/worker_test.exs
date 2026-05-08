defmodule Sorrel.Pool.WorkerTest do
  # Not async: the NimblePool worker runs under the global
  # Sorrel.Pool.Registry / DynamicSupervisor, so async tests would
  # race for registry entries.
  use ExUnit.Case

  alias Sorrel.Endpoint
  alias Sorrel.Pool
  alias Sorrel.Pool.Worker

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp tmp_socket_path do
    Path.join(
      System.tmp_dir!(),
      "docker-pool-worker-test-#{System.unique_integer([:positive])}.sock"
    )
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

  defp pool_signature(%Endpoint{transport: :unix} = ep), do: {:unix, ep.socket_path}

  defp pool_signature(%Endpoint{transport: :tcp} = ep) do
    tls = ep.tls || %{}

    {:tcp, ep.scheme, ep.host, ep.port,
     {tls[:verify], tls[:cacertfile], tls[:certfile], tls[:keyfile]}}
  end

  defp register_pool_cleanup(endpoint) do
    on_exit(fn ->
      sig = pool_signature(endpoint)

      case Registry.lookup(Sorrel.Pool.Registry, sig) do
        [{pid, _meta}] ->
          DynamicSupervisor.terminate_child(Sorrel.Pool.DynamicSupervisor, pid)

        [] ->
          :ok
      end
    end)
  end

  defp start_unix_server(socket_path, responder, extra_opts \\ []) do
    base = [transport: :unix, socket_path: socket_path, responder: responder]

    {:ok, server} =
      base
      |> Keyword.merge(extra_opts)
      |> FakeHttpServer.start()

    on_exit(fn -> FakeHttpServer.stop(server) end)
    server
  end

  defp start_tcp_server(responder, extra_opts \\ []) do
    base = [transport: :tcp, ip: {127, 0, 0, 1}, port: 0, responder: responder]

    {:ok, server} =
      base
      |> Keyword.merge(extra_opts)
      |> FakeHttpServer.start()

    on_exit(fn -> FakeHttpServer.stop(server) end)
    {:ok, port} = FakeHttpServer.port(server)
    {server, port}
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

  defp close_after_responder(body) do
    fn _req ->
      {:close_after,
       [
         "HTTP/1.1 200 OK\r\n",
         "Content-Type: text/plain\r\n",
         "Content-Length: #{byte_size(body)}\r\n",
         "\r\n",
         body
       ]}
    end
  end

  defp silent_responder do
    fn _req ->
      Process.sleep(60_000)
      ""
    end
  end

  # Wraps Pool.checkout/3 to call run_request/6 with the full client_state.
  defp run(endpoint, method, path, headers, body, opts \\ []) do
    Pool.checkout(
      endpoint,
      fn client_state ->
        Worker.run_request(client_state, method, path, headers, body, opts)
      end,
      opts
    )
  end

  # ---------------------------------------------------------------------------
  # Lazy connect
  # ---------------------------------------------------------------------------

  describe "init_worker/1 lazy connect" do
    test "pool start succeeds even when the target socket does not exist" do
      # Workers connect lazily, so starting a pool against a non-existent
      # Unix socket must not crash. The failure surfaces only on the first
      # checkout that tries to actually open the conn.
      ep =
        unix_endpoint(
          "/tmp/this-socket-should-not-exist-#{System.unique_integer([:positive])}.sock"
        )

      register_pool_cleanup(ep)

      assert {:ok, _name} = Pool.start(ep)
    end
  end

  # ---------------------------------------------------------------------------
  # First request opens; second reuses the conn
  # ---------------------------------------------------------------------------

  describe "request reuse" do
    test "first request opens the conn; second reuses it (Unix)" do
      socket_path = tmp_socket_path()

      server =
        start_unix_server(
          socket_path,
          ok_responder("OK")
        )

      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      # Pool size of 1 to force reuse on the same worker.
      {:ok, _} = Pool.start(ep, pool_size: 1)

      assert {:ok, %{status: 200, body: "OK"}} =
               run(ep, :get, "/first", [{"host", "localhost"}], "")

      assert {:ok, %{status: 200, body: "OK"}} =
               run(ep, :get, "/second", [{"host", "localhost"}], "")

      assert FakeHttpServer.accepted_count(server) === 1
    end
  end

  # ---------------------------------------------------------------------------
  # Reconnect after server-side close
  # ---------------------------------------------------------------------------

  describe "request reconnects after server-side close" do
    test "second request reopens the conn when the first response closed it" do
      socket_path = tmp_socket_path()

      server =
        start_unix_server(
          socket_path,
          close_after_responder("OK")
        )

      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      {:ok, _} = Pool.start(ep, pool_size: 1)

      assert {:ok, %{status: 200, body: "OK"}} =
               run(ep, :get, "/one", [{"host", "localhost"}], "", receive_timeout: 1_000)

      assert {:ok, %{status: 200, body: "OK"}} =
               run(ep, :get, "/two", [{"host", "localhost"}], "", receive_timeout: 1_000)

      # Two accepted connections — one per request — because the server
      # closes after each response.
      assert FakeHttpServer.accepted_count(server) === 2
    end
  end

  # ---------------------------------------------------------------------------
  # Transport error surfaces; pool stays usable
  # ---------------------------------------------------------------------------

  describe "request transport error" do
    test "returns {:error, _} and the pool keeps accepting subsequent requests" do
      missing = "/tmp/docker-pool-worker-missing-#{System.unique_integer([:positive])}.sock"
      ep = unix_endpoint(missing)
      register_pool_cleanup(ep)

      {:ok, _} = Pool.start(ep, pool_size: 1)

      assert {:error, _reason1} =
               run(ep, :get, "/_ping", [{"host", "localhost"}], "")

      # Pool worker has been removed; NimblePool spawns a new lazy worker.
      assert {:error, _reason2} =
               run(ep, :get, "/_ping", [{"host", "localhost"}], "")
    end
  end

  # ---------------------------------------------------------------------------
  # Atom and string method
  # ---------------------------------------------------------------------------

  describe "request method conversion" do
    test "atom :get is accepted and converted to string method" do
      socket_path = tmp_socket_path()
      test_pid = self()

      responder = fn req ->
        send(test_pid, {:saw_method, req.method})

        [
          "HTTP/1.1 200 OK\r\n",
          "Content-Length: 2\r\n",
          "\r\n",
          "OK"
        ]
      end

      _server = start_unix_server(socket_path, responder)
      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      {:ok, _} = Pool.start(ep, pool_size: 1)

      assert {:ok, %{status: 200}} =
               run(ep, :get, "/_ping", [{"host", "localhost"}], "")

      assert_receive {:saw_method, "GET"}, 1_000
    end

    test "string method is also accepted" do
      socket_path = tmp_socket_path()
      _server = start_unix_server(socket_path, ok_responder("OK"))
      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      {:ok, _} = Pool.start(ep, pool_size: 1)

      assert {:ok, %{status: 200, body: "OK"}} =
               run(ep, "GET", "/_ping", [{"host", "localhost"}], "")
    end
  end

  # ---------------------------------------------------------------------------
  # receive_timeout honoured
  # ---------------------------------------------------------------------------

  describe "request receive_timeout" do
    test "returns Mint.TransportError{reason: :timeout} on slow server" do
      socket_path = tmp_socket_path()
      _server = start_unix_server(socket_path, silent_responder())
      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      {:ok, _} = Pool.start(ep, pool_size: 1)

      started = System.monotonic_time(:millisecond)

      assert {:error, %Mint.TransportError{reason: :timeout}} =
               run(
                 ep,
                 :get,
                 "/wait",
                 [{"host", "localhost"}],
                 "",
                 receive_timeout: 100
               )

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < 1_000
    end
  end

  # ---------------------------------------------------------------------------
  # TCP transport variant — Worker is transport-agnostic
  # ---------------------------------------------------------------------------

  describe "request TCP" do
    test "succeeds against a TCP fake server" do
      {_server, port} = start_tcp_server(ok_responder("HELLO"))
      ep = tcp_endpoint(port)
      register_pool_cleanup(ep)

      {:ok, _} = Pool.start(ep, pool_size: 1)

      assert {:ok, %{status: 200, body: "HELLO"}} =
               run(ep, :get, "/_ping", [{"host", "localhost"}], "")
    end
  end
end

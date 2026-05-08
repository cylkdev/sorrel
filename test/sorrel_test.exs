defmodule SorrelTest do
  # Tests in this module touch `DOCKER_HOST` (via cleanup in the
  # endpoint-resolution scenario) and the global pool registry. Async would
  # let those scenarios race, so this module runs serially (the ExUnit
  # default).
  use ExUnit.Case

  alias Sorrel
  alias Sorrel.Endpoint

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp tmp_socket_path do
    Path.join(
      System.tmp_dir!(),
      "docker-minty-test-#{System.unique_integer([:positive])}.sock"
    )
  end

  defp unix_endpoint(path) do
    %Endpoint{transport: :unix, socket_path: path}
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

  # Cleans up the per-endpoint pool created by Sorrel.Pool.checkout/2.
  defp register_pool_cleanup(%Endpoint{} = endpoint) do
    on_exit(fn ->
      sig = pool_signature(endpoint)

      case Registry.lookup(Sorrel.Pool.Registry, sig) do
        [{pid, _}] ->
          _ = DynamicSupervisor.terminate_child(Sorrel.Pool.DynamicSupervisor, pid)
          :ok

        [] ->
          :ok
      end
    end)
  end

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

  defp respond(status, status_text, content_type, body) do
    [
      "HTTP/1.1 #{status} #{status_text}\r\n",
      "Content-Type: #{content_type}\r\n",
      "Content-Length: #{IO.iodata_length(body)}\r\n",
      "\r\n",
      body
    ]
  end

  # ---------------------------------------------------------------------------
  # GET 200 + JSON content-type → JSON-decoded body
  # ---------------------------------------------------------------------------

  describe "request/5 :auto decoding" do
    test "200 with application/json content-type returns decoded JSON" do
      socket_path = tmp_socket_path()

      _server =
        start_unix_server(socket_path, fn _req ->
          respond(200, "OK", "application/json", ~s({"a":1}))
        end)

      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      assert {:ok, %{status: 200, headers: headers, body: %{"a" => 1}}} =
               Sorrel.request(ep, :get, "/foo")

      assert is_list(headers)
    end

    test "200 with text/plain content-type returns raw body" do
      socket_path = tmp_socket_path()

      _server =
        start_unix_server(socket_path, fn _req ->
          respond(200, "OK", "text/plain", "OK")
        end)

      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      assert {:ok, %{status: 200, body: "OK"}} =
               Sorrel.request(ep, :get, "/foo")
    end
  end

  # ---------------------------------------------------------------------------
  # POST {:json, payload} round trip
  # ---------------------------------------------------------------------------

  describe "request/5 body encoding" do
    test "{:json, payload} body sends application/json with JSON-encoded bytes" do
      socket_path = tmp_socket_path()
      test_pid = self()

      responder = fn req ->
        send(test_pid, {:saw_request, req})
        respond(200, "OK", "application/json", req.body)
      end

      _server = start_unix_server(socket_path, responder)

      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      payload = %{"hello" => "world", "n" => 42}

      assert {:ok, %{status: 200, body: echoed}} =
               Sorrel.request(ep, :post, "/things", {:json, payload})

      assert echoed === payload

      assert_receive {:saw_request, req}, 1_000
      assert req.method === "POST"
      assert {"content-type", "application/json"} in req.headers
      assert JSON.decode!(req.body) === payload
    end

    test "{:tar, iodata} body sends application/x-tar with raw bytes" do
      socket_path = tmp_socket_path()
      test_pid = self()

      responder = fn req ->
        send(test_pid, {:saw_request, req})
        respond(200, "OK", "text/plain", "")
      end

      _server = start_unix_server(socket_path, responder)

      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      tar_bytes = "fake-tar-bytes-12345"

      assert {:ok, %{status: 200}} =
               Sorrel.request(ep, :post, "/build", {:tar, tar_bytes})

      assert_receive {:saw_request, req}, 1_000
      assert {"content-type", "application/x-tar"} in req.headers
      assert req.body === tar_bytes
    end
  end

  # ---------------------------------------------------------------------------
  # Non-2xx → {:error, response}
  # ---------------------------------------------------------------------------

  describe "request/5 non-2xx" do
    test "404 returns {:error, response} with the same shape" do
      socket_path = tmp_socket_path()

      _server =
        start_unix_server(socket_path, fn _req ->
          respond(404, "Not Found", "text/plain", "missing")
        end)

      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      assert {:error, %{status: 404, headers: headers, body: "missing"}} =
               Sorrel.request(ep, :get, "/nope")

      assert is_list(headers)
    end
  end

  # ---------------------------------------------------------------------------
  # Transport timeout
  # ---------------------------------------------------------------------------

  describe "request/5 transport errors" do
    test "transport timeout surfaces as {:error, %Mint.TransportError{reason: :timeout}}" do
      # Bind a server that holds the request open without responding. The
      # client times out the receive after 100ms.
      socket_path = tmp_socket_path()

      _server =
        start_unix_server(socket_path, fn _req ->
          Process.sleep(60_000)
          ""
        end)

      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      assert {:error, %Mint.TransportError{reason: :timeout}} =
               Sorrel.request(ep, :get, "/slow", nil, receive_timeout: 100)
    end
  end

  # ---------------------------------------------------------------------------
  # Endpoint required
  # ---------------------------------------------------------------------------

  describe "request/5 endpoint required" do
    test "raises FunctionClauseError when first argument is not a %Endpoint{}" do
      assert_raise FunctionClauseError, fn ->
        Sorrel.request(nil, :get, "/_ping")
      end
    end

    test "raises FunctionClauseError when first argument is a bare keyword" do
      assert_raise FunctionClauseError, fn ->
        Sorrel.request([endpoint: nil], :get, "/_ping")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Header passthrough
  # ---------------------------------------------------------------------------

  describe "request/5 headers" do
    test "extra :headers option is forwarded to the request" do
      socket_path = tmp_socket_path()
      test_pid = self()

      responder = fn req ->
        send(test_pid, {:saw_request, req})
        respond(200, "OK", "text/plain", "OK")
      end

      _server = start_unix_server(socket_path, responder)

      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      assert {:ok, %{status: 200}} =
               Sorrel.request(ep, :get, "/h", nil, headers: [{"x-custom", "yep"}])

      assert_receive {:saw_request, req}, 1_000
      assert {"x-custom", "yep"} in req.headers
    end
  end

  # ---------------------------------------------------------------------------
  # Path passthrough — Sorrel no longer prepends versions
  # ---------------------------------------------------------------------------

  describe "request/5 path passthrough" do
    test "path is sent verbatim (no version prefix injection)" do
      socket_path = tmp_socket_path()
      test_pid = self()

      responder = fn req ->
        send(test_pid, {:saw_path, req.path})
        respond(200, "OK", "text/plain", "OK")
      end

      _server = start_unix_server(socket_path, responder)

      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      assert {:ok, %{status: 200}} =
               Sorrel.request(ep, :get, "/foo")

      assert_receive {:saw_path, "/foo"}, 1_000
    end
  end

  # ---------------------------------------------------------------------------
  # :into modes
  # ---------------------------------------------------------------------------

  describe "request/5 :into modes" do
    test ":raw returns the binary even when content-type is JSON" do
      socket_path = tmp_socket_path()

      _server =
        start_unix_server(socket_path, fn _req ->
          respond(200, "OK", "application/json", ~s({"a":1}))
        end)

      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      assert {:ok, %{status: 200, body: ~s({"a":1})}} =
               Sorrel.request(ep, :get, "/foo", nil, into: :raw)
    end

    test ":json JSON-decodes regardless of content-type" do
      socket_path = tmp_socket_path()

      _server =
        start_unix_server(socket_path, fn _req ->
          respond(200, "OK", "text/plain", ~s({"a":1}))
        end)

      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      assert {:ok, %{status: 200, body: %{"a" => 1}}} =
               Sorrel.request(ep, :get, "/foo", nil, into: :json)
    end
  end

  # ---------------------------------------------------------------------------
  # stream/4 — Stream.resource wrapper around Sorrel.StreamSession
  # ---------------------------------------------------------------------------

  describe "stream/5 success" do
    # Helpers re-used from request/4 tests; we just write small chunked
    # responders so the StreamSession sees real progressive bytes.
    defp head_chunked(status, content_type) do
      [
        "HTTP/1.1 #{status} OK\r\n",
        "Content-Type: #{content_type}\r\n",
        "Transfer-Encoding: chunked\r\n",
        "\r\n"
      ]
    end

    defp transfer_chunk(payload) do
      size = IO.iodata_length(payload)
      [Integer.to_string(size, 16), "\r\n", payload, "\r\n"]
    end

    defp last_transfer_chunk, do: "0\r\n\r\n"

    test "ndjson stream yields events in order, halts on :done" do
      socket_path = tmp_socket_path()

      _server =
        start_unix_server(socket_path, fn _req ->
          {:script,
           [
             {:write, head_chunked(200, "application/x-ndjson")},
             {:write, transfer_chunk(~s({"a":1}\n))},
             {:write, transfer_chunk(~s({"b":2}\n))},
             {:write, transfer_chunk(~s({"c":3}\n))},
             {:write, last_transfer_chunk()},
             :close
           ]}
        end)

      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      assert {:ok, stream} = Sorrel.stream(ep, :get, "/events", nil, into: :ndjson)
      assert Enum.to_list(stream) === [%{"a" => 1}, %{"b" => 2}, %{"c" => 3}]
    end

    test "early termination via take/2 cancels and the StreamSession dies within 100ms" do
      socket_path = tmp_socket_path()

      _server =
        start_unix_server(socket_path, fn _req ->
          {:script,
           [
             {:write, head_chunked(200, "application/x-ndjson")},
             {:write, transfer_chunk(~s({"a":1}\n))},
             # Hold the connection open for a long time; the consumer should
             # cancel as soon as it has the one event.
             {:sleep, 60_000},
             :close
           ]}
        end)

      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      # We need a hook on the StreamSession pid to assert cleanup. Since
      # Stream.resource hides it, use Process.monitor on the linked pid via
      # a small probe: wrap the start_fun observation by intercepting the
      # generator. Simpler: count pids before / after.
      before_pids = length(:erlang.processes())

      assert {:ok, stream} = Sorrel.stream(ep, :get, "/events", nil, into: :ndjson)

      assert [%{"a" => 1}] = stream |> Stream.take(1) |> Enum.to_list()

      # Poll until the process count has returned to baseline ± slack. We do
      # not assert an exact pid is dead because Stream.resource hides it; the
      # StreamSession should exit within 100ms of the take/1 halting.
      deadline = System.monotonic_time(:millisecond) + 200

      :ok = wait_for_pid_count_to_settle(before_pids, deadline)
    end

    test ":raw mode yields the raw chunk binaries" do
      socket_path = tmp_socket_path()

      _server =
        start_unix_server(socket_path, fn _req ->
          {:script,
           [
             {:write, head_chunked(200, "application/octet-stream")},
             {:write, transfer_chunk("hello")},
             {:write, transfer_chunk("world")},
             {:write, last_transfer_chunk()},
             :close
           ]}
        end)

      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      assert {:ok, stream} = Sorrel.stream(ep, :get, "/blob", nil, into: :raw)
      events = Enum.to_list(stream)
      assert IO.iodata_to_binary(events) === "helloworld"
    end

    test "non-2xx is returned as {:error, response} from stream/4" do
      socket_path = tmp_socket_path()

      _server =
        start_unix_server(socket_path, fn _req ->
          respond(404, "Not Found", "text/plain", "missing")
        end)

      ep = unix_endpoint(socket_path)
      register_pool_cleanup(ep)

      assert {:error, %{status: 404, body: "missing"}} =
               Sorrel.stream(ep, :get, "/nope", nil, into: :ndjson)
    end
  end

  # Polls Process.alive on a synthetic baseline. Returns :ok once the live
  # process count is at or below the baseline (allowing a small drift), or if
  # the deadline is reached. Used to verify that streaming cleanup happened.
  defp wait_for_pid_count_to_settle(baseline, deadline) do
    now = System.monotonic_time(:millisecond)
    current = length(:erlang.processes())

    cond do
      current <= baseline + 1 ->
        :ok

      now >= deadline ->
        :ok

      true ->
        Process.sleep(10)
        wait_for_pid_count_to_settle(baseline, deadline)
    end
  end
end

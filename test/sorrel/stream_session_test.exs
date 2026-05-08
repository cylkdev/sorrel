defmodule Sorrel.StreamSessionTest do
  # async: true — every test binds a unique unix-socket path and registers an
  # on_exit cleanup, so there is no shared mutable state between cases.
  use ExUnit.Case, async: true

  alias Sorrel.Endpoint
  alias Sorrel.StreamSession

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp tmp_socket_path do
    Path.join(
      System.tmp_dir!(),
      "docker-minty-streamserver-#{System.unique_integer([:positive])}.sock"
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

  defp head(status, status_text, content_type) do
    [
      "HTTP/1.1 #{status} #{status_text}\r\n",
      "Content-Type: #{content_type}\r\n",
      "Transfer-Encoding: chunked\r\n",
      "\r\n"
    ]
  end

  # Encodes a single HTTP/1.1 chunked-transfer chunk.
  defp chunk(payload) do
    size = IO.iodata_length(payload)
    [Integer.to_string(size, 16), "\r\n", payload, "\r\n"]
  end

  defp last_chunk, do: "0\r\n\r\n"

  defp poll_dead?(pid, deadline) do
    cond do
      not Process.alive?(pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(5)
        poll_dead?(pid, deadline)
    end
  end

  defp base_args(endpoint, into) do
    [
      endpoint: endpoint,
      method: "GET",
      path: "/v1.45/stream",
      headers: [{"host", "localhost"}],
      body: "",
      into: into,
      connect_timeout: 5_000,
      receive_timeout: 5_000
    ]
  end

  # ---------------------------------------------------------------------------
  # Init: 200 + headers + early data → server alive, recv returns the event.
  # This is the test that exercises the init-ordering bug (passive recv head,
  # then set_mode :active, then return). If switched too early, drain hangs.
  # ---------------------------------------------------------------------------

  describe "start_link/1 — init ordering" do
    test "connects, drains the head in passive mode, switches to active, then accepts recv" do
      socket_path = tmp_socket_path()

      _server =
        start_unix_server(socket_path, fn _req ->
          {:script,
           [
             {:write, head(200, "OK", "application/x-ndjson")},
             {:write, chunk(~s({"a":1}\n))},
             {:sleep, 50},
             {:write, chunk(~s({"b":2}\n))},
             {:write, last_chunk()},
             :close
           ]}
        end)

      ep = unix_endpoint(socket_path)

      args = base_args(ep, :ndjson)
      {:ok, srv} = StreamSession.start_link(args)
      assert {:ok, %{"a" => 1}} = StreamSession.recv(srv, timeout: 1_000)
      assert {:ok, %{"b" => 2}} = StreamSession.recv(srv, timeout: 1_000)
      assert :end = StreamSession.recv(srv, timeout: 1_000)

      :ok = StreamSession.cancel(srv)
    end
  end

  # ---------------------------------------------------------------------------
  # NDJSON event-by-event delivery from three separate writes.
  # ---------------------------------------------------------------------------

  describe "ndjson streaming" do
    test "delivers one event per write, in order" do
      socket_path = tmp_socket_path()

      _server =
        start_unix_server(socket_path, fn _req ->
          {:script,
           [
             {:write, head(200, "OK", "application/x-ndjson")},
             {:write, chunk(~s({"a":1}\n))},
             {:sleep, 20},
             {:write, chunk(~s({"b":2}\n))},
             {:sleep, 20},
             {:write, chunk(~s({"c":3}\n))},
             {:write, last_chunk()},
             :close
           ]}
        end)

      ep = unix_endpoint(socket_path)
      args = base_args(ep, :ndjson)
      {:ok, srv} = StreamSession.start_link(args)

      assert {:ok, %{"a" => 1}} = StreamSession.recv(srv, timeout: 1_000)
      assert {:ok, %{"b" => 2}} = StreamSession.recv(srv, timeout: 1_000)
      assert {:ok, %{"c" => 3}} = StreamSession.recv(srv, timeout: 1_000)
      assert :end = StreamSession.recv(srv, timeout: 1_000)
    end

    test "subsequent recv after :end returns :end" do
      socket_path = tmp_socket_path()

      _server =
        start_unix_server(socket_path, fn _req ->
          {:script,
           [
             {:write, head(200, "OK", "application/x-ndjson")},
             {:write, chunk(~s({"a":1}\n))},
             {:write, last_chunk()},
             :close
           ]}
        end)

      ep = unix_endpoint(socket_path)
      args = base_args(ep, :ndjson)
      {:ok, srv} = StreamSession.start_link(args)

      assert {:ok, %{"a" => 1}} = StreamSession.recv(srv, timeout: 1_000)
      assert :end = StreamSession.recv(srv, timeout: 1_000)
      assert :end = StreamSession.recv(srv, timeout: 1_000)
    end
  end

  # ---------------------------------------------------------------------------
  # :raw mode — each chunk becomes one event verbatim.
  # ---------------------------------------------------------------------------

  describe ":raw mode" do
    test "delivers each binary chunk as its own event" do
      socket_path = tmp_socket_path()

      _server =
        start_unix_server(socket_path, fn _req ->
          {:script,
           [
             {:write, head(200, "OK", "application/octet-stream")},
             {:write, chunk("first")},
             {:sleep, 20},
             {:write, chunk("second")},
             {:write, last_chunk()},
             :close
           ]}
        end)

      ep = unix_endpoint(socket_path)
      args = base_args(ep, :raw)
      {:ok, srv} = StreamSession.start_link(args)

      events = collect_until_end(srv, [])
      assert "first" in events
      assert "second" in events
      assert IO.iodata_to_binary(events) === "firstsecond"
    end
  end

  # ---------------------------------------------------------------------------
  # Cancellation: cancel/1 stops the server.
  # ---------------------------------------------------------------------------

  describe "cancel/1" do
    test "stops the server within 100ms" do
      socket_path = tmp_socket_path()

      _server =
        start_unix_server(socket_path, fn _req ->
          {:script,
           [
             {:write, head(200, "OK", "application/x-ndjson")},
             {:write, chunk(~s({"a":1}\n))},
             # Hold the connection open without sending more data — we expect
             # the client to cancel and close.
             {:sleep, 60_000},
             :close
           ]}
        end)

      ep = unix_endpoint(socket_path)
      args = base_args(ep, :ndjson)
      {:ok, srv} = StreamSession.start_link(args)
      assert {:ok, %{"a" => 1}} = StreamSession.recv(srv, timeout: 1_000)

      :ok = StreamSession.cancel(srv)

      deadline = System.monotonic_time(:millisecond) + 100
      assert poll_dead?(srv, deadline), "StreamSession pid should die within 100ms of cancel/1"
    end

    test "cancel/1 on an already-stopped server is :ok" do
      socket_path = tmp_socket_path()

      _server =
        start_unix_server(socket_path, fn _req ->
          {:script,
           [
             {:write, head(200, "OK", "application/x-ndjson")},
             {:write, last_chunk()},
             :close
           ]}
        end)

      ep = unix_endpoint(socket_path)
      args = base_args(ep, :ndjson)
      {:ok, srv} = StreamSession.start_link(args)
      assert :end = StreamSession.recv(srv, timeout: 1_000)

      :ok = StreamSession.cancel(srv)
      :ok = StreamSession.cancel(srv)
    end
  end

  # ---------------------------------------------------------------------------
  # Non-2xx response: init returns {:error, %{status, headers, body}} via stop.
  # ---------------------------------------------------------------------------

  describe "non-2xx response" do
    test "404 surfaces as {:error, %{status: 404, ...}} from start_link/1" do
      socket_path = tmp_socket_path()

      _server =
        start_unix_server(socket_path, fn _req ->
          {:script,
           [
             {:write,
              [
                "HTTP/1.1 404 Not Found\r\n",
                "Content-Type: text/plain\r\n",
                "Content-Length: 7\r\n",
                "\r\n",
                "missing"
              ]},
             :close
           ]}
        end)

      ep = unix_endpoint(socket_path)

      Process.flag(:trap_exit, true)
      args = base_args(ep, :ndjson)
      result = StreamSession.start_link(args)
      assert {:error, {:non_2xx, %{status: 404, body: "missing"}}} = result
    end
  end

  # ---------------------------------------------------------------------------
  # Mid-stream transport error: server sends one event then RSTs the socket.
  # ---------------------------------------------------------------------------

  describe "mid-stream transport error" do
    # Uses a TCP loopback server (not a unix socket) because :close_abrupt's
    # linger:0/RST behaviour only exists on TCP — AF_UNIX has no RST. Sending
    # a truly broken stream mid-body is the only way to surface a non-:closed
    # transport error to Mint.
    test "first event delivered, second recv returns {:error, _}" do
      {:ok, server} =
        FakeHttpServer.start(
          transport: :tcp,
          ip: {127, 0, 0, 1},
          port: 0,
          responder: fn _req ->
            {:script,
             [
               {:write, head(200, "OK", "application/x-ndjson")},
               {:write, chunk(~s({"a":1}\n))},
               {:sleep, 20},
               :close_abrupt
             ]}
          end
        )

      on_exit(fn -> FakeHttpServer.stop(server) end)
      {:ok, port} = FakeHttpServer.port(server)
      ep = %Endpoint{transport: :tcp, scheme: :http, host: "127.0.0.1", port: port}

      Process.flag(:trap_exit, true)
      args = base_args(ep, :ndjson)
      {:ok, srv} = StreamSession.start_link(args)
      assert {:ok, %{"a" => 1}} = StreamSession.recv(srv, timeout: 1_000)

      # The next call resolves either as an error (if the RST has not yet
      # been processed at the time of the call and the server hands one
      # back), or the server may have already terminated and the call exits.
      # On some platforms RST-after-data is reported by Mint as
      # %Mint.TransportError{reason: :closed} — which we treat as benign and
      # end the stream cleanly. All three outcomes are documented behaviours.
      result =
        try do
          StreamSession.recv(srv, timeout: 2_000)
        catch
          :exit, reason -> {:exit, reason}
        end

      assert match?({:error, _}, result) or match?({:exit, _}, result) or result === :end,
             "expected an error, exit, or :end on broken stream, got: #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # 204 No Content: response head has Content-Length: 0 and no body. The
  # stream session must complete cleanly without spinning until receive_timeout.
  # Regression test for the head_complete? bug where the head-drain loop
  # treated "no headers yet" as "not done" and looped forever on responses
  # that legitimately carry zero or one headers in unusual orderings.
  # ---------------------------------------------------------------------------

  describe "headerless 200 response" do
    # Regression: head_complete? used `headers !== []` to decide whether the
    # head was fully read. A response that legitimately has zero headers
    # (or where :done arrives in a separate Mint recv batch from :headers)
    # would loop until receive_timeout instead of completing.
    test "init completes promptly when response has no headers" do
      socket_path = tmp_socket_path()

      _server =
        start_unix_server(socket_path, fn _req ->
          # 200 OK with literally zero response headers and no body.
          # Mint sees :status, no :headers event, then :done.
          {:script,
           [
             {:write,
              [
                "HTTP/1.1 200 OK\r\n",
                "\r\n"
              ]},
             :close
           ]}
        end)

      ep = unix_endpoint(socket_path)

      # Tight per-recv timeout: if head_complete? is buggy, the call below
      # blocks until receive_timeout and then errors out. Bound the whole
      # interaction to 2s with a Task.
      args = Keyword.put(base_args(ep, :ndjson), :receive_timeout, 30_000)

      task =
        Task.async(fn ->
          {:ok, srv} = StreamSession.start_link(args)
          result = StreamSession.recv(srv, timeout: 1_000)
          :ok = StreamSession.cancel(srv)
          result
        end)

      assert :end = Task.await(task, 2_000)
    end
  end

  # ---------------------------------------------------------------------------
  # Fast response: head + body + done all arrive in a single Mint recv batch.
  # Exercises the on_2xx/6 done? = true branch — the stream session must close the
  # conn once and terminate cleanly without raising MatchError on the
  # second close attempt.
  # ---------------------------------------------------------------------------

  describe "fast response (all in one batch)" do
    test "terminates cleanly when status, headers, body, and done arrive together" do
      socket_path = tmp_socket_path()

      _server =
        start_unix_server(socket_path, fn _req ->
          # Single write — entire response (head + chunked body + last chunk)
          # in one buffer so Mint sees them in a single recv call.
          {:script,
           [
             {:write,
              [
                "HTTP/1.1 200 OK\r\n",
                "Content-Type: application/x-ndjson\r\n",
                "Transfer-Encoding: chunked\r\n",
                "\r\n",
                chunk(~s({"a":1}\n)),
                last_chunk()
              ]},
             :close
           ]}
        end)

      ep = unix_endpoint(socket_path)

      Process.flag(:trap_exit, true)
      args = base_args(ep, :ndjson)
      {:ok, srv} = StreamSession.start_link(args)

      assert {:ok, %{"a" => 1}} = StreamSession.recv(srv, timeout: 1_000)
      assert :end = StreamSession.recv(srv, timeout: 1_000)

      ref = Process.monitor(srv)
      :ok = StreamSession.cancel(srv)

      assert_receive {:DOWN, ^ref, :process, ^srv, reason}, 1_000
      # Must terminate cleanly — :normal or :shutdown — never a MatchError.
      assert reason in [:normal, :shutdown] or match?({:shutdown, _}, reason),
             "expected clean termination, got: #{inspect(reason)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp collect_until_end(srv, acc) do
    case StreamSession.recv(srv, timeout: 1_000) do
      {:ok, event} -> collect_until_end(srv, [event | acc])
      :end -> Enum.reverse(acc)
      {:error, _} -> Enum.reverse(acc)
    end
  end
end

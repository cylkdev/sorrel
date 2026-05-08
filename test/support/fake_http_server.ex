defmodule FakeHttpServer do
  @moduledoc """
  Minimal HTTP/1.1 server for use in ExUnit tests.

  Spawns a listener (plain TCP, plain Unix-domain socket, or TLS over TCP),
  accepts a single inbound connection at a time, parses a minimal HTTP/1.1
  request, and writes back whatever the caller-supplied responder returns.
  The listener loop keeps running until `stop/1` is called, so the same server
  can serve multiple sequential request/response cycles.

  This module is `async: true` safe: TCP and TLS variants bind ephemeral
  ports and the `port/1` accessor reports the actual one, and Unix variants
  accept any caller-supplied path (use a unique tempfile per test).

  ## Examples

      iex> {:ok, server} = FakeHttpServer.start(
      ...>   transport: :tcp,
      ...>   ip: {127, 0, 0, 1},
      ...>   port: 0,
      ...>   responder: fn _req -> "HTTP/1.1 200 OK\\r\\nContent-Length: 0\\r\\n\\r\\n" end
      ...> )
      iex> {:ok, _port} = FakeHttpServer.port(server)
      iex> :ok = FakeHttpServer.stop(server)

  ## TLS variant

  Pass `transport: :tls` plus the cert files (e.g. from `CertFixture`).
  Optionally require a client cert with `fail_if_no_peer_cert: true`:

      {:ok, server} = FakeHttpServer.start(
        transport: :tls,
        ip: {127, 0, 0, 1},
        port: 0,
        cacertfile: paths.ca,
        certfile: paths.server_cert,
        keyfile: paths.server_key,
        fail_if_no_peer_cert: true,
        responder: ...
      )

  ## Responder contract

  The `:responder` function is invoked with a parsed request map of the form:

      %{method: "GET", path: "/_ping", headers: [{"host", "localhost"}, ...], body: ""}

  It must return one of:

    * `iodata` — written to the socket; the connection is then kept open for
      the next request on the same socket (HTTP keep-alive style).
    * `{:close_after, iodata}` — written, then the socket is closed cleanly.
    * `{:script, [step]}` — runs a sequence of steps in order, where each
      `step` is one of:
      - `{:write, iodata}` — writes the bytes to the socket.
      - `{:sleep, ms}` — sleeps for `ms` milliseconds.
      - `:close` — closes the socket cleanly. No further steps execute.
      - `:close_abrupt` — closes the socket without a graceful TCP shutdown
        (no FIN); the peer sees a transport reset / closed condition mid-
        stream. No further steps execute.
      The script is intended for tests that need to pace chunked or
      streaming responses or simulate mid-stream transport errors.

  Any exception raised by the responder propagates into the acceptor process,
  which logs it and closes the socket.
  """

  use GenServer

  require Logger

  alias FakeHttpServer.Impl

  @type transport :: :unix | :tcp | :tls
  @type request :: %{
          method: String.t(),
          path: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }
  @type responder :: (request() -> iodata() | {:close_after, iodata()})

  @type start_opts :: [
          {:transport, transport()}
          | {:socket_path, Path.t()}
          | {:ip, :inet.ip_address()}
          | {:port, :inet.port_number()}
          | {:responder, responder()}
          | {:cacertfile, Path.t()}
          | {:certfile, Path.t()}
          | {:keyfile, Path.t()}
          | {:fail_if_no_peer_cert, boolean()}
          | {:notify, pid()}
        ]

  @doc """
  Starts a fake HTTP server.

  Required options:

    * `:transport` — `:tcp`, `:tls`, or `:unix`.
    * `:responder` — function returning the response.

  TCP / TLS options:

    * `:ip` — defaults to `{127, 0, 0, 1}`.
    * `:port` — defaults to `0` (ephemeral; query with `port/1`).

  TLS-only options (all required when `transport: :tls`):

    * `:cacertfile` — CA bundle used for peer-cert verification.
    * `:certfile` — server cert PEM.
    * `:keyfile` — server private key PEM.
    * `:fail_if_no_peer_cert` — boolean, defaults to `false`. When `true` the
      handshake fails unless the client presents a cert (mTLS).

  Unix-only options:

    * `:socket_path` — required, must be a writable filesystem path. The
      caller is responsible for using a unique path per test (e.g.
      `Path.join(System.tmp_dir!(), "fake-\#{System.unique_integer([:positive])}.sock")`).
  """
  @spec start(start_opts()) :: {:ok, pid()} | {:error, term()}
  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @doc """
  Returns the actual port the listener is bound to.

  Works for both `:tcp` and `:tls` transports. Errors with
  `{:error, :not_tcp}` for Unix-socket servers.
  """
  @spec port(pid()) :: {:ok, :inet.port_number()} | {:error, :not_tcp}
  def port(server), do: GenServer.call(server, :port)

  @doc """
  Stops the server and releases the listening socket. For Unix-socket servers,
  also removes the socket file from disk.
  """
  @spec stop(pid()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal, 1_000)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Returns the number of inbound connections accepted by the server since it
  started. Useful for tests that need to assert connection reuse vs.
  reconnect.
  """
  @spec accepted_count(pid()) :: non_neg_integer()
  def accepted_count(server), do: GenServer.call(server, :accepted_count)

  ## GenServer

  @impl true
  def init(opts) do
    transport = Keyword.fetch!(opts, :transport)
    responder = Keyword.fetch!(opts, :responder)
    notify = Keyword.get(opts, :notify)

    # Trap exits so we can observe acceptor terminations and respawn an
    # acceptor for the next inbound connection. Without trap_exit, a normal
    # acceptor exit silently leaves the listener idle.
    Process.flag(:trap_exit, true)

    case open_listener(transport, opts) do
      {:ok, listen_socket, info} ->
        state = %{
          transport: transport,
          listen_socket: listen_socket,
          responder: responder,
          info: info,
          acceptor: nil,
          notify: notify,
          accepted_count: 0
        }

        {:ok, start_acceptor(state)}

      {:error, reason} ->
        {:stop, {:listen_failed, reason}}
    end
  end

  @impl true
  def handle_call(:port, _from, %{transport: t, info: %{port: port}} = state)
      when t === :tcp or t === :tls do
    {:reply, {:ok, port}, state}
  end

  def handle_call(:port, _from, state) do
    {:reply, {:error, :not_tcp}, state}
  end

  def handle_call(:accepted_count, _from, state) do
    {:reply, state.accepted_count, state}
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, %{acceptor: pid} = state) do
    # A finished acceptor is normal — start the next one to keep accepting.
    {:noreply, start_acceptor(state)}
  end

  def handle_info({:fake_http_accepted, _pid}, state) do
    if is_pid(state.notify), do: send(state.notify, :fake_http_accepted)
    {:noreply, %{state | accepted_count: state.accepted_count + 1}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{transport: transport, listen_socket: ls, info: info}) do
    close_listen_socket(transport, ls)
    remove_unix_socket_file(transport, info)
    :ok
  end

  defp close_listen_socket(_transport, nil) do
    :ok
  end

  defp close_listen_socket(:tls, ls) do
    :ok = :ssl.close(ls)
  end

  defp close_listen_socket(_other_transport, ls) do
    :ok = :gen_tcp.close(ls)
  end

  defp remove_unix_socket_file(:unix, %{socket_path: socket_path}) do
    case File.rm(socket_path) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp remove_unix_socket_file(_other_transport, _info) do
    :ok
  end

  ## Internals

  defp open_listener(:tcp, opts) do
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    port = Keyword.get(opts, :port, 0)
    listen_opts = Impl.tcp_listen_opts(ip)

    case :gen_tcp.listen(port, listen_opts) do
      {:ok, ls} ->
        {:ok, actual_port} = :inet.port(ls)
        {:ok, ls, %{ip: ip, port: actual_port}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp open_listener(:tls, opts) do
    {:ok, _started} = Application.ensure_all_started(:ssl)

    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    port = Keyword.get(opts, :port, 0)
    cacertfile = Keyword.fetch!(opts, :cacertfile)
    certfile = Keyword.fetch!(opts, :certfile)
    keyfile = Keyword.fetch!(opts, :keyfile)
    fail_if_no_peer_cert = Keyword.get(opts, :fail_if_no_peer_cert, false)

    listen_opts =
      Impl.tls_listen_opts(ip, cacertfile, certfile, keyfile, fail_if_no_peer_cert)

    case :ssl.listen(port, listen_opts) do
      {:ok, ls} ->
        {:ok, {_ip, actual_port}} = :ssl.sockname(ls)
        {:ok, ls, %{ip: ip, port: actual_port}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp open_listener(:unix, opts) do
    socket_path = Keyword.fetch!(opts, :socket_path)
    _removed = File.rm(socket_path)

    listen_opts = Impl.unix_listen_opts(socket_path)

    # Port 0 is required for AF_UNIX listen sockets via :gen_tcp.
    case :gen_tcp.listen(0, listen_opts) do
      {:ok, ls} -> {:ok, ls, %{socket_path: socket_path}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_acceptor(state) do
    parent = self()
    transport = state.transport
    listen_socket = state.listen_socket
    responder = state.responder

    # Acceptor process owns the accepted socket end-to-end.
    pid =
      spawn_link(fn ->
        _accept_result =
          case accept(transport, listen_socket) do
            {:ok, client} ->
              send(parent, {:fake_http_accepted, self()})
              serve(transport, client, responder)

            {:error, :closed} ->
              :ok

            {:error, reason} ->
              Logger.debug("FakeHttpServer accept failed: #{inspect(reason)}")
              :ok
          end

        send(parent, {:acceptor_done, self()})
      end)

    %{state | acceptor: pid}
  end

  # Accept-and-handshake helper. For TLS we must complete the SSL handshake
  # before reading any application bytes; failures here include the alert
  # raised when fail_if_no_peer_cert is true and no client cert was sent.
  defp accept(:tls, listen_socket) do
    case :ssl.transport_accept(listen_socket, 5_000) do
      {:ok, sock} ->
        case :ssl.handshake(sock, 5_000) do
          {:ok, ssl_sock} -> {:ok, ssl_sock}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  defp accept(_transport, listen_socket) do
    :gen_tcp.accept(listen_socket, 5_000)
  end

  defp serve(transport, client, responder) do
    case read_request(transport, client, "") do
      {:ok, request, leftover} ->
        dispatch(
          transport,
          client,
          responder,
          safe_call_responder(responder, request),
          leftover
        )

      {:error, :closed} ->
        close(transport, client)

      {:error, reason} ->
        Logger.debug("FakeHttpServer read failed: #{inspect(reason)}")
        close(transport, client)
    end
  end

  defp dispatch(transport, client, responder, responder_result, leftover) do
    case Impl.classify_responder_result(responder_result) do
      {:close_after, iodata} ->
        case send_data(transport, client, iodata) do
          :ok -> close(transport, client)
          {:error, _reason} -> close(transport, client)
        end

      {:script, steps} ->
        run_script(transport, client, steps)

      {:keep_alive, iodata} ->
        case send_data(transport, client, iodata) do
          :ok -> serve_keep_alive(transport, client, responder, leftover)
          {:error, _reason} -> close(transport, client)
        end
    end
  end

  # Executes a list of script steps against the open socket. Stops on the
  # first :close, :close_abrupt, or write error. After a clean :close (or the
  # script ending naturally), the socket is closed gracefully. After a
  # :close_abrupt, the socket is closed with linger:0 so the peer sees an RST
  # rather than a graceful FIN.
  defp run_script(transport, client, []) do
    close(transport, client)
  end

  defp run_script(transport, client, [{:write, iodata} | rest]) do
    case send_data(transport, client, iodata) do
      :ok -> run_script(transport, client, rest)
      {:error, _reason} -> close(transport, client)
    end
  end

  defp run_script(transport, client, [{:sleep, ms} | rest]) when is_integer(ms) and ms >= 0 do
    Process.sleep(ms)
    run_script(transport, client, rest)
  end

  defp run_script(transport, client, [:close | _rest]) do
    close(transport, client)
  end

  defp run_script(transport, client, [:close_abrupt | _rest]) do
    close_abrupt(transport, client)
  end

  defp close_abrupt(:tls, sock) do
    # :ssl has no direct linger:0 equivalent that is portable across OTPs; the
    # closest behaviour is to close the underlying transport. ssl.close/1
    # tries to send a TLS close_notify; for our test purposes a best-effort
    # close is sufficient since Mint surfaces either :closed or a transport
    # error on the consumer side.
    case :ssl.close(sock) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp close_abrupt(_other_transport, sock) do
    # linger:0 makes close() drop pending data and send RST, so the peer sees
    # an abrupt termination instead of a clean FIN. This is what we want when
    # simulating a mid-stream transport error.
    case :inet.setopts(sock, linger: {true, 0}) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end

    case :gen_tcp.close(sock) do
      :ok -> :ok
    end
  end

  defp serve_keep_alive(transport, client, responder, "") do
    serve(transport, client, responder)
  end

  defp serve_keep_alive(transport, client, responder, leftover) do
    case Impl.parse_request(leftover) do
      {:need_more, _buffer} -> serve(transport, client, responder)
      {:ok, _request, _next_leftover} -> serve(transport, client, responder)
    end
  end

  defp send_data(:tls, sock, iodata), do: :ssl.send(sock, iodata)
  defp send_data(_transport, sock, iodata), do: :gen_tcp.send(sock, iodata)

  defp close(:tls, sock), do: :ssl.close(sock)
  defp close(_transport, sock), do: :gen_tcp.close(sock)

  defp safe_call_responder(responder, request) do
    responder.(request)
  rescue
    e ->
      Logger.error("FakeHttpServer responder raised: #{Exception.message(e)}")
      {:close_after, "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n"}
  end

  defp read_request(transport, socket, buffer) do
    case Impl.parse_request(buffer) do
      {:ok, request, leftover} ->
        {:ok, request, leftover}

      {:need_more, buffer} ->
        case recv(transport, socket) do
          {:ok, more} -> read_request(transport, socket, buffer <> more)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp recv(:tls, sock) do
    :ssl.recv(sock, 0, 5_000)
  end

  defp recv(_other_transport, sock) do
    :gen_tcp.recv(sock, 0, 5_000)
  end
end

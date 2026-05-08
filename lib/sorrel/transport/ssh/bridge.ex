defmodule Sorrel.Transport.SSH.Bridge do
  @moduledoc """
  Pumps bytes between a one-shot loopback TCP socket and an already-open
  SSH channel, in both directions, until either side closes.

  This bridge exists because `Mint.HTTP1.connect/4` only accepts
  `gen_tcp` or `:ssl` sockets. To get HTTP/1.1 over an SSH byte stream
  without forking Mint, the SSH transport interposes this loopback
  bridge:

      Mint  <───────────────>  Bridge  <─────────────>  remote
            127.0.0.1:port              SSH channel

  The bridge takes ownership of an existing SSH connection ref and an
  already-opened channel id; it does not negotiate either. It binds a
  loopback listener on `127.0.0.1:0`, returns the bound port to the
  caller, accepts exactly one inbound connection (Mint's), and from
  that point on simply copies bytes in both directions.

  ## Lifecycle

    * **Startup**: `start_link/1` opens the loopback listener
      synchronously inside `init/1` so the returned `port` is already
      bound and ready to accept. Acceptance happens asynchronously via
      a short-lived acceptor process spawned during `handle_continue/2`.
    * **Steady state**: every byte received on the loopback socket is
      forwarded to the SSH channel; every byte received on the SSH
      channel is written back to the loopback socket.
    * **Shutdown**: when either side closes, the bridge closes the
      other and exits. On any exit (including owner death) the bridge
      closes both sides - the SSH channel and the SSH connection - in
      `terminate/2`.

  The bridge is *linked* to the supplied `:owner` pid: if the owner
  dies, the bridge dies with it (and tears down SSH on the way out).
  Conversely the bridge traps exits so its `terminate/2` always runs.

  ## When you would call this module yourself

  Most callers do not. `Sorrel.Transport.SSH.connect/2` opens the
  SSH connection and hands `(ssh_conn, target)` to this module. The
  bridge opens the channel itself; reach for this module directly only
  in tests or when wiring up a custom transport.

  ## Why the bridge opens the channel

  OTP `:ssh_connection.session_channel/2`, `:ssh_connection.exec/4`,
  and `:ssh_connection.open_channel/4` deliver `{:ssh_cm, ssh_conn, _}`
  channel-message events to **the process that opened the channel**.
  Because the bridge is the process that needs to react to those
  events (forwarding incoming data onto the loopback socket, reacting
  to channel close, and so on), it must be the process that opens the
  channel - there is no public OTP API to transfer channel ownership
  to a different process after the fact.

  This is why `start_link/1` accepts a `:target` option (which the
  bridge uses to open the right channel type) rather than asking the
  caller to open the channel and pass a `:channel_id` in. The
  `:channel_id` option still exists for tests and for callers that
  manage their own channels.

  ## Test injection points

  For unit tests that want to exercise the bridge without standing up
  a real SSH daemon, two functional options exist (default to thin
  wrappers around the OTP `:ssh_connection` API):

    * `:ssh_send_fun` - `fn ssh_conn, channel_id, data -> :ok | term end`
      called whenever loopback-side bytes need to be forwarded to the
      SSH channel. Defaults to `:ssh_connection.send/3`.
    * `:ssh_close_fun` - `fn ssh_conn, channel_id -> :ok | term end`
      called when the bridge needs to close the SSH channel. Defaults
      to `:ssh_connection.close/2`.
    * `:ssh_conn_close_fun` - `fn ssh_conn -> :ok | term end` called
      to tear down the SSH connection itself. Defaults to
      `:ssh.close/1`.

  These options are intended for testing only; production callers
  should leave them unset.

  ## Examples

      # Caller has already opened an SSH connection and a channel:
      iex> {:ok, %{port: port, bridge: _pid}} =
      ...>   Sorrel.Transport.SSH.Bridge.start_link(
      ...>     ssh_conn: ssh_ref,
      ...>     channel_id: chan,
      ...>     owner: self()
      ...>   )
      iex> {:ok, _conn} = Mint.HTTP1.connect(:http, "127.0.0.1", port, [])
  """

  # What this module is:
  #   A GenServer that owns four resources:
  #     * a loopback `:gen_tcp` listener bound to 127.0.0.1:0
  #     * the accepted client socket (set after the acceptor delivers it)
  #     * an OTP `:ssh` connection ref (passed in)
  #     * an SSH channel id on that connection (either passed in via
  #       `:channel_id` for test/manual mode, or opened by this module
  #       in production mode via `:target`)
  #
  # State map:
  #   %{
  #     listen_socket:        port() | nil,            # loopback listener (closed once accepted)
  #     client_socket:        port() | nil,            # accepted loopback socket
  #     ssh_conn:             term(),                  # opaque OTP ssh connection ref
  #     channel_id:           non_neg_integer(),
  #     owner:                pid(),
  #     accept_timeout:       pos_integer(),
  #     ssh_send_fun:         (term, integer, iodata -> term),
  #     ssh_close_fun:        (term, integer -> term),
  #     ssh_conn_close_fun:   (term -> term),
  #     ssh_closed?:          boolean(),               # set true once we've issued ssh_close_fun
  #     pending_ssh_data:     iolist(),                # SSH bytes buffered before client_socket is set
  #     ssh_close_pending?:   boolean(),               # SSH side closed/eof before client_socket was set
  #     exit_status:          non_neg_integer() | nil, # captured from {:ssh_cm, _, {:exit_status, _, n}}
  #     exit_signal:          {String.t(), String.t()} | nil, # captured from {:exit_signal, _, sig, msg, _lang}
  #     bytes_forwarded?:     boolean()                # has any SSH->loopback byte already been written/flushed?
  #   }
  #
  # Rules that always hold:
  #   1. After `init/1` returns successfully the loopback listener is bound
  #      and `state.listen_socket` is non-nil. The returned `port` matches
  #      `:inet.port(state.listen_socket)`. `state.channel_id` is set -
  #      either to the value supplied via `:channel_id` (test/manual mode)
  #      or to the id of the channel `init/1` opened via `:target`
  #      (production mode).
  #   2. At any time exactly one of `listen_socket`/`client_socket` is the
  #      "live" loopback resource. Once a client connects, `listen_socket`
  #      is closed and forgotten; from then on `client_socket` carries the
  #      bytes.
  #   3. `terminate/2` closes whichever loopback resource is open AND
  #      issues `ssh_close_fun` and `ssh_conn_close_fun` (idempotently)
  #      regardless of exit reason.
  #   4. The bridge LINKS to `owner`. Owner death -> bridge death -> SSH
  #      teardown.
  #   5. Channel-open errors (production mode) surface as
  #      `start_link/1` returning `{:error, reason}`. The reason uses
  #      the project-wide tagged-tuple convention:
  #      `{:ssh_target_unreachable, _}`,
  #      `{:streamlocal_not_supported_by_otp, _}`, or bare `:timeout`.

  use GenServer

  require Logger

  @type target ::
          {:exec, iodata()} | {:tcp, String.t(), :inet.port_number()} | {:unix, String.t()}

  @type start_opts :: [
          ssh_conn: term(),
          target: target(),
          channel_id: non_neg_integer(),
          channel_open_timeout: pos_integer(),
          owner: pid(),
          accept_timeout: pos_integer(),
          ssh_send_fun: (term(), non_neg_integer(), iodata() -> term()),
          ssh_close_fun: (term(), non_neg_integer() -> term()),
          ssh_conn_close_fun: (term() -> term())
        ]

  @type start_result :: %{port: pos_integer(), bridge: pid()}

  @doc """
  Starts a bridge process and returns once the loopback listener is
  bound and ready to accept.

  The bridge does not open an SSH connection or channel itself; the
  caller passes in an existing connection ref (`:ssh_conn`) and channel
  id (`:channel_id`). Once the caller connects to the returned port,
  the bridge accepts that connection and begins pumping bytes in both
  directions until either side closes.

  ## Parameters

    * `opts` - `keyword()`. Recognised keys:

      | Key                     | Required?         | Type                                          | Default           | What it is                                                                                                  |
      | ----------------------- | ----------------- | --------------------------------------------- | ----------------- | ----------------------------------------------------------------------------------------------------------- |
      | `:ssh_conn`             | yes               | `term()`                                      | -                 | The OTP `:ssh` connection ref. The bridge takes ownership; on bridge exit it calls `:ssh.close/1`.          |
      | `:target`               | production-mode   | `target()`                                    | -                 | `{:exec, iodata}` \| `{:tcp, host, port}` \| `{:unix, path}`. The bridge opens the matching SSH channel itself and becomes its owner - see "Why the bridge opens the channel" below. |
      | `:channel_id`           | test/manual-mode  | `non_neg_integer()`                           | -                 | A channel id the caller has already arranged for. The bridge skips the channel-open step and uses this directly. Tests use this with sentinel ids and inject `:ssh_cm` messages. |
      | `:channel_open_timeout` | no                | `pos_integer()`                               | `10_000`          | Milliseconds to wait for the channel open (production mode only). On expiry the bridge stops with `{:shutdown, :timeout}`. |
      | `:owner`                | yes               | `pid()`                                       | -                 | The pid that owns this bridge. The bridge LINKS to this pid; owner death tears the bridge down.             |
      | `:accept_timeout`       | no                | `pos_integer()`                               | `5_000`           | Milliseconds to wait for a client to connect to the loopback listener. On expiry the bridge stops with `{:shutdown, :accept_timeout}`. |
      | `:ssh_send_fun`         | no                | `(ssh_conn, channel_id, iodata -> term)`      | `:ssh_connection.send/3` | Test-only injection point.                                                                          |
      | `:ssh_close_fun`        | no                | `(ssh_conn, channel_id -> term)`              | `:ssh_connection.close/2`| Test-only injection point.                                                                          |
      | `:ssh_conn_close_fun`   | no                | `(ssh_conn -> term)`                          | `:ssh.close/1`           | Test-only injection point.                                                                          |

  Exactly ONE of `:target` and `:channel_id` must be supplied; supplying both, or neither, raises an `{:invalid_args, _}` error from `start_link/1`.

  ## Returns

    * `{:ok, %{port: port, bridge: pid}}` - `port` is the bound
      loopback listener port (`pos_integer()`); `bridge` is the
      `GenServer` pid.

    * `{:error, reason}` - could not bind the loopback listener.
      `reason` is whatever `:gen_tcp.listen/2` surfaced (typically a
      POSIX atom like `:eaddrinuse`, vanishingly rare on `127.0.0.1:0`).

    * `{:error, {:invalid_args, term}}` - required option missing or
      malformed. `term` describes the offending key.

  This function does not raise for expected failures.
  """
  @spec start_link(start_opts()) :: {:ok, start_result()} | {:error, term()}
  def start_link(opts) when is_list(opts) do
    case GenServer.start_link(__MODULE__, opts) do
      {:ok, pid} ->
        port = GenServer.call(pid, :port)
        {:ok, %{port: port, bridge: pid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, ssh_conn} <- fetch_required(opts, :ssh_conn),
         {:ok, owner} <- fetch_required(opts, :owner),
         :ok <- link_to_owner(owner),
         {:ok, channel_id} <- resolve_channel_id(opts, ssh_conn),
         {:ok, listen_socket} <- open_listener() do
      state = %{
        listen_socket: listen_socket,
        client_socket: nil,
        ssh_conn: ssh_conn,
        channel_id: channel_id,
        owner: owner,
        accept_timeout: Sorrel.Config.accept_timeout(opts),
        ssh_send_fun: Keyword.get(opts, :ssh_send_fun, &default_ssh_send/3),
        ssh_close_fun: Keyword.get(opts, :ssh_close_fun, &default_ssh_close/2),
        ssh_conn_close_fun: Keyword.get(opts, :ssh_conn_close_fun, &default_ssh_conn_close/1),
        ssh_closed?: false,
        pending_ssh_data: [],
        ssh_close_pending?: false,
        # Captured from `{:ssh_cm, _, {:exit_status, _, n}}` /
        # `{:exit_signal, _, sig, msg, lang}` channel messages. We DO
        # NOT act on these immediately because exec semantics are
        # accept-then-run: the SSH server accepts the exec request
        # (channel is "successfully" open), then the program runs (or
        # fails to run, e.g. `dial-stdio: not found, exit 127`), and
        # only at channel-close time do we know whether anything
        # useful happened. Holding the value lets the close handler
        # decide whether to surface a typed `{:ssh_exec_failed, _}`
        # error or fall through to a clean `:normal` exit.
        exit_status: nil,
        exit_signal: nil,
        # Tracks whether any byte from the SSH side has already
        # crossed the boundary toward Mint (either by being written
        # to the active loopback socket, or by being flushed out of
        # `pending_ssh_data` at accept-time). This flag is the
        # boundary between two cases:
        #
        #   * `bytes_forwarded? == false` - no response was ever
        #     produced. A non-zero exit can be safely surfaced as a
        #     typed error: nothing downstream has acted on a partial
        #     response yet.
        #
        #   * `bytes_forwarded? == true` - a response (or part of
        #     one) has already reached Mint, which may have parsed
        #     it and handed it to the caller. Inventing an error at
        #     this point would corrupt the caller's view of the
        #     world; the late exit_status MUST stay invisible. This
        #     is a deliberate tradeoff: callers that need
        #     mid-response failure detection must do it at the HTTP
        #     layer (e.g. detect truncated bodies, mismatched
        #     Content-Length).
        bytes_forwarded?: false
      }

      {:ok, state, {:continue, :accept}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # Picks the channel id to use, based on which option the caller supplied.
  #
  # Production mode (`:target` option): the bridge opens the channel
  # itself by calling into OTP. The bridge becomes the channel owner -
  # which is the whole point of this layer; it means `:ssh_cm` messages
  # for this channel are delivered to this process rather than to the
  # caller of start_link.
  #
  # Test/manual mode (`:channel_id` option): the caller has already
  # opened the channel (or, in tests, is using a sentinel id) and just
  # wants the bridge to use it.
  #
  # Supplying both is a misuse and produces an `:invalid_args` error.
  defp resolve_channel_id(opts, ssh_conn) do
    target_opt = Keyword.get(opts, :target)
    channel_opt = Keyword.get(opts, :channel_id)

    case {target_opt, channel_opt} do
      {nil, nil} ->
        {:error, {:invalid_args, {:missing, :target_or_channel_id}}}

      {_, channel_id} when is_integer(channel_id) and channel_id >= 0 ->
        {:ok, channel_id}

      {target, nil} ->
        timeout = Sorrel.Config.channel_open_timeout(opts)
        open_channel(ssh_conn, target, timeout)
    end
  end

  # Opens an SSH channel of the right shape for the target. The bridge
  # becomes the channel owner: all subsequent `{:ssh_cm, _, _}` messages
  # for this channel are delivered to this process.
  #
  # Errors are mapped to the project-wide tagged-tuple convention. A
  # bare `:timeout` is preserved so callers can match the same shape
  # the TCP and Unix transports use for connect timeouts.
  @spec open_channel(term(), target(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defp open_channel(ssh_conn, {:exec, command}, timeout) do
    with {:ok, channel_id} <- session_channel(ssh_conn, timeout),
         :ok <- exec_on_channel(ssh_conn, channel_id, command, timeout) do
      {:ok, channel_id}
    end
  end

  defp open_channel(ssh_conn, {:tcp, host, port}, timeout)
       when is_binary(host) and is_integer(port) do
    chan_data = encode_direct_tcpip(host, port)

    case :ssh_connection.open_channel(ssh_conn, ~c"direct-tcpip", chan_data, timeout) do
      {:ok, channel_id} -> {:ok, channel_id}
      {:error, :timeout} -> {:error, :timeout}
      {:error, reason} -> {:error, {:ssh_target_unreachable, reason}}
    end
  end

  defp open_channel(ssh_conn, {:unix, path}, timeout) when is_binary(path) do
    chan_data = encode_direct_streamlocal(path)

    case :ssh_connection.open_channel(
           ssh_conn,
           ~c"direct-streamlocal@openssh.com",
           chan_data,
           timeout
         ) do
      {:ok, channel_id} -> {:ok, channel_id}
      {:error, :timeout} -> {:error, :timeout}
      {:error, reason} -> {:error, {:streamlocal_not_supported_by_otp, reason}}
    end
  end

  defp session_channel(ssh_conn, timeout) do
    case :ssh_connection.session_channel(ssh_conn, timeout) do
      {:ok, channel_id} -> {:ok, channel_id}
      {:error, :timeout} -> {:error, :timeout}
      {:error, reason} -> {:error, {:ssh_target_unreachable, reason}}
    end
  end

  # OTP's `:ssh_connection.exec/4` typespec only permits
  # `:success | :failure | {:error, :timeout}`, but the runtime can
  # produce other `{:error, reason}` shapes (channel torn down,
  # connection lost, etc.) that we want to surface as a structured
  # `{:ssh_target_unreachable, _}` to the caller. Suppress the
  # narrowed-success-typing warning so the catch-all clause stays.
  @dialyzer {:nowarn_function, exec_on_channel: 4}
  defp exec_on_channel(ssh_conn, channel_id, command, timeout) do
    cmd_charlist = command |> IO.iodata_to_binary() |> String.to_charlist()

    case :ssh_connection.exec(ssh_conn, channel_id, cmd_charlist, timeout) do
      :success -> :ok
      :failure -> {:error, {:ssh_target_unreachable, :connection_failed}}
      {:error, :timeout} -> {:error, :timeout}
      {:error, reason} -> {:error, {:ssh_target_unreachable, reason}}
    end
  end

  # Channel-open data per RFC 4254 §7.2 (direct-tcpip):
  #   string  host to connect
  #   uint32  port to connect
  #   string  originator IP address
  #   uint32  originator port
  defp encode_direct_tcpip(host, port) when is_binary(host) and is_integer(port) do
    originator = "127.0.0.1"

    <<byte_size(host)::32, host::binary, port::32, byte_size(originator)::32, originator::binary,
      0::32>>
  end

  # Channel-open data per the OpenSSH PROTOCOL spec (direct-streamlocal):
  #   string  socket path
  #   string  reserved
  #   uint32  reserved
  defp encode_direct_streamlocal(path) when is_binary(path) do
    reserved = ""

    <<byte_size(path)::32, path::binary, byte_size(reserved)::32, reserved::binary, 0::32>>
  end

  @impl true
  def handle_continue(:accept, %{listen_socket: listen_socket} = state) do
    bridge = self()
    timeout = state.accept_timeout

    # Spawn an acceptor that:
    #   1. blocks on :gen_tcp.accept
    #   2. transfers ownership of the accepted socket to the bridge
    #      BEFORE exiting (otherwise OTP closes the socket when the
    #      acceptor dies)
    #   3. tells the bridge the result, then exits.
    spawn_link(fn -> accept_loop(listen_socket, timeout, bridge) end)

    {:noreply, state}
  end

  defp accept_loop(listen_socket, timeout, bridge) do
    result =
      case :gen_tcp.accept(listen_socket, timeout) do
        {:ok, client_socket} = ok -> hand_off_socket(client_socket, bridge, ok)
        {:error, _reason} = err -> err
      end

    send(bridge, {:accept_result, result})
  end

  defp hand_off_socket(client_socket, bridge, ok_result) do
    case :gen_tcp.controlling_process(client_socket, bridge) do
      :ok ->
        ok_result

      {:error, reason} ->
        _ = :gen_tcp.close(client_socket)
        {:error, {:controlling_process, reason}}
    end
  end

  @impl true
  def handle_call(:port, _from, %{listen_socket: listen_socket} = state) do
    {:ok, port} = :inet.port(listen_socket)
    {:reply, port, state}
  end

  @impl true
  def handle_info({:accept_result, {:ok, client_socket}}, state) do
    # The acceptor has already transferred ownership before exiting; we
    # just need to flush any pre-accept SSH data, activate the socket,
    # and forget the listener. Order matters: bytes that arrived from
    # the SSH side BEFORE the client connected must be delivered before
    # we activate the loopback socket and start handling new traffic.
    #
    # Drain queued `exit_status` / `exit_signal` channel messages from
    # our mailbox first so the accept-time poisoning decision below
    # sees the most up-to-date `exit_status` / `exit_signal` values.
    # Without this drain, a fast remote that emits exit_status BEFORE
    # the client connects can race the accept_result message and the
    # poisoning branch would miss the failure signal.
    state = drain_pending_exit_messages(state)
    #
    # Whether we flush an empty buffer or actual bytes determines
    # `bytes_forwarded?`: an empty flush means nothing has crossed the
    # boundary yet, so a captured exec failure can still be surfaced
    # as a typed shutdown reason. A non-empty flush means a response
    # has already reached Mint and we MUST keep the close invisible
    # (see the `bytes_forwarded?` comment in `init/1`).
    pending = state.pending_ssh_data
    had_pending? = pending !== []

    flushed_state =
      %{
        state
        | listen_socket: nil,
          client_socket: client_socket,
          pending_ssh_data: [],
          bytes_forwarded?: state.bytes_forwarded? or had_pending?
      }

    case flush_pending_to_socket(client_socket, pending) do
      :ok ->
        _ = :gen_tcp.close(state.listen_socket)

        cond do
          state.ssh_close_pending? and not flushed_state.bytes_forwarded? and exec_failed?(state) ->
            # Accept-time poisoning. The remote exec failed before any
            # bytes were produced AND the client has just connected.
            # The listener was already bound when Mint dialed in, so
            # we accept the connection only to immediately close it;
            # this lets Mint's connect succeed and then surface the
            # bridge's `{:shutdown, {:ssh_exec_failed, _}}` exit via
            # the transport's monitor. We can't reject the connect
            # outright (the listener is non-blocking accept-once and
            # Mint may already be mid-handshake), so we let it land
            # and poison it at this single point.
            _ = :gen_tcp.close(client_socket)

            {:stop, {:shutdown, {:ssh_exec_failed, exec_failure_reason(state)}},
             %{flushed_state | client_socket: nil}}

          state.ssh_close_pending? ->
            # The SSH side closed before the client connected. Flush is
            # done; close the loopback so Mint sees EOF after reading the
            # buffered response, and exit normally. This covers both the
            # clean-finish case (exit 0 or no exit_status at all, e.g.
            # direct-tcpip channels) AND the mid-stream-failure case
            # where bytes were buffered then a non-zero exit arrived -
            # we deliberately keep that invisible because a response
            # was produced.
            _ = :gen_tcp.close(client_socket)
            {:stop, :normal, %{flushed_state | client_socket: nil}}

          true ->
            :ok = :inet.setopts(client_socket, active: :once, packet: :raw)
            {:noreply, flushed_state}
        end

      {:error, reason} ->
        _ = :gen_tcp.close(state.listen_socket)
        {:stop, {:shutdown, {:loopback_send_failed, reason}}, flushed_state}
    end
  end

  def handle_info({:accept_result, {:error, :timeout}}, state) do
    {:stop, {:shutdown, :accept_timeout}, state}
  end

  def handle_info({:accept_result, {:error, reason}}, state) do
    {:stop, {:shutdown, {:accept_error, reason}}, state}
  end

  # Loopback -> SSH
  def handle_info({:tcp, sock, data}, %{client_socket: sock} = state) do
    case state.ssh_send_fun.(state.ssh_conn, state.channel_id, data) do
      :ok ->
        :ok = :inet.setopts(sock, active: :once)
        {:noreply, state}

      {:error, :closed} ->
        # The SSH channel has already been closed by the peer; the data
        # we were about to send is dropped silently. Close the loopback
        # so Mint sees EOF (after reading any buffered response that
        # arrived earlier) and exit normally - the channel close is the
        # peer's signal that the response is complete.
        close_client_socket(state)
        {:stop, :normal, %{state | client_socket: nil, ssh_closed?: true}}

      other ->
        {:stop, {:shutdown, {:ssh_send_failed, other}}, state}
    end
  end

  def handle_info({:tcp_closed, sock}, %{client_socket: sock} = state) do
    {:stop, :normal, %{state | client_socket: nil}}
  end

  def handle_info({:tcp_error, sock, reason}, %{client_socket: sock} = state) do
    {:stop, {:shutdown, {:tcp_error, reason}}, state}
  end

  # SSH -> loopback (client connected - forward immediately)
  def handle_info(
        {:ssh_cm, ssh_conn, {:data, channel_id, _type, data}},
        %{ssh_conn: ssh_conn, channel_id: channel_id, client_socket: sock} = state
      )
      when not is_nil(sock) do
    case :gen_tcp.send(sock, data) do
      :ok ->
        # A successful send means at least one byte from the SSH side
        # has now crossed the boundary toward Mint. Flip the flag so
        # any subsequent non-zero exit_status becomes invisible - see
        # the `bytes_forwarded?` comment in `init/1` for the tradeoff.
        {:noreply, %{state | bytes_forwarded?: true}}

      {:error, reason} ->
        {:stop, {:shutdown, {:loopback_send_failed, reason}}, state}
    end
  end

  # SSH -> loopback (client not yet connected - buffer until accept completes)
  def handle_info(
        {:ssh_cm, ssh_conn, {:data, channel_id, _type, data}},
        %{ssh_conn: ssh_conn, channel_id: channel_id, client_socket: nil} = state
      ) do
    {:noreply, %{state | pending_ssh_data: [state.pending_ssh_data, data]}}
  end

  def handle_info(
        {:ssh_cm, ssh_conn, {:eof, channel_id}},
        %{ssh_conn: ssh_conn, channel_id: channel_id, client_socket: sock} = state
      )
      when not is_nil(sock) do
    # SSH-side half-close. The remote may also have queued
    # `exit_status` / `exit_signal` channel messages just before
    # EOF; OTP delivers them as separate `:ssh_cm` messages and the
    # delivery order to *our* mailbox is not guaranteed to match
    # protocol order. Drain any queued exit messages from our
    # mailbox before deciding the stop reason, so a "ran-but-exited-
    # 127" sequence (exit_status + eof, in either mailbox order)
    # surfaces as a typed error rather than a `:normal` close.
    drained = drain_pending_exit_messages(state)
    close_client_socket(drained)
    {:stop, post_accept_close_reason(drained), %{drained | client_socket: nil}}
  end

  def handle_info(
        {:ssh_cm, ssh_conn, {:eof, channel_id}},
        %{ssh_conn: ssh_conn, channel_id: channel_id, client_socket: nil} = state
      ) do
    # Client hasn't connected yet. Defer the shutdown to the accept
    # handler so the buffered response is delivered before we close.
    {:noreply, %{state | ssh_close_pending?: true}}
  end

  def handle_info(
        {:ssh_cm, ssh_conn, {:closed, channel_id}},
        %{ssh_conn: ssh_conn, channel_id: channel_id, client_socket: sock} = state
      )
      when not is_nil(sock) do
    # Same drain as in the `:eof` handler - `exit_status` may still
    # be sitting in our mailbox even though the channel-close
    # message has been pulled. See that handler's comment for why
    # this matters.
    drained = drain_pending_exit_messages(state)
    close_client_socket(drained)
    # The channel has already been closed by the peer; mark it so
    # terminate/2 doesn't redundantly close it. Decide between :normal
    # (a response was already produced, OR no exec failure was
    # captured) and `{:shutdown, {:ssh_exec_failed, _}}` (no bytes
    # forwarded AND a non-zero exit_status / exit_signal landed).
    {:stop, post_accept_close_reason(drained), %{drained | client_socket: nil, ssh_closed?: true}}
  end

  def handle_info(
        {:ssh_cm, ssh_conn, {:closed, channel_id}},
        %{ssh_conn: ssh_conn, channel_id: channel_id, client_socket: nil} = state
      ) do
    # Same as :eof - defer until the client has connected and the
    # buffered response has been flushed.
    {:noreply, %{state | ssh_close_pending?: true, ssh_closed?: true}}
  end

  # SSH `exit_status` / `exit_signal` channel messages.
  #
  # We capture these into state instead of dropping them. The reason
  # is exec semantics: the SSH server accepts the exec request first
  # (the channel becomes "successfully open"), then the program runs
  # - and only at channel-close time do we know whether the program
  # actually produced anything useful. A non-zero exit_status (e.g.
  # `dial-stdio: not found, exit 127`) is the only signal a remote
  # exec ever has that "the thing you asked for never happened".
  #
  # The decision of whether to surface this as a typed error is
  # deferred to the close handler, which weighs the captured value
  # against `bytes_forwarded?` (see `init/1` for that flag's
  # tradeoff).
  def handle_info(
        {:ssh_cm, ssh_conn, {:exit_status, channel_id, status}},
        %{ssh_conn: ssh_conn, channel_id: channel_id} = state
      ) do
    {:noreply, %{state | exit_status: status}}
  end

  def handle_info(
        {:ssh_cm, ssh_conn, {:exit_signal, channel_id, sig, msg, _lang}},
        %{ssh_conn: ssh_conn, channel_id: channel_id} = state
      ) do
    # Normalise the OTP charlist sig/msg into UTF-8 strings so the
    # exit_signal stored in state has a stable shape that test
    # assertions and log lines can match without round-tripping
    # through `to_string/1` repeatedly.
    {:noreply, %{state | exit_signal: {charlist_to_string(sig), charlist_to_string(msg)}}}
  end

  # The acceptor process exiting normally is expected (it sent us its
  # result and is done). Any other exit from a linked process tears us
  # down - but we want our terminate/2 to run.
  def handle_info({:EXIT, _pid, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %{owner: owner} = state) when pid === owner do
    {:stop, {:shutdown, {:owner_down, reason}}, state}
  end

  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, {:shutdown, {:linked_exit, reason}}, state}
  end

  # Catch-all for stray messages (other channels, late deliveries, etc.).
  # Logging at debug avoids noise in normal operation while leaving a
  # breadcrumb if something genuinely unexpected arrives.
  def handle_info(msg, state) do
    Logger.debug(fn -> "Sorrel.Transport.SSH.Bridge ignoring message: #{inspect(msg)}" end)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    close_client_socket(state)
    close_listen_socket(state)
    close_ssh(state)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp fetch_required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_args, {:missing, key}}}
    end
  end

  defp link_to_owner(pid) when is_pid(pid) do
    Process.link(pid)
    :ok
  rescue
    _ -> {:error, {:invalid_args, {:owner_dead, pid}}}
  end

  defp link_to_owner(other), do: {:error, {:invalid_args, {:owner_not_pid, other}}}

  defp open_listener do
    :gen_tcp.listen(0,
      ip: {127, 0, 0, 1},
      mode: :binary,
      active: false,
      packet: :raw,
      reuseaddr: true,
      backlog: 1
    )
  end

  defp close_listen_socket(%{listen_socket: nil}), do: :ok

  defp close_listen_socket(%{listen_socket: socket}) do
    _ = :gen_tcp.close(socket)
    :ok
  end

  defp close_client_socket(%{client_socket: nil}), do: :ok

  defp close_client_socket(%{client_socket: socket}) do
    _ = :gen_tcp.close(socket)
    :ok
  end

  # Writes any pre-accept SSH data to the just-connected loopback
  # socket. Returns :ok on success or {:error, reason} on send failure.
  # An empty pending buffer is a no-op.
  defp flush_pending_to_socket(_socket, []), do: :ok

  defp flush_pending_to_socket(socket, pending) do
    case :gen_tcp.send(socket, pending) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  defp close_ssh(%{ssh_closed?: true} = state) do
    # Channel already torn down by the peer; just close the connection.
    safely(fn -> state.ssh_conn_close_fun.(state.ssh_conn) end)
    :ok
  end

  defp close_ssh(state) do
    safely(fn -> state.ssh_close_fun.(state.ssh_conn, state.channel_id) end)
    safely(fn -> state.ssh_conn_close_fun.(state.ssh_conn) end)
    :ok
  end

  defp safely(fun) do
    fun.()
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  # Drains any queued `{:ssh_cm, _, {:exit_status, _, _}}` and
  # `{:ssh_cm, _, {:exit_signal, _, _, _, _}}` messages from the
  # bridge's own mailbox into state, applying the same captures as
  # the regular handlers do.
  #
  # Why this exists: OTP `:ssh` delivers exit-status, exit-signal,
  # eof, and close as separate `:ssh_cm` messages, and the order in
  # which they reach our mailbox is not guaranteed to match
  # protocol order. We want close-time decisions to see the latest
  # available values, so we pull any queued exit messages forward
  # before deciding the stop reason.
  #
  # Uses a 0-timeout selective receive: only messages already in
  # the mailbox are taken; the bridge is never blocked waiting for
  # one to arrive.
  @spec drain_pending_exit_messages(map()) :: map()
  defp drain_pending_exit_messages(state) do
    ssh_conn = state.ssh_conn
    channel_id = state.channel_id

    receive do
      {:ssh_cm, ^ssh_conn, {:exit_status, ^channel_id, status}} ->
        drain_pending_exit_messages(%{state | exit_status: status})

      {:ssh_cm, ^ssh_conn, {:exit_signal, ^channel_id, sig, msg, _lang}} ->
        drain_pending_exit_messages(%{
          state
          | exit_signal: {charlist_to_string(sig), charlist_to_string(msg)}
        })
    after
      0 -> state
    end
  end

  # Has the channel signalled a remote-exec failure? True when an
  # exit_status was captured and is non-zero, OR an exit_signal was
  # captured. A nil exit_status means the channel never reported one
  # (e.g. direct-tcpip channels never do) - that's not a failure
  # signal, just absence of information.
  @spec exec_failed?(map()) :: boolean()
  defp exec_failed?(state) do
    case state.exit_status do
      nil -> state.exit_signal !== nil
      0 -> state.exit_signal !== nil
      _ -> true
    end
  end

  # Builds the second element of `{:ssh_exec_failed, reason}`. We
  # prefer exit_status when both are present (Unix convention: the
  # signal is the cause, but the status is what the shell would
  # report). Shape is intentionally narrow - `{:status, n}` for a
  # non-zero exit code, `{:signal, "TERM"}` for a signal-driven exit.
  @spec exec_failure_reason(map()) ::
          {:status, non_neg_integer()} | {:signal, String.t()}
  defp exec_failure_reason(%{exit_status: n}) when is_integer(n) and n !== 0 do
    {:status, n}
  end

  defp exec_failure_reason(%{exit_signal: {sig, _msg}}) when is_binary(sig) do
    {:signal, sig}
  end

  # Picks the GenServer stop reason at post-accept channel-close time.
  # Mirrors the logic in the accept-time poisoning branch: surface a
  # typed error only when no response was produced and a remote-exec
  # failure was captured. Otherwise stay `:normal` to preserve the
  # existing behaviour for clean closes and mid-stream exits.
  @spec post_accept_close_reason(map()) ::
          :normal | {:shutdown, {:ssh_exec_failed, term()}}
  defp post_accept_close_reason(state) do
    if not state.bytes_forwarded? and exec_failed?(state) do
      {:shutdown, {:ssh_exec_failed, exec_failure_reason(state)}}
    else
      :normal
    end
  end

  # OTP delivers exit_signal sig/msg as charlists. We render them as
  # UTF-8 strings; if the bytes aren't valid UTF-8 (vanishingly rare
  # but theoretically possible from a malformed peer), fall back to
  # `inspect/1` so the value is at least loggable rather than
  # crashing the bridge.
  @spec charlist_to_string(charlist() | binary() | term()) :: String.t()
  defp charlist_to_string(value) when is_list(value) do
    List.to_string(value)
  rescue
    _ -> inspect(value)
  end

  defp charlist_to_string(value) when is_binary(value), do: value
  defp charlist_to_string(value), do: inspect(value)

  defp default_ssh_send(ssh_conn, channel_id, data) do
    :ssh_connection.send(ssh_conn, channel_id, data)
  end

  defp default_ssh_close(ssh_conn, channel_id) do
    :ssh_connection.close(ssh_conn, channel_id)
  end

  defp default_ssh_conn_close(ssh_conn) do
    :ssh.close(ssh_conn)
  end
end

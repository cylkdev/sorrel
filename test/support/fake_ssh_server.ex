defmodule Sorrel.Test.FakeSSHServer do
  @moduledoc """
  Minimal in-process SSH daemon for use in ExUnit tests.

  Spawns an Erlang `:ssh` daemon bound to `127.0.0.1` on an ephemeral
  port. Configurable to accept password and/or public-key authentication
  and to handle three different channel modes that exercise the
  `Sorrel.Transport.SSH` paths:

    1. **`session` channel + `exec`** — when the client sends an `exec`
       request, the daemon spawns a small handler that bridges the
       channel's stdin/stdout to a caller-supplied function. This is
       what tests use to mock "remote command stdout speaks HTTP/1.1".
    2. **`direct-tcpip`** — handled natively by the OTP daemon when
       `:tcpip_tunnel_in` is enabled (which is the default for this
       module). The daemon connects out to whatever host/port the
       client requested and bridges bytes.
    3. **`direct-streamlocal@openssh.com`** — *not supported by the
       OTP `:ssh` daemon*. See **Streamlocal limitation** below.

  Host keys are generated on demand into a temporary system directory
  that the server cleans up on `stop/1`. The fingerprint is exposed in
  the start result so tests can assemble a `known_hosts` entry without
  reaching into the temp dir directly.

  ## Rules that always hold

    * The daemon binds `127.0.0.1` only — never an externally
      reachable interface.
    * The daemon is stopped synchronously on `stop/1`, and the temp
      `system_dir`, `user_dir`, and any `authorized_keys` content are
      removed before `stop/1` returns.
    * If the caller does not enable a given auth method, the daemon
      will reject it. With no auth methods enabled at all, every
      connection will fail.
    * The fingerprint reported in `start/1`'s success tuple is the
      SHA-256 fingerprint of the daemon's RSA host key, in the format
      OpenSSH prints (`SHA256:<base64>`), as a binary.

  ## Streamlocal limitation

  The OTP `:ssh` daemon does not implement the
  `direct-streamlocal@openssh.com` channel type. A client that opens
  such a channel against this fake server will receive a
  `SSH_OPEN_UNKNOWN_CHANNEL_TYPE` failure regardless of the
  `:streamlocal_targets` option. End-to-end tests for streamlocal
  forwarding require a real OpenSSH daemon. The option is accepted
  (and documented) so the transport's API surface stays exercise-able
  without crashing the fake server, but no streamlocal traffic will
  actually flow.

  ## Examples

      iex> {:ok, pid, %{port: port, host_key_fingerprint: fp}} =
      ...>   Sorrel.Test.FakeSSHServer.start(
      ...>     auth_methods: [:password],
      ...>     user: "testuser",
      ...>     password: "testpass"
      ...>   )
      iex> is_integer(port) and port > 0
      true
      iex> String.starts_with?(fp, "SHA256:")
      true
      iex> :ok = Sorrel.Test.FakeSSHServer.stop(pid)
  """

  use GenServer

  require Logger

  @type auth_method :: :password | :publickey

  @type exec_handler ::
          (charlist(),
           (iodata() -> :ok),
           (timeout :: non_neg_integer() -> {:ok, binary()} | :eof | {:error, term()}) ->
             :ok)

  @type info :: %{
          port: :inet.port_number(),
          host_key_fingerprint: binary(),
          system_dir: charlist()
        }

  @type start_opts :: [
          {:auth_methods, [auth_method()]}
          | {:user, String.t()}
          | {:password, String.t()}
          | {:authorized_keys, binary()}
          | {:exec_handler, exec_handler()}
          | {:tcpip_targets, %{optional(:inet.port_number()) => true}}
          | {:streamlocal_targets, [Path.t()]}
        ]

  ## Public API

  @doc """
  Starts the fake SSH daemon.

  ## Options

    * `:auth_methods` — list of `:password` and/or `:publickey`. Default
      is `[:password, :publickey]`. Order is preserved when telling the
      daemon which methods to advertise.
    * `:user` — the accepted username. Required when `:password` is in
      `:auth_methods`.
    * `:password` — the accepted password (binary). Required when
      `:password` is in `:auth_methods`.
    * `:authorized_keys` — binary content for `authorized_keys`,
      written into the daemon's `user_dir`. Required when `:publickey`
      is in `:auth_methods`.
    * `:exec_handler` — a 3-arity function called for every `exec`
      request: `(cmd_charlist, send_fun, recv_fun) -> :ok`. The
      `send_fun` writes data back as channel stdout. The `recv_fun`
      blocks for incoming channel data with a timeout in milliseconds.
      If absent, exec requests are rejected.
    * `:tcpip_targets` — currently informational only; OTP's
      `direct-tcpip` handler does not consult a per-port whitelist.
      Accepted for forward compatibility.
    * `:streamlocal_targets` — accepted but not honoured; see
      "Streamlocal limitation" in the moduledoc.

  Returns `{:ok, pid, info}` on success where `info` is a map with
  `:port`, `:host_key_fingerprint` (string `"SHA256:..."`), and
  `:system_dir` (charlist path to the temp dir holding the host key).
  """
  @spec start(start_opts()) :: {:ok, pid(), info()} | {:error, term()}
  def start(opts \\ []) do
    case GenServer.start(__MODULE__, opts) do
      {:ok, pid} ->
        case GenServer.call(pid, :info, 10_000) do
          {:ok, info} -> {:ok, pid, info}
          {:error, _reason} = err -> err
        end

      {:error, _reason} = err ->
        err
    end
  end

  @doc """
  Stops the daemon and removes its temporary directories.

  Always returns `:ok`. Calling `stop/1` on an already-stopped server
  is safe.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end

  ## GenServer

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, validated} <- validate_opts(opts),
         {:ok, paths} <- prepare_paths(validated),
         {:ok, daemon} <- start_daemon(validated, paths) do
      {:ok, port} = fetch_daemon_port(daemon)

      info = %{
        port: port,
        host_key_fingerprint: paths.fingerprint,
        system_dir: paths.system_dir
      }

      {:ok,
       %{
         daemon: daemon,
         paths: paths,
         info: info
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, %{info: info} = state) do
    {:reply, {:ok, info}, state}
  end

  @impl true
  def terminate(_reason, %{daemon: daemon, paths: paths}) do
    _ = stop_daemon_safely(daemon)
    _ = cleanup_paths(paths)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Internals

  defp validate_opts(opts) do
    auth_methods = Keyword.get(opts, :auth_methods, [:password, :publickey])

    with :ok <- validate_auth_methods(auth_methods),
         :ok <- validate_password_auth(auth_methods, opts),
         :ok <- validate_publickey_auth(auth_methods, opts) do
      {:ok,
       %{
         auth_methods: auth_methods,
         user: Keyword.get(opts, :user),
         password: Keyword.get(opts, :password),
         authorized_keys: Keyword.get(opts, :authorized_keys),
         exec_handler: Keyword.get(opts, :exec_handler)
       }}
    end
  end

  defp validate_auth_methods(methods) when not is_list(methods),
    do: {:error, {:invalid_option, :auth_methods}}

  defp validate_auth_methods([]), do: {:error, :no_auth_methods}

  defp validate_auth_methods(methods) do
    if Enum.any?(methods, fn m -> m not in [:password, :publickey] end) do
      {:error, {:invalid_auth_method, methods}}
    else
      :ok
    end
  end

  defp validate_password_auth(methods, opts) do
    cond do
      :password not in methods -> :ok
      is_nil(Keyword.get(opts, :user)) -> {:error, :password_auth_requires_user}
      is_nil(Keyword.get(opts, :password)) -> {:error, :password_auth_requires_password}
      true -> :ok
    end
  end

  defp validate_publickey_auth(methods, opts) do
    cond do
      :publickey not in methods ->
        :ok

      is_nil(Keyword.get(opts, :authorized_keys)) ->
        {:error, :publickey_auth_requires_authorized_keys}

      true ->
        :ok
    end
  end

  defp prepare_paths(validated) do
    base = Path.join(System.tmp_dir!(), "fake_ssh_server_#{:erlang.unique_integer([:positive])}")
    system_dir = Path.join(base, "system")
    user_dir = Path.join(base, "user")
    File.mkdir_p!(system_dir)
    File.mkdir_p!(user_dir)

    {private_key, public_key} = generate_rsa_host_key()
    pem = encode_rsa_private_key_pem(private_key)
    host_key_path = Path.join(system_dir, "ssh_host_rsa_key")
    File.write!(host_key_path, pem)
    File.chmod!(host_key_path, 0o600)

    fingerprint =
      :sha256
      |> :ssh.hostkey_fingerprint(public_key)
      |> List.to_string()

    if is_binary(validated.authorized_keys) do
      authorized_keys_path = Path.join(user_dir, "authorized_keys")
      File.write!(authorized_keys_path, validated.authorized_keys)
    end

    {:ok,
     %{
       base: base,
       system_dir: String.to_charlist(system_dir),
       user_dir: String.to_charlist(user_dir),
       fingerprint: fingerprint
     }}
  end

  defp start_daemon(validated, paths) do
    daemon_opts = build_daemon_opts(validated, paths)

    case :ssh.daemon({127, 0, 0, 1}, 0, daemon_opts) do
      {:ok, daemon} -> {:ok, daemon}
      {:error, reason} -> {:error, {:daemon_start_failed, reason}}
    end
  end

  defp build_daemon_opts(validated, paths) do
    base = [
      system_dir: paths.system_dir,
      user_dir: paths.user_dir,
      auth_methods: encode_auth_methods(validated.auth_methods),
      tcpip_tunnel_in: true,
      tcpip_tunnel_out: false,
      ssh_cli: cli_spec(validated.exec_handler),
      subsystems: [],
      no_auth_needed: false,
      idle_time: :infinity,
      parallel_login: false
    ]

    base
    |> add_pwdfun(validated)
    |> add_pubkey_opts(validated)
  end

  defp encode_auth_methods(methods) do
    methods
    |> Enum.map_join(",", fn
      :password -> "password"
      :publickey -> "publickey"
    end)
    |> String.to_charlist()
  end

  defp cli_spec(nil), do: :no_cli

  defp cli_spec(handler) when is_function(handler, 3) do
    {Sorrel.Test.FakeSSHServer.Cli, [handler]}
  end

  defp add_pwdfun(opts, %{auth_methods: methods}) when methods === [:publickey], do: opts

  defp add_pwdfun(opts, %{user: user, password: password}) do
    expected_user = String.to_charlist(user)
    expected_pass = String.to_charlist(password)

    pwdfun = fn user_in, pass_in, _peer, _state ->
      user_in === expected_user and pass_in === expected_pass
    end

    Keyword.put(opts, :pwdfun, pwdfun)
  end

  defp add_pubkey_opts(opts, %{authorized_keys: nil}), do: opts
  defp add_pubkey_opts(opts, %{authorized_keys: _content}), do: opts

  defp fetch_daemon_port(daemon) do
    case :ssh.daemon_info(daemon) do
      {:ok, info} ->
        case Keyword.fetch(info, :port) do
          {:ok, port} -> {:ok, port}
          :error -> {:error, :no_port_in_daemon_info}
        end

      {:error, _} = err ->
        err
    end
  end

  defp stop_daemon_safely(daemon) do
    :ssh.stop_daemon(daemon)
  catch
    _kind, _reason -> :ok
  end

  defp cleanup_paths(%{base: base}) do
    File.rm_rf(base)
  rescue
    _ -> :ok
  end

  defp cleanup_paths(_), do: :ok

  ## Crypto helpers

  # We generate an RSA-2048 host key and use the legacy PEM format
  # because OTP 27's `:ssh_file.encode/2` with `:openssh_key_v1` is
  # broken for RSA private keys. PEM is read back without issue by
  # `:ssh_file.host_key/2`.
  defp generate_rsa_host_key do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    public_key = rsa_public_from_private(private_key)
    {private_key, public_key}
  end

  # The RSAPrivateKey record is:
  #   {:RSAPrivateKey, version, modulus, publicExponent, privateExponent, ...}
  # The RSAPublicKey record is:
  #   {:RSAPublicKey, modulus, publicExponent}
  defp rsa_public_from_private(private_key) do
    modulus = elem(private_key, 2)
    public_exponent = elem(private_key, 3)
    {:RSAPublicKey, modulus, public_exponent}
  end

  defp encode_rsa_private_key_pem(private_key) do
    pem_entry = :public_key.pem_entry_encode(:RSAPrivateKey, private_key)
    :public_key.pem_encode([pem_entry])
  end
end

defmodule Sorrel.Test.FakeSSHServer.Cli do
  @moduledoc """
  Custom `:ssh_server_channel` callback used by
  `Sorrel.Test.FakeSSHServer` to handle session channels.

  When the client issues an `exec` request, this module spawns a
  helper process that runs the user-supplied `exec_handler/3` with a
  pair of closures bound to the channel:

    * `send_fun` writes channel-stdout bytes back to the client.
    * `recv_fun` returns the next inbound chunk of channel-stdin from
      the client (or `:eof` if EOF has been signalled).

  The handler runs inside a linked process so a crash in the handler
  closes the channel cleanly without taking down the daemon.

  This module is not part of the public API of
  `Sorrel.Test.FakeSSHServer`. It is exposed only because the
  OTP `:ssh` daemon needs a module name to spawn callback processes
  from.
  """

  @behaviour :ssh_server_channel

  require Logger

  @type state :: %{
          handler: Sorrel.Test.FakeSSHServer.exec_handler(),
          channel_id: term() | nil,
          conn: term() | nil,
          worker: pid() | nil,
          buffer: :queue.queue(binary() | :eof),
          waiting: nil | {pid(), reference()}
        }

  ## ssh_server_channel callbacks

  @impl true
  def init([handler]) do
    state = %{
      handler: handler,
      channel_id: nil,
      conn: nil,
      worker: nil,
      buffer: :queue.new(),
      waiting: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_msg({:ssh_channel_up, channel_id, conn}, state) do
    {:ok, %{state | channel_id: channel_id, conn: conn}}
  end

  def handle_msg({:fake_ssh_recv, from, ref}, state) do
    case :queue.out(state.buffer) do
      {{:value, item}, rest} ->
        send(from, {:fake_ssh_recv_reply, ref, item})
        {:ok, %{state | buffer: rest}}

      {:empty, _} ->
        {:ok, %{state | waiting: {from, ref}}}
    end
  end

  def handle_msg({:fake_ssh_send, iodata}, %{conn: conn, channel_id: ch} = state)
      when not is_nil(conn) and not is_nil(ch) do
    case :ssh_connection.send(conn, ch, iodata) do
      :ok -> {:ok, state}
      {:error, _reason} -> {:stop, ch, state}
    end
  end

  def handle_msg({:fake_ssh_done, _result}, %{channel_id: ch, conn: conn} = state) do
    if not is_nil(conn) and not is_nil(ch) do
      _ = :ssh_connection.send_eof(conn, ch)
      _ = :ssh_connection.exit_status(conn, ch, 0)
      _ = :ssh_connection.close(conn, ch)
    end

    {:stop, ch, state}
  end

  def handle_msg({:EXIT, pid, reason}, %{worker: pid, channel_id: ch, conn: conn} = state) do
    if reason !== :normal do
      Logger.debug("FakeSSHServer exec handler crashed: #{inspect(reason)}")
    end

    if not is_nil(conn) and not is_nil(ch) do
      _ = :ssh_connection.send_eof(conn, ch)
      _ = :ssh_connection.exit_status(conn, ch, exit_code_for(reason))
      _ = :ssh_connection.close(conn, ch)
    end

    {:stop, ch, %{state | worker: nil}}
  end

  def handle_msg(_msg, state) do
    {:ok, state}
  end

  @impl true
  def handle_ssh_msg({:ssh_cm, conn, {:exec, channel_id, want_reply, cmd}}, state) do
    handler = state.handler

    if is_nil(handler) do
      :ssh_connection.reply_request(conn, want_reply, :failure, channel_id)
      {:stop, channel_id, state}
    else
      :ssh_connection.reply_request(conn, want_reply, :success, channel_id)
      worker = spawn_worker(self(), handler, cmd)
      {:ok, %{state | worker: worker}}
    end
  end

  def handle_ssh_msg({:ssh_cm, _conn, {:data, channel_id, _type, data}}, state) do
    state2 = enqueue_input(state, data)
    _ = :ssh_connection.adjust_window(state.conn, channel_id, byte_size(data))
    {:ok, state2}
  end

  def handle_ssh_msg({:ssh_cm, _conn, {:eof, _channel_id}}, state) do
    state2 = enqueue_input(state, :eof)
    {:ok, state2}
  end

  def handle_ssh_msg({:ssh_cm, _conn, {:signal, _channel_id, _signal}}, state) do
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _conn, {:closed, channel_id}}, state) do
    {:stop, channel_id, state}
  end

  def handle_ssh_msg(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{worker: worker}) do
    if is_pid(worker) and Process.alive?(worker) do
      Process.exit(worker, :shutdown)
    end

    :ok
  end

  ## Internals

  defp spawn_worker(channel_pid, handler, cmd) do
    spawn_link(fn ->
      send_fun = fn iodata ->
        send(channel_pid, {:fake_ssh_send, iodata})
        :ok
      end

      recv_fun = fn timeout ->
        ref = make_ref()
        send(channel_pid, {:fake_ssh_recv, self(), ref})

        receive do
          {:fake_ssh_recv_reply, ^ref, :eof} -> :eof
          {:fake_ssh_recv_reply, ^ref, data} -> {:ok, data}
        after
          timeout -> {:error, :timeout}
        end
      end

      result =
        try do
          handler.(cmd, send_fun, recv_fun)
        rescue
          e ->
            Logger.debug("FakeSSHServer exec handler raised: #{Exception.message(e)}")
            {:error, e}
        end

      send(channel_pid, {:fake_ssh_done, result})
    end)
  end

  defp enqueue_input(%{waiting: nil} = state, item) do
    %{state | buffer: :queue.in(item, state.buffer)}
  end

  defp enqueue_input(%{waiting: {pid, ref}} = state, item) do
    send(pid, {:fake_ssh_recv_reply, ref, item})
    %{state | waiting: nil}
  end

  defp exit_code_for(:normal), do: 0
  defp exit_code_for(_), do: 1
end

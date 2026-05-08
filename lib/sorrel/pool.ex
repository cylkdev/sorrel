defmodule Sorrel.Pool do
  @moduledoc """
  A registry of connection pools, with one pool per server you talk to.

  When you talk to many servers from the same application, each server
  gets its own pool of workers - typically 10 by default - and each
  worker holds its own open connection. Reusing a worker means reusing
  its connection, which avoids the TCP handshake and TLS handshake on
  every request.

  ## How a pool comes into being

  Pools come into being **lazily** - the first `checkout/3` for an
  endpoint signature spawns the pool if none exists yet. You can also
  start a pool eagerly with `start/2` (or its alias
  `ensure_started/2`) when you want to warm a pool at boot time.

  `start/2` is **idempotent**: calling it twice for the same endpoint
  returns the same pool name without doing anything new.

      iex> {:ok, pool_name} = Sorrel.Pool.start(endpoint)

  Most callers never need to call this module directly.
  `Sorrel.request/5` and `Sorrel.stream/5` (where pooled)
  call `checkout/3` themselves.

  ## How pools are identified

  A pool is keyed by an internal **signature** of the endpoint, not by
  the endpoint struct itself. The signatures are:

    * for Unix endpoints: `{:unix, socket_path}`.
    * for TCP endpoints: `{:tcp, scheme, host, port, tls_signature}`,
      where `tls_signature` is `:no_tls` for plain HTTP/HTTPS-with-OS-CA,
      or a four-tuple of `{verify, cacertfile, certfile, keyfile}` paths
      when explicit TLS material is set.
    * for SSH endpoints: `{:ssh, host, port, user, target, auth_signature}`,
      where `target` is the endpoint's `target` field as-is
      (`{:exec, _}` / `{:tcp, _, _}` / `{:unix, _}`) and `auth_signature`
      is a five-tuple of
      `{auth_methods, identity_file, has_password?, known_hosts_file, verify}`.
      The literal password value is **not** part of the signature
      (only a boolean indicating whether one was supplied), so two
      otherwise-identical endpoints differing only in password share a
      pool. `connect_timeout` is also excluded - it is a per-connect
      knob, not a destination identifier.

  Two endpoint structs that hash to the same signature share a pool.

  ## Sizing and idle eviction

  Defaults:

    * `:pool_size` - `10` workers.
    * `:pool_timeout` - `5_000` milliseconds to wait for a free worker.
    * `:conn_max_idle_time` - `30_000` milliseconds. A worker whose conn
      has been idle longer than this opens a fresh conn at the next
      checkout instead of reusing the stale one.
    * `:pool_max_idle_time` - `:infinity`. When set to a finite value,
      the entire pool is torn down once it stays idle that long; the
      next call lazily spawns a new one.

  Sizing and idle-eviction options are read from the **first** call
  for an endpoint signature (whether that's a `start/2` or a lazy
  `checkout/3`); later calls' values are silently ignored. This keeps
  pool identity stable.

  ## Examples

      # Send a request - checkout/3 spawns the pool on the first call:
      iex> ep = %Sorrel.Endpoint{transport: :unix, socket_path: "/tmp/myapp.sock"}
      iex> Sorrel.Pool.checkout(ep, fn {_kind, conn, _ep, _opts} ->
      ...>   {{:ok, :hello}, {:ok, conn}}
      ...> end)
      {:ok, :hello}

      # Or warm the pool at boot:
      iex> {:ok, _pool_name} = Sorrel.Pool.start(ep)
  """

  # What this module is:
  #   Runtime state is the union of:
  #     - entries in Sorrel.Pool.Registry
  #     - children of Sorrel.Pool.DynamicSupervisor
  #   Together they map endpoint-signatures to live NimblePool processes.
  #   Default starting state: empty registry, no children.
  #
  # Rules that always hold:
  #   1. Every (sig, pid) entry in the registry has a matching live child
  #      under the DynamicSupervisor.
  #   2. start/2 is idempotent for the same endpoint signature: concurrent
  #      first-use yields exactly one pool, not several.
  #   3. checkout/3 spawns a pool lazily on first call for a signature.
  #      The lazy-start path is also race-tolerant.

  alias Sorrel.Endpoint
  alias Sorrel.Pool.Worker

  @type pool_name :: {:via, module(), {module(), term()}}

  @doc """
  Returns `{:ok, pool_name}` for the pool that handles `endpoint`,
  starting a new pool if one does not exist yet.

  Safe to call as often as you like - repeated calls for the same
  endpoint signature do nothing extra. The first call wins on sizing
  and idle-eviction options.

  ## Parameters

    * `endpoint` - `Sorrel.Endpoint.t()`. The pool is keyed by an
      internal **signature** derived from this endpoint, not by the
      struct identity. See the module docs above for what fields go
      into the signature.

    * `opts` - `keyword()`. Recognised keys (only honoured on the very
      first call for an endpoint signature):

      | Key                   | Type                | Default     | What it does                                                 |
      | --------------------- | ------------------- | ----------- | ------------------------------------------------------------ |
      | `:pool_size`          | positive integer    | `10`        | Number of workers in the pool.                               |
      | `:conn_max_idle_time` | non-neg integer / `:infinity` | `30_000` | Per-conn max idle time, in milliseconds.            |
      | `:pool_max_idle_time` | non-neg integer / `:infinity` | `:infinity` | Pool-wide max idle time before the pool is torn down. |
      | `:connect_timeout`    | non-neg integer     | `10_000`    | Forwarded to `Transport.connect/2` on each open.             |

      Any other keys are ignored.

  ## Returns

    * `{:ok, pool_name}` - the pool exists and is ready to use.
      `pool_name` is an opaque `:via` tuple suitable for handing to
      `NimblePool.checkout!/4`. Callers normally do not look inside this
      value.

  This function does not raise.
  """
  @spec start(Endpoint.t(), keyword()) :: {:ok, pool_name()}
  def start(%Endpoint{} = endpoint, opts \\ []) when is_list(opts) do
    sig = signature(endpoint)
    name = pool_name(sig)

    case Registry.lookup(Sorrel.Pool.Registry, sig) do
      [{_pid, _value}] ->
        {:ok, name}

      [] ->
        spec = nimble_pool_spec(sig, endpoint, opts)

        case DynamicSupervisor.start_child(Sorrel.Pool.DynamicSupervisor, spec) do
          {:ok, _pid} -> {:ok, name}
          {:error, {:already_started, _pid}} -> {:ok, name}
        end
    end
  end

  @doc """
  Alias for `start/2`. Provided so that callers can clearly express
  intent: "warm up the pool at boot, do nothing if it already exists".
  """
  @spec ensure_started(Endpoint.t(), keyword()) :: {:ok, pool_name()}
  def ensure_started(%Endpoint{} = endpoint, opts \\ []) when is_list(opts) do
    start(endpoint, opts)
  end

  @doc """
  Borrows a worker from the pool for `endpoint`, runs `fun.(client_state)`,
  returns the worker to the pool, and returns whatever the result tuple's
  first element was.

  The worker is returned to the pool **even if `fun` raises or exits** -
  workers cannot leak from the pool through bad caller code. A non-
  successful result causes the worker to be evicted (rather than
  reused) so a half-consumed conn cannot be handed to the next request.

  Lazily starts a pool for `endpoint` if none exists yet.

  ## Parameters

    * `endpoint` - `Sorrel.Endpoint.t()`. The pool is started on
      first use if it does not already exist.

    * `fun` - `((client_state) -> {result, checkin})`. Receives a
      four-tuple `{kind, conn, endpoint, conn_opts}`:

        - `kind` - `:fresh` for a newly opened conn, `:reused` for one
          taken from the pool.
        - `conn` - a `Mint.HTTP.t()` in passive mode.
        - `endpoint` - the endpoint the conn speaks to (used for retry
          on stale-reuse failure).
        - `conn_opts` - keyword forwarded to `Transport.connect/2` if a
          retry needs to open a fresh conn.

      The function MUST return `{result, checkin}` where `result` is
      surfaced to the caller and `checkin` is one of:

        - `{:ok, conn}` - the conn is returned to the pool and reused
          on the next checkout.
        - `{:closed, reason}` - the conn was closed (or is unsafe to
          reuse). The worker is evicted.

      `Sorrel.Pool.Worker.run_request/6` produces this shape from
      `Conn.request/6`'s return value.

    * `opts` - `keyword()`. Recognised keys:

      | Key                | Type                | Default     | What it does                                       |
      | ------------------ | ------------------- | ----------- | -------------------------------------------------- |
      | `:pool_timeout`    | non-neg integer     | `5_000`     | Milliseconds to wait for a free worker.            |
      | `:poolboy_timeout` | non-neg integer     | `5_000`     | Backwards-compat alias for `:pool_timeout`.         |

      Lazy-start passes through `opts` to `start/2`. Any other keys
      are ignored.

  ## Returns

    * `result` - the first element of whatever `fun` returned.

  ## Raises

    * `Sorrel.Pool.NotStartedError` - Lazy-start would normally
      mean this never raises. The exception is preserved for
      compatibility with callers that rely on it; it is raised when a
      `:noproc` exit propagates after a pool start race that loses to a
      concurrent shutdown.

    * Any exception raised by `fun` itself.

  ## Exits

    * `{:timeout, _}` - no worker became free within `:pool_timeout`
      milliseconds. This is the standard `NimblePool.checkout!/4`
      timeout exit.
  """
  @spec checkout(
          Endpoint.t(),
          (Worker.client_state() -> {term(), Worker.checkin_reason()}),
          keyword()
        ) ::
          term()
  def checkout(%Endpoint{} = endpoint, fun, opts \\ [])
      when is_function(fun, 1) and is_list(opts) do
    sig = signature(endpoint)

    name =
      case Registry.lookup(Sorrel.Pool.Registry, sig) do
        [{_pid, _}] ->
          pool_name(sig)

        [] ->
          {:ok, pool_name} = start(endpoint, opts)
          pool_name
      end

    timeout = opts |> apply_pool_timeout_alias() |> Sorrel.Config.pool_timeout()

    try do
      NimblePool.checkout!(
        name,
        :checkout,
        fn _from, client_state ->
          case fun.(client_state) do
            {_result, {:ok, _conn}} = pair -> pair
            {_result, {:closed, _reason}} = pair -> pair
            other -> {other, {:closed, :unused}}
          end
        end,
        timeout
      )
    rescue
      e in Sorrel.Pool.ConnectError ->
        {:error, e.reason}
    catch
      :exit, {:noproc, _} ->
        raise Sorrel.Pool.NotStartedError, endpoint: endpoint
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  @spec pool_name(term()) :: pool_name()
  defp pool_name(sig) do
    {:via, Registry, {Sorrel.Pool.Registry, sig}}
  end

  # Preserves the legacy `:poolboy_timeout` option as an alias for
  # `:pool_timeout`. Caller's `:pool_timeout` always wins; the alias is
  # only consulted when `:pool_timeout` is absent.
  @spec apply_pool_timeout_alias(keyword()) :: keyword()
  defp apply_pool_timeout_alias(opts) do
    case Keyword.fetch(opts, :poolboy_timeout) do
      {:ok, value} -> Keyword.put_new(opts, :pool_timeout, value)
      :error -> opts
    end
  end

  @spec nimble_pool_spec(term(), Endpoint.t(), keyword()) :: :supervisor.child_spec()
  defp nimble_pool_spec(sig, endpoint, opts) do
    init_arg = [endpoint: endpoint, opts: opts]
    pool_size = Sorrel.Config.pool_size(opts)
    pool_max_idle_time = Keyword.get(opts, :pool_max_idle_time, :infinity)

    base_opts = [
      worker: {Worker, init_arg},
      pool_size: pool_size,
      lazy: true,
      name: pool_name(sig)
    ]

    nimble_opts = maybe_put_worker_idle_timeout(base_opts, pool_max_idle_time)

    %{
      id: {:nimble_pool, sig},
      start: {NimblePool, :start_link, [nimble_opts]},
      restart: :transient,
      type: :worker
    }
  end

  defp maybe_put_worker_idle_timeout(opts, :infinity), do: opts

  defp maybe_put_worker_idle_timeout(opts, ms) when is_integer(ms) and ms >= 0,
    do: Keyword.put(opts, :worker_idle_timeout, ms)

  # `signature/1` produces a stable hashable key.
  #
  # For unix endpoints:  {:unix, socket_path}
  # For tcp endpoints:   {:tcp, scheme, host, port, tls_signature}
  # For ssh endpoints:   {:ssh, host, port, user, target, auth_signature}
  defp signature(%Endpoint{transport: :unix} = ep), do: {:unix, ep.socket_path}

  defp signature(%Endpoint{transport: :tcp, tls: tls} = ep) do
    tls_sig =
      case tls do
        nil -> :no_tls
        %{} = m -> {m[:verify], m[:cacertfile], m[:certfile], m[:keyfile]}
      end

    {:tcp, ep.scheme, ep.host, ep.port, tls_sig}
  end

  defp signature(%Endpoint{transport: :ssh, ssh: ssh} = ep) do
    ssh = ssh || %{}

    auth_sig =
      {ssh[:auth], ssh[:identity_file], ssh[:password] !== nil, ssh[:known_hosts_file],
       ssh[:verify]}

    {:ssh, ep.host, ep.port, ep.user, ep.target, auth_sig}
  end
end

defmodule Sorrel.Pool.Worker do
  @moduledoc """
  A `NimblePool` worker that owns one Mint connection for the lifetime of
  one request at a time, plus the request helpers used by the pool's
  checkout callback.

  Each worker holds either no connection or a single open
  `Mint.HTTP.t()`. The connection is **active** while the worker is idle
  in the pool (so the worker observes server-side `FIN`s and stray data
  via `c:handle_info/2`) and **passive** while a checkout caller is
  driving a request (so `Mint.HTTP.recv/3` returns synchronously). This
  mode-toggling discipline mirrors Finch's HTTP/1 pool.

  ## Lifecycle

    * **`init_worker/1`** - lazy: returns a worker with `conn: nil`. The
      first checkout opens the connection. This preserves the pre-NimblePool
      Sorrel behaviour where a missing peer does not crash pool start-up.
    * **`handle_checkout/4`** - opens (if `conn == nil`) or reuses
      (otherwise, after `Mint.HTTP.open?/1` and an idle-time check) the
      connection, switching it to passive mode for the caller.
    * **`handle_checkin/4`** - switches the conn back to active mode and
      stamps `last_checkin_at`. A non-`{:ok, conn}` checkin reason
      (caller died, raised, or returned `{:closed, _}`) drops the
      worker.
    * **`handle_info/2`** - drives `Mint.HTTP.stream/2` for unsolicited
      transport messages while the worker is idle. Errors evict the
      worker.
    * **`handle_ping/2`** - periodic timer; if the pool has been idle
      long enough returns `{:stop, :idle_timeout}` to tear the whole
      pool down.
    * **`terminate_worker/3`** - best-effort close.

  ## What this module does *not* do

    * It does not retry on transport errors **except** for the one-shot
      stale-reuse retry inside `run_request/6`, which preserves the
      pre-existing Sorrel behaviour where a request on a reused conn that
      fails opens a fresh conn and tries once more.
    * It does not own pooling decisions - `NimblePool` does. We only
      implement the callbacks.
  """

  # What this module is:
  #   The NimblePool worker callback module. The "worker state" is a map
  #   that owns at most one Mint conn:
  #     %{
  #       endpoint:           %Endpoint{},
  #       conn:               nil | Mint.HTTP.t(),
  #       last_checkin_at:    integer() | nil,    # :erlang.monotonic_time(:millisecond)
  #       conn_max_idle_time: non_neg_integer() | :infinity,
  #       connect_timeout:    non_neg_integer()
  #     }
  #
  # Rules that always hold:
  #   1. Between checkouts, a non-nil `conn` is in **active** mode and
  #      the worker process is its controlling process.
  #   2. During a checkout, the conn is in **passive** mode and the
  #      checkout caller drives `Mint.HTTP.recv/3` synchronously.
  #   3. A checkin with a non-`{:ok, _}` reason - caller death, caller
  #      raise, caller-returned `{:closed, _}` - must NOT return
  #      `{:ok, _, _}`. The conn is dropped via `{:remove, :closed, _}`
  #      so it cannot be handed to the next request mid-response.

  @behaviour NimblePool

  alias Sorrel.Conn
  alias Sorrel.Endpoint
  alias Sorrel.Transport

  @type method :: :get | :post | :put | :delete | :head | String.t()
  @type response :: %{status: integer(), headers: list(), body: binary()}
  @type kind :: :fresh | :reused
  @type client_state :: {kind(), Mint.HTTP.t(), Endpoint.t(), keyword()}
  @type checkin_reason :: {:ok, Mint.HTTP.t()} | {:closed, term()}

  @type worker_state :: %{
          endpoint: Endpoint.t(),
          conn: nil | Mint.HTTP.t(),
          last_checkin_at: nil | integer(),
          conn_max_idle_time: non_neg_integer() | :infinity,
          connect_timeout: non_neg_integer()
        }

  @type pool_state :: %{
          endpoint: Endpoint.t(),
          opts: keyword(),
          pool_max_idle_time: non_neg_integer() | :infinity
        }

  # ---------------------------------------------------------------------------
  # Public helpers (used by Sorrel.Pool.checkout/3 callers)
  # ---------------------------------------------------------------------------

  @doc """
  Runs one HTTP request against the conn supplied by `handle_checkout/4`.

  Returns a `{result, checkin}` pair: `result` is what
  `Pool.checkout/3` returns to its caller; `checkin` is what
  `Pool.checkout/3` hands back to NimblePool for `handle_checkin/4`.

  When the conn was reused (`kind == :reused`) and the request fails on
  it (typical "peer closed since last response" case), opens a brand-new
  conn and retries the request **once** before giving up. This preserves
  Sorrel's prior stale-reuse retry semantics.

  ## Returns

    * `{{:ok, response}, {:ok, conn}}` - the request completed; `conn`
      goes back into the pool.
    * `{{:error, reason}, {:closed, reason}}` - the request failed; the
      conn (if any) was closed best-effort and the worker is evicted on
      checkin.
  """
  @spec run_request(client_state(), method(), String.t(), list(), iodata(), keyword()) ::
          {{:ok, response()} | {:error, term()}, checkin_reason()}
  def run_request({kind, conn, endpoint, conn_opts}, method, path, headers, body, opts \\ []) do
    method_string = method_to_string(method)

    case Conn.request(conn, method_string, path, headers, body, opts) do
      {:ok, response, conn} ->
        {{:ok, response}, {:ok, conn}}

      {:error, reason, conn} when kind === :reused ->
        :ok = safe_close(conn)

        retry_after_stale_reuse(
          endpoint,
          conn_opts,
          method_string,
          path,
          headers,
          body,
          opts,
          reason
        )

      {:error, reason, conn} ->
        :ok = safe_close(conn)
        {{:error, reason}, {:closed, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # NimblePool callbacks
  # ---------------------------------------------------------------------------

  @impl NimblePool
  @spec init_pool(keyword()) :: {:ok, pool_state()}
  def init_pool(init_arg) do
    endpoint = Keyword.fetch!(init_arg, :endpoint)
    opts = Keyword.get(init_arg, :opts, [])

    state = %{
      endpoint: endpoint,
      opts: opts,
      pool_max_idle_time: Keyword.get(opts, :pool_max_idle_time, :infinity)
    }

    {:ok, state}
  end

  @impl NimblePool
  @spec init_worker(pool_state()) :: {:ok, worker_state(), pool_state()}
  def init_worker(%{endpoint: endpoint, opts: opts} = pool_state) do
    worker = %{
      endpoint: endpoint,
      conn: nil,
      last_checkin_at: nil,
      conn_max_idle_time: Sorrel.Config.conn_max_idle_time(opts),
      connect_timeout: Sorrel.Config.connect_timeout(opts)
    }

    {:ok, worker, pool_state}
  end

  @impl NimblePool
  def handle_checkout(:checkout, _from, %{conn: nil} = worker, pool_state) do
    case open_passive(worker) do
      {:ok, conn} ->
        worker = %{worker | conn: conn}
        client = build_client(:fresh, conn, worker)
        {:ok, client, worker, pool_state}

      {:error, reason} ->
        # Skip rather than `:remove`: a connect failure means every other
        # worker in the pool would also fail to connect (same endpoint).
        # Returning `:skip` with a connect-error exception bails out
        # immediately so callers see `{:error, reason}` from
        # `Pool.checkout/3` instead of waiting for `pool_timeout`.
        {:skip, Sorrel.Pool.ConnectError.exception(reason: reason), pool_state}
    end
  end

  def handle_checkout(:checkout, _from, %{conn: conn} = worker, pool_state) do
    cond do
      not Mint.HTTP.open?(conn) ->
        # Stale conn: drop it so NimblePool can spawn a fresh worker.
        :ok = safe_close(conn)
        {:remove, :closed, pool_state}

      idle_exceeded?(worker) ->
        :ok = safe_close(conn)
        {:remove, :idle_timeout, pool_state}

      true ->
        case Mint.HTTP.set_mode(conn, :passive) do
          {:ok, conn} ->
            worker = %{worker | conn: conn}
            client = build_client(:reused, conn, worker)
            {:ok, client, worker, pool_state}

          {:error, _reason} ->
            :ok = safe_close(conn)
            {:remove, :closed, pool_state}
        end
    end
  end

  @impl NimblePool
  def handle_checkin(checkin, _from, _old_worker, pool_state) do
    case checkin do
      {:ok, conn} ->
        case Mint.HTTP.set_mode(conn, :active) do
          {:ok, conn} ->
            worker = build_worker(conn, pool_state)
            {:ok, worker, pool_state}

          {:error, _reason} ->
            :ok = safe_close(conn)
            {:remove, :closed, pool_state}
        end

      _other ->
        # `{:closed, _}`, an exception class atom, or any other dirty
        # checkin - caller died, raised, or run_request/6 returned a
        # closed conn. Drop the worker.
        {:remove, :closed, pool_state}
    end
  end

  @impl NimblePool
  def handle_info(_message, %{conn: nil} = worker), do: {:ok, worker}

  def handle_info(message, %{conn: conn} = worker) do
    case Mint.HTTP.stream(conn, message) do
      {:ok, conn, _responses} ->
        {:ok, %{worker | conn: conn}}

      {:error, _conn, _reason, _responses} ->
        :ok = safe_close(conn)
        {:remove, :closed}

      :unknown ->
        {:ok, worker}
    end
  end

  @impl NimblePool
  def handle_ping(_worker, %{pool_max_idle_time: :infinity}), do: {:ok, :no_change}

  def handle_ping(_worker, %{pool_max_idle_time: _ms}) do
    # NimblePool only invokes handle_ping/2 once a worker has been idle
    # for `:worker_idle_timeout` ms (which we set equal to
    # `pool_max_idle_time`). Reaching here means the pool-wide threshold
    # has been crossed for at least one worker; tear the whole pool
    # down so the next request lazily spawns a fresh one.
    {:stop, :idle_timeout}
  end

  @impl NimblePool
  def handle_cancelled(_state, _pool_state), do: :ok

  @impl NimblePool
  def terminate_worker(_reason, %{conn: conn}, pool_state) do
    :ok = safe_close(conn)
    {:ok, pool_state}
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # Open a fresh conn and run the request once on it. Used after a reused
  # conn fails - preserves the prior Sorrel stale-reuse retry semantics.
  defp retry_after_stale_reuse(
         endpoint,
         conn_opts,
         method,
         path,
         headers,
         body,
         opts,
         _prev_reason
       ) do
    case Transport.connect(endpoint, conn_opts) do
      {:ok, conn} ->
        case Conn.request(conn, method, path, headers, body, opts) do
          {:ok, response, conn} ->
            {{:ok, response}, {:ok, conn}}

          {:error, reason, conn} ->
            :ok = safe_close(conn)
            {{:error, reason}, {:closed, reason}}
        end

      {:error, reason} ->
        {{:error, reason}, {:closed, reason}}
    end
  end

  defp build_client(kind, conn, worker) do
    {kind, conn, worker.endpoint, [mode: :passive, connect_timeout: worker.connect_timeout]}
  end

  defp build_worker(conn, pool_state) do
    %{
      endpoint: pool_state.endpoint,
      conn: conn,
      last_checkin_at: :erlang.monotonic_time(:millisecond),
      conn_max_idle_time: Sorrel.Config.conn_max_idle_time(pool_state.opts),
      connect_timeout: Sorrel.Config.connect_timeout(pool_state.opts)
    }
  end

  defp open_passive(%{endpoint: endpoint, connect_timeout: timeout}) do
    Transport.connect(endpoint, mode: :passive, connect_timeout: timeout)
  end

  defp idle_exceeded?(%{conn_max_idle_time: :infinity}), do: false

  defp idle_exceeded?(%{last_checkin_at: nil}), do: false

  defp idle_exceeded?(%{conn_max_idle_time: ms, last_checkin_at: ts}) do
    :erlang.monotonic_time(:millisecond) - ts > ms
  end

  defp safe_close(nil), do: :ok

  defp safe_close(conn) do
    case Mint.HTTP.close(conn) do
      {:ok, _closed} -> :ok
    end
  catch
    _kind, _reason -> :ok
  end

  defp method_to_string(method) when is_binary(method), do: method

  defp method_to_string(method) when is_atom(method) do
    method |> Atom.to_string() |> String.upcase()
  end
end

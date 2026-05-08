defmodule Sorrel.StreamSession do
  @moduledoc """
  A short-lived server process that owns one HTTP connection while a
  single streaming response is being read.

  When you call `Sorrel.stream/4` and the response is 2xx, a
  process of this module is started. The process opens the connection,
  sends the request, reads the status and headers, and then sits in a
  loop receiving body bytes from the network and turning them into
  decoded events. Callers ask for the next event with `recv/2` and stop
  the stream with `cancel/2`.

  ## When you would use this module yourself

  Most callers do not. `Sorrel.stream/4` already wraps a
  `StreamSession` in an Elixir `Stream` for you, which is the friendly
  shape (works with `Enum.*`, `Stream.*`, `for`, etc.). Reach for
  `Sorrel.StreamSession` directly only when:

    * You want full control over the stream's lifetime (e.g. you store
      the pid in your own state and decide when to call `recv/2` and
      `cancel/2`).
    * You are testing the streaming behaviour without the lazy `Stream`
      wrapper in the way.

  ## Where the logic lives

  This module is the live `GenServer` shell. All state transitions
  (queue management, parking callers in `recv/2`, decoding chunks) live
  in `Sorrel.StreamSession.Impl` so they can be tested as plain
  functions.

  ## Promises this module guarantees

    * **Order**: events come out in the order they arrived.
    * **Termination**: once `recv/2` returns `:end`, every subsequent
      `recv/2` call also returns `:end`. The stream does not "reopen".
    * **Idempotent cancel**: `cancel/2` is safe to call on an
      already-stopped server.

  ## Examples

      # Open a stream against a generic event endpoint:
      iex> {:ok, srv} =
      ...>   Sorrel.StreamSession.start_link(
      ...>     endpoint: ep,
      ...>     method: "GET",
      ...>     path: "/events",
      ...>     into: :ndjson
      ...>   )

      # Pull the next event:
      iex> Sorrel.StreamSession.recv(srv, timeout: 5_000)
      {:ok, %{"event" => "ready"}}

      # Stop the stream when you are done:
      iex> Sorrel.StreamSession.cancel(srv)
      :ok
  """

  # What this module is:
  #   The GenServer process shell that owns one in-flight streaming
  #   response. The state map is described in `Sorrel.StreamSession.Impl`.
  #   Logically: a finite or infinite sequence of events from the
  #   server, delivered to recv/2 callers in arrival order.
  #
  # Rules that always hold:
  #   1. The connection is open until a terminal condition (server-side
  #      close, transport error, or `cancel/2`).
  #   2. Events in the queue are in arrival order.
  #   3. Once `recv/2` has returned `:end` once, every subsequent
  #      `recv/2` call returns `:end`.

  use GenServer

  alias Sorrel.StreamSession.Impl

  @doc """
  Spawns a streaming-response server linked to the calling process and
  returns its pid, after the response status and headers have been
  fully received.

  Synchronous. The returned `{:ok, pid}` is only delivered after the
  response head has arrived and was 2xx - by the time you hold the
  pid, you know the server accepted the request and is now sending
  body bytes.

  ## Parameters

    * `args` - `keyword()`. Required keys:

      | Key         | Type                                | What it is                                                                |
      | ----------- | ----------------------------------- | ------------------------------------------------------------------------- |
      | `:endpoint` | `Sorrel.Endpoint.t()`         | Where to connect.                                                          |
      | `:method`   | `String.t()` (uppercase)            | HTTP method.                                                              |
      | `:path`     | `String.t()`                        | Request path including query string.                                       |
      | `:into`     | `:ndjson | :raw`                    | How to decode arriving chunks.                                             |

      Optional keys:

      | Key                | Type                                | Default     | What it does                                                  |
      | ------------------ | ----------------------------------- | ----------- | ------------------------------------------------------------- |
      | `:headers`         | `list()` of `{name, value}` tuples  | `[]`         | Extra request headers.                                        |
      | `:body`            | `iodata()`                          | `""`         | Request body.                                                 |
      | `:connect_timeout` | `non_neg_integer()`                 | `10_000`     | Milliseconds for the connect/handshake.                       |
      | `:receive_timeout` | `non_neg_integer()` or `:infinity`  | `15_000`     | Milliseconds per receive while reading the response head.     |

  ## Returns

    * `{:ok, pid}` - the server is alive and has read a 2xx status.
      Some body bytes may already be buffered as decoded events. Call
      `recv/2` to start consuming them.

    * `{:error, {:non_2xx, response}}` - the response status was
      outside 200..299. `response` is a complete map of
      `%{status: integer(), headers: list(), body: term()}` with the
      body decoded according to `args[:into]`. The connection has
      already been closed; no cleanup needed by the caller.

    * `{:error, reason}` - a transport failure happened before the
      response head was fully received. Typical reasons:
      `:econnrefused`, `:enoent`, `:timeout`, `{:tls_alert, _}`,
      `%Mint.TransportError{...}`.

  ## A subtle note on linking and non-2xx errors

  `start_link/1` *links* the new process to the caller. When `init/1`
  returns `{:stop, reason}` for a non-`:normal` reason, OTP also
  delivers an `EXIT` signal to the linker - which kills the caller
  unless it is trapping exits. If you want to inspect the result
  before linking, use `start/1` instead and call `Process.link/1`
  yourself only on success.

  ## Raises

    * `KeyError` - when any of the required keys is missing from
      `args`.

  ## Examples

      iex> args = [
      ...>   endpoint: ep,
      ...>   method: "POST",
      ...>   path: "/items?stream=1",
      ...>   into: :ndjson
      ...> ]
      iex> {:ok, _srv} = Sorrel.StreamSession.start_link(args)
  """
  @spec start_link(keyword()) :: GenServer.on_start() | {:error, term()}
  def start_link(args) when is_list(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @doc """
  Same as `start_link/1` but does **not** link the new process to the
  caller.

  Use this when you want to inspect the start result before deciding
  whether to link. The typical pattern is:

      case Sorrel.StreamSession.start(args) do
        {:ok, pid} ->
          Process.link(pid)
          {:ok, pid}

        {:error, _} = error ->
          error
      end

  Without the link, an `init/1` that returns
  `{:stop, {:non_2xx, response}}` does not deliver an `EXIT` signal to
  the caller - the caller cleanly gets back `{:error, ...}` and can
  decide what to do.

  ## Parameters

  Same as `start_link/1`. See its docs for the full list.

  ## Returns

  Same shape as `start_link/1`:

    * `{:ok, pid}` - server alive, response status was 2xx.
    * `{:error, {:non_2xx, response}}` - response status was non-2xx.
    * `{:error, reason}` - transport failure.

  ## Raises

    * `KeyError` - when any of the required keys is missing from
      `args`.
  """
  @spec start(keyword()) :: GenServer.on_start() | {:error, term()}
  def start(args) when is_list(args) do
    GenServer.start(__MODULE__, args)
  end

  @doc """
  Pulls the next event from the stream and returns it; or returns
  `:end` if the stream is finished; or returns an error tuple if the
  transport failed.

  Blocks the calling process until one of the three outcomes is ready.
  Calls are serialised - only one caller can be parked in `recv/2` at
  a time. If you call `recv/2` from two processes against the same
  server, the second one waits until the first has been answered.

  ## Parameters

    * `server` - `pid()`. The pid returned by `start_link/1` or
      `start/1`.

    * `opts` - `keyword()`. Recognised keys:

      | Key        | Type                | Default     | What it does                                                                |
      | ---------- | ------------------- | ----------- | --------------------------------------------------------------------------- |
      | `:timeout` | `non_neg_integer()` or `:infinity` | `:infinity` | The outer `GenServer.call/3` timeout - how long the caller is willing to wait for an event before exiting. The default is `:infinity` because streaming callers usually want to wait as long as the server takes. |

      Unknown keys are ignored.

  ## Returns

    * `{:ok, event}` - one decoded event. The shape of `event`
      depends on the `:into` mode the server was started with:
      `:ndjson` yields one decoded JSON value (typically a map);
      `:raw` yields one binary chunk.

    * `:end` - the server has closed the response and there are no
      more events. Once you receive `:end`, every subsequent
      `recv/2` call also returns `:end`.

    * `{:error, reason}` - a transport-level failure happened
      mid-stream. Typical reasons: `:closed`, `:timeout`,
      `%Mint.TransportError{...}`. After this, the server process
      exits with the same `reason`. The pid is no longer usable.

  ## Exits

    * `:exit, {:timeout, _}` - when the *outer* `:timeout` runs out
      before the server replies. This is the standard
      `GenServer.call/3` exit. Avoid by using `:infinity` (the
      default) for normal streaming reads.

  ## Examples

      iex> Sorrel.StreamSession.recv(srv, timeout: 5_000)
      {:ok, %{"event" => "ready"}}

      iex> Sorrel.StreamSession.recv(srv)
      :end

      iex> Sorrel.StreamSession.recv(srv)
      {:error, :closed}
  """
  @spec recv(pid(), keyword()) :: {:ok, term()} | :end | {:error, term()}
  def recv(server, opts \\ []) do
    GenServer.call(server, :recv, opts[:timeout] || :infinity)
  end

  @doc """
  Stops the server, which closes its underlying connection and ends
  any in-flight request.

  Safe to call more than once. Calls after the first do nothing - the
  function returns `:ok` whether the server is alive or already gone.

  ## Parameters

    * `server` - `pid()`. The pid returned by `start_link/1` or
      `start/1`. May already be dead.

    * `opts` - `keyword()`. Recognised keys:

      | Key        | Type                | Default     | What it does                                                                |
      | ---------- | ------------------- | ----------- | --------------------------------------------------------------------------- |
      | `:timeout` | `non_neg_integer()` or `:infinity` | `1_000`     | Milliseconds to wait for the server's `terminate/2` to finish before forcefully killing the process. |

      Unknown keys are ignored.

  ## Returns

  `:ok`. The server exits with reason `:normal` (a clean shutdown).
  Any caller currently parked in `recv/2` against this server may
  receive an `:exit` signal as the process goes down - wrap their call
  in `try ... catch :exit, _ -> ...` if that matters to you.

  This function does not raise. The internal `:exit` from the server
  is caught and turned into `:ok` so calling `cancel/2` on an
  already-dead server stays a no-op.

  ## Examples

      iex> Sorrel.StreamSession.cancel(srv)
      :ok

      # Calling cancel a second time is also fine:
      iex> Sorrel.StreamSession.cancel(srv)
      :ok
  """
  @spec cancel(pid(), keyword()) :: :ok
  def cancel(server, opts \\ []) do
    GenServer.stop(server, :normal, opts[:timeout] || 1_000)
  catch
    # The server may exit between calls. The exit signal we get here is
    # benign; the contract is "ok and do nothing" for that case.
    :exit, _reason -> :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks - process shell only; logic delegated to Impl.
  # ---------------------------------------------------------------------------

  @impl true
  def init(args) do
    Impl.init(args)
  end

  @impl true
  def handle_call(:recv, from, state) do
    Impl.handle_recv(state, from)
  end

  @impl true
  def handle_info(msg, state) do
    Impl.handle_transport_message(state, msg)
  end

  @impl true
  def terminate(_reason, state) do
    Impl.terminate(state)
  end
end

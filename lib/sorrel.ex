defmodule Sorrel do
  @moduledoc """
  Sorrel is a HTTP client that can talk to servers over Unix sockets, TCP,
  or SSH-forwarded byte streams, with optional TLS.

  Sorrel is built on top of `Mint` and provides a low-level API for making
  HTTP requests. It is built for cases where you want granular control over
  HTTP connections, for example:

  - Talking to a service on a Unix socket
  - Calling an internal HTTP API over TLS
  - Upgrading a request into a raw byte channel

  ## The mental model

  Sorrel has two pieces:

    1. **One struct** — `%Sorrel.Endpoint{}` describes *where* to
       connect: which Unix socket, or which host and port, and whether
       to use TLS.
    2. **Three functions** — `request/5`, `stream/5`, and `tunnel/5`.
       Each takes the endpoint as its **first argument**, then the HTTP
       method, path, optional body, and options.

  You build an endpoint once and reuse it for as many calls as you
  like. Behind the scenes, the first call to a new endpoint opens a
  small pool of connections; later calls reuse pooled connections
  automatically.

  ## Step 1 — Build an endpoint

  The endpoint struct tells Sorrel where the server lives. The easiest
  way to build one is `Sorrel.Endpoint.parse/2`, which accepts a
  URL string. There are three transports to choose from.

  ### Unix socket

  For an HTTP server listening on a filesystem socket, use `unix://`
  followed by the absolute path:

      iex> {:ok, endpoint} = Sorrel.Endpoint.parse("unix:///var/run/docker.sock")
      iex> endpoint
      %Sorrel.Endpoint{
        transport: :unix,
        socket_path: "/var/run/docker.sock",
        scheme: nil,
        host: nil,
        port: nil,
        tls: nil
      }

  The example points at the Docker daemon's socket, but Sorrel doesn't
  know or care what's on the other end — the path can be any `AF_UNIX`
  HTTP socket on disk. When `transport` is `:unix`, only `socket_path`
  is meaningful. There is no host, no port, and no TLS — Unix sockets
  are a filesystem-local mechanism, so the path *is* the address.

  ### Plain TCP

  When the server listens on a TCP port without TLS, use `tcp://`:

      iex> {:ok, endpoint} = Sorrel.Endpoint.parse("tcp://10.0.0.5:2375")
      iex> endpoint
      %Sorrel.Endpoint{
        transport: :tcp,
        socket_path: nil,
        scheme: :http,
        host: "10.0.0.5",
        port: 2375,
        tls: nil
      }

  `tcp://` and `http://` are equivalent — both produce a `:tcp`
  endpoint with `scheme: :http`. The default port is **80** when the
  URL omits it.

  ### TCP with TLS — HTTPS or mutual TLS

  For HTTPS, parse an `https://` URL. `parse/2` deliberately does not
  load certificate files for you — it sets `tls: nil` and leaves the
  TLS configuration to you, so the function never touches the disk:

      iex> {:ok, base} = Sorrel.Endpoint.parse("https://api.example.com")
      iex> base.scheme
      :https
      iex> base.port
      443

      # Fill in TLS by hand. For mutual TLS, point at the CA, your
      # client cert, and your client key:
      iex> endpoint = %{base |
      ...>   tls: %{
      ...>     verify: :verify_peer,
      ...>     cacertfile: "/etc/ssl/certs/ca.pem",
      ...>     certfile: "/etc/ssl/certs/client.pem",
      ...>     keyfile: "/etc/ssl/private/client.key"
      ...>   }
      ...> }
      iex> endpoint.tls.verify
      :verify_peer

  The default port for `https://` is **443**. Use
  `verify: :verify_none` to skip certificate verification — only do
  this in development.

  ### Building a struct by hand

  If you do not have a URL handy (e.g. the host and port come from
  separate config keys), build the struct directly. The same shape
  rules apply: for `:unix`, set `socket_path` and leave the TCP fields
  `nil`; for `:tcp`, set `scheme`, `host`, and `port`.

      iex> endpoint = %Sorrel.Endpoint{
      ...>   transport: :tcp,
      ...>   scheme: :http,
      ...>   host: "localhost",
      ...>   port: 4000
      ...> }
      iex> endpoint.transport
      :tcp

  See `Sorrel.Endpoint` for the full set of validation rules.

  ## Step 2 — Pick the right function

  Once you have an endpoint, the right function depends on the shape
  of the response you expect:

  | Function     | Use when                                                                              |
  | ------------ | ------------------------------------------------------------------------------------- |
  | `request/5`  | One request, one response. The whole body fits in memory.                              |
  | `stream/5`   | The response is a long-running sequence of events (server-sent events, log tails).     |
  | `tunnel/5`   | The server replies `101 Switching Protocols` and you want raw bytes after the upgrade. |

  The same `endpoint` struct works with all three. The transport
  (Unix, TCP, TLS) is hidden behind the struct — you do not write
  different code for different transports.

  ## Step 3 — Send a request

  `request/5` is the workhorse. Pass the endpoint, HTTP method, path,
  optional body, and options:

      iex> {:ok, endpoint} = Sorrel.Endpoint.parse("unix:///var/run/docker.sock")
      iex> {:ok, response} = Sorrel.request(endpoint, :get, "/_ping")
      iex> response.status
      200
      iex> response.body
      "OK"

  For a 2xx response, the result is `{:ok, response}`. For 4xx and 5xx
  the **same** map comes back tagged `{:error, response}`, so you can
  pattern-match on `:status`. For transport failures (connection
  refused, timeout) the result is `{:error, reason}` instead.

  See `request/5` for body shapes (binary, JSON, tar), decoding modes,
  and the full options table.

  ## Step 4 — Stream a long response

  When the server sends events over a long period, use `stream/5`.
  It returns a lazy `Stream` that you walk with `Enum.*` / `Stream.*`
  functions; bytes are pulled from the server only as you advance:

      iex> {:ok, endpoint} = Sorrel.Endpoint.parse("unix:///var/run/docker.sock")
      iex> {:ok, events} =
      ...>   Sorrel.stream(endpoint, :get, "/events", nil, into: :ndjson)
      iex> Enum.take(events, 1)
      [%{"Type" => "container", "Action" => "start", "id" => _}]

  Discarding the stream (e.g. `Stream.take/2` followed by
  `Enum.to_list/1`) cancels the in-flight request and closes the
  connection. A non-2xx response does not return a stream — it returns
  `{:error, response}` synchronously, like `request/5`.

  See `stream/5` for the full lifecycle: cancellation, mid-stream
  errors, and the difference between `:ndjson` and `:raw` modes.

  ## Step 5 — Upgrade to a raw socket

  When the server replies `101 Switching Protocols` and then stops
  speaking HTTP on that connection — WebSocket upgrades,
  container-runtime exec/attach channels, and similar — use
  `tunnel/5`. It returns the raw socket so you can exchange whatever
  bytes the post-upgrade protocol expects:

      iex> {:ok, endpoint} = Sorrel.Endpoint.parse("unix:///var/run/docker.sock")
      iex> {:ok, socket, _leftover} =
      ...>   Sorrel.tunnel(
      ...>     endpoint,
      ...>     :post,
      ...>     "/v1.43/containers/abc/attach?stream=1&stdout=1",
      ...>     ""
      ...>   )
      iex> Sorrel.Tunnel.close(socket)
      :ok

  Unlike `request/5` and `stream/5`, the socket returned by `tunnel/5`
  is **unpooled** — the caller owns it and is responsible for closing
  it. See `tunnel/5` and `Sorrel.Tunnel` for details.

  ## What Sorrel puts on the wire for you

  Beyond the headers you pass in `options[:headers]`, Sorrel adds two
  defaults if you have not already provided them:

  | Header        | Default                  | When it is added                                      |
  | ------------- | ------------------------ | ----------------------------------------------------- |
  | `host`        | `"localhost"`            | Only for `:unix` endpoints. TCP endpoints let Mint derive `host` from the connect-time hostname. |
  | `user-agent`  | `"sorrel/<version>"`     | Always, unless you supplied one.                      |

  Caller-supplied headers always win — if you pass `{"host", "h"}`
  yourself, that value reaches the wire unchanged.

  ## What Sorrel deliberately does not do

  Sorrel exposes primitives. It does **not** handle:

    * **Authentication** — no automatic Basic/Bearer/digest headers.
      You add the header yourself in `options[:headers]`.
    * **API versioning** — `path` is sent verbatim. Sorrel never
      prepends `/api/v2` or anything else.
    * **Request multiplexing** — one request per connection at a time.
    * **Retries, circuit breaking, backoff** — failures bubble up to
      the caller as `{:error, reason}`.

  These belong in higher-level wrappers built on top of Sorrel.

  ## Where to look next

    * `Sorrel.Endpoint` — building and validating endpoints in
      detail (URL parsing, TLS struct shape, hand-built endpoints).
    * `Sorrel.request/5` — one-shot request/response, with the
      full body and decoder reference.
    * `Sorrel.stream/5` — lazy streaming response, with the
      full lifecycle reference.
    * `Sorrel.tunnel/5` — `101 Upgrade` to a raw byte channel.
    * `Sorrel.Codec` — body encoders and decoders, exposed for
      callers wiring up their own HTTP loop.
    * `Sorrel.Transport` — opening a single connection by hand.
    * `Sorrel.Tunnel` — the underlying tunnel API `tunnel/5`
      delegates to (open, send, recv, close).
  """

  # What this module is:
  #   Stateless top-level entry point. Takes (endpoint, method, path,
  #   body, options) and either:
  #     - returns {:ok, response} (request/5),
  #     - returns {:ok, Enumerable} (stream/5), or
  #     - returns {:ok, socket, leftover} (tunnel/5).
  #
  # Rules that always hold:
  #   1. Every public function takes a `%Sorrel.Endpoint{}` as
  #      its first argument, pattern-matched in the head.
  #   2. request/5 returns {:ok, response} when the request reached the
  #      remote AND the remote responded with a 2xx status; {:error, _}
  #      otherwise.
  #   3. stream/5 returns an Enumerable that, when fully consumed or
  #      discarded, releases its underlying connection.
  #   4. tunnel/5 returns {:ok, socket, leftover} on a successful
  #      101/200 upgrade; the socket is unpooled and owned by the
  #      caller.

  alias Sorrel.Codec
  alias Sorrel.Endpoint
  alias Sorrel.Pool
  alias Sorrel.StreamSession
  alias Sorrel.Tunnel

  @type method :: :get | :post | :put | :delete | :head
  @type body :: nil | iodata() | {:json, term()} | {:tar, iodata()}
  @type into :: :auto | :json | :ndjson | :raw
  @type response :: %{status: 100..599, headers: list(), body: term()}

  @doc """
  Sends one HTTP request, waits for the whole response, and returns it
  tagged `:ok` for a 2xx status or `:error` for anything else.

  Blocks the calling process until either the response is fully
  received, the per-receive timeout elapses, or the transport fails.
  The first call to a new endpoint also starts a connection pool of 10
  workers + up to 5 overflow workers (see `Sorrel.Pool` for
  details and how to override the size — overrides only apply on the
  first call).

  ## Parameters

    * `endpoint` — `%Sorrel.Endpoint{}`. Where to send the
      request. Pattern-matched in the function head; passing anything
      else raises `FunctionClauseError`.

    * `method` — `:get | :post | :put | :delete | :head`. The HTTP
      method. Atoms are converted to uppercase strings (`:get` →
      `"GET"`).

    * `path` — `String.t()`. The request path including any query
      string. Sent verbatim. Examples: `"/ping"`, `"/items?limit=10"`.

    * `body` — `nil | iodata() | {:json, term()} | {:tar, iodata()}`.
      The request body. One of these four shapes:

      | Shape                | What goes on the wire                                       | Headers Sorrel adds                                  |
      | -------------------- | ----------------------------------------------------------- | --------------------------------------------------- |
      | `nil`                | empty body                                                  | none                                                |
      | a binary or iolist   | the bytes, sent verbatim                                    | none — caller adds `Content-Type` if needed         |
      | `{:json, term}`      | JSON-encoded `term` (e.g. `~s({"a":1})`)                    | `[{"content-type", "application/json"}]`            |
      | `{:tar, bytes}`      | `bytes`, sent verbatim                                      | `[{"content-type", "application/x-tar"}]`           |

    * `options` — `keyword()`. Recognised keys:

      | Key                   | Type                                | Default     | What it does                                                                     |
      | --------------------- | ----------------------------------- | ----------- | -------------------------------------------------------------------------------- |
      | `:headers`            | `list()` of `{name, value}` tuples  | `[]`         | Extra request headers. Caller-supplied values win over Sorrel's auto-injected `host` and `user-agent`. |
      | `:receive_timeout`    | `non_neg_integer()` or `:infinity`  | `15_000`     | Milliseconds to wait per receive. Use `:infinity` for very long calls.            |
      | `:into`               | `:auto | :json | :raw`              | `:auto`      | How to decode the response body. `:auto` decodes when the headers say JSON; `:json` always decodes; `:raw` never decodes. |
      | `:pool_size`          | `non_neg_integer()`                 | `10`         | Worker pool size. Honoured **only on the first call** for an endpoint signature. |
      | `:pool_max_overflow`  | `non_neg_integer()`                 | `5`          | Overflow workers. Honoured **only on the first call** for an endpoint signature.  |
      | `:poolboy_timeout`    | `non_neg_integer()`                 | `5_000`      | Milliseconds to wait for a free worker before exiting `:timeout`.                |
      | `:connect_timeout`    | `non_neg_integer()`                 | `10_000`     | Milliseconds to wait when (re)opening the underlying connection.                  |
      | `:timeout`            | `non_neg_integer()` or `:infinity`  | `:infinity`  | Outer `GenServer.call/3` timeout for the worker round-trip.                       |

      Unknown keys are ignored.

  ## Returns

    * `{:ok, response}` — the server responded with a status in
      200..299. `response` is a map:

          %{
            status: 200..299,                     # the response status code
            headers: [{String.t(), String.t()}],  # response headers, in order
            body: term()                          # decoded according to :into
          }

      The shape of `body` depends on `:into`:
      `:auto` → a map/list (when headers say JSON) or a binary;
      `:json` → a map/list/etc. produced by `JSON.decode!/1`;
      `:raw`  → the original binary.

    * `{:error, response}` — same shape, but the status was outside
      200..299. Use this to handle 4xx / 5xx responses.

    * `{:error, reason}` — a transport-level failure. Common reasons:
      `:closed`, `:timeout`, `:econnrefused`, `:enoent`,
      `{:tls_alert, _}`, `%Mint.TransportError{...}`,
      `%Mint.HTTPError{...}`. The pool worker has already dropped its
      connection; the next call will open a fresh one.

  ## Raises

    * `JSON.DecodeError` — when `:into` is `:json` and the body is not
      valid JSON, or when `:into` is `:auto` and the response headers
      say JSON but the body is malformed. `:raw` never raises.
    * `Protocol.UndefinedError` — when `body` is `{:json, term}` and
      `term` contains a value Elixir's JSON protocol cannot encode.

  ## Examples

      # The examples below all use the Docker daemon's socket as a
      # concrete worked example — Sorrel itself is transport-agnostic;
      # any HTTP server reachable over a Unix socket would behave
      # the same way.
      iex> {:ok, endpoint} = Sorrel.Endpoint.parse("unix:///var/run/docker.sock")
      iex> endpoint.transport
      :unix
      iex> endpoint.socket_path
      "/var/run/docker.sock"

      # Successful 2xx — this endpoint returns the literal body "OK":
      iex> {:ok, response} = Sorrel.request(endpoint, :get, "/_ping")
      iex> response.status
      200
      iex> response.body
      "OK"

      # Non-2xx — same map shape, but tagged :error so a `with` chain
      # short-circuits on it. A missing resource returns 404:
      iex> {:error, response} =
      ...>   Sorrel.request(endpoint, :get, "/v1.43/containers/does-not-exist/json")
      iex> response.status
      404
      iex> response.body
      %{"message" => "No such container: does-not-exist"}

      # POST with a JSON body — Sorrel adds `content-type: application/json`
      # on the wire and decodes the JSON response back into a map:
      iex> {:ok, response} =
      ...>   Sorrel.request(
      ...>     endpoint,
      ...>     :post,
      ...>     "/v1.43/containers/create",
      ...>     {:json, %{Image: "alpine:latest", Cmd: ["echo", "hi"]}}
      ...>   )
      iex> response.status
      201
      iex> Map.keys(response.body)
      ["Id", "Warnings"]

      # Raw response, no decoding — `:into` set to `:raw` keeps the body
      # as the original bytes even when the headers say JSON:
      iex> {:ok, response} =
      ...>   Sorrel.request(endpoint, :get, "/_ping", nil, into: :raw)
      iex> response.body
      "OK"
      iex> is_binary(response.body)
      true

      # Passing something other than an %Endpoint{} raises in the
      # function head — there is no "missing endpoint" error tuple:
      iex> Sorrel.request(nil, :get, "/_ping")
      ** (FunctionClauseError) no function clause matching in Sorrel.request/5
  """
  @spec request(Endpoint.t(), method(), String.t(), body(), keyword()) ::
          {:ok, response()} | {:error, response() | term()}
  def request(%Endpoint{} = endpoint, method, path, body \\ nil, options \\ []) do
    {request_body, encoded_headers} = Codec.encode(body)
    headers = build_headers(encoded_headers, endpoint, options)
    method_string = method_string(method)
    worker_opts = opts_for_worker(options)

    # Pool.checkout/3 lazily starts the pool on first call for an endpoint
    # signature, so we no longer pay a Registry.lookup + tuple alloc on every
    # request through Pool.start/2 here. Tests and apps that need the pool
    # warm before any request happens can call Pool.ensure_started/2.
    Pool.checkout(
      endpoint,
      fn client_state ->
        result =
          Sorrel.Pool.Worker.run_request(
            client_state,
            method_string,
            path,
            headers,
            request_body,
            worker_opts
          )

        # `result` is `{request_result, checkin_reason}`; the request
        # result is what callers see, the checkin reason is what
        # NimblePool feeds back into handle_checkin/4.
        {request_result, checkin} = result
        {finalize_response(request_result, into(options)), checkin}
      end,
      options
    )
  end

  # Decodes the raw worker reply into the user-facing response shape and
  # tags it `:ok` for 2xx, `:error` for everything else. Lifted out of
  # `request/5` so the public function stays shallow.
  @spec finalize_response(
          {:ok, %{status: integer(), headers: list(), body: binary()}}
          | {:error, term()},
          into()
        ) :: {:ok, response()} | {:error, response() | term()}
  defp finalize_response({:ok, %{status: status, headers: hs, body: raw}}, into) do
    decoded = Codec.decode_body(raw, into, hs)
    response = %{status: status, headers: hs, body: decoded}

    if status in 200..299 do
      {:ok, response}
    else
      {:error, response}
    end
  end

  defp finalize_response({:error, reason}, _into), do: {:error, reason}

  @doc """
  Sends one HTTP request and returns a lazy Elixir `Stream` that yields
  one event per chunk as the response arrives, or returns an error if
  the response head failed.

  Use this for endpoints that send a long-running sequence of events:
  server-sent events, log tails, change feeds, anything where the
  body keeps arriving over time. The request is sent up front; bytes
  are pulled from the server only as you walk the stream with
  `Enum.*` or `Stream.*` functions.

  ## Parameters

  All the parameters of `request/5`, plus a different default and set
  of valid values for `:into`:

    * `endpoint`, `method`, `path`, `body` — same as `request/5`.

    * `options` — `keyword()`. All `request/5` keys are recognised.
      Important differences:

      | Key                   | Type                                | Default     | What it does                                                                     |
      | --------------------- | ----------------------------------- | ----------- | -------------------------------------------------------------------------------- |
      | `:into`               | `:ndjson | :raw`                    | `:ndjson`    | How to decode arriving chunks. `:ndjson` splits on `"\\n"` and JSON-decodes each line; `:raw` yields each chunk as a binary. `:auto` and `:json` from `request/5` are not valid here. |
      | `:receive_timeout`    | `non_neg_integer()` or `:infinity`  | `15_000`     | Per-receive timeout while reading bytes. Resets every time bytes arrive — a slow but steady stream can run for hours. |
      | `:connect_timeout`    | `non_neg_integer()`                 | `10_000`     | Connect/handshake timeout.                                                        |

  ## Returns

    * `{:ok, stream}` — the response status was in 200..299 and the
      headers have been received. `stream` is a lazy Elixir `Stream`.
      Properties:

      | Property                     | Behaviour                                                                                                  |
      | ---------------------------- | ---------------------------------------------------------------------------------------------------------- |
      | order                        | One element per decoded event, in arrival order.                                                            |
      | clean termination            | The stream halts on its own when the server closes the response.                                            |
      | early termination            | Discarding the stream (e.g. `Stream.take/2`) cancels the in-flight request and closes the connection.       |
      | mid-stream transport failure | The *next pull* raises `Sorrel.Error` with the failure reason in `e.reason`.                          |
      | linkage                      | The underlying `Sorrel.StreamSession` is linked to the calling process. If it crashes, the caller crashes too (unless trapping exits). |

    * `{:error, response}` — the response status was outside 200..299.
      `response` is a map with `:status`, `:headers`, and `:body`,
      where `:body` is decoded using `:into`. The connection has
      already been closed.

    * `{:error, reason}` — a transport failure happened before the
      response head was fully received.

  ## Raises

  **Returning** the stream does not raise. **Consuming** the stream
  may raise:

    * `Sorrel.Error` — a transport failure happened mid-stream.
      `e.reason` carries the underlying cause.
    * `JSON.DecodeError` — for `:ndjson` mode, if a complete line is
      not valid JSON.

  ## Examples

      # The examples below use the Docker daemon as a concrete worked
      # example — the same call shape works against any HTTP endpoint
      # that emits a long-running NDJSON or chunked stream.
      iex> {:ok, endpoint} = Sorrel.Endpoint.parse("unix:///var/run/docker.sock")

      # Take just the first event from the daemon's /events feed. Each
      # element is one decoded NDJSON line:
      iex> {:ok, events} =
      ...>   Sorrel.stream(endpoint, :get, "/events", nil, into: :ndjson)
      iex> [first] = Enum.take(events, 1)
      iex> first
      %{
        "Type" => "container",
        "Action" => "start",
        "id" => "9c8f...",
        "time" => 1_715_000_000
      }

      # Iterate until the server closes the stream. The Stream is lazy
      # — bytes are pulled only as `Enum.each` advances:
      iex> {:ok, events} =
      ...>   Sorrel.stream(endpoint, :get, "/events", nil, into: :ndjson)
      iex> Enum.each(events, fn %{"Action" => action} -> IO.puts(action) end)
      :ok

      # Raw byte chunks instead of decoded JSON. Useful for log tails
      # where the framing is not line-based:
      iex> {:ok, chunks} =
      ...>   Sorrel.stream(
      ...>     endpoint,
      ...>     :get,
      ...>     "/v1.43/containers/abc123/logs?stdout=1&follow=1",
      ...>     nil,
      ...>     into: :raw
      ...>   )
      iex> Enum.take(chunks, 2)
      [<<1, 0, 0, 0, 0, 0, 0, 5, "hello">>, <<1, 0, 0, 0, 0, 0, 0, 6, "world!">>]

      # Non-2xx returns synchronously — no stream is opened:
      iex> Sorrel.stream(endpoint, :get, "/v1.43/containers/nope/logs")
      {:error,
       %{
         status: 404,
         headers: [{"content-type", "application/json"} | _],
         body: %{"message" => "No such container: nope"}
       }}
  """
  @spec stream(Endpoint.t(), method(), String.t(), body(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, response() | term()}
  def stream(%Endpoint{} = endpoint, method, path, body \\ nil, options \\ []) do
    {request_body, encoded_headers} = Codec.encode(body)
    headers = build_headers(encoded_headers, endpoint, options)
    method_string = method_string(method)

    args = [
      endpoint: endpoint,
      method: method_string,
      path: path,
      headers: headers,
      body: request_body,
      into: stream_into(options),
      connect_timeout: Sorrel.Config.connect_timeout(options),
      receive_timeout: Sorrel.Config.receive_timeout(options)
    ]

    # Use start/1 + Process.link/1 instead of start_link/1 directly. With
    # start_link, an init that returns {:stop, reason} for any non-:normal
    # reason also delivers an EXIT signal to the parent — which kills the
    # caller unless it traps exits. By starting unlinked and linking only
    # on a successful init we get the same liveness coupling for the happy
    # path without leaking exit signals into caller code on the non-2xx /
    # connect-error paths.
    case StreamSession.start(args) do
      {:ok, pid} ->
        Process.link(pid)
        {:ok, build_enumerable(pid)}

      {:error, {:non_2xx, response}} ->
        {:error, response}

      {:error, _} = error ->
        error
    end
  end

  defp build_enumerable(pid) do
    Stream.resource(
      fn -> pid end,
      fn pid ->
        case StreamSession.recv(pid, timeout: :infinity) do
          {:ok, event} -> {[event], pid}
          :end -> {:halt, pid}
          {:error, error} -> raise Sorrel.Error, error
        end
      end,
      fn pid -> StreamSession.cancel(pid) end
    )
  end

  defp stream_into(options) do
    case Keyword.get(options, :into) do
      nil -> :ndjson
      mode when mode in [:ndjson, :raw] -> mode
      mode -> mode
    end
  end

  @doc """
  Sends one HTTP request asking for a `101 Upgrade` and returns the raw
  socket on success, or an error tuple if the upgrade was refused or a
  transport failure happened.

  Use this when the server responds with `101 Switching Protocols` (or
  `200 OK` for legacy upgrade dialects) and then stops speaking HTTP
  on that connection — both peers exchange whatever bytes the protocol
  on top of the upgrade dictates. Unlike `request/5` and `stream/5`,
  the socket returned here is **unpooled**: the caller owns it and is
  responsible for closing it via `Sorrel.Tunnel.close/1`.

  ## Parameters

    * `endpoint` — `%Sorrel.Endpoint{}`. Where to connect.
      Pattern-matched in the function head; passing anything else
      raises `FunctionClauseError`.
    * `method` — `:post | :get`. The HTTP method to use.
    * `path` — `String.t()`. The request path including any query
      string, sent verbatim.
    * `body` — `iodata()`. The request body. Use `""` for endpoints
      that take no body. The body is sent as-is — this function does
      not encode it.
    * `options` — `keyword()`. Recognised keys:

      | Key                | Type                                | Default     | What it does                                                  |
      | ------------------ | ----------------------------------- | ----------- | ------------------------------------------------------------- |
      | `:headers`         | `list()` of `{name, value}` tuples  | `[]`         | Extra request headers, appended to the upgrade base headers.  |
      | `:connect_timeout` | `non_neg_integer()`                 | `10_000`     | Milliseconds for the connect/handshake.                       |
      | `:receive_timeout` | `non_neg_integer()` or `:infinity`  | `10_000`     | Milliseconds per receive while reading the response head.     |

  ## Returns

    * `{:ok, socket, leftover}` — the server replied with `101` or
      `200`. `socket` is a `:gen_tcp.socket()` or `:ssl.sslsocket()`
      in passive mode with `packet: :raw`. `leftover` is any bytes
      already buffered past the response head; consume them before
      reading from the socket directly.
    * `{:error, %{status: code, body: body}}` — the server returned a
      status other than 101 or 200. The connection has been closed.
    * `{:error, reason}` — any transport or protocol failure during
      connect, handshake, or response-head read.

  ## Examples

      # Worked example: attach to a Docker container. `/attach`
      # responds with `101 Switching Protocols` and then speaks the
      # daemon's stdio multiplexing on the raw socket. The same
      # tunnel/5 call shape works for any 101-upgrade endpoint:
      iex> {:ok, endpoint} = Sorrel.Endpoint.parse("unix:///var/run/docker.sock")
      iex> {:ok, socket, leftover} =
      ...>   Sorrel.tunnel(
      ...>     endpoint,
      ...>     :post,
      ...>     "/v1.43/containers/abc123/attach?stream=1&stdout=1&stderr=1",
      ...>     ""
      ...>   )
      iex> is_port(socket) or match?({:sslsocket, _, _}, socket)
      true
      iex> leftover
      ""

      # The caller owns the socket — close it explicitly when done:
      iex> Sorrel.Tunnel.close(socket)
      :ok

      # Like `request/5` and `stream/5`, a non-`%Endpoint{}` first
      # argument raises rather than returning an error tuple:
      iex> Sorrel.tunnel(nil, :post, "/x", "")
      ** (FunctionClauseError) no function clause matching in Sorrel.tunnel/5
  """
  @spec tunnel(Endpoint.t(), method(), String.t(), iodata(), keyword()) ::
          {:ok, :gen_tcp.socket() | :ssl.sslsocket(), binary()}
          | {:error, term()}
  def tunnel(%Endpoint{} = endpoint, method, path, body, options \\ []) do
    # Tunnel.upgrade still consumes endpoint via options for now; thread
    # the bound endpoint back into options to keep this PR minimal.
    Tunnel.upgrade(method, path, body, Keyword.put(options, :endpoint, endpoint))
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # Builds the wire-level header list. Order matters only insofar as we
  # want the codec-supplied content-type to win over a user-supplied
  # default; we therefore put codec headers ahead of `:headers` and let
  # HTTP/1.1's last-write-wins rule favour the codec value if a
  # duplicate slips in. The `Host` header is always set to "localhost"
  # for unix-socket endpoints because the underlying address has no
  # meaningful hostname; for TCP we leave it unset and let Mint derive
  # it from the connect-time hostname.
  defp build_headers(encoded_headers, endpoint, options) do
    base = encoded_headers ++ Keyword.get(options, :headers, [])

    # Single pass: detect both `host` and `user-agent` in one walk over the
    # header list. Two `Enum.any?` calls each downcasing every name was
    # measurably the bulk of build_headers' cost on hot request paths.
    {has_host?, has_ua?} =
      Enum.reduce(base, {false, false}, fn
        {n, _v}, {h?, u?} when is_binary(n) ->
          case String.downcase(n) do
            "host" -> {true, u?}
            "user-agent" -> {h?, true}
            _ -> {h?, u?}
          end

        _, acc ->
          acc
      end)

    base =
      if endpoint.transport === :unix and not has_host? do
        [{"host", "localhost"} | base]
      else
        base
      end

    if has_ua? do
      base
    else
      user_agent = Sorrel.Config.user_agent(options)
      [{"user-agent", user_agent} | base]
    end
  end

  defp into(options) do
    case Keyword.get(options, :into) do
      nil -> :auto
      mode -> mode
    end
  end

  defp method_string(method) when is_binary(method), do: method

  defp method_string(method) when is_atom(method) do
    method |> Atom.to_string() |> String.upcase()
  end

  defp opts_for_worker(options) do
    [receive_timeout: Sorrel.Config.receive_timeout(options)]
  end
end

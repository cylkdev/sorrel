defmodule Sorrel.Conn do
  @moduledoc """
  Sends one HTTP request and reads the response. Two entry points:

    * `request/6` - caller already has an open conn; this module threads
      it through one full request/response and hands it back idle.
    * `open_and_send/6` - caller wants a fresh conn, has one request to
      send, and will drive the response itself; this module opens the
      conn via `Sorrel.Transport.connect/2`, issues the request,
      and hands ownership of the conn and the request `ref` back.

  This is the lowest-level building block in Sorrel for sending a request.
  You give it a connection (built by `Sorrel.Transport.connect/2`),
  an HTTP method, a path, headers, and a body - and it blocks the
  calling process until either the entire response has arrived or
  something goes wrong.

  ## When you would call this module yourself

  Most callers do not. `Sorrel.request/4` already takes care of
  opening a pooled connection, sending the request through this module,
  and decoding the body - that is the right entry point for almost
  everything. Reach for `Sorrel.Conn.request/6` directly when:

    * You want to manage the connection's lifetime yourself (open it
      once, send many requests on it, close it when done).
    * You are writing a test that needs to measure exactly how long one
      request takes.
    * You are wiring up something `Sorrel.Pool` cannot do, like
      pipelining or sharing a connection across processes.

  Reach for `open_and_send/6` when you want a one-shot fresh conn (no
  pooling), need to drive the response yourself (e.g. an HTTP/1.1
  Upgrade where the body becomes a raw byte stream), and do not want
  to repeat the connect+request boilerplate at every call site.

  ## What it does *not* do

    * It does not pool, retry, or reconnect. One call, one request, one
      response.
    * It does not decode the response body. The body comes back as a
      raw binary; use `Sorrel.Codec.decode_body/3` if you want it
      decoded.
    * It does not add headers for you. The bytes you pass are the bytes
      that go on the wire (modulo Mint's standard `Content-Length`
      handling).

  ## Examples

      # Open a connection and send one request:
      iex> {:ok, conn} = Sorrel.Transport.connect(endpoint)
      iex> {:ok, response, conn} =
      ...>   Sorrel.Conn.request(conn, "GET", "/ping", [], "")
      iex> response
      %{status: 200, headers: [{"content-type", "text/plain"}], body: "OK"}

      # The same connection can be reused for the next request, since the
      # successful return guarantees it is idle:
      iex> {:ok, _next_response, _conn} =
      ...>   Sorrel.Conn.request(conn, "GET", "/ping", [], "")
  """

  # What this module does:
  #   Stateless. Two send primitives:
  #     - request/6 threads a caller-owned Mint conn through one full
  #       request/response.
  #     - open_and_send/6 opens a fresh Mint conn via Transport.connect,
  #       issues one Mint.HTTP.request, and returns the conn and ref to
  #       the caller (who then drives recv themselves).
  #
  # Rules that always hold:
  #   1. On {:ok, response, conn} from request/6, the returned conn has
  #      zero in-flight requests and is safe to reuse for the next call
  #      to request/6.
  #   2. On {:error, reason, conn} from request/6, the conn may be in any
  #      state and the caller should close it with Mint.HTTP.close/1.
  #   3. On {:ok, conn, ref} from open_and_send/6, the caller owns the
  #      conn and the ref, and is responsible for driving recv and
  #      eventually closing.
  #   4. On any error from open_and_send/6, no conn is leaked: a connect
  #      failure never owned a conn; a request failure closes the conn
  #      best-effort before returning.

  alias Sorrel.Endpoint
  alias Sorrel.Transport

  @doc """
  Sends one HTTP request on `conn` and returns the complete response, or
  returns an error if something goes wrong.

  Blocks the calling process until the response is fully received or the
  receive timeout elapses. The underlying socket is in passive mode - no
  Mint messages land in the caller's mailbox during the call.

  ## Parameters

    * `conn` - `Mint.HTTP.t()`. An open connection with no in-flight
      requests. Get one from `Sorrel.Transport.connect/2`. The same
      connection can be passed back into this function once it returns
      successfully (it is returned in the success tuple, idle).

    * `method` - `String.t()`. The HTTP method, uppercase. Typical values
      are `"GET"`, `"POST"`, `"PUT"`, `"DELETE"`, `"HEAD"`. Other valid
      method strings (e.g. `"PATCH"`) are passed through unchanged.

    * `path` - `String.t()`. The request path, including any version
      prefix and any query string. Sent verbatim - this module does not
      transform it. Examples: `"/ping"`, `"/items?limit=10"`,
      `"/users/42/avatar"`.

    * `headers` - `list()` of `{name, value}` string tuples. The headers
      are sent as-is. Mint adds a `Content-Length` header automatically;
      everything else is the caller's responsibility (including
      `Host`, `User-Agent`, `Content-Type`).

    * `body` - `iodata()`. The request body. Use `""` for requests with
      no body.

    * `opts` - `keyword()`. Recognised keys:

      | Key                | Type                | Default     | What it does                                                    |
      | ------------------ | ------------------- | ----------- | --------------------------------------------------------------- |
      | `:receive_timeout` | `non_neg_integer()` or `:infinity` | `15_000`    | Milliseconds to wait for *each* receive while reading the response. A slow but steady response can take much longer than this in total - the timeout resets every time bytes arrive. |

      Unknown keys are ignored.

  ## Returns

    * `{:ok, response, conn}` - the request and response completed. The
      shape is:

          response = %{
            status: integer(),                    # e.g. 200
            headers: [{String.t(), String.t()}],  # response headers, in order
            body: binary()                        # the full raw body bytes
          }

      The `body` is whatever bytes the server sent - no JSON decoding,
      no charset conversion. Use `Sorrel.Codec.decode_body/3` to
      decode if you want.

      `conn` is the same connection you passed in, now idle. It is safe
      to reuse for another call to `request/6`.

    * `{:error, reason, conn}` - the request or response failed. Common
      `reason` values:

      | Reason                            | What it means                                                                                       |
      | --------------------------------- | --------------------------------------------------------------------------------------------------- |
      | `:closed`                         | The peer closed the connection.                                                                     |
      | `:timeout`                        | A receive took longer than `:receive_timeout` milliseconds.                                         |
      | `%Mint.HTTPError{...}`            | A protocol error (malformed response, request after close, etc.).                                   |
      | `%Mint.TransportError{...}`       | A transport error (TCP reset, broken pipe, TLS alert mid-response).                                 |

      The returned `conn` may be in any internal state. Treat it as
      unusable: close it with `Mint.HTTP.close/1` and open a fresh one
      for your next request.

  Any partial response bytes received before the error are discarded.
  This function does not surface partial bodies.

  This function does not raise.

  ## Examples

      # Successful round trip:
      iex> {:ok, conn} = Sorrel.Transport.connect(endpoint)
      iex> {:ok, response, _conn} = Sorrel.Conn.request(conn, "GET", "/ping", [], "")
      iex> response.status
      200
      iex> response.body
      "OK"

      # Posting a JSON body - caller adds the Content-Type header:
      iex> Sorrel.Conn.request(
      ...>   conn,
      ...>   "POST",
      ...>   "/items",
      ...>   [{"content-type", "application/json"}],
      ...>   ~s({"name":"first"})
      ...> )
      # => {:ok, %{status: 201, headers: [...], body: "..."}, conn}

      # The peer closed mid-response:
      iex> Sorrel.Conn.request(conn, "GET", "/slow", [], "", receive_timeout: 100)
      {:error, :timeout, conn}
  """
  @spec request(Mint.HTTP.t(), String.t(), String.t(), list(), iodata(), keyword()) ::
          {:ok, %{status: integer(), headers: list(), body: binary()}, Mint.HTTP.t()}
          | {:error, term(), Mint.HTTP.t()}
  def request(conn, method, path, headers, body, opts \\ []) do
    receive_timeout = Sorrel.Config.receive_timeout(opts)

    case Mint.HTTP.request(conn, method, path, headers, body) do
      {:ok, conn, ref} ->
        recv_loop(conn, ref, receive_timeout, %{
          status: nil,
          headers: [],
          body_iodata: []
        })

      {:error, conn, reason} ->
        # Per the data invariant: the conn is in a known-bad state after a
        # request error; closing it is the caller's responsibility.
        {:error, reason, conn}
    end
  end

  @doc """
  Opens a fresh connection to `endpoint` and sends one HTTP request on it,
  returning the connection and the request `ref` so the caller can drive
  the response loop themselves.

  Use this when you want a one-shot conn (no pooling) and need to read the
  response yourself - for example, an HTTP/1.1 `Upgrade` handshake where
  the response body is the start of a raw byte channel and `request/6`'s
  "block until `:done`" loop is the wrong shape.

  ## Parameters

    * `endpoint` - `Sorrel.Endpoint.t()`. Where to connect. Built by
      `Sorrel.Endpoint.parse/2` or by hand.

    * `method` - `String.t()`. HTTP method, uppercase (e.g. `"GET"`,
      `"POST"`).

    * `path` - `String.t()`. Request path, sent verbatim.

    * `headers` - `[{String.t(), String.t()}]`. Sent as-is. Mint adds
      `Content-Length`; everything else is the caller's responsibility.

    * `body` - `iodata()`. The request body. Use `""` for no body.

    * `opts` - `keyword()`. Forwarded verbatim to
      `Sorrel.Transport.connect/2`. Recognised keys are
      `:connect_timeout` (default `10_000`) and `:mode` (default
      `:passive`). Unknown keys are ignored.

  ## Returns

    * `{:ok, conn, ref}` - the connection is open and the request has been
      written. Caller owns `conn` and `ref`: they must drive
      `Mint.HTTP.recv/3` (or `Mint.HTTP.stream/2` if active mode was
      requested) and eventually call `Mint.HTTP.close/1`.

    * `{:error, reason}` - either the connect or the request failed. On
      a connect failure, no conn was ever owned. On a request failure
      (after a successful connect), the conn has been closed best-effort
      before this tuple is returned, so the caller has nothing to clean up.

  This function does not raise.

  ## Examples

      iex> {:ok, ep} = Sorrel.Endpoint.parse("unix:///tmp/myapp.sock")
      iex> {:ok, conn, ref} =
      ...>   Sorrel.Conn.open_and_send(ep, "GET", "/_ping", [{"host", "localhost"}], "")
      iex> is_reference(ref) and Mint.HTTP.open?(conn)
      true
  """
  @spec open_and_send(
          Endpoint.t(),
          String.t(),
          String.t(),
          [{String.t(), String.t()}],
          iodata(),
          keyword()
        ) :: {:ok, Mint.HTTP.t(), reference()} | {:error, term()}
  def open_and_send(endpoint, method, path, headers, body, opts \\ []) do
    case Transport.connect(endpoint, opts) do
      {:ok, conn} ->
        case Mint.HTTP.request(conn, method, path, headers, body) do
          {:ok, conn, ref} ->
            {:ok, conn, ref}

          {:error, conn, reason} ->
            :ok = safe_close(conn)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec safe_close(Mint.HTTP.t()) :: :ok
  defp safe_close(conn) do
    case Mint.HTTP.close(conn) do
      {:ok, _closed_conn} -> :ok
    end
  catch
    _kind, _reason -> :ok
  end

  # Drives one Mint.HTTP.recv/3 call at a time in passive mode, accumulating
  # response parts until {:done, ref} arrives.
  #
  # Mint.HTTP.recv(conn, 0, timeout) blocks until at least one response item
  # is available; it should not normally return {:ok, conn, []} when the
  # timeout is positive, but we treat an empty-list reply as "keep looping"
  # to be defensive against future Mint behaviour.
  defp recv_loop(conn, ref, timeout, acc) do
    case Mint.HTTP.recv(conn, 0, timeout) do
      {:ok, conn, []} ->
        recv_loop(conn, ref, timeout, acc)

      {:ok, conn, responses} ->
        case absorb(responses, ref, acc) do
          {:done, acc} -> {:ok, finalize(acc), conn}
          {:cont, acc} -> recv_loop(conn, ref, timeout, acc)
        end

      {:error, conn, reason, _responses} ->
        # Any responses already buffered are dropped: the response is
        # incomplete and the caller has no use for a partial body. The
        # caller is expected to close the conn.
        {:error, reason, conn}
    end
  end

  # Folds a list of Mint response items into the accumulator. Returns
  # `{:done, acc}` once `{:done, ref}` is seen, otherwise `{:cont, acc}`.
  defp absorb(responses, ref, acc) do
    Enum.reduce_while(responses, {:cont, acc}, fn
      {:status, ^ref, status}, {:cont, acc} ->
        {:cont, {:cont, %{acc | status: status}}}

      {:headers, ^ref, hs}, {:cont, acc} ->
        # Prepend (reversed) per :headers event; finalize/1 reverses once.
        # Plain `++` here would be O(headers² ) across multiple events.
        {:cont, {:cont, %{acc | headers: Enum.reverse(hs, acc.headers)}}}

      {:data, ^ref, chunk}, {:cont, acc} ->
        {:cont, {:cont, %{acc | body_iodata: [acc.body_iodata, chunk]}}}

      {:done, ^ref}, {:cont, acc} ->
        {:halt, {:done, acc}}

      _other, state ->
        # Items for other refs are not expected on a single-request conn,
        # but we ignore them defensively.
        {:cont, state}
    end)
  end

  defp finalize(%{status: status, headers: headers, body_iodata: body_iodata}) do
    # Headers were accumulated in reverse during absorb/3 to avoid an O(n²)
    # left-append; restore arrival order here.
    %{
      status: status,
      headers: Enum.reverse(headers),
      body: IO.iodata_to_binary(body_iodata)
    }
  end
end

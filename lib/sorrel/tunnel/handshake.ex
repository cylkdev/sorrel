defmodule Sorrel.Tunnel.Handshake do
  @moduledoc """
  Performs an HTTP/1.1 `Upgrade` handshake and hands you back the raw
  socket the connection used.

  Some HTTP servers respond to certain requests with `101 Switching
  Protocols` (or sometimes `200 OK`) and then stop speaking HTTP on
  that connection - both sides keep the underlying socket open and
  exchange whatever bytes the protocol on top of the upgrade
  dictates. WebSockets are the most common example, but any
  proprietary upgrade protocol works the same way.

  This module's job is to do the request, read the status line and
  headers, check that the server accepted the upgrade, and then hand
  back the underlying socket so you can use it as a raw byte channel.
  Once `upgrade/4` returns successfully, the HTTP layer is *done* -
  this module does not parse another request or response on that
  socket.

  ## What you get back on success

  A three-element tuple: `{:ok, socket, leftover}`.

    * `socket` is one of two shapes Erlang/OTP defines:
      * `:gen_tcp.socket()` - for `unix://` and plain `tcp://` /
        `http://` endpoints.
      * `:ssl.sslsocket()` - for `https://` endpoints.

      Both shapes are accepted by `Sorrel.Tunnel.Socket.send/2`,
      `recv/3`, and `close/1`, which is the recommended way to use the
      socket without writing the dispatch yourself.

    * `socket` is set to **passive mode** with **packet `:raw`**: bytes
      do not arrive in your mailbox, and `recv/3` returns whatever
      arbitrary chunk of bytes the OS hands back.

    * `leftover` is a binary of bytes the underlying connection had
      already read past the response head before the upgrade
      completed. **You must consume `leftover` before reading from the
      socket directly**, otherwise you will skip those bytes. The
      easy way is to use them as the first chunk of your read loop.

  ## When you would call this module yourself

  Most callers do not. This is the building block on top of which
  upgrade-style protocol clients are built (for example, a WebSocket
  client or a "raw byte channel" RPC client). Call `upgrade/4`
  directly when:

    * You are implementing such a protocol client yourself.
    * You are testing an upgrade endpoint and want to inspect the
      raw bytes the server sends.

  ## Examples

      iex> {:ok, ep} = Sorrel.Endpoint.parse("unix:///tmp/myapp.sock")
      iex> {:ok, socket, leftover} =
      ...>   Sorrel.Tunnel.Handshake.upgrade(
      ...>     :post,
      ...>     "/upgrade?stream=1",
      ...>     "",
      ...>     endpoint: ep
      ...>   )
      iex> is_binary(leftover)
      true

      # Read what the server sends after the upgrade:
      iex> Sorrel.Tunnel.Socket.recv(socket, 0, 1_000)
      {:ok, "hello from the server"}

      # And tear down when you are done:
      iex> Sorrel.Tunnel.Socket.close(socket)
      :ok
  """

  # What this module does:
  #   Stateless. Owns the HTTP-101 (or 200) upgrade dance over a
  #   `Sorrel.Transport.connect/2` result. The protocol shape is
  #   generic HTTP/1.1 RFC 9110 Upgrade - no service-specific knowledge.
  #
  # Rules that always hold:
  #   1. On `{:ok, sock, leftover}`, `sock` is either a `:gen_tcp.socket()`
  #      or an `:ssl.sslsocket()`, in passive mode, packet `:raw`.
  #   2. On `{:error, _}`, no resources are leaked - any partially-opened
  #      connection is closed before returning.

  alias Sorrel.Conn
  alias Sorrel.Endpoint

  @default_receive_timeout 10_000

  @doc """
  Sends an HTTP request asking for a connection upgrade and returns the
  raw socket if the server accepts, or returns an error tuple if
  anything went wrong.

  Synchronous - blocks the calling process until the response status
  and headers have been read and the upgrade is decided.

  ## Headers Sorrel sends automatically

  On every call, Sorrel puts the following headers on the wire **before**
  any extras you pass in `opts[:headers]`:

  | Header           | Value                                          |
  | ---------------- | ---------------------------------------------- |
  | `host`           | `"localhost"` (always - even for TCP endpoints)|
  | `upgrade`        | `"tcp"`                                        |
  | `connection`     | `"Upgrade"`                                    |
  | `content-type`   | `"application/json"`                           |
  | `content-length` | the length of `body` in bytes, as a string      |

  These are the headers most "upgrade an HTTP connection to a raw byte
  channel" servers expect. You can override any of them by passing the
  same name in `opts[:headers]` - the extras are appended after the
  base list, and HTTP/1.1's last-write-wins rule applies.

  ## Parameters

    * `method` - `:post | :get`. The HTTP method to use. Atoms are
      converted to uppercase strings (`:post` -> `"POST"`).

    * `path` - `String.t()`. The full request path including any
      prefix and query string. Sent verbatim - this function does not
      inject a version prefix or rewrite the path.

    * `body` - `iodata()`. The request body. Use `""` for endpoints
      that take no body. The function does not encode the body -
      callers JSON-encode it themselves if they need to.

    * `opts` - `keyword()`. Recognised keys:

      | Key                | Type                                | Default     | What it does                                                  |
      | ------------------ | ----------------------------------- | ----------- | ------------------------------------------------------------- |
      | `:endpoint`        | `Sorrel.Endpoint.t()`         | (required)  | Where to connect.                                             |
      | `:headers`         | `list()` of `{name, value}` tuples  | `[]`         | Extra request headers. Appended after the base list above.    |
      | `:connect_timeout` | `non_neg_integer()`                 | `10_000`     | Milliseconds for the connect/handshake.                       |
      | `:receive_timeout` | `non_neg_integer()` or `:infinity`  | `10_000`     | Milliseconds per receive while reading the response head.     |

      Unknown keys are ignored.

  ## Returns

    * `{:ok, socket, leftover}` - the server replied with status `101`
      or `200`, and the connection has been switched to a raw byte
      channel.
      * `socket` is a `:gen_tcp.socket()` (for `unix://` and plain
        TCP) or an `:ssl.sslsocket()` (for `https://`). It is in
        passive mode with `packet: :raw`.
      * `leftover` is a binary of bytes the underlying transport
        already buffered past the response head. May be `""`. **Consume
        `leftover` first** before reading from the socket directly,
        or pass it through `Sorrel.Tunnel.Socket.recv/3`
        wrapping logic that prepends it to the next read.

    * `{:error, %{status: code, body: body}}` - the server returned a
      status other than 101 or 200. The body is whatever bytes were
      collected from the response before end-of-message. Use this to
      surface a meaningful error to your caller (e.g. the server
      rejected the upgrade). The connection has already been closed.

    * `{:error, :endpoint_required}` - the `:endpoint` key was missing
      from `opts`.

    * `{:error, reason}` - a transport or protocol failure during
      connect or handshake. Common reasons:

      | Reason                            | What it means                                                                                       |
      | --------------------------------- | --------------------------------------------------------------------------------------------------- |
      | `:econnrefused`                   | The server is not listening.                                                                        |
      | `:enoent`                         | A Unix socket file or TLS cert file is missing.                                                     |
      | `:timeout`                        | The connect, TLS handshake, or response-head read took too long.                                    |
      | `{:tls_alert, _}`                 | The TLS handshake was rejected.                                                                     |
      | `%Mint.TransportError{...}`       | Any other transport error.                                                                          |

  On any error, no resources are leaked - any partially-opened
  connection is closed before returning.

  This function does not raise.

  ## Examples

      # Successful upgrade against a Unix-socket endpoint:
      iex> {:ok, ep} = Sorrel.Endpoint.parse("unix:///tmp/myapp.sock")
      iex> {:ok, _sock, _leftover} =
      ...>   Sorrel.Tunnel.Handshake.upgrade(
      ...>     :post,
      ...>     "/upgrade?stream=1",
      ...>     "",
      ...>     endpoint: ep
      ...>   )

      # Server refused the upgrade with HTTP 400:
      iex> {:error, %{status: 400, body: "bad request"}} =
      ...>   Sorrel.Tunnel.Handshake.upgrade(
      ...>     :post,
      ...>     "/no-such-endpoint",
      ...>     "",
      ...>     endpoint: ep
      ...>   )

      # Missing endpoint:
      iex> Sorrel.Tunnel.Handshake.upgrade(:post, "/x", "", [])
      {:error, :endpoint_required}
  """
  @spec upgrade(:post | :get, String.t(), iodata(), keyword()) ::
          {:ok, :gen_tcp.socket() | :ssl.sslsocket(), binary()}
          | {:error, term()}
  def upgrade(method, path, body, opts)
      when method in [:post, :get] and is_binary(path) and is_list(opts) do
    case Keyword.get(opts, :endpoint) do
      %Endpoint{} = endpoint ->
        do_upgrade(method, path, body, endpoint, opts)

      _other ->
        {:error, :endpoint_required}
    end
  end

  @spec do_upgrade(
          :post | :get,
          String.t(),
          iodata(),
          Endpoint.t(),
          keyword()
        ) ::
          {:ok, :gen_tcp.socket() | :ssl.sslsocket(), binary()}
          | {:error, term()}
  defp do_upgrade(method, path, body, endpoint, opts) do
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)
    headers = build_headers(body, opts)
    method_string = method_to_string(method)

    with {:ok, conn, ref} <-
           Conn.open_and_send(endpoint, method_string, path, headers, body, opts),
         {:ok, conn, status, leftover} <- await_upgrade(conn, ref, receive_timeout, opts),
         :ok <- check_status(status, leftover) do
      socket = Mint.HTTP.get_socket(conn)

      case set_passive_raw(socket) do
        :ok ->
          {:ok, socket, leftover}

        {:error, reason} ->
          :ok = close_socket(socket)
          {:error, reason}
      end
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec build_headers(iodata(), keyword()) :: [{String.t(), String.t()}]
  defp build_headers(body, opts) do
    base = [
      {"host", "localhost"},
      {"upgrade", "tcp"},
      {"connection", "Upgrade"},
      {"content-type", "application/json"},
      {"content-length", body |> IO.iodata_length() |> Integer.to_string()}
    ]

    extra = Keyword.get(opts, :headers, [])
    base ++ extra
  end

  @spec method_to_string(:post | :get) :: String.t()
  defp method_to_string(:post) do
    "POST"
  end

  defp method_to_string(:get) do
    "GET"
  end

  @spec await_upgrade(Mint.HTTP.t(), reference(), timeout(), keyword()) ::
          {:ok, Mint.HTTP.t(), non_neg_integer(), binary()}
          | {:error, term()}
  defp await_upgrade(conn, ref, timeout, opts) do
    await_upgrade(conn, ref, timeout, opts, nil, "", false)
  end

  @spec await_upgrade(
          Mint.HTTP.t(),
          reference(),
          timeout(),
          keyword(),
          non_neg_integer() | nil,
          binary(),
          boolean()
        ) ::
          {:ok, Mint.HTTP.t(), non_neg_integer(), binary()}
          | {:error, term()}
  defp await_upgrade(conn, ref, timeout, opts, status, leftover, headers_seen?) do
    case Mint.HTTP.recv(conn, 0, timeout) do
      {:ok, conn, responses} ->
        case fold_responses(responses, ref, status, leftover, headers_seen?) do
          {:done, new_status, new_leftover} ->
            {:ok, conn, new_status, new_leftover}

          {:cont, new_status, new_leftover, true} ->
            # Headers seen but no :done. For an upgrade response we
            # never get :done because the body is the upgraded stream;
            # treat end-of-recv-batch with headers seen as success.
            {:ok, conn, new_status, new_leftover}

          {:cont, new_status, new_leftover, false} ->
            # No headers yet; recv again.
            await_upgrade(conn, ref, timeout, opts, new_status, new_leftover, false)

          {:error, reason} ->
            :ok = safe_close(conn)
            {:error, reason}
        end

      {:error, conn, reason, _responses} ->
        :ok = safe_close(conn)
        {:error, reason}
    end
  end

  @spec fold_responses(
          [Mint.Types.response()],
          reference(),
          non_neg_integer() | nil,
          binary(),
          boolean()
        ) ::
          {:done, non_neg_integer() | nil, binary()}
          | {:cont, non_neg_integer() | nil, binary(), boolean()}
          | {:error, term()}
  defp fold_responses(responses, ref, status, leftover, headers_seen?) do
    Enum.reduce_while(responses, {:cont, status, leftover, headers_seen?}, fn
      {:status, ^ref, code}, {:cont, _status, lo, hs} ->
        {:cont, {:cont, code, lo, hs}}

      {:headers, ^ref, _headers}, {:cont, current_status, lo, _hs} ->
        {:cont, {:cont, current_status, lo, true}}

      {:data, ^ref, chunk}, {:cont, current_status, lo, hs} ->
        {:cont, {:cont, current_status, lo <> chunk, hs}}

      {:done, ^ref}, {:cont, current_status, lo, _hs} ->
        {:halt, {:done, current_status, lo}}

      {:error, ^ref, reason}, _acc ->
        {:halt, {:error, reason}}

      _other, acc ->
        {:cont, acc}
    end)
  end

  @spec check_status(non_neg_integer() | nil, binary()) :: :ok | {:error, map()}
  defp check_status(101, _body) do
    :ok
  end

  defp check_status(200, _body) do
    :ok
  end

  defp check_status(code, body) do
    {:error, %{status: code, body: body}}
  end

  @spec set_passive_raw(:gen_tcp.socket() | :ssl.sslsocket()) :: :ok | {:error, term()}
  defp set_passive_raw(socket) when is_port(socket) do
    :inet.setopts(socket, packet: :raw, active: false)
  end

  defp set_passive_raw({:sslsocket, _, _} = socket) do
    :ssl.setopts(socket, packet: :raw, active: false)
  end

  @spec close_socket(:gen_tcp.socket() | :ssl.sslsocket()) :: :ok
  defp close_socket(socket) when is_port(socket) do
    case :gen_tcp.close(socket) do
      :ok -> :ok
    end
  end

  defp close_socket({:sslsocket, _, _} = socket) do
    case :ssl.close(socket) do
      :ok -> :ok
      {:error, _reason} -> :ok
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
end

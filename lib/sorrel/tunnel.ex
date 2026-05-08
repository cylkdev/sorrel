defmodule Sorrel.Tunnel do
  @moduledoc """
  Public entrypoint for opening and using HTTP-to-raw-socket tunnels
  against any HTTP endpoint that supports `Connection: Upgrade`.

  A tunnel is the result of an HTTP/1.1 `Upgrade` handshake (RFC 9110):
  the request goes out as ordinary HTTP, the server replies with `101
  Switching Protocols` (or `200 OK` for legacy upgrade dialects), and
  from that point on the underlying socket is no longer HTTP - both
  peers exchange whatever bytes the protocol on top of the upgrade
  dictates.

  This module is the front door for callers. The lifecycle is:

      {:ok, socket, leftover} = Sorrel.Tunnel.upgrade(method, path, body, opts)
      :ok = Sorrel.Tunnel.send(socket, payload)
      {:ok, bytes} = Sorrel.Tunnel.recv(socket, 0, timeout)
      :ok = Sorrel.Tunnel.close(socket)

  The returned `socket` is in passive mode with `packet: :raw` - it is a
  `:gen_tcp.socket()` for `unix://` and plain `tcp://` / `http://`
  endpoints, or a `:ssl.sslsocket()` for `https://`. Callers should
  reach the tunnel API through this module rather than calling
  `Sorrel.Tunnel.Handshake` or `Sorrel.Tunnel.Socket`
  directly; those are internal implementation modules of the tunnel
  subsystem and their surface may change.

  ## Example

      iex> {:ok, ep} = Sorrel.Endpoint.parse("unix:///tmp/myapp.sock")
      iex> {:ok, socket, _leftover} =
      ...>   Sorrel.Tunnel.upgrade(:post, "/upgrade?stream=1", "", endpoint: ep)
      iex> :ok = Sorrel.Tunnel.send(socket, "ping\\n")
      iex> {:ok, _reply} = Sorrel.Tunnel.recv(socket, 0, 1_000)
      iex> Sorrel.Tunnel.close(socket)
      :ok
  """

  # What this module is:
  #   Stateless façade. Re-exports the four-function tunnel surface
  #   (upgrade, send, recv, close) by delegating to the implementation
  #   modules `Tunnel.Handshake` and `Tunnel.Socket`. Holds no state
  #   and adds no logic of its own - every call is a one-line forward.
  #
  # Rules that always hold:
  #   1. `upgrade/4` returns exactly what `Tunnel.Handshake.upgrade/4`
  #      returns: `{:ok, socket, leftover} | {:error, term()}`.
  #   2. `send/2`, `recv/3`, `close/1` accept the same socket shapes
  #      `Tunnel.Socket` accepts (a `:gen_tcp.socket()` port or an
  #      `{:sslsocket, _, _}` tuple) and dispatch identically.
  #   3. This module never wraps the socket in a struct or opaque
  #      type - the return shape is the same as the implementation
  #      modules', so callers can mix-and-match if they need to.

  alias Sorrel.Tunnel.Handshake
  alias Sorrel.Tunnel.Socket

  @typedoc """
  An open tunnel socket - a `:gen_tcp.socket()` or `:ssl.sslsocket()`
  in passive mode with `packet: :raw`.
  """
  @type t :: Socket.t()

  @doc """
  Sends an HTTP request asking for a connection upgrade and returns the
  raw socket if the server accepts, or returns an error tuple if the
  upgrade was refused or a transport failure happened.

  See `Sorrel.Tunnel.Handshake.upgrade/4` for the full parameter
  table, returns, and error reasons.
  """
  @spec upgrade(:post | :get, String.t(), iodata(), keyword()) ::
          {:ok, :gen_tcp.socket() | :ssl.sslsocket(), binary()}
          | {:error, term()}
  defdelegate upgrade(method, path, body, opts), to: Handshake

  @doc """
  Writes `data` to the tunnel socket's send buffer and returns `:ok`
  on success, or `{:error, reason}` if the underlying transport call
  fails.

  See `Sorrel.Tunnel.Socket.send/2` for full semantics.
  """
  @spec send(t(), iodata()) :: :ok | {:error, term()}
  defdelegate send(socket, data), to: Socket

  @doc """
  Reads bytes from the tunnel socket and returns them, or returns an
  error if no bytes arrived in time, the peer closed, or the transport
  failed.

  See `Sorrel.Tunnel.Socket.recv/3` for full semantics.
  """
  @spec recv(t(), non_neg_integer(), timeout()) ::
          {:ok, binary()} | {:error, term()}
  defdelegate recv(socket, length, timeout), to: Socket

  @doc """
  Closes the tunnel socket and returns `:ok`. Safe to call more than
  once.

  See `Sorrel.Tunnel.Socket.close/1` for full semantics.
  """
  @spec close(t()) :: :ok
  defdelegate close(socket), to: Socket
end

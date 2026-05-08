defmodule Sorrel.Tunnel.Socket do
  @moduledoc """
  A unified read/write/close interface for the raw socket you get from
  an HTTP upgrade.

  When `Sorrel.Tunnel.Handshake.upgrade/4` succeeds, it hands
  back a socket that no longer speaks HTTP - both peers are now free to
  exchange whatever bytes the protocol on top of the upgrade dictates
  (a custom byte stream, a WebSocket frame, etc.). That underlying
  socket is one of two Erlang/OTP shapes:

    * a `:gen_tcp.socket()` - an Erlang port. Used for `unix://`
      endpoints and plain `tcp://` / `http://` endpoints.
    * a `:ssl.sslsocket()` - a `{:sslsocket, _, _}` tuple. Used for
      `https://` endpoints.

  Callers do not want to write `case socket do ... end` every time
  they read or write a byte. This module provides three functions
  that work on either shape: `send/2`, `recv/3`, `close/1`. Each one
  looks at the socket shape and dispatches to the right transport
  module (`:gen_tcp` or `:ssl`).

  ## Passive mode

  All sockets handed to this module are expected to be in passive
  mode - bytes do not arrive in the calling process's mailbox.
  Instead, callers ask for bytes explicitly via `recv/3`. This is the
  mode `Handshake.upgrade/4` configures before returning.

  ## A short worked example

      # `socket` came from a successful Handshake.upgrade/4:
      iex> :ok = Sorrel.Tunnel.Socket.send(socket, "hello\\n")
      iex> Sorrel.Tunnel.Socket.recv(socket, 0, 500)
      {:ok, "got: hello\\n"}
      iex> Sorrel.Tunnel.Socket.close(socket)
      :ok

  ## What this module does *not* do

    * It does not interpret the bytes. Whatever protocol you and the
      server agreed on lives above this layer.
    * It does not buffer or reassemble. `recv/3` returns whatever the
      OS hands back in one call.
    * It does not track open/closed state. `close/1` is safe to call
      again, but the function does not remember that it was closed.
  """

  @type t :: :gen_tcp.socket() | :ssl.sslsocket()

  @doc """
  Writes `data` to the socket's send buffer and returns `:ok` on
  success, or `{:error, reason}` if the underlying transport call
  fails.

  Returning `:ok` only means the OS accepted the bytes into its send
  buffer. It does **not** mean the peer has received them. If the
  peer has closed the connection, the next `send/2` (or `recv/3`)
  typically reports `{:error, :closed}`.

  Dispatches on the socket shape:

    * `:gen_tcp.socket()` (a port) -> `:gen_tcp.send/2`.
    * `:ssl.sslsocket()` (a `{:sslsocket, _, _}` tuple) -> `:ssl.send/2`.

  ## Parameters

    * `socket` - `t()`. A socket returned by
      `Sorrel.Tunnel.Handshake.upgrade/4`.
    * `data` - `iodata()`. The bytes to write. Includes any trailing
      newline, framing, or length prefix the protocol expects - this
      function does not add any.

  ## Returns

    * `:ok` - the bytes were accepted into the send buffer.
    * `{:error, :closed}` - the peer has closed the connection.
    * `{:error, :timeout}` - the send did not complete in time
      (rare for buffered sends).
    * `{:error, %Mint.TransportError{...}}` or other low-level error
      tuples - anything else `:gen_tcp` or `:ssl` surfaces.

  This function does not raise.

  ## Examples

      iex> Sorrel.Tunnel.Socket.send(socket, "hello\\n")
      :ok

      # After the peer has closed:
      iex> Sorrel.Tunnel.Socket.send(socket, "hello\\n")
      {:error, :closed}
  """
  @spec send(t(), iodata()) :: :ok | {:error, term()}
  def send(socket, data) when is_port(socket) do
    :gen_tcp.send(socket, data)
  end

  def send({:sslsocket, _, _} = socket, data) do
    :ssl.send(socket, data)
  end

  @doc """
  Reads bytes from the socket and returns them, or returns an error if
  no bytes arrived in time, the peer closed, or the transport failed.

  Blocks the calling process until the requested number of bytes is
  available, the timeout elapses, or the connection ends. Works only
  in passive mode - sockets handed back by `Handshake.upgrade/4` are
  always passive.

  Dispatches on the socket shape:

    * `:gen_tcp.socket()` (a port) -> `:gen_tcp.recv/3`.
    * `:ssl.sslsocket()` (a `{:sslsocket, _, _}` tuple) -> `:ssl.recv/3`.

  ## Parameters

    * `socket` - `t()`. A socket returned by
      `Sorrel.Tunnel.Handshake.upgrade/4`.
    * `length` - `non_neg_integer()`. The number of bytes to read.
      Two distinct shapes:
      * `0` means "give me any number of bytes that are currently
        available, even just one." Useful for streaming reads where
        you do not know the chunk size in advance.
      * any positive number means "wait until exactly that many
        bytes are available." If fewer bytes than that arrive
        before the timeout, `{:error, :timeout}` is returned and the
        partial bytes are buffered for the next call.
    * `timeout` - `timeout()`. Milliseconds to wait, or `:infinity`
      to wait forever.

  ## Returns

    * `{:ok, binary()}` - the bytes that were read. The binary's
      length is exactly `length` (when `length > 0`) or whatever was
      available (when `length == 0`).
    * `{:error, :timeout}` - nothing (or not enough) arrived within
      `timeout` milliseconds.
    * `{:error, :closed}` - the peer has closed the socket. No more
      bytes will ever come on this socket.
    * `{:error, reason}` - any other transport failure surfaced by
      `:gen_tcp` or `:ssl`.

  This function does not raise.

  ## Examples

      # Read whatever is available, with a 500 ms idle window:
      iex> Sorrel.Tunnel.Socket.recv(socket, 0, 500)
      {:ok, "got: hello\\n"}

      # Read exactly 5 bytes, blocking up to 1 second:
      iex> Sorrel.Tunnel.Socket.recv(socket, 5, 1_000)
      {:ok, "12345"}

      # Nothing arrived in time:
      iex> Sorrel.Tunnel.Socket.recv(socket, 0, 100)
      {:error, :timeout}

      # Peer closed:
      iex> Sorrel.Tunnel.Socket.recv(socket, 0, 1_000)
      {:error, :closed}
  """
  @spec recv(t(), non_neg_integer(), timeout()) ::
          {:ok, binary()} | {:error, term()}
  def recv(socket, length, timeout) when is_port(socket) do
    :gen_tcp.recv(socket, length, timeout)
  end

  def recv({:sslsocket, _, _} = socket, length, timeout) do
    :ssl.recv(socket, length, timeout)
  end

  @doc """
  Closes the socket and returns `:ok`.

  Safe to call more than once. Calls after the first do nothing - the
  function returns `:ok` regardless of whether the socket was open.

  Dispatches on the socket shape:

    * `:gen_tcp.socket()` (a port) -> `:gen_tcp.close/1`.
    * `:ssl.sslsocket()` (a `{:sslsocket, _, _}` tuple) -> `:ssl.close/1`.

  ## Parameters

    * `socket` - `t()`. A socket returned by
      `Sorrel.Tunnel.Handshake.upgrade/4`.

  ## Returns

  `:ok`. Always.

  This function does not raise. Errors from the underlying
  `:gen_tcp.close/1` or `:ssl.close/1` are swallowed so that close is
  unconditionally safe.

  ## Examples

      iex> Sorrel.Tunnel.Socket.close(socket)
      :ok

      # Calling close a second time is fine:
      iex> Sorrel.Tunnel.Socket.close(socket)
      :ok
  """
  @spec close(t()) :: :ok
  def close(socket) when is_port(socket) do
    case :gen_tcp.close(socket) do
      :ok -> :ok
    end
  end

  def close({:sslsocket, _, _} = socket) do
    case :ssl.close(socket) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end
end

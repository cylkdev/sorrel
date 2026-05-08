defmodule Sorrel.Transport do
  @moduledoc """
  A thin dispatcher that opens a single network connection to the server
  described by an endpoint.

  Sorrel supports three transports:

  1. Unix domain sockets
  2. TCP (with optional TLS)
  3. SSH

  This module is the seam between them. You hand it a `Sorrel.Endpoint` struct;
  it looks at the struct's `:transport` field and forwards the call to one of
  `Sorrel.Transport.Unix`, `Sorrel.Transport.Tcp`, or `Sorrel.Transport.SSH`.
  It does no work of its own beyond that.

  ## When you would call this module yourself

  Most callers never do. `Sorrel.request/4` and
  `Sorrel.stream/4` open and close connections for you, pooled by
  the `Sorrel.Pool` module. Reach for `connect/2` directly only
  when:

    * You are wiring up your own HTTP loop with `Sorrel.Conn` and
      want full control over the connection's life.
    * You want to test connectivity by itself (see if the server is
      reachable before sending any requests).

  ## What you get back

  `connect/2` returns `{:ok, conn}` where `conn` is a `Mint.HTTP.t()` -
  Sorrel uses the `mint` library underneath. You hand `conn` to
  `Sorrel.Conn.request/6` to send a request on it, and you close
  it with `Mint.HTTP.close/1` when you are done. Each call to `connect/2`
  opens a brand-new connection. There is no caching at this layer.

  ## Examples

      # Open a connection to a server listening on a Unix socket file:
      iex> {:ok, endpoint} = Sorrel.Endpoint.parse("unix:///tmp/myapp.sock")
      iex> {:ok, conn} = Sorrel.Transport.connect(endpoint)
      iex> is_struct(conn, Mint.HTTP1)
      true

      # The dispatch is purely on the :transport field:
      iex> ep = %Sorrel.Endpoint{transport: :tcp, scheme: :http, host: "127.0.0.1", port: 8080}
      iex> match?({:ok, _conn} <- Sorrel.Transport.connect(ep), false)
      false
  """

  # What this module does:
  #   Stateless. Looks at endpoint.transport and forwards to one of two
  #   sibling modules.
  #
  # Rules that always hold:
  #   1. The dispatch table covers every legal value of endpoint.transport
  #      (`:unix`, `:tcp`, `:ssh`). A struct with any other transport
  #      value produces a `FunctionClauseError`, which surfaces a
  #      corrupted struct immediately rather than producing a misleading
  #      transport error later.

  @doc """
  The contract every transport implementation must satisfy.

  `Sorrel.Transport.Unix`, `Sorrel.Transport.Tcp`, and
  `Sorrel.Transport.SSH` implement this callback. If you are
  writing a fourth transport (and there are very few reasons to),
  implement this and add a clause to the `connect/2` dispatcher in
  this module.

  ## Parameters

    * `endpoint` - `Sorrel.Endpoint.t()`. The endpoint to connect
      to. Implementations may pattern-match on the struct's transport
      field and assume their own transport.
    * `opts` - `keyword()`. Forwarded by `connect/2` from the caller.
      Implementations should at minimum honour `:connect_timeout`
      (milliseconds, default `10_000`).

  ## Returns

    * `{:ok, conn}` on success, where `conn` is a `Mint.HTTP.t()` ready
      to send requests. The implementation must own the connection until
      it returns success - partial sockets must be cleaned up before an
      error is returned.
    * `{:error, reason}` on failure. Implementations should return
      transport-style error atoms (e.g. `:econnrefused`, `:enoent`,
      `:timeout`) and Mint error structs as-is. They should not raise
      for expected network failures.
  """
  @callback connect(Sorrel.Endpoint.t(), opts :: keyword()) ::
              {:ok, Mint.HTTP.t()} | {:error, term()}

  @doc """
  Opens a single network connection to the server described by `endpoint`
  and returns a connection handle, or returns an error on failure.

  ## Parameters

    * `endpoint` - `Sorrel.Endpoint.t()`. Must satisfy the rules in
      `Sorrel.Endpoint`'s "Rules that always hold" comment - in
      particular, `transport` must be `:unix`, `:tcp`, or `:ssh`. Build
      one with `Sorrel.Endpoint.parse/2` or by hand.
    * `opts` - `keyword()`. Forwarded verbatim to the chosen transport
      implementation. Recognised keys:

      | Key                | Type           | Default     | What it does                                                  |
      | ------------------ | -------------- | ----------- | ------------------------------------------------------------- |
      | `:connect_timeout` | `non_neg_integer()` | `10_000`     | Milliseconds to wait for the TCP connect / TLS handshake.      |
      | `:mode`            | `:passive` / `:active` | `:passive` | Underlying socket mode handed to Mint.                        |

      Unknown keys are ignored.

  ## Returns

    * `{:ok, conn}` - `conn` is a `Mint.HTTP.t()` (specifically a
      `Mint.HTTP1.t()` since Sorrel's transports always negotiate HTTP/1.1).
      The connection is open and ready for one in-flight request at a
      time. Pass it to `Sorrel.Conn.request/6`. Close it with
      `Mint.HTTP.close/1` when finished.

    * `{:error, reason}` - failure to open the connection. Common
      `reason` values:

      | Reason                            | What it means                                                                                       |
      | --------------------------------- | --------------------------------------------------------------------------------------------------- |
      | `:econnrefused`                   | Nothing is listening on the target host:port.                                                       |
      | `:enoent`                         | A Unix socket file or TLS certificate file the connection needs is missing.                         |
      | `:eacces`                         | The Unix socket file exists but the current process lacks permission to connect to it.              |
      | `:timeout`                        | The TCP connect or TLS handshake took longer than `:connect_timeout`.                               |
      | `{:tls_alert, alert}`             | The TLS handshake was rejected - wrong certificate, hostname mismatch, expired cert, etc.           |
      | `%Mint.TransportError{...}`       | Any other error Mint surfaced from the underlying socket.                                           |

  Each call opens a fresh connection; this module never caches or pools.

  ## Raises

    * `FunctionClauseError` - when `endpoint.transport` is none of
      `:unix`, `:tcp`, or `:ssh`. A struct produced by
      `Sorrel.Endpoint.parse/2` will never trigger this. The
      clause failure exists so a corrupted struct surfaces immediately
      rather than producing a misleading transport error later.

  ## Examples

      # Successful Unix-socket connect (assumes a server is listening):
      iex> {:ok, ep} = Sorrel.Endpoint.parse("unix:///tmp/myapp.sock")
      iex> {:ok, _conn} = Sorrel.Transport.connect(ep)

      # Missing socket file produces :enoent:
      iex> Sorrel.Transport.connect(
      ...>   %Sorrel.Endpoint{transport: :unix, socket_path: "/no/such/file"})
      {:error, :enoent}

      # TCP connect with a custom timeout:
      iex> ep = %Sorrel.Endpoint{transport: :tcp, scheme: :http, host: "127.0.0.1", port: 8080}
      iex> Sorrel.Transport.connect(ep, connect_timeout: 2_000)
      # => {:ok, conn} or {:error, :econnrefused} depending on whether something is listening
  """
  @spec connect(Sorrel.Endpoint.t(), keyword()) :: {:ok, Mint.HTTP.t()} | {:error, term()}
  def connect(endpoint, opts \\ [])

  def connect(%Sorrel.Endpoint{transport: :unix} = ep, opts),
    do: Sorrel.Transport.Unix.connect(ep, opts)

  def connect(%Sorrel.Endpoint{transport: :tcp} = ep, opts),
    do: Sorrel.Transport.Tcp.connect(ep, opts)

  def connect(%Sorrel.Endpoint{transport: :ssh} = ep, opts),
    do: Sorrel.Transport.SSH.connect(ep, opts)
end

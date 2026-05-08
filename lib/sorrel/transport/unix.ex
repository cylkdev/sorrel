defmodule Sorrel.Transport.Unix do
  @moduledoc """
  Opens an HTTP/1.1 connection to a server listening on a Unix domain
  socket file.

  A Unix domain socket is a file on the local filesystem (typically
  with a path like `/tmp/myapp.sock` or `/var/run/something.sock`)
  that two processes on the same machine use to talk to each other.
  The OS handles the byte transport - there is no network involved,
  no TCP, no port, and no DNS. Many local services (databases,
  background services, developer tools) expose an HTTP API this way
  to avoid binding a TCP port.

  This module wraps `Mint.HTTP1.connect/4` with the `{:local, path}`
  address tuple OTP uses for AF_UNIX sockets, and fills in a sensible
  HTTP `Host` header (`"localhost"`) since there is no real hostname.

  ## When you would call this module yourself

  Most callers do not. `Sorrel.Transport.connect/2` looks at an
  endpoint's `:transport` field and forwards `:unix` endpoints here
  automatically. Reach for `Sorrel.Transport.Unix.connect/2`
  directly only if you want to bypass the dispatcher (e.g. in a test or
  benchmark).

  ## What you get back

  A `Mint.HTTP1.t()` connection. Use it with `Sorrel.Conn.request/6`
  to send a request, then close it with `Mint.HTTP.close/1` when you are
  done. The same connection can serve many sequential requests as long
  as each one finishes before the next starts (HTTP/1.1, no pipelining).

  ## Examples

      # Open the connection:
      iex> ep = %Sorrel.Endpoint{transport: :unix, socket_path: "/tmp/myapp.sock"}
      iex> {:ok, conn} = Sorrel.Transport.Unix.connect(ep)

      # Send a request through it (illustrative shape; assumes a server is listening):
      iex> Sorrel.Conn.request(conn, "GET", "/ping", [], "", [])
      # => {:ok, %{status: 200, headers: [...], body: "OK"}, conn}

      # Missing socket file -> :enoent:
      iex> Sorrel.Transport.Unix.connect(
      ...>   %Sorrel.Endpoint{transport: :unix, socket_path: "/no/such/file.sock"})
      {:error, :enoent}
  """

  # What this module does:
  #   Stateless. Wraps Mint.HTTP1.connect/4 with the {:local, path}
  #   address tuple OTP uses for AF_UNIX sockets.
  #
  # Rules that always hold:
  #   1. connect/2 is only called with endpoints whose transport is :unix.

  @behaviour Sorrel.Transport

  @doc """
  Opens a connection through the Unix socket file at
  `endpoint.socket_path` and returns a `Mint.HTTP1.t()`, or returns an
  error tag on failure.

  The socket file must already exist and the current OS process must
  have permission to connect to it. Both conditions are owned by
  whichever process is *listening* on the socket - typically a
  long-running server. This function neither creates the file nor
  changes its permissions.

  ## Parameters

    * `endpoint` - `Sorrel.Endpoint.t()`. The struct's `:transport`
      field must be `:unix` and `:socket_path` must be a non-empty
      string. Anything else fails the function-clause guard.
    * `opts` - `keyword()`. Recognised keys:

      | Key                | Type                | Default     | What it does                                                  |
      | ------------------ | ------------------- | ----------- | ------------------------------------------------------------- |
      | `:connect_timeout` | `non_neg_integer()` | `10_000`     | Milliseconds to wait for the OS connect call to finish.        |
      | `:mode`            | `:passive` / `:active` | `:passive` | Underlying socket mode handed to Mint. `:passive` means data is read with explicit `recv` calls; `:active` means data arrives in the owning process's mailbox. Sorrel's higher layers expect `:passive`. |

      Unknown keys are ignored.

  ## Returns

    * `{:ok, conn}` - `conn` is a `Mint.HTTP1.t()` ready to send requests.
      Sorrel fills in `Host: localhost` as a default HTTP header on
      requests sent through this connection - Unix sockets have no real
      hostname.
    * `{:error, :enoent}` - the socket file `socket_path` does not
      exist.
    * `{:error, :eacces}` - the socket file exists but the current
      process is not allowed to connect to it (typically a permission
      issue on the file).
    * `{:error, :econnrefused}` - the socket file exists but no process
      is listening on it.
    * `{:error, :timeout}` - the connect attempt did not finish within
      `:connect_timeout` milliseconds. Rare for local sockets but
      possible if the listener is overwhelmed.
    * `{:error, %Mint.TransportError{...}}` - any other transport-layer
      error Mint surfaces.

  This function does not raise for expected failures.

  ## Examples

      # Successful connect:
      iex> ep = %Sorrel.Endpoint{transport: :unix, socket_path: "/tmp/myapp.sock"}
      iex> {:ok, _conn} = Sorrel.Transport.Unix.connect(ep, connect_timeout: 5_000)

      # Missing socket file:
      iex> Sorrel.Transport.Unix.connect(
      ...>   %Sorrel.Endpoint{transport: :unix, socket_path: "/no/such/file"})
      {:error, :enoent}
  """
  # Dialyzer warning we are suppressing here, captured from
  # `mix dialyzer` against Mint 1.7 + OTP 27:
  #
  #   Function connect/1 has no local return.
  #   Function connect/2 has no local return.
  #
  #   Mint.HTTP1.connect(:http, {:local, _}, 0, [
  #     {:hostname, <<_::72>>} | {:mode, _} | {:transport_opts, [{:timeout, _}, ...]},
  #     ...
  #   ])
  #
  #   will never return since the 2nd arguments differ
  #   from the success typing arguments:
  #
  #   (atom(), binary(), any(), Keyword.t())
  #
  # Why the warning is wrong (and the suppression is safe):
  #
  #   `Mint.HTTP1.connect/4`'s declared `@spec` accepts `Mint.Types.address()`,
  #   which expands via `:inet.socket_address()` to include the
  #   `{:local, binary() | string()}` tuple OTP uses for AF_UNIX sockets. The
  #   call succeeds at runtime - the unit tests in
  #   `test/sorrel/transport/unix_test.exs` exercise it against a
  #   real Unix socket and round-trip a request.
  #
  #   The warning comes from dialyzer's inferred *success typing* for
  #   `Mint.Core.Transport.TCP.connect/3` collapsing the address argument
  #   down to `binary()` (the binary-guard clause), even though the
  #   behaviour callback's declared spec is `Types.address()`. The narrower
  #   success typing then propagates up to `Mint.HTTP1.connect/4` and makes
  #   dialyzer believe our `{:local, path}` call cannot succeed.
  #
  # Scope: the suppression covers ONLY this function. It does not silence
  # any unrelated `:no_return` or `:call` warnings elsewhere.
  @dialyzer {:nowarn_function, connect: 1, connect: 2}

  @impl Sorrel.Transport
  @spec connect(Sorrel.Endpoint.t(), keyword()) :: {:ok, Mint.HTTP.t()} | {:error, term()}
  def connect(%Sorrel.Endpoint{transport: :unix, socket_path: path}, opts \\ []) do
    Mint.HTTP1.connect(:http, {:local, path}, 0,
      hostname: "localhost",
      mode: Keyword.get(opts, :mode, :passive),
      transport_opts: [timeout: Sorrel.Config.connect_timeout(opts)]
    )
  end
end

defmodule Sorrel.Transport.Tcp do
  @moduledoc """
  Opens an HTTP/1.1 connection to a server reachable by host and port,
  with optional plain TLS or mutual TLS.

  This is the transport you want for any HTTP server you reach over a
  network - including, in many cases, a server on the same machine that
  has chosen to bind a TCP port. The connection itself is opened by
  `Mint.HTTP1.connect/4`; this module's job is to translate a
  `Sorrel.Endpoint` struct into the right Mint arguments.

  ## When you would call this module yourself

  Most callers do not. `Sorrel.Transport.connect/2` looks at an
  endpoint's `:transport` field and forwards `:tcp` endpoints here
  automatically. Reach for `Sorrel.Transport.Tcp.connect/2`
  directly only if you want to bypass the dispatcher.

  ## Three ways the connection is opened

  The three TLS modes are picked off the endpoint, not from `connect/2`'s
  options:

    * `scheme: :http`, `tls: nil` - plain TCP. No TLS handshake.
    * `scheme: :https`, `tls: nil` - TLS handshake using the operating
      system's certificate trust store, with hostname verification
      enabled. Use this when the server's certificate is signed by a
      well-known certificate authority.
    * `scheme: :https`, `tls: %{...}` - TLS handshake using explicit
      certificate files from the `:tls` map. The map's recognised keys
      are `:verify`, `:cacertfile`, `:certfile`, and `:keyfile`. Any of
      `cacertfile`, `certfile`, `keyfile` may be `nil` - `nil` values
      are dropped before being handed to `:ssl`. Use this when the
      server presents a self-signed certificate, an internal-CA
      certificate, or requires you to present a client certificate
      (mutual TLS).

  Server Name Indication (SNI) is set to the endpoint's `:host` field for
  the explicit-TLS mode so that hostname matching against the server
  certificate's Subject Alternative Names works as expected.

  ## Examples

      # Plain HTTP, port 8080:
      iex> ep = %Sorrel.Endpoint{transport: :tcp, scheme: :http, host: "127.0.0.1", port: 8080}
      iex> {:ok, conn} = Sorrel.Transport.Tcp.connect(ep)
      iex> is_struct(conn, Mint.HTTP1)
      true

      # HTTPS with the operating system's trust store:
      iex> ep = %Sorrel.Endpoint{transport: :tcp, scheme: :https, host: "api.example.com", port: 443}
      iex> {:ok, _conn} = Sorrel.Transport.Tcp.connect(ep)

      # HTTPS with an explicit CA + client certificate (mutual TLS):
      iex> ep = %Sorrel.Endpoint{
      ...>   transport: :tcp, scheme: :https, host: "internal.example.com", port: 8443,
      ...>   tls: %{
      ...>     verify: :verify_peer,
      ...>     cacertfile: "/etc/myapp/ca.pem",
      ...>     certfile: "/etc/myapp/client.crt",
      ...>     keyfile: "/etc/myapp/client.key"
      ...>   }}
      iex> {:ok, _conn} = Sorrel.Transport.Tcp.connect(ep)
  """

  # What this module does:
  #   Stateless. Wraps Mint.HTTP1.connect/4 with scheme/host/port and
  #   translates Endpoint.tls into Mint's transport_opts. The TLS clauses
  #   build the keyword list that :ssl wants:
  #     - scheme :http               -> just a connect_timeout
  #     - scheme :https with tls=nil -> verify_peer + OS trust store
  #     - scheme :https with tls=%{} -> verify + SNI + supplied cert files
  #
  # Rules that always hold:
  #   1. connect/2 is only called with endpoints whose transport is :tcp.
  #   2. The transport_opts list returned by tls_opts/2 never carries `nil`
  #      values for ssl-only keys (cacertfile/certfile/keyfile). nil fields
  #      in endpoint.tls are dropped instead of being passed through.

  @behaviour Sorrel.Transport

  @doc """
  Opens a TCP connection to `endpoint.host` on `endpoint.port` (performing
  a TLS handshake first when the scheme is `:https`) and returns a
  `Mint.HTTP1.t()`, or returns an error tag on failure.

  ## Parameters

    * `endpoint` - `Sorrel.Endpoint.t()`. The struct's `:transport`
      must be `:tcp`. The fields used:

      | Field    | Required for         | Effect                                                   |
      | -------- | -------------------- | -------------------------------------------------------- |
      | `host`   | every call           | The hostname or IP address to connect to and SNI value.  |
      | `port`   | every call           | The TCP port (1..65535).                                  |
      | `scheme` | every call           | `:http` for plain TCP, `:https` for TLS.                  |
      | `tls`    | only when `scheme: :https` and explicit certs are needed | A map of `:verify`, `:cacertfile`, `:certfile`, `:keyfile` paths. |

    * `opts` - `keyword()`. Recognised keys:

      | Key                | Type                | Default     | What it does                                                  |
      | ------------------ | ------------------- | ----------- | ------------------------------------------------------------- |
      | `:connect_timeout` | `non_neg_integer()` | `10_000`     | Milliseconds to wait for the TCP connect *and* the TLS handshake combined. |
      | `:mode`            | `:passive` / `:active` | `:passive` | Underlying socket mode handed to Mint.                        |

      Unknown keys are ignored.

  ## Returns

    * `{:ok, conn}` - `conn` is a `Mint.HTTP1.t()` ready to send
      requests. For `:https` endpoints, the TLS handshake has completed
      before this returns.

    * `{:error, :econnrefused}` - nothing is listening on the target
      `host:port`.

    * `{:error, :nxdomain}` - DNS lookup for `host` returned no record.

    * `{:error, :timeout}` - the TCP connect or TLS handshake took longer
      than `:connect_timeout` milliseconds.

    * `{:error, {:tls_alert, alert}}` - the TLS handshake itself was
      rejected. Common eager reasons:

      | Cause                                              | Typical alert tag                  |
      | -------------------------------------------------- | ---------------------------------- |
      | Server certificate not signed by the supplied CA   | `:unknown_ca`                      |
      | Hostname does not match certificate's SAN          | `:handshake_failure`               |
      | Server certificate has expired                     | `:certificate_expired`             |
      | Server demands a client cert but none was supplied | `:certificate_required` (TLS 1.2)  |

    * `{:error, %Mint.TransportError{...}}` - anything else Mint surfaces
      from the underlying socket or TLS layer (broken pipe, reset,
      malformed handshake response, etc.).

  ## TLS 1.3 caveat

  Some mTLS failures cannot be detected at handshake time when the
  server speaks TLS 1.3, because client-certificate verification is
  post-handshake in TLS 1.3. In that case `connect/2` returns
  `{:ok, conn}` and the alert surfaces on the first `Mint.HTTP.recv/3`
  as `{:error, conn, %Mint.TransportError{reason: {:tls_alert, _}}, _}`.
  Examples:

    * The server requires a client cert but none was presented.
    * The configured `:certfile` path could not be read by `:ssl` at
      handshake time.

  Treat any `{:tls_alert, _}` from the *first* recv on a `:https`
  connection as a handshake error.

  This function does not raise for expected failures.

  ## Examples

      # Plain HTTP:
      iex> ep = %Sorrel.Endpoint{transport: :tcp, scheme: :http, host: "127.0.0.1", port: 8080}
      iex> {:ok, _conn} = Sorrel.Transport.Tcp.connect(ep)

      # HTTPS with explicit certificates (mutual TLS):
      iex> ep = %Sorrel.Endpoint{
      ...>   transport: :tcp, scheme: :https, host: "remote", port: 8443,
      ...>   tls: %{verify: :verify_peer, cacertfile: "/c/ca.pem", certfile: "/c/c.pem", keyfile: "/c/k.pem"}}
      iex> {:ok, _conn} = Sorrel.Transport.Tcp.connect(ep)

      # Connection refused:
      iex> ep = %Sorrel.Endpoint{transport: :tcp, scheme: :http, host: "127.0.0.1", port: 1}
      iex> Sorrel.Transport.Tcp.connect(ep)
      {:error, :econnrefused}
  """
  @impl Sorrel.Transport
  @spec connect(Sorrel.Endpoint.t(), keyword()) :: {:ok, Mint.HTTP.t()} | {:error, term()}
  def connect(%Sorrel.Endpoint{transport: :tcp} = ep, opts \\ []) do
    Mint.HTTP1.connect(ep.scheme, ep.host, ep.port,
      hostname: ep.host,
      mode: Keyword.get(opts, :mode, :passive),
      transport_opts: tls_opts(ep, opts)
    )
  end

  # Private. Caller-observable behaviour:
  #   - For scheme :http, returns [timeout: connect_timeout].
  #   - For scheme :https with tls=nil, returns [timeout, verify: :verify_peer,
  #     cacerts: :public_key.cacerts_get/0]. The OS trust store is consulted
  #     because the user did not supply explicit TLS material but did pick
  #     https://, which means "verify against system CAs".
  #   - For scheme :https with tls=%{}, returns [timeout, verify, sni] plus
  #     whichever of :cacertfile/:certfile/:keyfile were non-nil. SNI is
  #     required for hostname matching against the server cert's SAN.
  defp tls_opts(%Sorrel.Endpoint{scheme: :http}, opts) do
    [timeout: Sorrel.Config.connect_timeout(opts)]
  end

  defp tls_opts(%Sorrel.Endpoint{scheme: :https, tls: nil}, opts) do
    [
      timeout: Sorrel.Config.connect_timeout(opts),
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get()
    ]
  end

  defp tls_opts(%Sorrel.Endpoint{scheme: :https, tls: %{} = tls} = ep, opts) do
    base = [
      timeout: Sorrel.Config.connect_timeout(opts),
      verify: Map.get(tls, :verify) || :verify_peer,
      server_name_indication: String.to_charlist(ep.host)
    ]

    base
    |> maybe_put(:cacertfile, Map.get(tls, :cacertfile))
    |> maybe_put(:certfile, Map.get(tls, :certfile))
    |> maybe_put(:keyfile, Map.get(tls, :keyfile))
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)
end

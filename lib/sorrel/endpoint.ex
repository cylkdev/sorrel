defmodule Sorrel.Endpoint do
  @moduledoc """
  An address book entry for a single HTTP server you want to talk to.

  An endpoint is a small struct that captures everything Sorrel needs to
  open a connection: which kind of transport to use (a Unix socket file,
  a TCP host and port, or an SSH-forwarded byte stream), the address
  itself, and (for HTTPS) optional TLS certificate files. It is plain
  data - building one does not open a network connection, touch a file,
  or read an environment variable.

  Most callers do not build the struct by hand. They start from a URL
  string and call `parse/2`:

      iex> Sorrel.Endpoint.parse("unix:///tmp/myapp.sock")
      {:ok,
       %Sorrel.Endpoint{
         transport: :unix,
         socket_path: "/tmp/myapp.sock",
         scheme: nil,
         host: nil,
         port: nil,
         tls: nil
       }}

      iex> Sorrel.Endpoint.parse("https://api.example.com:8443")
      {:ok,
       %Sorrel.Endpoint{
         transport: :tcp,
         scheme: :https,
         host: "api.example.com",
         port: 8443,
         socket_path: nil,
         tls: nil
       }}

  The resulting struct is then passed as `endpoint:` to `Sorrel.request/4`,
  `Sorrel.stream/4`, `Sorrel.Transport.connect/2`, and friends.

  ## What you can do with this module

    * Parse a URL string into a struct with `parse/2`.
    * Build the struct directly when you already have the parts:

          %Sorrel.Endpoint{
            transport: :tcp,
            scheme: :https,
            host: "api.example.com",
            port: 443,
            tls: %{
              verify: :verify_peer,
              cacertfile: "/etc/ssl/certs/ca-bundle.crt",
              certfile: nil,
              keyfile: nil
            }
          }

    * Read fields off the struct to inspect where a request will go.

  ## What this module does not do

    * It does not open connections (see `Sorrel.Transport`).
    * It does not read environment variables or files. Resolving an
      endpoint from environment variables (or from a default socket
      path on disk) is the responsibility of higher-level wrappers
      built on top of Sorrel.
    * It does not load TLS certificate files from disk. The `:tls` map
      holds *paths*; the TLS handshake reads them later when the
      connection is opened.
    * It does not open SSH connections, read identity files, or contact
      ssh-agent. The `:ssh` map holds configuration only; the SSH
      transport reads files and talks to the agent later, when the
      connection is opened.

  ## Three transports, side by side

  Plain TCP, port 8080:

      %Sorrel.Endpoint{
        transport: :tcp,
        scheme: :http,
        host: "127.0.0.1",
        port: 8080,
        socket_path: nil,
        tls: nil
      }

  Unix socket file:

      %Sorrel.Endpoint{
        transport: :unix,
        socket_path: "/tmp/myapp.sock",
        scheme: nil,
        host: nil,
        port: nil,
        tls: nil
      }

  SSH-forwarded byte stream (a remote command's stdio, here). The
  struct shape itself is generic; the example below names
  `docker system dial-stdio` because that's the most common deployment,
  but any remote command that speaks HTTP/1.1 on its stdio works:

      %Sorrel.Endpoint{
        transport: :ssh,
        host: "remote.example.com",
        port: 22,
        user: "deploy",
        ssh: %{
          auth: [:agent, :identity, :password],
          identity_file: "~/.ssh/id_ed25519",
          password: nil,
          known_hosts_file: nil,
          verify: :verify_peer,
          connect_timeout: 10_000
        },
        target: {:exec, "docker system dial-stdio"},
        socket_path: nil,
        scheme: nil,
        tls: nil
      }
  """

  # What each field means:
  #   `transport` says which family of address to use:
  #     `:unix` means an AF_UNIX socket file at `socket_path`.
  #     `:tcp`  means an AF_INET host:port at `scheme`/`host`/`port`.
  #     `:ssh`  means an SSH-forwarded byte stream to `host:port` as
  #             `user`, configured by `ssh`, terminating at `target`.
  #   For `:unix`, `scheme`/`host`/`port`/`tls`/`user`/`ssh`/`target`
  #     are nil and unused.
  #   For `:tcp`, `socket_path`/`user`/`ssh`/`target` are nil; `scheme`
  #     is `:http` or `:https`; `tls` is either nil (no TLS) or a map
  #     of certificate files.
  #   For `:ssh`, `socket_path`/`scheme`/`tls` are nil; `host` is the
  #     SSH server host; `port` is the SSH server port (defaults to 22);
  #     `user` is the SSH login (required, no default); `ssh` is a map
  #     of auth and verification options; `target` is one of
  #     `{:exec, cmd}`, `{:tcp, host, port}`, `{:unix, path}` and names
  #     what is on the far side of the SSH channel.
  #   Default starting struct: %Endpoint{transport: :unix, socket_path: nil}.
  #
  # Rules that always hold:
  #   1. `transport` is `:unix`, `:tcp`, or `:ssh`.
  #   2. When `transport == :unix`: `socket_path` is a non-empty string AND
  #      `scheme`, `host`, `port`, `tls`, `user`, `ssh`, `target` are all nil.
  #   3. When `transport == :tcp`: `socket_path`, `user`, `ssh`, `target`
  #      are nil AND `scheme` is `:http` or `:https` AND `host` is a
  #      non-empty string AND `port` is between 1 and 65535.
  #   4. `tls` is non-nil only when `transport == :tcp` AND `scheme == :https`.
  #   5. When `transport == :ssh`: `socket_path`, `scheme`, `tls` are nil
  #      AND `host` is a non-empty string AND `port` is between 1 and
  #      65535 AND `user` is a non-empty string AND `ssh` is a map of
  #      auth options AND `target` is one of the three target shapes.

  @type tls :: %{
          verify: :verify_none | :verify_peer,
          cacertfile: Path.t() | nil,
          certfile: Path.t() | nil,
          keyfile: Path.t() | nil
        }

  @type ssh_auth_method :: :agent | :identity | :password

  @type ssh_options :: %{
          auth: [ssh_auth_method()],
          identity_file: Path.t() | nil,
          password: String.t() | nil,
          known_hosts_file: Path.t() | nil,
          verify: :verify_none | :verify_peer,
          connect_timeout: non_neg_integer()
        }

  @type ssh_target ::
          {:exec, iodata()}
          | {:tcp, String.t(), 1..65_535}
          | {:unix, String.t()}

  @type t :: %__MODULE__{
          transport: :unix | :tcp | :ssh,
          socket_path: Path.t() | nil,
          scheme: :http | :https | nil,
          host: String.t() | nil,
          port: 1..65_535 | nil,
          tls: tls() | nil,
          user: String.t() | nil,
          ssh: ssh_options() | nil,
          target: ssh_target() | nil
        }

  defstruct transport: :unix,
            socket_path: nil,
            scheme: nil,
            host: nil,
            port: nil,
            tls: nil,
            user: nil,
            ssh: nil,
            target: nil

  @doc """
  Turns a URL string into a `Sorrel.Endpoint` struct, or returns an
  error tag when the URL is unsupported or malformed.

  Use this when you already have a URL - for example you read it from a
  configuration file, accepted it as a command-line argument, or pulled it
  out of an environment variable yourself - and you want the struct shape
  Sorrel's request and connect functions accept.

  ## Parameters

    * `url` - `String.t()`. The URL to parse. Must include a scheme. The
      schemes this function understands:

      | Scheme prefix              | What you get back                                                                     |
      | -------------------------- | ------------------------------------------------------------------------------------- |
      | `unix:///path`             | A `:unix` endpoint pointing at the socket file at `/path`.                            |
      | `tcp://host[:p]`           | A `:tcp` endpoint with `scheme: :http`. Port defaults to **80** if not given.         |
      | `http://host[:p]`          | A `:tcp` endpoint with `scheme: :http`. Port defaults to **80** if not given.         |
      | `https://host[:p]`         | A `:tcp` endpoint with `scheme: :https`. Port defaults to **443** if not given.       |
      | `ssh://[user@]host[:p]`    | A `:ssh` endpoint. Port defaults to **22**. The URL alone is not enough - the caller must supply `target:` (and may supply `ssh:` and `:user`) via `options`. |

      The path part of `tcp://`, `http://`, `https://`, and `ssh://`
      URLs is ignored - only the authority (user, host, and port) is used.

    * `options` - `keyword()`. Optional overrides for fields that would
      otherwise be filled in from the URL (or from per-scheme defaults).
      Precedence is **options -> URL value -> defaults**: a key in `options`
      wins over the URL, the URL value wins over the per-scheme default,
      and unknown keys are ignored. Default `[]`.

      | Key            | Used by                         | Effect                                                                  |
      | -------------- | ------------------------------- | ----------------------------------------------------------------------- |
      | `:socket_path` | `unix://`                       | Overrides the path from the URL.                                        |
      | `:scheme`      | `tcp://`, `http://`, `https://` | Overrides the per-scheme default scheme.                                |
      | `:host`        | `tcp://`, `http://`, `https://` | Overrides the URL host.                                                 |
      | `:port`        | `tcp://`, `http://`, `https://` | Overrides the URL port and default port.                                |
      | `:user`        | `ssh://`                        | Overrides the URL userinfo. Required if the URL has none.               |
      | `:ssh`         | `ssh://`                        | Map of SSH options. Missing keys are filled with defaults.              |
      | `:target`      | `ssh://`                        | Required for `ssh://`. One of `{:exec, iodata}`, `{:tcp, host, port}`, `{:unix, path}`. |

  ## Returns

  On a URL that parses successfully, `{:ok, endpoint}`. The struct's fields
  are filled in like this:

    * `transport` is `:unix` for `unix://`, `:tcp` for `tcp://`, `http://`,
      and `https://`, and `:ssh` for `ssh://`.
    * `socket_path` is the URL's path for `unix://` (e.g. `"/tmp/myapp.sock"`),
      and `nil` for everything else.
    * `scheme` is `nil` for `unix://` and `ssh://`, `:http` for `tcp://`
      and `http://`, `:https` for `https://`.
    * `host` and `port` are filled in from the URL's authority for `:tcp`
      and `:ssh`, `nil` for `:unix`. The default ports are 80 (plain),
      443 (HTTPS), and 22 (SSH) - they apply only when the URL omits the port.
    * `tls` is always `nil` from this function - it never reads certificate
      files or environment variables. Callers who want TLS fill `:tls` in
      themselves before passing the struct on.
    * `user`, `ssh`, `target` are filled in for `ssh://` URLs (from the
      URL's userinfo and the matching `options` keys); they are `nil`
      for every other transport.

  On a URL that does not parse, the function returns one of:

    * `{:error, {:invalid_url, :missing_scheme}}` - the URL has no scheme
      (e.g. `"example.com"`).
    * `{:error, {:invalid_url, {:unsupported_scheme, scheme}}}` - the
      scheme is something other than `unix`, `tcp`, `http`, `https`, or
      `ssh` (e.g. `"ftp://..."` returns `{:error, {:invalid_url, {:unsupported_scheme, "ftp"}}}`).
    * `{:error, {:invalid_url, :missing_socket_path}}` - a `unix://` URL
      with no path (e.g. `"unix://"`).
    * `{:error, {:invalid_url, :missing_host}}` - a `tcp://`, `http://`,
      `https://`, or `ssh://` URL with no host.
    * `{:error, {:invalid_url, :missing_user}}` - an `ssh://` URL with
      no userinfo and no `:user` option.
    * `{:error, {:invalid_url, :missing_ssh_target}}` - an `ssh://` URL
      with no `:target` option.
    * `{:error, {:invalid_url, {:invalid_target, target}}}` - an
      `ssh://` URL whose `:target` option does not match one of the
      three accepted shapes.
    * `{:error, {:invalid_url, {:port_out_of_range, port}}}` - an explicit
      port outside the range 1..65535.
    * `{:error, {:invalid_url, reason}}` - any other parse failure, where
      `reason` is whatever Elixir's `URI.new/1` returned.

  This function never raises and never opens a connection or reads a file.

  ## Examples

      # Unix socket file:
      iex> Sorrel.Endpoint.parse("unix:///tmp/myapp.sock")
      {:ok, %Sorrel.Endpoint{transport: :unix, socket_path: "/tmp/myapp.sock"}}

      # Plain TCP with explicit port:
      iex> Sorrel.Endpoint.parse("tcp://10.0.0.1:8080")
      {:ok, %Sorrel.Endpoint{transport: :tcp, scheme: :http, host: "10.0.0.1", port: 8080}}

      # Plain TCP, no port - falls back to port 80:
      iex> Sorrel.Endpoint.parse("tcp://api.example.com")
      {:ok, %Sorrel.Endpoint{transport: :tcp, scheme: :http, host: "api.example.com", port: 80}}

      # HTTPS, no port - falls back to port 443:
      iex> Sorrel.Endpoint.parse("https://api.example.com")
      {:ok, %Sorrel.Endpoint{transport: :tcp, scheme: :https, host: "api.example.com", port: 443}}

      # Malformed URL:
      iex> match?({:error, {:invalid_url, _}}, Sorrel.Endpoint.parse("not a url"))
      true

      # Out-of-range port:
      iex> Sorrel.Endpoint.parse("tcp://h:99999")
      {:error, {:invalid_url, {:port_out_of_range, 99999}}}

      # `:port` option overrides the URL's port:
      iex> Sorrel.Endpoint.parse("tcp://h:2375", port: 9999)
      {:ok, %Sorrel.Endpoint{transport: :tcp, scheme: :http, host: "h", port: 9999}}
  """
  @spec parse(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def parse(url, options \\ [])

  def parse(url, options) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: nil}} ->
        {:error, {:invalid_url, :missing_scheme}}

      {:ok, %URI{scheme: "unix", path: path}} ->
        parse_unix(path, options)

      {:ok, %URI{scheme: "tcp", host: host, port: port}} ->
        parse_tcp(host, port, options)

      {:ok, %URI{scheme: "http", host: host, port: port}} ->
        parse_http(host, port, options)

      {:ok, %URI{scheme: "https", host: host, port: port}} ->
        parse_https(host, port, options)

      {:ok, %URI{scheme: "ssh", userinfo: userinfo, host: host, port: port}} ->
        parse_ssh(userinfo, host, port, options)

      {:ok, %URI{scheme: scheme}} ->
        {:error, {:invalid_url, {:unsupported_scheme, scheme}}}

      {:error, reason} ->
        {:error, {:invalid_url, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Internals - parse helpers
  # ---------------------------------------------------------------------------

  @spec parse_unix(String.t() | nil, keyword()) :: {:ok, t()} | {:error, term()}
  defp parse_unix(path, opts) do
    resolved = Keyword.get(opts, :socket_path) || path

    if is_binary(resolved) and resolved !== "" do
      {:ok, %__MODULE__{transport: :unix, socket_path: resolved}}
    else
      {:error, {:invalid_url, :missing_socket_path}}
    end
  end

  @spec parse_tcp(String.t() | nil, 1..65_535 | nil, keyword()) :: {:ok, t()} | {:error, term()}
  defp parse_tcp(host, port, opts) do
    scheme = Keyword.get(opts, :scheme) || :http
    host = Keyword.get(opts, :host) || host
    port = Keyword.get(opts, :port) || port || 80
    build_tcp_endpoint(scheme, host, port)
  end

  @spec parse_http(String.t() | nil, 1..65_535 | nil, keyword()) :: {:ok, t()} | {:error, term()}
  defp parse_http(host, port, opts) do
    scheme = Keyword.get(opts, :scheme) || :http
    host = Keyword.get(opts, :host) || host
    port = Keyword.get(opts, :port) || port || 80
    build_tcp_endpoint(scheme, host, port)
  end

  @spec parse_https(String.t() | nil, 1..65_535 | nil, keyword()) ::
          {:ok, t()} | {:error, term()}
  defp parse_https(host, port, opts) do
    scheme = Keyword.get(opts, :scheme) || :https
    host = Keyword.get(opts, :host) || host
    port = Keyword.get(opts, :port) || port || 443
    build_tcp_endpoint(scheme, host, port)
  end

  @spec build_tcp_endpoint(:http | :https, String.t() | nil, integer() | nil) ::
          {:ok, t()} | {:error, term()}
  defp build_tcp_endpoint(scheme, host, port) do
    cond do
      not is_binary(host) or host === "" ->
        {:error, {:invalid_url, :missing_host}}

      not is_integer(port) or port < 1 or port > 65_535 ->
        {:error, {:invalid_url, {:port_out_of_range, port}}}

      true ->
        {:ok, %__MODULE__{transport: :tcp, scheme: scheme, host: host, port: port}}
    end
  end

  @spec parse_ssh(String.t() | nil, String.t() | nil, 1..65_535 | nil, keyword()) ::
          {:ok, t()} | {:error, term()}
  defp parse_ssh(userinfo, host, port, opts) do
    with {:ok, host} <- resolve_ssh_host(host),
         {:ok, port} <- resolve_ssh_port(port, opts),
         {:ok, user} <- resolve_ssh_user(userinfo, opts),
         {:ok, target} <- resolve_ssh_target(opts),
         {:ok, ssh} <- build_ssh_options(Keyword.get(opts, :ssh, %{})) do
      {:ok,
       %__MODULE__{
         transport: :ssh,
         host: host,
         port: port,
         user: user,
         ssh: ssh,
         target: target
       }}
    end
  end

  defp resolve_ssh_host(host) do
    if is_binary(host) and host !== "" do
      {:ok, host}
    else
      {:error, {:invalid_url, :missing_host}}
    end
  end

  defp resolve_ssh_port(port, opts) do
    case opts[:port] || port do
      nil -> {:ok, 22}
      port when is_integer(port) and port >= 1 and port <= 65_535 -> {:ok, port}
      port -> {:error, {:invalid_url, {:port_out_of_range, port}}}
    end
  end

  defp resolve_ssh_user(userinfo, opts) do
    case {opts[:user], userinfo} do
      {override, _} when is_binary(override) and override !== "" ->
        {:ok, override}

      {_, userinfo} when is_binary(userinfo) and userinfo !== "" ->
        case String.split(userinfo, ":", parts: 2) do
          [user | _] when user !== "" -> {:ok, user}
          _ -> {:error, {:invalid_url, :missing_user}}
        end

      {_, _} ->
        {:error, {:invalid_url, :missing_user}}
    end
  end

  defp resolve_ssh_target(opts) do
    case Keyword.fetch(opts, :target) do
      :error ->
        {:error, {:invalid_url, :missing_ssh_target}}

      {:ok, target} ->
        validate_ssh_target(target)
    end
  end

  defp validate_ssh_target({:exec, cmd}) do
    if iodata?(cmd) do
      {:ok, {:exec, cmd}}
    else
      {:error, {:invalid_url, {:invalid_target, {:exec, cmd}}}}
    end
  end

  defp validate_ssh_target({:tcp, host, port})
       when is_binary(host) and host !== "" and is_integer(port) and port >= 1 and port <= 65_535 do
    {:ok, {:tcp, host, port}}
  end

  defp validate_ssh_target({:unix, path}) when is_binary(path) and path !== "" do
    {:ok, {:unix, path}}
  end

  defp validate_ssh_target(term) do
    {:error, {:invalid_url, {:invalid_target, term}}}
  end

  @spec build_ssh_options(map()) :: {:ok, ssh_options()} | {:error, term()}
  defp build_ssh_options(ssh) when is_map(ssh) do
    auth = resolve_ssh_auth(ssh)

    case validate_ssh_auth(auth) do
      :ok ->
        {:ok,
         %{
           auth: auth,
           identity_file: Map.get(ssh, :identity_file),
           password: Map.get(ssh, :password),
           known_hosts_file: Map.get(ssh, :known_hosts_file),
           verify: resolve_ssh_verify(ssh),
           connect_timeout:
             Map.get(ssh, :connect_timeout) || Sorrel.Config.ssh_connect_timeout([])
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_ssh_options(_),
    do:
      {:ok,
       %{
         auth: resolve_ssh_auth(%{}),
         identity_file: nil,
         password: nil,
         known_hosts_file: nil,
         verify: resolve_ssh_verify(%{}),
         connect_timeout: Sorrel.Config.ssh_connect_timeout([])
       }}

  defp resolve_ssh_auth(ssh) do
    Map.get(ssh, :auth) || Sorrel.Config.ssh_auth() ||
      raise ArgumentError,
            "Sorrel SSH auth methods are not configured. " <>
              "Set `config :sorrel, ssh_auth: [:agent, :identity, :password]` " <>
              "(or pass `auth:` in the SSH options for this endpoint)."
  end

  defp resolve_ssh_verify(ssh) do
    Map.get(ssh, :verify) || Sorrel.Config.ssh_verify() ||
      raise ArgumentError,
            "Sorrel SSH host-key verification mode is not configured. " <>
              "Set `config :sorrel, ssh_verify: :verify_peer` " <>
              "(or pass `verify:` in the SSH options for this endpoint)."
  end

  @spec validate_ssh_auth(term()) :: :ok | {:error, term()}
  defp validate_ssh_auth(methods) when is_list(methods) do
    case Enum.find(methods, fn method -> method not in [:agent, :identity, :password] end) do
      nil -> :ok
      bad -> {:error, {:invalid_url, {:invalid_ssh_auth, bad}}}
    end
  end

  defp validate_ssh_auth(other), do: {:error, {:invalid_url, {:invalid_ssh_auth, other}}}

  @spec iodata?(term()) :: boolean()
  defp iodata?(value) when is_binary(value), do: true

  defp iodata?(value) when is_list(value) do
    _ = :erlang.iolist_size(value)
    true
  rescue
    ArgumentError -> false
  end

  defp iodata?(_), do: false
end

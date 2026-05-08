defmodule Sorrel.Transport.SSH.Auth do
  @moduledoc """
  Translates a `Sorrel.Endpoint` SSH variant into the keyword
  list of options OTP's `:ssh.connect/3` expects.

  This module is **pure**. It does not open files, read environment
  variables, or contact ssh-agent. Every option emitted is computed
  directly from the endpoint struct. The actual disk reads (identity
  files, `known_hosts`) and agent contact happen later, inside
  `:ssh.connect/3`, when a connection is opened.

  Keeping the option-builder pure means the SSH transport can be
  unit-tested without standing up an SSH server, without touching the
  filesystem, and without leaking secrets into test fixtures.

  ## When you would call this module yourself

  You would not, normally. `Sorrel.Transport.SSH.connect/2` calls
  `options/1` for you. Reach for it directly only when you want to
  inspect the exact option list - typically in tests, or when
  debugging an `:ssh.connect/3` rejection.

  ## Mapping at a glance

  | Endpoint field                  | Option key                                         | Notes                                               |
  | ------------------------------- | -------------------------------------------------- | --------------------------------------------------- |
  | `endpoint.user`                 | `user: charlist`                                   | Always emitted.                                     |
  | `endpoint.ssh.auth`             | `auth_methods: charlist`                           | `:agent` and `:identity` both map to `'publickey'`. Method names are deduplicated. Empty list omits the key entirely. |
  | `endpoint.ssh.identity_file`    | `key_cb: {:ssh_file, []}` plus `user_dir: charlist` | The default `:ssh_file` callback only locates keys by directory. The transport points `user_dir` at `Path.dirname/1` of the identity file. (See "Identity file limitation" below.) |
  | `endpoint.ssh.known_hosts_file` | `user_dir: charlist`                               | Set to `Path.dirname/1` of the file. Honoured only when `verify == :verify_peer`. |
  | `endpoint.ssh.password`         | `password: charlist`                               | Emitted only when non-`nil`.                        |
  | `endpoint.ssh.verify`           | `silently_accept_hosts`, `user_interaction`        | `:verify_peer` -> strict; `:verify_none` -> accept any host key, no interactive prompts. |
  | `endpoint.ssh.connect_timeout`  | `connect_timeout: integer`                         | Pass-through, in milliseconds.                      |

  The endpoint's `host`/`port` are **not** part of the keyword list -
  they are positional arguments to `:ssh.connect/3`.

  ## Verify mode in detail

  | `verify`        | Emitted options                                                    |
  | --------------- | ------------------------------------------------------------------ |
  | `:verify_peer`  | `silently_accept_hosts: false`, `user_interaction: false`, `key_cb: {:ssh_file, []}`. If `known_hosts_file` is set, also `user_dir: <Path.dirname/1>`. With both `silently_accept_hosts: false` and `user_interaction: false`, OTP fails the connection when the host key is not in `known_hosts`, rather than prompting on stdin. |
  | `:verify_none`  | `silently_accept_hosts: true`, `user_interaction: false`. `user_dir` is **not** set in this mode - there is nothing to verify against. |

  `key_cb: {:ssh_file, []}` is the OTP default, but emitted explicitly
  so that `silently_accept_hosts: false` always pairs with a callback
  that can read a `known_hosts` file out of `user_dir`.

  ## Identity file limitation

  The default OTP `:ssh_file` callback locates identity files by
  scanning a directory (`user_dir`) for known names: `id_rsa`,
  `id_ecdsa`, `id_ed25519`, etc. There is no documented option to
  point it at an arbitrary file path.

  When `endpoint.ssh.identity_file` is set, this module sets
  `user_dir` to the directory containing that file. If the file is
  named one of the OTP-recognised names, OTP will pick it up. If it
  is named something else (e.g. `id_deploy`), OTP will not. We do
  **not** copy or rename the user's file - that would surprise them
  and is outside this module's pure-function contract. A future
  iteration could provide a custom `key_cb` that knows how to read a
  named file directly.

  When **both** `identity_file` and `known_hosts_file` are set and
  they live in different directories, `user_dir` is set to the
  parent of the `known_hosts_file` (host-key verification wins;
  the identity file should be reachable through ssh-agent or named
  conventionally in that directory).

  ## ssh-agent

  OTP's `:ssh` enables agent authentication automatically when
  `'publickey'` is among the requested auth methods and
  `SSH_AUTH_SOCK` is set in the environment. We emit nothing extra
  for this - picking up the agent is OTP's job. This module does
  **not** read `SSH_AUTH_SOCK` itself.

  ## OTP version requirement

  The option keys this module emits are stable across OTP 26 and OTP
  27. Anything older has not been validated. The project currently
  pins Elixir `~> 1.18`, which requires OTP 26 or newer.
  """

  # What this module does:
  #   Stateless, pure. Walks an Endpoint with `transport: :ssh` and
  #   produces a keyword list of options for `:ssh.connect/3`.
  #
  # Rules that always hold:
  #   1. `options/1` is only called with endpoints whose transport is
  #      `:ssh`. The function clause guards on this - passing any other
  #      transport raises `FunctionClauseError`.
  #   2. The returned keyword list never contains `nil` values. Optional
  #      keys (`password`, `auth_methods`, `user_dir`, ...) are simply
  #      omitted when their corresponding endpoint field is nil/empty.
  #   3. The `user` key is always present.
  #   4. The keyword list never carries the SSH server `host` or `port`
  #      - those are positional arguments to `:ssh.connect/3`.
  #   5. No filesystem read, no environment read, no network call.

  alias Sorrel.Endpoint

  @doc """
  Returns the `:ssh.connect/3` options keyword list for the given
  endpoint.

  ## Parameters

    * `endpoint` - `Sorrel.Endpoint.t()`. Must have
      `transport: :ssh` and a non-nil `:ssh` map. Anything else fails
      the function-clause guard with `FunctionClauseError`.

  ## Returns

  A `keyword()` list suitable for passing as the third argument to
  `:ssh.connect/3`. The keys that may appear, in the order they are
  emitted:

  | Key                       | When emitted                                              |
  | ------------------------- | --------------------------------------------------------- |
  | `:user`                   | Always.                                                   |
  | `:auth_methods`           | When `endpoint.ssh.auth` is a non-empty list.             |
  | `:password`               | When `endpoint.ssh.password` is a non-empty binary.       |
  | `:silently_accept_hosts`  | Always (its value depends on `:verify`).                  |
  | `:user_interaction`       | Always - `false` in both `:verify_peer` and `:verify_none` modes (see "Verify mode in detail" above). |
  | `:key_cb`                 | When `verify == :verify_peer`.                            |
  | `:user_dir`               | When `verify == :verify_peer` AND a directory was derived from `identity_file` or `known_hosts_file`. |
  | `:connect_timeout`        | Always.                                                   |

  Pure: this function performs no I/O.

  ## Examples

      iex> ep = %Sorrel.Endpoint{
      ...>   transport: :ssh, host: "h", port: 22, user: "u",
      ...>   ssh: %{auth: [:agent, :password], identity_file: nil, password: "secret",
      ...>          known_hosts_file: nil, verify: :verify_none, connect_timeout: 5_000},
      ...>   target: {:exec, "/bin/cat"}}
      iex> opts = Sorrel.Transport.SSH.Auth.options(ep)
      iex> Keyword.fetch!(opts, :user)
      ~c"u"
      iex> Keyword.fetch!(opts, :auth_methods)
      ~c"publickey,password"
      iex> Keyword.fetch!(opts, :password)
      ~c"secret"
      iex> Keyword.fetch!(opts, :silently_accept_hosts)
      true
  """
  @spec options(Endpoint.t()) :: keyword()
  def options(%Endpoint{transport: :ssh, ssh: %{} = ssh, user: user} = _endpoint)
      when is_binary(user) do
    []
    |> put_user(user)
    |> put_auth_methods(Map.get(ssh, :auth, []))
    |> put_password(Map.get(ssh, :password))
    |> put_verify(
      Map.get(ssh, :verify, :verify_peer),
      Map.get(ssh, :identity_file),
      Map.get(ssh, :known_hosts_file)
    )
    |> put_connect_timeout(Map.fetch!(ssh, :connect_timeout))
  end

  # ---------------------------------------------------------------------------
  # Private builders
  # ---------------------------------------------------------------------------

  @spec put_user(keyword(), String.t()) :: keyword()
  defp put_user(opts, user), do: opts ++ [user: String.to_charlist(user)]

  # Empty `auth` list -> omit `auth_methods`, letting OTP fall back to its
  # default ordering.
  @spec put_auth_methods(keyword(), [Endpoint.ssh_auth_method()]) :: keyword()
  defp put_auth_methods(opts, []), do: opts

  defp put_auth_methods(opts, methods) when is_list(methods) do
    encoded =
      methods
      |> Enum.map(&encode_auth_method/1)
      |> Enum.uniq()
      |> Enum.intersperse(?,)
      |> List.flatten()

    opts ++ [auth_methods: encoded]
  end

  @spec encode_auth_method(Endpoint.ssh_auth_method()) :: charlist()
  defp encode_auth_method(:agent), do: ~c"publickey"
  defp encode_auth_method(:identity), do: ~c"publickey"
  defp encode_auth_method(:password), do: ~c"password"

  @spec put_password(keyword(), String.t() | nil) :: keyword()
  defp put_password(opts, nil), do: opts
  defp put_password(opts, ""), do: opts

  defp put_password(opts, password) when is_binary(password) do
    opts ++ [password: String.to_charlist(password)]
  end

  # `:verify_peer` keeps the strict OTP defaults but pairs them with an
  # explicit `key_cb` and (when supplied) a `user_dir` derived from the
  # known-hosts or identity-file paths. `known_hosts_file` wins over
  # `identity_file` when both are set and live in different directories
  # - host-key verification is the more security-critical concern.
  @spec put_verify(keyword(), :verify_peer | :verify_none, String.t() | nil, String.t() | nil) ::
          keyword()
  defp put_verify(opts, :verify_peer, identity_file, known_hosts_file) do
    base =
      opts ++
        [silently_accept_hosts: false, user_interaction: false, key_cb: {:ssh_file, []}]

    put_user_dir(base, known_hosts_file, identity_file)
  end

  defp put_verify(opts, :verify_none, _identity_file, _known_hosts_file) do
    opts ++ [silently_accept_hosts: true, user_interaction: false]
  end

  @spec put_user_dir(keyword(), String.t() | nil, String.t() | nil) :: keyword()
  defp put_user_dir(opts, nil, nil), do: opts

  defp put_user_dir(opts, known_hosts_file, _identity_file)
       when is_binary(known_hosts_file) do
    opts ++ [user_dir: known_hosts_file |> Path.dirname() |> String.to_charlist()]
  end

  defp put_user_dir(opts, nil, identity_file) when is_binary(identity_file) do
    opts ++ [user_dir: identity_file |> Path.dirname() |> String.to_charlist()]
  end

  @spec put_connect_timeout(keyword(), non_neg_integer()) :: keyword()
  defp put_connect_timeout(opts, timeout) when is_integer(timeout) and timeout >= 0 do
    opts ++ [connect_timeout: timeout]
  end
end

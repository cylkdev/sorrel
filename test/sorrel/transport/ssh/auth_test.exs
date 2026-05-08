defmodule Sorrel.Transport.SSH.AuthTest do
  use ExUnit.Case, async: true

  alias Sorrel.Endpoint
  alias Sorrel.Transport.SSH.Auth

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp endpoint(ssh_overrides) do
    ssh =
      Map.merge(
        %{
          auth: [:agent, :identity, :password],
          identity_file: nil,
          password: nil,
          known_hosts_file: nil,
          verify: :verify_peer,
          connect_timeout: 10_000
        },
        ssh_overrides
      )

    %Endpoint{
      transport: :ssh,
      host: "remote.example.com",
      port: 22,
      user: "deploy",
      ssh: ssh,
      target: {:exec, "/bin/cat"}
    }
  end

  defp options(ssh_overrides \\ %{}) do
    ssh_overrides |> endpoint() |> Auth.options()
  end

  # Verbose because the type checker likes it, not because we need it:
  # `endpoint/1` is invoked indirectly through `options/1`, so its arg
  # never carries a default value at the call sites.

  # ---------------------------------------------------------------------------
  # `:user`
  # ---------------------------------------------------------------------------

  describe "user" do
    test "is always present, encoded as a charlist" do
      assert Keyword.fetch!(options(), :user) === ~c"deploy"
    end
  end

  # ---------------------------------------------------------------------------
  # `:auth_methods`
  # ---------------------------------------------------------------------------

  describe "auth_methods" do
    test "default endpoint maps [:agent, :identity, :password] to 'publickey,password'" do
      assert Keyword.fetch!(options(), :auth_methods) === ~c"publickey,password"
    end

    test "[:agent, :password] becomes 'publickey,password'" do
      opts = options(%{auth: [:agent, :password]})
      assert Keyword.fetch!(opts, :auth_methods) === ~c"publickey,password"
    end

    test "[:agent, :identity] dedupes to 'publickey'" do
      opts = options(%{auth: [:agent, :identity]})
      assert Keyword.fetch!(opts, :auth_methods) === ~c"publickey"
    end

    test "single :password method becomes 'password'" do
      opts = options(%{auth: [:password]})
      assert Keyword.fetch!(opts, :auth_methods) === ~c"password"
    end

    test "preserves user-supplied order" do
      opts = options(%{auth: [:password, :agent]})
      assert Keyword.fetch!(opts, :auth_methods) === ~c"password,publickey"
    end

    test "empty auth list omits the :auth_methods key entirely" do
      opts = options(%{auth: []})
      refute Keyword.has_key?(opts, :auth_methods)
    end
  end

  # ---------------------------------------------------------------------------
  # `:password`
  # ---------------------------------------------------------------------------

  describe "password" do
    test "set password becomes a charlist option" do
      opts = options(%{password: "s3cret"})
      assert Keyword.fetch!(opts, :password) === ~c"s3cret"
    end

    test "nil password omits the :password key" do
      opts = options(%{password: nil})
      refute Keyword.has_key?(opts, :password)
    end

    test "empty-string password omits the :password key" do
      opts = options(%{password: ""})
      refute Keyword.has_key?(opts, :password)
    end
  end

  # ---------------------------------------------------------------------------
  # `:verify`
  # ---------------------------------------------------------------------------

  describe "verify: :verify_peer" do
    test "sets silently_accept_hosts: false" do
      opts = options(%{verify: :verify_peer})
      assert Keyword.fetch!(opts, :silently_accept_hosts) === false
    end

    test "sets key_cb to the OTP default {:ssh_file, []}" do
      opts = options(%{verify: :verify_peer})
      assert Keyword.fetch!(opts, :key_cb) === {:ssh_file, []}
    end

    test "sets user_interaction: false to prevent stdin prompts on unknown hosts" do
      opts = options(%{verify: :verify_peer})
      assert Keyword.fetch!(opts, :user_interaction) === false
    end
  end

  describe "verify: :verify_none" do
    test "sets silently_accept_hosts: true" do
      opts = options(%{verify: :verify_none})
      assert Keyword.fetch!(opts, :silently_accept_hosts) === true
    end

    test "sets user_interaction: false" do
      opts = options(%{verify: :verify_none})
      assert Keyword.fetch!(opts, :user_interaction) === false
    end

    test "does not set key_cb" do
      opts = options(%{verify: :verify_none})
      refute Keyword.has_key?(opts, :key_cb)
    end

    test "does not set user_dir even when known_hosts_file is supplied" do
      opts = options(%{verify: :verify_none, known_hosts_file: "/x/known_hosts"})
      refute Keyword.has_key?(opts, :user_dir)
    end
  end

  # ---------------------------------------------------------------------------
  # `:user_dir`
  # ---------------------------------------------------------------------------

  describe "user_dir" do
    test "known_hosts_file '/x/known_hosts' produces user_dir '/x' as a charlist" do
      opts = options(%{known_hosts_file: "/x/known_hosts"})
      assert Keyword.fetch!(opts, :user_dir) === ~c"/x"
    end

    test "identity_file alone produces user_dir from its parent directory" do
      opts = options(%{identity_file: "/home/me/.ssh/id_ed25519"})
      assert Keyword.fetch!(opts, :user_dir) === ~c"/home/me/.ssh"
    end

    test "known_hosts_file wins over identity_file when both are set" do
      opts =
        options(%{
          identity_file: "/home/me/.ssh/id_ed25519",
          known_hosts_file: "/etc/ssh/ssh_known_hosts"
        })

      assert Keyword.fetch!(opts, :user_dir) === ~c"/etc/ssh"
    end

    test "neither file → no user_dir key" do
      refute Keyword.has_key?(options(), :user_dir)
    end
  end

  # ---------------------------------------------------------------------------
  # `:connect_timeout`
  # ---------------------------------------------------------------------------

  describe "connect_timeout" do
    test "propagates verbatim from the endpoint" do
      opts = options(%{connect_timeout: 5_000})
      assert Keyword.fetch!(opts, :connect_timeout) === 5_000
    end

    test "default endpoint timeout is 10_000 ms" do
      assert Keyword.fetch!(options(), :connect_timeout) === 10_000
    end
  end

  # ---------------------------------------------------------------------------
  # Guards / shape
  # ---------------------------------------------------------------------------

  describe "shape" do
    test "host and port are not part of the option list" do
      opts = options()
      refute Keyword.has_key?(opts, :host)
      refute Keyword.has_key?(opts, :port)
    end

    test "no nil values appear in the keyword list" do
      refute Enum.any?(options(), fn {_k, v} -> is_nil(v) end)
    end

    # The negative tests below funnel the call through a runtime-resolved
    # MFA so Elixir 1.18's compile-time type checker does not flag the
    # deliberately mistyped struct shapes. The runtime semantics
    # (function-clause failure) are unchanged.

    test "endpoint with ssh: nil raises FunctionClauseError" do
      ep = %Endpoint{
        transport: :ssh,
        host: "remote",
        port: 22,
        user: "deploy",
        ssh: nil,
        target: {:exec, "/bin/cat"}
      }

      assert_raise FunctionClauseError, fn -> call_options(ep) end
    end

    test "non-:ssh endpoint raises FunctionClauseError" do
      ep = %Endpoint{transport: :tcp, scheme: :http, host: "h", port: 80}
      assert_raise FunctionClauseError, fn -> call_options(ep) end
    end

    test "endpoint with nil user raises FunctionClauseError" do
      ep = %Endpoint{
        transport: :ssh,
        host: "remote",
        port: 22,
        user: nil,
        ssh: %{
          auth: [],
          identity_file: nil,
          password: nil,
          known_hosts_file: nil,
          verify: :verify_peer,
          connect_timeout: 1_000
        },
        target: {:exec, "/bin/cat"}
      }

      assert_raise FunctionClauseError, fn -> call_options(ep) end
    end
  end

  # ---------------------------------------------------------------------------
  # Combined / smoke
  # ---------------------------------------------------------------------------

  describe "combined" do
    test "verify_peer + identity_file + password + agent produces every expected key" do
      opts =
        options(%{
          auth: [:agent, :identity, :password],
          identity_file: "/home/me/.ssh/id_ed25519",
          password: "hunter2",
          known_hosts_file: "/home/me/.ssh/known_hosts",
          verify: :verify_peer,
          connect_timeout: 7_500
        })

      assert Keyword.fetch!(opts, :user) === ~c"deploy"
      assert Keyword.fetch!(opts, :auth_methods) === ~c"publickey,password"
      assert Keyword.fetch!(opts, :password) === ~c"hunter2"
      assert Keyword.fetch!(opts, :silently_accept_hosts) === false
      assert Keyword.fetch!(opts, :key_cb) === {:ssh_file, []}
      assert Keyword.fetch!(opts, :user_dir) === ~c"/home/me/.ssh"
      assert Keyword.fetch!(opts, :connect_timeout) === 7_500
    end
  end

  # Runtime-MFA indirection: lets the negative tests pass shapes the
  # compile-time type checker would otherwise flag.
  defp call_options(endpoint) do
    Module.concat([Auth]).options(endpoint)
  end
end

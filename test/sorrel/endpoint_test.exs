defmodule Sorrel.EndpointTest do
  use ExUnit.Case, async: true

  alias Sorrel.Endpoint

  # ===========================================================================
  # parse/2
  # ===========================================================================

  describe "parse/2" do
    test "parses a unix:// URL with a path" do
      assert {:ok, ep} = Endpoint.parse("unix:///var/run/docker.sock")
      assert ep.transport === :unix
      assert ep.socket_path === "/var/run/docker.sock"
      assert ep.scheme === nil
      assert ep.host === nil
      assert ep.port === nil
      assert ep.tls === nil
    end

    test "parses a tcp:// URL with explicit port" do
      assert {:ok, ep} = Endpoint.parse("tcp://10.0.0.1:2375")
      assert ep.transport === :tcp
      assert ep.scheme === :http
      assert ep.host === "10.0.0.1"
      assert ep.port === 2375
      assert ep.tls === nil
    end

    test "defaults port to 80 for a tcp:// URL with no port" do
      assert {:ok, ep} = Endpoint.parse("tcp://api.example.com")
      assert ep.scheme === :http
      assert ep.port === 80
    end

    test "defaults port to 443 for an https:// URL with no port" do
      assert {:ok, ep} = Endpoint.parse("https://api.example.com")
      assert ep.transport === :tcp
      assert ep.scheme === :https
      assert ep.port === 443
      assert ep.tls === nil
    end

    test "rejects a malformed URL" do
      assert {:error, {:invalid_url, _}} = Endpoint.parse("not a url")
    end

    test "rejects a URL with an unsupported scheme" do
      assert {:error, {:invalid_url, _}} = Endpoint.parse("ftp://server/foo")
    end

    test "rejects a tcp:// URL with no host" do
      assert {:error, {:invalid_url, _}} = Endpoint.parse("tcp:///path")
    end

    test "rejects a URL with an out-of-range port" do
      assert {:error, {:invalid_url, _}} = Endpoint.parse("tcp://h:99999")
    end

    test "parse never opens a connection or reads env vars (smoke check)" do
      # parse/2 is purely string → struct. Setting DOCKER_HOST must not
      # change the parsed result for an unrelated URL.
      System.put_env("DOCKER_HOST", "tcp://other:1111")

      try do
        assert {:ok, ep} = Endpoint.parse("tcp://h:2375")
        assert ep.host === "h"
        assert ep.port === 2375
      after
        System.delete_env("DOCKER_HOST")
      end
    end

    test "ignores the second options argument (reserved for future use)" do
      assert {:ok, ep1} = Endpoint.parse("tcp://h:2375")
      assert {:ok, ep2} = Endpoint.parse("tcp://h:2375", some_unknown_key: :ignored)
      assert ep1 === ep2
    end

    test "parsed struct has no :version field" do
      assert {:ok, ep} = Endpoint.parse("tcp://h:2375")
      refute Map.has_key?(ep, :version)
    end
  end

  # ===========================================================================
  # parse/2 options
  # ===========================================================================

  describe "parse/2 options" do
    test ":port option overrides an explicit URL port" do
      assert {:ok, ep} = Endpoint.parse("tcp://h:2375", port: 9999)
      assert ep.port === 9999
    end

    test ":port option supplies a port when the URL has none" do
      assert {:ok, ep} = Endpoint.parse("tcp://h", port: 9999)
      assert ep.port === 9999
    end

    test ":scheme option overrides the per-scheme default" do
      assert {:ok, ep} = Endpoint.parse("tcp://h", scheme: :https)
      assert ep.scheme === :https
    end

    test ":host option overrides the URL host" do
      assert {:ok, ep} = Endpoint.parse("https://h", host: "other.example")
      assert ep.host === "other.example"
    end

    test ":socket_path option overrides the unix:// path" do
      assert {:ok, ep} = Endpoint.parse("unix:///a", socket_path: "/b")
      assert ep.socket_path === "/b"
    end

    test "an out-of-range :port option fails validation" do
      assert Endpoint.parse("https://h", port: 99_999) ===
               {:error, {:invalid_url, {:port_out_of_range, 99_999}}}
    end
  end

  # ===========================================================================
  # parse/2 — ssh:// URLs
  # ===========================================================================

  describe "parse/2 ssh:// URLs" do
    test "parses ssh://user@host with target option (port defaults to 22, ssh defaults filled in)" do
      assert {:ok, ep} =
               Endpoint.parse("ssh://deploy@remote.example.com",
                 target: {:exec, "docker system dial-stdio"}
               )

      assert ep.transport === :ssh
      assert ep.host === "remote.example.com"
      assert ep.port === 22
      assert ep.user === "deploy"
      assert ep.target === {:exec, "docker system dial-stdio"}
      assert ep.socket_path === nil
      assert ep.scheme === nil
      assert ep.tls === nil

      assert ep.ssh === %{
               auth: [:agent, :identity, :password],
               identity_file: nil,
               password: nil,
               known_hosts_file: nil,
               verify: :verify_peer,
               connect_timeout: 10_000
             }
    end

    test "parses ssh://user@host:port with explicit port and full ssh options" do
      ssh_opts = %{
        auth: [:identity, :password],
        identity_file: "~/.ssh/id_ed25519",
        password: "hunter2",
        known_hosts_file: "/etc/ssh/known_hosts",
        verify: :verify_none,
        connect_timeout: 5_000
      }

      assert {:ok, ep} =
               Endpoint.parse("ssh://deploy@remote.example.com:2222",
                 target: {:tcp, "127.0.0.1", 2375},
                 ssh: ssh_opts
               )

      assert ep.transport === :ssh
      assert ep.host === "remote.example.com"
      assert ep.port === 2222
      assert ep.user === "deploy"
      assert ep.target === {:tcp, "127.0.0.1", 2375}
      assert ep.ssh === ssh_opts
    end

    test "rejects ssh:// URL with no userinfo and no :user option" do
      assert Endpoint.parse("ssh://remote.example.com",
               target: {:exec, "true"}
             ) === {:error, {:invalid_url, :missing_user}}
    end

    test "rejects ssh:// URL with no host" do
      assert {:error, {:invalid_url, :missing_host}} =
               Endpoint.parse("ssh://user@", target: {:exec, "true"})
    end

    test "rejects ssh:// URL with no :target option" do
      assert Endpoint.parse("ssh://deploy@remote.example.com") ===
               {:error, {:invalid_url, :missing_ssh_target}}
    end

    test "parses target {:exec, cmd}" do
      assert {:ok, ep} =
               Endpoint.parse("ssh://deploy@host", target: {:exec, "docker system dial-stdio"})

      assert ep.target === {:exec, "docker system dial-stdio"}
    end

    test "parses target {:tcp, host, port}" do
      assert {:ok, ep} =
               Endpoint.parse("ssh://deploy@host", target: {:tcp, "10.0.0.1", 2375})

      assert ep.target === {:tcp, "10.0.0.1", 2375}
    end

    test "parses target {:unix, path}" do
      assert {:ok, ep} =
               Endpoint.parse("ssh://deploy@host", target: {:unix, "/var/run/docker.sock"})

      assert ep.target === {:unix, "/var/run/docker.sock"}
    end

    test "rejects an invalid target shape" do
      bad_target = {:weird, "thing"}

      assert Endpoint.parse("ssh://deploy@host", target: bad_target) ===
               {:error, {:invalid_url, {:invalid_target, bad_target}}}
    end

    test "rejects a {:tcp, _, _} target with an out-of-range port" do
      bad_target = {:tcp, "host", 99_999}

      assert Endpoint.parse("ssh://deploy@host", target: bad_target) ===
               {:error, {:invalid_url, {:invalid_target, bad_target}}}
    end

    test ":user option overrides the URL userinfo" do
      assert {:ok, ep} =
               Endpoint.parse("ssh://deploy@host",
                 user: "override",
                 target: {:exec, "true"}
               )

      assert ep.user === "override"
    end

    test "user:password userinfo extracts only the user part" do
      assert {:ok, ep} =
               Endpoint.parse("ssh://deploy:secret@host", target: {:exec, "true"})

      assert ep.user === "deploy"
    end
  end
end

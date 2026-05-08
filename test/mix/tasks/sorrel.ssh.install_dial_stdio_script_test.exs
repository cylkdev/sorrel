defmodule Mix.Tasks.Sorrel.SSH.InstallDialStdioScriptTest do
  use ExUnit.Case

  alias Mix.Tasks.Sorrel.SSH.InstallDialStdioScript
  alias Sorrel.Transport.SSH.DockerDialStdio

  describe "argv parsing" do
    test "missing USER_AT_HOST argument raises Mix error with usage hint" do
      assert_raise Mix.Error, ~r/USER_AT_HOST/, fn ->
        InstallDialStdioScript.run([])
      end
    end
  end

  describe "build_plan/5 - default remote path" do
    test "uses default remote path when no override is given" do
      default = DockerDialStdio.default_remote_path()
      local = DockerDialStdio.local_path()

      plan = InstallDialStdioScript.build_plan(local, "user@host", default, nil, nil)

      assert [
               {:scp, "scp", scp_args, :no_check},
               {:ssh_chmod, "ssh", ssh_chmod_args, :no_check},
               {:ssh_verify, "ssh", ssh_verify_args, :expect_ok}
             ] = plan

      assert List.last(scp_args) === "user@host:#{default}"
      assert ssh_chmod_args === ["user@host", "chmod", "+x", default]
      assert ssh_verify_args === ["user@host", "[ -x #{default} ] && echo ok"]
    end
  end

  describe "build_plan/5 - --remote-path override" do
    test "propagates the override into every step's argv" do
      local = DockerDialStdio.local_path()

      plan = InstallDialStdioScript.build_plan(local, "user@host", "/opt/bin/bridge", nil, nil)

      assert [
               {:scp, "scp", scp_args, :no_check},
               {:ssh_chmod, "ssh", ssh_chmod_args, :no_check},
               {:ssh_verify, "ssh", ssh_verify_args, :expect_ok}
             ] = plan

      assert List.last(scp_args) === "user@host:/opt/bin/bridge"
      assert ssh_chmod_args === ["user@host", "chmod", "+x", "/opt/bin/bridge"]
      assert ssh_verify_args === ["user@host", "[ -x /opt/bin/bridge ] && echo ok"]
    end
  end

  describe "build_plan/5 - argv shapes" do
    test "exact scp/ssh argv with identity and port flags" do
      default = DockerDialStdio.default_remote_path()
      local = DockerDialStdio.local_path()

      plan =
        InstallDialStdioScript.build_plan(
          local,
          "deploy@example.com",
          default,
          "/home/me/.ssh/id_ed25519",
          "2222"
        )

      assert [
               {:scp, "scp", scp_args, :no_check},
               {:ssh_chmod, "ssh", ssh_chmod_args, :no_check},
               {:ssh_verify, "ssh", ssh_verify_args, :expect_ok}
             ] = plan

      assert scp_args === [
               "-i",
               "/home/me/.ssh/id_ed25519",
               "-P",
               "2222",
               local,
               "deploy@example.com:#{default}"
             ]

      assert ssh_chmod_args === [
               "-i",
               "/home/me/.ssh/id_ed25519",
               "-p",
               "2222",
               "deploy@example.com",
               "chmod",
               "+x",
               default
             ]

      assert ssh_verify_args === [
               "-i",
               "/home/me/.ssh/id_ed25519",
               "-p",
               "2222",
               "deploy@example.com",
               "[ -x #{default} ] && echo ok"
             ]
    end

    test "no identity or port flags when not provided" do
      default = DockerDialStdio.default_remote_path()
      local = DockerDialStdio.local_path()

      plan = InstallDialStdioScript.build_plan(local, "user@host", default, nil, nil)

      assert [
               {:scp, "scp", scp_args, :no_check},
               {:ssh_chmod, "ssh", ssh_chmod_args, :no_check},
               _
             ] = plan

      assert scp_args === [local, "user@host:#{default}"]
      assert ssh_chmod_args === ["user@host", "chmod", "+x", default]
    end
  end
end

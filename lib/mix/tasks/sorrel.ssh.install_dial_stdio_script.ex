defmodule Mix.Tasks.Sorrel.SSH.InstallDialStdioScript do
  @shortdoc "Deploys the dial-stdio wrapper script to a remote SSH host"
  @moduledoc """
  Optional Docker convenience layer built on top of Sorrel's
  transport-agnostic SSH transport. Sorrel itself is not
  Docker-specific; this task is.

  Deploys the bundled `dial-stdio` wrapper script to a remote SSH
  host using `scp` and `ssh`.

  ## Usage

      mix sorrel.ssh.install_dial_stdio_script USER_AT_HOST [opts]

  ## Options

    * `--remote-path` -- destination path on the host. Defaults to
      `/usr/local/bin/docker-stdio-bridge`.
    * `--identity` -- passed through to `scp`/`ssh` as `-i`.
    * `--port` -- SSH port (passed as `-P` to `scp` and `-p` to
      `ssh`).

  Requires `scp` and `ssh` to be on `PATH` locally.

  ## What the task does

    1. `scp`s the bundled wrapper script to the host.
    2. `ssh`s into the host and runs `chmod +x` on the deployed
       file.
    3. Verifies by running `[ -x <remote_path> ] && echo ok` over
       `ssh` and checking that stdout contains `ok`.

  Subprocess execution is performed via `ElixirExec.run/2`. On any
  failure the task aborts via `Mix.raise/1` quoting the failing
  subcommand's combined stdout/stderr verbatim. On success it prints
  a single human-readable line:

      Installed <local_path> -> user@host:<remote_path>
  """
  use Mix.Task

  alias Sorrel.Transport.SSH.DockerDialStdio

  @impl Mix.Task
  def run(argv) do
    {opts, positional, _invalid} =
      OptionParser.parse(argv,
        strict: [
          remote_path: :string,
          identity: :string,
          port: :string
        ]
      )

    user_at_host = parse_user_at_host(positional)
    remote_path = Keyword.get(opts, :remote_path, DockerDialStdio.default_remote_path())
    identity = Keyword.get(opts, :identity)
    port = Keyword.get(opts, :port)
    local = DockerDialStdio.local_path()

    local
    |> build_plan(user_at_host, remote_path, identity, port)
    |> Enum.each(&execute_step!/1)

    Mix.shell().info("Installed #{local} → #{user_at_host}:#{remote_path}")
    :ok
  end

  @doc """
  Builds the ordered list of subprocess steps the task will run.

  Each entry is a `{step_name, executable, args, check}` tuple. `check`
  is `:no_check` for steps that only care about exit status, or
  `:expect_ok` for the verification step (which additionally requires
  the literal `"ok"` to appear in stdout).

  Exposed for unit testing — production callers go through `run/1`.
  """
  @spec build_plan(Path.t(), String.t(), Path.t(), String.t() | nil, String.t() | nil) ::
          [{atom(), String.t(), [String.t()], :no_check | :expect_ok}]
  def build_plan(local, user_at_host, remote_path, identity, port) do
    id_args = identity_arg(identity)

    [
      {:scp, "scp", id_args ++ port_arg(port, "-P") ++ [local, "#{user_at_host}:#{remote_path}"],
       :no_check},
      {:ssh_chmod, "ssh",
       id_args ++ port_arg(port, "-p") ++ [user_at_host, "chmod", "+x", remote_path], :no_check},
      {:ssh_verify, "ssh",
       id_args ++ port_arg(port, "-p") ++ [user_at_host, "[ -x #{remote_path} ] && echo ok"],
       :expect_ok}
    ]
  end

  defp parse_user_at_host([]) do
    Mix.raise(
      "missing required USER_AT_HOST argument. " <>
        "Usage: mix sorrel.ssh.install_dial_stdio_script USER_AT_HOST [--remote-path PATH] [--identity FILE] [--port PORT]"
    )
  end

  defp parse_user_at_host([user_at_host | _rest]), do: user_at_host

  defp execute_step!({_step, cmd, args, check}) do
    case ElixirExec.run([cmd | args], sync: true, stdout: true, stderr: :stdout) do
      {:ok, %ElixirExec.Output{stdout: chunks}} ->
        verify_check!(check, IO.iodata_to_binary(chunks))

      {:error, proplist} when is_list(proplist) ->
        proplist
        |> Keyword.get(:stdout, [])
        |> IO.iodata_to_binary()
        |> Mix.raise()

      {:error, reason} ->
        Mix.raise("subprocess failed: #{inspect(reason)}")
    end
  end

  defp verify_check!(:no_check, _output), do: :ok

  defp verify_check!(:expect_ok, output) do
    if String.contains?(output, "ok") do
      :ok
    else
      Mix.raise(
        "verification failed: expected stdout to contain \"ok\" but got: #{inspect(output)}"
      )
    end
  end

  defp identity_arg(nil), do: []
  defp identity_arg(identity), do: ["-i", identity]

  defp port_arg(nil, _flag), do: []
  defp port_arg(port, flag), do: [flag, port]
end

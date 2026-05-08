defmodule Sorrel.Transport.SSH.DockerDialStdio do
  @moduledoc """
  Optional Docker convenience layer built on top of Sorrel's
  transport-agnostic SSH transport. Sorrel itself is not
  Docker-specific; this module is.

  Locates the shell script bundled with this package that wraps
  `docker system dial-stdio` on a remote SSH host and translates
  non-zero exits into HTTP 502 responses.

  The script lives on the *remote* SSH host, not on the machine
  running this library. Use `local_path/0` to find the bundled
  copy on disk, then deploy it to your host -- either manually
  with `scp`, or via the
  `mix sorrel.ssh.install_dial_stdio_script` task.

  ## Why this exists

  When a remote `dial-stdio` invocation fails (binary missing,
  permission denied, daemon crash), the SSH channel just closes
  with no signal at the HTTP layer. The bundled wrapper inspects
  the exit status with `$?` and writes a real HTTP/1.1 502
  response when the wrapped command produced no output, so the
  client sees a typed HTTP error instead of an opaque EOF.

  ## Tradeoffs

    * The wrapper buffers `dial-stdio`'s stdout through a tempfile
      so it can decide -- after the wrapped command exits --
      whether to overlay a synthetic 502. This loses streaming.
      Do not use the wrapper for streaming Docker endpoints
      (image pulls, build logs, attach/exec output): the in-library
      mid-stream detection on the client side already covers those
      cases. The wrapper is meant for the request/response endpoints
      where buffering is fine and a typed HTTP error is worth more
      than a clean EOF.
    * The wrapper can only synthesize a 502 when `dial-stdio`
      produced *no* output before failing. Once any byte has crossed
      toward the client, the wrapper is a passthrough and the client
      falls back to its in-library detection.

  ## Deployment

      iex> path = Sorrel.Transport.SSH.DockerDialStdio.local_path()
      iex> File.exists?(path)
      true

  Deploy with the bundled Mix task:

      mix sorrel.ssh.install_dial_stdio_script user@host

  Or manually:

      scp $(elixir -e 'IO.puts(Sorrel.Transport.SSH.DockerDialStdio.local_path())') \\
          user@host:/usr/local/bin/docker-stdio-bridge
      ssh user@host chmod +x /usr/local/bin/docker-stdio-bridge

  Then point the SSH transport at the deployed path:

      target: {:exec, "/usr/local/bin/docker-stdio-bridge"}
  """

  @doc """
  Returns the absolute path of the bundled shell script on the
  *local* filesystem.

  This path lives inside the application's `priv` directory and is
  intended to be the source for an `scp` (or equivalent) call that
  copies the script onto a remote SSH host.
  """
  @spec local_path() :: Path.t()
  def local_path do
    :sorrel
    |> :code.priv_dir()
    |> Path.join("docker_dial_stdio_script.sh")
  end

  @doc """
  Returns the recommended absolute path of the deployed script on
  the *remote* SSH host.

  This is the destination used by
  `mix sorrel.ssh.install_dial_stdio_script` when the caller
  does not pass `--remote-path`, and the path that should be named
  in the endpoint's `target: {:exec, _}` after deployment.
  """
  @spec default_remote_path() :: Path.t()
  def default_remote_path, do: "/usr/local/bin/docker-stdio-bridge"
end

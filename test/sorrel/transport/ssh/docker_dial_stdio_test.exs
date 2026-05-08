defmodule Sorrel.Transport.SSH.DockerDialStdioTest do
  use ExUnit.Case, async: true

  alias Sorrel.Transport.SSH.DockerDialStdio

  describe "local_path/0" do
    test "returns a path that exists on disk" do
      path = DockerDialStdio.local_path()
      assert is_binary(path) or is_list(path)
      assert File.exists?(path), "expected #{inspect(path)} to exist on disk"
    end

    test "the file at that path is readable and starts with #!/bin/sh" do
      path = DockerDialStdio.local_path()
      contents = File.read!(path)

      assert String.starts_with?(contents, "#!/bin/sh"),
             "expected script to start with #!/bin/sh; got: #{String.slice(contents, 0, 40)}"
    end
  end

  describe "default_remote_path/0" do
    test "returns the documented constant" do
      assert DockerDialStdio.default_remote_path() ===
               "/usr/local/bin/docker-stdio-bridge"
    end
  end
end

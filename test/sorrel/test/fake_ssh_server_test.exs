defmodule Sorrel.Test.FakeSSHServerTest do
  @moduledoc """
  Smoke tests for `Sorrel.Test.FakeSSHServer`.

  These tests use the OTP `:ssh` *client* directly (no Mint, no
  bridge) to exercise the daemon's auth, exec-channel, and direct-tcpip
  code paths. They are deliberately narrow: their job is to prove the
  test-support server actually accepts connections, runs the configured
  handler, and bridges TCP forwards.
  """

  use ExUnit.Case, async: true

  alias Sorrel.Test.FakeSSHServer

  @loopback ~c"127.0.0.1"

  describe "start/1 + stop/1" do
    test "rejects empty auth_methods" do
      assert {:error, :no_auth_methods} = FakeSSHServer.start(auth_methods: [])
    end

    test "rejects password auth without user" do
      assert {:error, :password_auth_requires_user} =
               FakeSSHServer.start(
                 auth_methods: [:password],
                 password: "p"
               )
    end

    test "rejects publickey auth without authorized_keys" do
      assert {:error, :publickey_auth_requires_authorized_keys} =
               FakeSSHServer.start(auth_methods: [:publickey])
    end

    test "starts and stops cleanly" do
      {:ok, pid, info} =
        FakeSSHServer.start(
          auth_methods: [:password],
          user: "alice",
          password: "secret"
        )

      assert is_pid(pid)
      assert is_integer(info.port) and info.port > 0
      assert String.starts_with?(info.host_key_fingerprint, "SHA256:")
      assert is_list(info.system_dir)

      sys_dir_str = List.to_string(info.system_dir)
      assert File.exists?(sys_dir_str)

      assert :ok = FakeSSHServer.stop(pid)
      refute Process.alive?(pid)
      refute File.exists?(sys_dir_str)
    end
  end

  describe "password auth" do
    test "accepts the configured user/password" do
      {:ok, pid, %{port: port}} =
        FakeSSHServer.start(
          auth_methods: [:password],
          user: "alice",
          password: "secret"
        )

      on_exit(fn -> FakeSSHServer.stop(pid) end)

      assert {:ok, conn} = ssh_connect(port, ~c"alice", ~c"secret")
      :ok = :ssh.close(conn)
    end

    test "rejects wrong password" do
      {:ok, pid, %{port: port}} =
        FakeSSHServer.start(
          auth_methods: [:password],
          user: "alice",
          password: "secret"
        )

      on_exit(fn -> FakeSSHServer.stop(pid) end)

      assert {:error, _reason} = ssh_connect(port, ~c"alice", ~c"wrong")
    end
  end

  describe "publickey auth" do
    test "accepts a connection authenticated with the configured key" do
      # Generate an ed25519 keypair for the client.
      key_dir = Path.join(System.tmp_dir!(), "fake_ssh_pk_#{System.unique_integer([:positive])}")
      File.mkdir_p!(key_dir)

      priv_path = Path.join(key_dir, "id_ed25519")
      pub_path = Path.join(key_dir, "id_ed25519.pub")
      System.cmd("ssh-keygen", ["-t", "ed25519", "-N", "", "-f", priv_path, "-q"])

      authorized_keys = File.read!(pub_path)

      {:ok, pid, %{port: port}} =
        FakeSSHServer.start(
          auth_methods: [:publickey],
          authorized_keys: authorized_keys
        )

      on_exit(fn ->
        FakeSSHServer.stop(pid)
        File.rm_rf(key_dir)
      end)

      # The OTP client looks for keys in user_dir.
      assert {:ok, conn} =
               :ssh.connect(@loopback, port,
                 user: ~c"someone",
                 auth_methods: ~c"publickey",
                 silently_accept_hosts: true,
                 user_interaction: false,
                 user_dir: String.to_charlist(key_dir)
               )

      :ok = :ssh.close(conn)
    end
  end

  describe "exec channel" do
    test "runs the configured handler and bridges stdin/stdout" do
      handler = fn cmd, send_fun, recv_fun ->
        :ok = send_fun.("echo:" <> List.to_string(cmd) <> "\n")

        case recv_fun.(2_000) do
          {:ok, data} ->
            :ok = send_fun.("got:" <> data)
            :ok

          :eof ->
            :ok
        end
      end

      {:ok, pid, %{port: port}} =
        FakeSSHServer.start(
          auth_methods: [:password],
          user: "u",
          password: "p",
          exec_handler: handler
        )

      on_exit(fn -> FakeSSHServer.stop(pid) end)

      {:ok, conn} = ssh_connect(port, ~c"u", ~c"p")
      {:ok, channel} = :ssh_connection.session_channel(conn, 5_000)
      :success = :ssh_connection.exec(conn, channel, ~c"hello", 5_000)

      :ok = :ssh_connection.send(conn, channel, "world")
      :ok = :ssh_connection.send_eof(conn, channel)

      bytes = collect_channel_bytes(channel, 3_000)
      assert bytes =~ "echo:hello\n"
      assert bytes =~ "got:world"

      :ok = :ssh.close(conn)
    end

    test "rejects exec when no handler is configured" do
      {:ok, pid, %{port: port}} =
        FakeSSHServer.start(
          auth_methods: [:password],
          user: "u",
          password: "p"
        )

      on_exit(fn -> FakeSSHServer.stop(pid) end)

      {:ok, conn} = ssh_connect(port, ~c"u", ~c"p")
      {:ok, channel} = :ssh_connection.session_channel(conn, 5_000)
      assert :failure = :ssh_connection.exec(conn, channel, ~c"hello", 5_000)
      :ok = :ssh.close(conn)
    end
  end

  describe "direct-tcpip" do
    test "forwards bytes to a local TCP listener" do
      # Stand up a tiny echo TCP server.
      {:ok, listen} =
        :gen_tcp.listen(0, [
          :binary,
          {:ip, {127, 0, 0, 1}},
          {:active, false},
          {:reuseaddr, true},
          {:packet, :raw}
        ])

      {:ok, target_port} = :inet.port(listen)

      acceptor =
        spawn_link(fn ->
          {:ok, sock} = :gen_tcp.accept(listen, 5_000)
          {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
          :ok = :gen_tcp.send(sock, "echo:" <> data)
          :gen_tcp.close(sock)
        end)

      _ = acceptor

      {:ok, pid, %{port: ssh_port}} =
        FakeSSHServer.start(
          auth_methods: [:password],
          user: "u",
          password: "p"
        )

      on_exit(fn ->
        FakeSSHServer.stop(pid)
        :gen_tcp.close(listen)
      end)

      {:ok, conn} = ssh_connect(ssh_port, ~c"u", ~c"p")

      result =
        :ssh_connection.open_channel(
          conn,
          ~c"direct-tcpip",
          encode_direct_tcpip("127.0.0.1", target_port, "127.0.0.1", 0),
          5_000
        )

      assert {:ok, channel} = result, "open_channel returned: #{inspect(result)}"

      :ok = :ssh_connection.send(conn, channel, "ping")

      bytes = collect_channel_bytes(channel, 3_000)
      assert bytes =~ "echo:ping", "got bytes: #{inspect(bytes)}"

      :ok = :ssh.close(conn)
    end
  end

  ## ssh client helpers

  defp ssh_connect(port, user, password) do
    :ssh.connect(@loopback, port,
      user: user,
      password: password,
      auth_methods: ~c"password",
      silently_accept_hosts: true,
      user_interaction: false,
      user_dir: client_user_dir()
    )
  end

  defp client_user_dir do
    dir = Path.join(System.tmp_dir!(), "fake_ssh_client_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    known_hosts_path = Path.join(dir, "known_hosts")
    File.write!(known_hosts_path, "")
    String.to_charlist(dir)
  end

  # SSH wire format for direct-tcpip: 4-byte length prefixes around
  # each string, raw 32-bit big-endian for ports.
  defp encode_direct_tcpip(host_to, port_to, originator, originator_port) do
    IO.iodata_to_binary([
      <<byte_size(host_to)::32>>,
      host_to,
      <<port_to::32>>,
      <<byte_size(originator)::32>>,
      originator,
      <<originator_port::32>>
    ])
  end

  # Reads channel data messages until eof or close, with `timeout` ms
  # of total wait time. Returns whatever bytes have arrived.
  defp collect_channel_bytes(channel, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect(channel, deadline, "")
  end

  defp do_collect(channel, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)
    remaining = if remaining < 0, do: 0, else: remaining

    receive do
      {:ssh_cm, _conn, {:data, ^channel, _type, data}} ->
        do_collect(channel, deadline, acc <> data)

      {:ssh_cm, _conn, {:eof, ^channel}} ->
        do_collect(channel, deadline, acc)

      {:ssh_cm, _conn, {:exit_status, ^channel, _status}} ->
        do_collect(channel, deadline, acc)

      {:ssh_cm, _conn, {:closed, ^channel}} ->
        acc
    after
      remaining -> acc
    end
  end
end

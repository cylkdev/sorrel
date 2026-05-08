defmodule Sorrel.Transport.SSHTest do
  # End-to-end integration tests for `Sorrel.Transport.SSH`.
  #
  # Each test stands up an in-process `FakeSSHServer` (and, for tcp-target
  # tests, a `FakeHttpServer`) and drives a real `:ssh.connect/4` against
  # it. Tests are NOT async because each test boots its own SSH daemon and
  # the OTP `:ssh` application is global state. Running them concurrently
  # tends to confuse test ports / temp directories on slower CI hosts.
  #
  # The `:unix` (direct-streamlocal@openssh.com) target test is tagged
  # `:external_ssh` because the in-process OTP `:ssh` daemon does NOT
  # implement that channel type; only a real OpenSSH daemon does. The
  # `test_helper.exs` excludes `:external_ssh` by default.
  use ExUnit.Case

  alias Sorrel.Endpoint
  alias Sorrel.Test.FakeSSHServer
  alias Sorrel.Transport.SSH, as: SSHTransport

  @ok_response "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ssh)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Spawns a FakeSSHServer accepting password auth and a caller-supplied
  # exec_handler. Stops it on test exit.
  defp start_password_ssh(opts) do
    full_opts =
      [
        auth_methods: [:password],
        user: "tester",
        password: "secret"
      ] ++ opts

    {:ok, pid, info} = FakeSSHServer.start(full_opts)
    on_exit(fn -> FakeSSHServer.stop(pid) end)
    {pid, info}
  end

  # Endpoint pointing at the fake SSH server, with the given target.
  defp endpoint(info, target, ssh_overrides \\ %{}) do
    ssh =
      Map.merge(
        %{
          auth: [:password],
          identity_file: nil,
          password: "secret",
          known_hosts_file: nil,
          verify: :verify_none,
          connect_timeout: 5_000
        },
        ssh_overrides
      )

    %Endpoint{
      transport: :ssh,
      host: "127.0.0.1",
      port: info.port,
      user: "tester",
      ssh: ssh,
      target: target
    }
  end

  # Builds an exec_handler that writes a fixed response and exits. Used
  # for request/5 tests where the remote command speaks one full HTTP
  # response on stdout.
  defp constant_response_handler(response_iodata) do
    fn _cmd, send_fun, _recv_fun ->
      :ok = send_fun.(response_iodata)
      :ok
    end
  end

  # Connects through SSHTransport and runs Mint.HTTP.recv until the
  # response is complete. Mirrors helpers from tcp_test.exs.
  defp do_request(ep, method \\ "GET", path \\ "/_ping") do
    with {:ok, conn} <- SSHTransport.connect(ep),
         {:ok, conn, ref} <- Mint.HTTP.request(conn, method, path, [], "") do
      recv_full_response(conn, ref)
    end
  end

  defp recv_full_response(conn, ref, acc \\ %{status: nil, body: ""}) do
    case Mint.HTTP.recv(conn, 0, 5_000) do
      {:ok, conn, responses} ->
        {acc2, done?} = absorb(responses, ref, acc)

        if done? do
          _ = Mint.HTTP.close(conn)
          {:ok, acc2}
        else
          recv_full_response(conn, ref, acc2)
        end

      {:error, conn, reason, _responses} ->
        _ = Mint.HTTP.close(conn)
        {:error, reason}
    end
  end

  defp absorb(responses, ref, acc) do
    Enum.reduce(responses, {acc, false}, fn
      {:status, ^ref, status}, {a, _} -> {%{a | status: status}, false}
      {:headers, ^ref, _}, {a, _} -> {a, false}
      {:data, ^ref, data}, {a, _} -> {%{a | body: a.body <> data}, false}
      {:done, ^ref}, {a, _} -> {a, true}
      _, acc_done -> acc_done
    end)
  end

  # Picks an unused TCP port by binding ephemerally and immediately
  # closing. Used for negative path tests.
  defp unused_port do
    {:ok, ls} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, reuseaddr: false])
    {:ok, port} = :inet.port(ls)
    :ok = :gen_tcp.close(ls)
    port
  end

  # ---------------------------------------------------------------------------
  # Target {:exec, _} happy path: request/5 round-trip
  # ---------------------------------------------------------------------------

  describe "exec target — successful round-trip" do
    test "request returns {:ok, %{status: 200, body: \"OK\"}}" do
      handler = constant_response_handler(@ok_response)
      {_pid, info} = start_password_ssh(exec_handler: handler)

      ep = endpoint(info, {:exec, "docker system dial-stdio"})

      assert {:ok, %{status: 200, body: "OK"}} = do_request(ep)
    end

    test "dispatches :ssh through Sorrel.Transport.connect/2 to the SSH transport" do
      handler = constant_response_handler(@ok_response)
      {_pid, info} = start_password_ssh(exec_handler: handler)

      ep = endpoint(info, {:exec, "/usr/bin/dial"})

      assert {:ok, conn} = Sorrel.Transport.connect(ep)
      assert is_struct(conn, Mint.HTTP1)
      _ = Mint.HTTP.close(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # Target {:exec, _} with chunked response: stream/5 reads multiple chunks
  # ---------------------------------------------------------------------------

  describe "exec target — chunked HTTP response" do
    test "request reads the full body across multiple writes" do
      # Two writes: response head, then trailing body bytes. Mint
      # reassembles them. Total Content-Length covers both writes.
      response_head =
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 11\r\nConnection: close\r\n\r\nhello"

      response_tail = " world"

      handler = fn _cmd, send_fun, _recv_fun ->
        :ok = send_fun.(response_head)
        Process.sleep(20)
        :ok = send_fun.(response_tail)
        :ok
      end

      {_pid, info} = start_password_ssh(exec_handler: handler)
      ep = endpoint(info, {:exec, "anything"})

      assert {:ok, %{status: 200, body: "hello world"}} = do_request(ep)
    end
  end

  # ---------------------------------------------------------------------------
  # Target {:exec, _} 101 Upgrade: bridge must outlive the Mint handoff
  # ---------------------------------------------------------------------------

  describe "exec target — 101 Switching Protocols" do
    test "raw bytes flow over the upgraded socket after Mint hands off" do
      # The exec handler:
      #   1. emits a 101 response head + a single byte of leftover.
      #   2. echoes any further client bytes back as channel stdout.
      #
      # The test then:
      #   1. uses Sorrel.Tunnel.upgrade to drive the upgrade.
      #   2. writes raw bytes on the returned socket and recvs them
      #      back, proving the bridge keeps pumping bytes after Mint
      #      has yielded ownership.
      handler = fn _cmd, send_fun, recv_fun ->
        :ok =
          send_fun.(
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: tcp\r\nConnection: Upgrade\r\n\r\n"
          )

        echo_loop(send_fun, recv_fun)
      end

      {_pid, info} = start_password_ssh(exec_handler: handler)

      ep = endpoint(info, {:exec, "tunnel-cmd"})

      # tunnel/5 negotiates the upgrade and returns the underlying socket.
      assert {:ok, socket, _leftover} =
               Sorrel.tunnel(ep, :post, "/upgrade", "", connect_timeout: 5_000)

      # Send a payload; expect the same bytes back via the bridge.
      :ok = :gen_tcp.send(socket, "ping-from-test")
      assert {:ok, "ping-from-test"} = :gen_tcp.recv(socket, 14, 2_000)

      :ok = Sorrel.Tunnel.close(socket)
    end
  end

  # Drains incoming bytes through the HTTP request's `\r\n\r\n` end-of-
  # headers sentinel (those bytes belong to the original upgrade request
  # and would confuse the test if echoed back), then echoes everything
  # the client writes from that point on, until either side closes.
  #
  # The test client uses an empty POST body, so the first appearance of
  # `\r\n\r\n` is the end of the headers AND the end of the request — any
  # bytes after the sentinel are post-handshake payload that must be
  # echoed.
  defp echo_loop(send_fun, recv_fun) do
    drain_request_then_echo(send_fun, recv_fun, "")
  end

  defp drain_request_then_echo(send_fun, recv_fun, buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {pos, len} ->
        # Found end of headers. Any bytes after the sentinel are
        # post-handshake payload — echo them, then drop into plain
        # echo mode for everything that follows.
        leftover = binary_part(buffer, pos + len, byte_size(buffer) - pos - len)
        if leftover !== "", do: :ok = send_fun.(leftover)
        plain_echo_loop(send_fun, recv_fun)

      :nomatch ->
        case recv_fun.(5_000) do
          {:ok, data} -> drain_request_then_echo(send_fun, recv_fun, buffer <> data)
          :eof -> :ok
          {:error, _reason} -> :ok
        end
    end
  end

  defp plain_echo_loop(send_fun, recv_fun) do
    case recv_fun.(5_000) do
      {:ok, data} ->
        :ok = send_fun.(data)
        plain_echo_loop(send_fun, recv_fun)

      :eof ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Failure paths
  # ---------------------------------------------------------------------------

  describe "auth failures" do
    test "wrong password yields {:error, :ssh_auth_failed}" do
      {_pid, info} = start_password_ssh([])

      ep = endpoint(info, {:exec, "x"}, %{password: "wrong-password"})

      assert {:error, {:ssh_auth_failed, _reason}} = SSHTransport.connect(ep)
    end
  end

  describe "host key verification" do
    test "verify_peer with mismatched known_hosts yields {:error, :ssh_host_key_mismatch}" do
      handler = constant_response_handler(@ok_response)
      {_pid, info} = start_password_ssh(exec_handler: handler)

      # Build a known_hosts file pointing at a different host key. The
      # OTP `:ssh_file` callback reads `known_hosts` from `user_dir`,
      # so we put it in a temp dir and point the endpoint at it.
      {known_hosts_path, _user_dir} = write_bogus_known_hosts(info.port)

      ep =
        endpoint(info, {:exec, "x"}, %{
          verify: :verify_peer,
          known_hosts_file: known_hosts_path
        })

      # OTP surfaces host-key mismatches as a long charlist beginning
      # with "Key exchange failed" or referencing the unknown host key.
      # Either is mapped to :ssh_host_key_mismatch.
      assert {:error, reason} = SSHTransport.connect(ep)

      assert match?({:ssh_host_key_mismatch, _}, reason) or match?({:ssh_auth_failed, _}, reason),
             "expected {:ssh_host_key_mismatch, _} (or {:ssh_auth_failed, _} if OTP collapsed " <>
               "the host-key rejection into an auth-failed message), got: #{inspect(reason)}"
    end

    test "verify_none accepts any host key" do
      handler = constant_response_handler(@ok_response)
      {_pid, info} = start_password_ssh(exec_handler: handler)

      ep = endpoint(info, {:exec, "x"}, %{verify: :verify_none})

      assert {:ok, conn} = SSHTransport.connect(ep)
      _ = Mint.HTTP.close(conn)
    end
  end

  describe "exec target — remote exec failure" do
    test "remote exits non-zero before sending bytes → {:error, {:ssh_exec_failed, _}}" do
      # Simulate a remote `dial-stdio: not found, exit 127` scenario:
      # the handler exits abnormally without sending bytes, which
      # causes the FakeSSHServer CLI worker to crash; the CLI then
      # emits a non-zero exit_status, EOF, and channel close —
      # exactly the channel-message sequence a real sshd produces
      # when the exec'd binary is missing or non-executable. The
      # transport must surface this as a typed `{:ssh_exec_failed,
      # _}` error instead of the generic Mint EOF that would
      # otherwise leak through.
      handler = fn _cmd, _send_fun, _recv_fun ->
        Process.exit(self(), :remote_exec_failed)
      end

      {_pid, info} = start_password_ssh(exec_handler: handler)
      ep = endpoint(info, {:exec, "/usr/bin/does-not-exist"})

      assert {:error, {:ssh_exec_failed, reason}} = SSHTransport.connect(ep)

      # Reason shape is `{:status, non_neg_integer}` (CLI emits 1 for
      # crashed handlers) or `{:signal, sig_string}`.
      assert match?({:status, n} when is_integer(n) and n !== 0, reason) or
               match?({:signal, _}, reason),
             "unexpected ssh_exec_failed reason: #{inspect(reason)}"
    end
  end

  describe "unreachable SSH server" do
    test "connecting to a closed port yields {:error, :ssh_unreachable}" do
      port = unused_port()

      ep = %Endpoint{
        transport: :ssh,
        host: "127.0.0.1",
        port: port,
        user: "tester",
        ssh: %{
          auth: [:password],
          identity_file: nil,
          password: "secret",
          known_hosts_file: nil,
          verify: :verify_none,
          connect_timeout: 1_000
        },
        target: {:exec, "x"}
      }

      assert {:error, {:ssh_unreachable, _reason}} = SSHTransport.connect(ep)
    end
  end

  describe "mid-stream remote close" do
    test "stream/5 raises Sorrel.Error when the channel closes mid-body" do
      # Handler emits a head with a bigger Content-Length than it'll
      # actually deliver, then closes the channel. The reader should
      # observe a closed connection and raise.
      head =
        "HTTP/1.1 200 OK\r\n" <>
          "Content-Type: application/x-ndjson\r\n" <>
          "Transfer-Encoding: chunked\r\n\r\n"

      # One chunk, then the handler returns -- which causes the channel
      # to close before any final-chunk-zero has been written.
      partial_chunk = "5\r\nhello\r\n"

      handler = fn _cmd, send_fun, _recv_fun ->
        :ok = send_fun.(head)
        Process.sleep(20)
        :ok = send_fun.(partial_chunk)
        :ok
      end

      {_pid, info} = start_password_ssh(exec_handler: handler)
      ep = endpoint(info, {:exec, "x"})

      assert {:ok, stream} =
               Sorrel.stream(ep, :get, "/events", nil,
                 into: :raw,
                 connect_timeout: 5_000,
                 receive_timeout: 1_500
               )

      # Consuming the stream should yield "hello" first, then raise on
      # the next pull when the underlying socket goes away.
      assert_raise Sorrel.Error, fn ->
        Enum.to_list(stream)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Target {:tcp, host, port} happy path
  # ---------------------------------------------------------------------------

  describe "tcp target — direct-tcpip channel" do
    test "round-trips a request to a FakeHttpServer through SSH direct-tcpip" do
      # A fake HTTP server listening on a local TCP port. The fake SSH
      # server's direct-tcpip channel forwards there.
      {:ok, http_server} =
        FakeHttpServer.start(
          transport: :tcp,
          ip: {127, 0, 0, 1},
          port: 0,
          responder: fn _req ->
            {:close_after,
             "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 4\r\nConnection: close\r\n\r\nPONG"}
          end
        )

      on_exit(fn -> FakeHttpServer.stop(http_server) end)
      {:ok, http_port} = FakeHttpServer.port(http_server)

      {_pid, info} = start_password_ssh([])

      ep = endpoint(info, {:tcp, "127.0.0.1", http_port})

      assert {:ok, %{status: 200, body: "PONG"}} = do_request(ep)
    end
  end

  # ---------------------------------------------------------------------------
  # Target {:unix, _} — direct-streamlocal@openssh.com
  #
  # The OTP :ssh daemon does NOT implement the
  # direct-streamlocal@openssh.com channel type, so this test only runs
  # against a real OpenSSH daemon. Tagged :external_ssh and excluded by
  # default in test_helper.exs.
  # ---------------------------------------------------------------------------

  describe "unix target — direct-streamlocal channel" do
    @tag :external_ssh
    test "round-trips a request to a FakeHttpServer over a Unix socket via OpenSSH" do
      sock_path =
        Path.join(
          System.tmp_dir!(),
          "ssh_unix_target_#{:erlang.unique_integer([:positive])}.sock"
        )

      {:ok, http_server} =
        FakeHttpServer.start(
          transport: :unix,
          socket_path: sock_path,
          responder: fn _req ->
            {:close_after,
             "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"}
          end
        )

      on_exit(fn ->
        FakeHttpServer.stop(http_server)
        File.rm(sock_path)
      end)

      # Caller environment must provide:
      #   SSH_HOST, SSH_PORT, SSH_USER, and one of
      #   {SSH_PASSWORD} or {SSH_IDENTITY_FILE} or just an agent.
      ssh_host = System.get_env("SSH_HOST") || flunk_external("SSH_HOST not set")
      ssh_port = String.to_integer(System.get_env("SSH_PORT") || "22")
      ssh_user = System.get_env("SSH_USER") || flunk_external("SSH_USER not set")

      ep = %Endpoint{
        transport: :ssh,
        host: ssh_host,
        port: ssh_port,
        user: ssh_user,
        ssh: %{
          auth: [:agent, :identity, :password],
          identity_file: System.get_env("SSH_IDENTITY_FILE"),
          password: System.get_env("SSH_PASSWORD"),
          known_hosts_file: nil,
          verify: :verify_none,
          connect_timeout: 10_000
        },
        target: {:unix, sock_path}
      }

      assert {:ok, %{status: 200, body: "OK"}} = do_request(ep)
    end

    defp flunk_external(reason) do
      ExUnit.Assertions.flunk("external SSH test misconfigured: #{reason}")
    end
  end

  # ---------------------------------------------------------------------------
  # Test helpers (private)
  # ---------------------------------------------------------------------------

  # Writes a known_hosts file containing a (deliberately wrong) host
  # key entry for the fake server's host:port. Returns the path.
  defp write_bogus_known_hosts(port) do
    user_dir =
      Path.join(System.tmp_dir!(), "ssh_known_hosts_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(user_dir)

    # A made-up RSA public-key line. The format is `host[:port] ssh-rsa <base64>`.
    # The base64 here is a minimum valid RSA key encoding -- OTP only
    # cares that it parses, not that it's the right key. Since it isn't
    # the server's actual key, host-key verification will fail.
    bogus_pubkey =
      "AAAAB3NzaC1yc2EAAAADAQABAAABAQC7vbqajDw4o1gWFA8m23WhmS3X8DDvEaiECkx9bvqI" <>
        "Tr0wkXYqmLbjhFPP5l4VSUfXX7d5y1OL+J5GEOA8+4dExVw8jCdyIqpiHlbGr4iqkrc8r0Ub" <>
        "h/XYwf9k7nbQp7JqW8M2CXtnT+l3wPeUEEtWxgdnoIVeIcjfoNfd0LXzgQDNn9ZWKnAuFFW1" <>
        "9F8wY7r1nJk1g4i6mq2PUGwK1nRLlYvZ8tUE7sV6kqhzlrl3o6cJ2sfFJgJfwd4iH5gAYsXV" <>
        "khq4Q9Q0Y2/8e07c7e7vyZG8vdxX3y3JbLLQ45WQUJ5jWjEH8bU7aS3eqGuBtmo3jc3cvjqN" <>
        "OwULp6mnIzpMrz"

    line = "[127.0.0.1]:#{port} ssh-rsa #{bogus_pubkey}\n"

    known_hosts_path = Path.join(user_dir, "known_hosts")
    File.write!(known_hosts_path, line)

    on_exit(fn -> File.rm_rf(user_dir) end)

    {known_hosts_path, user_dir}
  end
end

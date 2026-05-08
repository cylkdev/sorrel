defmodule Sorrel.Transport.TcpTest do
  use ExUnit.Case, async: true

  alias Sorrel.Endpoint
  alias Sorrel.Transport
  alias Sorrel.Transport.Tcp, as: TcpTransport

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp ping_responder do
    fn _req ->
      {:close_after,
       "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 4\r\nConnection: close\r\n\r\nOK\r\n"}
    end
  end

  defp start_tcp_server(responder \\ nil) do
    responder = responder || ping_responder()

    {:ok, server} =
      FakeHttpServer.start(
        transport: :tcp,
        ip: {127, 0, 0, 1},
        port: 0,
        responder: responder
      )

    on_exit(fn -> FakeHttpServer.stop(server) end)

    {:ok, port} = FakeHttpServer.port(server)
    {server, port}
  end

  # Spins up a TLS-enabled FakeHttpServer using a cert fixture. The server
  # always sets verify_peer + fail_if_no_peer_cert so the negative tests can
  # exercise the "no client cert" failure path. The fixture and the server
  # are both registered for cleanup.
  defp start_tls_server(responder \\ nil) do
    responder = responder || ping_responder()
    paths = CertFixture.generate()

    {:ok, server} =
      FakeHttpServer.start(
        transport: :tls,
        ip: {127, 0, 0, 1},
        port: 0,
        cacertfile: paths.ca,
        certfile: paths.server_cert,
        keyfile: paths.server_key,
        fail_if_no_peer_cert: true,
        responder: responder
      )

    on_exit(fn ->
      FakeHttpServer.stop(server)
      File.rm_rf!(paths.dir)
    end)

    {:ok, port} = FakeHttpServer.port(server)
    {paths, port}
  end

  defp endpoint(port) do
    %Endpoint{
      transport: :tcp,
      scheme: :http,
      host: "127.0.0.1",
      port: port
    }
  end

  defp tls_endpoint(port, tls) do
    %Endpoint{
      transport: :tcp,
      scheme: :https,
      host: "127.0.0.1",
      port: port,
      tls: tls
    }
  end

  # Picks an unused TCP port by binding ephemerally and immediately closing.
  # Race window: another listener could grab the port between close/0 and the
  # subsequent connect attempt; in practice this is reliable enough for unit
  # tests on localhost.
  defp unused_port do
    {:ok, ls} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, reuseaddr: false])
    {:ok, port} = :inet.port(ls)
    :ok = :gen_tcp.close(ls)
    port
  end

  defp recv_full_response(conn, ref, acc \\ %{status: nil, body: ""}) do
    case Mint.HTTP.recv(conn, 0, 5_000) do
      {:ok, conn, responses} ->
        {acc2, done?} = absorb(responses, ref, acc)

        if done? do
          {:ok, conn, acc2}
        else
          recv_full_response(conn, ref, acc2)
        end

      {:error, conn, reason, _responses} ->
        {:error, conn, reason}
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

  # ---------------------------------------------------------------------------
  # Success: round-trip a real HTTP/1.1 request through TCP.
  # ---------------------------------------------------------------------------

  describe "connect/2 success" do
    test "returns {:ok, %Mint.HTTP1{}} and round-trips a request" do
      {_server, port} = start_tcp_server()
      ep = endpoint(port)

      assert {:ok, conn} = TcpTransport.connect(ep)
      assert is_struct(conn, Mint.HTTP1)

      assert {:ok, conn, ref} =
               Mint.HTTP.request(conn, "GET", "/_ping", [{"host", "127.0.0.1"}], "")

      assert {:ok, _conn, %{status: 200, body: "OK\r\n"}} = recv_full_response(conn, ref)
    end

    test "honours :connect_timeout option" do
      {_server, port} = start_tcp_server()
      ep = endpoint(port)

      assert {:ok, _conn} = TcpTransport.connect(ep, connect_timeout: 5_000)
    end
  end

  # ---------------------------------------------------------------------------
  # Failure: nothing listening on the chosen port.
  # ---------------------------------------------------------------------------

  describe "connect/2 failures" do
    test "returns {:error, %Mint.TransportError{reason: :econnrefused}} when no daemon" do
      port = unused_port()

      ep = endpoint(port)

      # Mint surfaces an OS-level ECONNREFUSED as a Mint.TransportError with
      # `reason: :econnrefused`. We match loosely on the struct shape so future
      # Mint versions that wrap the reason differently still trigger the
      # documented {:error, :econnrefused} contract from the @doc.
      assert {:error, %Mint.TransportError{reason: :econnrefused}} = TcpTransport.connect(ep)
    end

    @tag :slow
    test "returns {:error, %Mint.TransportError{reason: :timeout}} when connect blocks" do
      # 1.2.3.4 is in TEST-NET-1 (RFC 5737) and is reliably non-routable on
      # public networks, so the TCP SYN is black-holed and the connect attempt
      # blocks until our :connect_timeout fires. Documented as a slow test in
      # case CI takes longer than ~200 ms to honour the timeout.
      ep = %Endpoint{
        transport: :tcp,
        scheme: :http,
        host: "1.2.3.4",
        port: 2375
      }

      assert {:error, %Mint.TransportError{reason: :timeout}} =
               TcpTransport.connect(ep, connect_timeout: 100)
    end
  end

  # ---------------------------------------------------------------------------
  # Dispatcher: Sorrel.Transport.connect/2 routes :tcp endpoints here.
  # ---------------------------------------------------------------------------

  describe "Sorrel.Transport.connect/2 dispatch" do
    test "routes a :tcp endpoint to Sorrel.Transport.Tcp" do
      {_server, port} = start_tcp_server()
      ep = endpoint(port)

      assert {:ok, conn} = Transport.connect(ep)
      assert is_struct(conn, Mint.HTTP1)
    end

    test "forwards opts (e.g. :connect_timeout) to the tcp implementation" do
      {_server, port} = start_tcp_server()
      ep = endpoint(port)

      assert {:ok, _conn} = Transport.connect(ep, connect_timeout: 2_000)
    end
  end

  # ---------------------------------------------------------------------------
  # mTLS: positive and negative paths against a TLS-enabled FakeHttpServer.
  # The server is always configured verify_peer + fail_if_no_peer_cert: true.
  # ---------------------------------------------------------------------------

  describe "connect/2 mTLS" do
    test "completes handshake and round-trips a request when client presents a cert" do
      {paths, port} = start_tls_server()

      ep =
        tls_endpoint(port, %{
          verify: :verify_peer,
          cacertfile: paths.ca,
          certfile: paths.client_cert,
          keyfile: paths.client_key
        })

      assert {:ok, conn} = TcpTransport.connect(ep)
      assert is_struct(conn, Mint.HTTP1)

      assert {:ok, conn, ref} =
               Mint.HTTP.request(conn, "GET", "/_ping", [{"host", "127.0.0.1"}], "")

      assert {:ok, _conn, %{status: 200, body: "OK\r\n"}} = recv_full_response(conn, ref)
    end

    test "fails with a tls_alert when client presents no cert" do
      {paths, port} = start_tls_server()

      ep =
        tls_endpoint(port, %{
          verify: :verify_peer,
          cacertfile: paths.ca,
          certfile: nil,
          keyfile: nil
        })

      # Under TLS 1.3, client-cert verification happens post-handshake, so
      # connect/2 returns {:ok, conn} and the alert surfaces on the first
      # recv. We accept either path: an early error from connect, or an
      # error from the request/recv after the alert arrives.
      #
      # The exact error shape varies with timing — sometimes Mint observes
      # the alert tuple, sometimes the server has already torn the socket
      # down and Mint sees %Mint.TransportError{reason: :closed}. Both
      # outcomes mean the same thing: the server rejected our handshake
      # because we did not present a client cert. Match loosely.
      reason = connect_then_request(ep)

      assert tls_alert?(reason) or tcp_error?(reason),
             "expected a tls_alert or transport error, got: #{inspect(reason)}"
    end

    test "fails when certfile points at a missing path" do
      {paths, port} = start_tls_server()

      ep =
        tls_endpoint(port, %{
          verify: :verify_peer,
          cacertfile: paths.ca,
          certfile: Path.join(paths.dir, "does-not-exist.pem"),
          keyfile: paths.client_key
        })

      # ssl does not eagerly read the cert file; if it cannot be loaded the
      # client behaves as though it had no cert at all and the server
      # rejects the handshake. The exact error term varies depending on:
      #   - OTP version (older OTP surfaces :enoent eagerly from connect/2)
      #   - TLS version (TLS 1.3 surfaces alerts post-handshake)
      #   - timing of when the server tears down the socket vs. when the
      #     client recv runs (alert vs :closed vs :einval all observed)
      # The contract being tested is "the request never succeeds against a
      # server that requires a client cert when no usable certfile is
      # configured" — match on any error reason.
      assert tcp_error?(connect_then_request(ep))
    end
  end

  # Try to connect; if the connect succeeds, send a request and recv until
  # something errors. Returns the first error reason encountered (the connect
  # error if connect failed, or the request/recv error otherwise).
  defp connect_then_request(ep) do
    with {:ok, conn} <- TcpTransport.connect(ep),
         {:ok, conn, _ref} <-
           Mint.HTTP.request(conn, "GET", "/_ping", [{"host", "127.0.0.1"}], "") do
      recv_first_error(conn)
    else
      {:error, reason} -> reason
      {:error, _conn, reason} -> reason
    end
  end

  defp recv_first_error(conn) do
    case Mint.HTTP.recv(conn, 0, 5_000) do
      {:error, _conn, reason, _} -> reason
      other -> other
    end
  end

  # Loose matcher for "any TLS handshake alert".
  defp tls_alert?(%Mint.TransportError{reason: {:tls_alert, _}}), do: true
  defp tls_alert?({:tls_alert, _}), do: true
  defp tls_alert?(_), do: false

  # Matches any error reason that could come back from a Mint connect or
  # request against a misconfigured TLS client (transport errors, raw
  # ssl/posix atoms, alert tuples). True for anything that is NOT a normal
  # success result — used by the missing-certfile test where the precise
  # shape varies by timing/OTP version.
  defp tcp_error?(%Mint.TransportError{}), do: true
  defp tcp_error?({:tls_alert, _}), do: true
  defp tcp_error?(reason) when is_atom(reason), do: true
  defp tcp_error?(_), do: false
end

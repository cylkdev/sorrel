defmodule Sorrel.ConfigTest do
  # async: false because tests mutate Application env and process env vars.
  # credo:disable-for-next-line BlitzCredoChecks.NoAsyncFalse
  use ExUnit.Case, async: false

  alias Sorrel.Config

  # ---------------------------------------------------------------------------
  # Setup / teardown — track every key (app env + os env) we touch so a
  # failing test cannot leak state into the next one.
  # ---------------------------------------------------------------------------

  setup do
    app_keys = [
      :connect_timeout,
      :receive_timeout,
      :pool_size,
      :pool_timeout,
      :conn_max_idle_time,
      :accept_timeout,
      :channel_open_timeout,
      :ssh_connect_timeout,
      :ssh_auth,
      :ssh_verify
    ]

    os_vars = [
      "SORREL_TEST_CONNECT_TIMEOUT",
      "SORREL_TEST_RECEIVE_TIMEOUT",
      "SORREL_TEST_FALLBACK_PRIMARY",
      "SORREL_TEST_BAD_INT"
    ]

    on_exit(fn ->
      Enum.each(app_keys, &Application.delete_env(:sorrel, &1))
      Enum.each(os_vars, &System.delete_env/1)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Representative integer accessor: connect_timeout/1
  # ---------------------------------------------------------------------------

  describe "connect_timeout/1" do
    test "per-call opts override every other source" do
      Application.put_env(:sorrel, :connect_timeout, 8_888)
      System.put_env("SORREL_TEST_CONNECT_TIMEOUT", "7777")
      assert Config.connect_timeout(connect_timeout: 999) === 999
    end

    test "app env wins when no per-call opt" do
      Application.put_env(:sorrel, :connect_timeout, 7_500)
      assert Config.connect_timeout([]) === 7_500
    end

    test "default applies when neither opt nor app env set" do
      Application.delete_env(:sorrel, :connect_timeout)
      assert Config.connect_timeout([]) === 10_000
    end

    test "{:system, var} resolves at runtime and coerces to integer" do
      System.put_env("SORREL_TEST_CONNECT_TIMEOUT", "30000")
      Application.put_env(:sorrel, :connect_timeout, {:system, "SORREL_TEST_CONNECT_TIMEOUT"})
      assert Config.connect_timeout([]) === 30_000
    end

    test "list fallback resolves to the first present value and coerces" do
      System.delete_env("SORREL_TEST_FALLBACK_PRIMARY")

      Application.put_env(
        :sorrel,
        :connect_timeout,
        [{:system, "SORREL_TEST_FALLBACK_PRIMARY"}, "20000"]
      )

      assert Config.connect_timeout([]) === 20_000
    end

    test "raises ArgumentError on unparseable string and surfaces the bad value" do
      System.put_env("SORREL_TEST_BAD_INT", "abc")
      Application.put_env(:sorrel, :connect_timeout, {:system, "SORREL_TEST_BAD_INT"})

      assert_raise ArgumentError, ~r/abc/, fn ->
        Config.connect_timeout([])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Representative integer-or-infinity accessor: receive_timeout/1
  # ---------------------------------------------------------------------------

  describe "receive_timeout/1" do
    test "default is 15_000" do
      Application.delete_env(:sorrel, :receive_timeout)
      assert Config.receive_timeout([]) === 15_000
    end

    test "per-call :infinity passes through unchanged" do
      assert Config.receive_timeout(receive_timeout: :infinity) === :infinity
    end

    test "{:system, var} with integer string coerces to integer" do
      System.put_env("SORREL_TEST_RECEIVE_TIMEOUT", "45000")
      Application.put_env(:sorrel, :receive_timeout, {:system, "SORREL_TEST_RECEIVE_TIMEOUT"})
      assert Config.receive_timeout([]) === 45_000
    end
  end

  # ---------------------------------------------------------------------------
  # Smoke tests: every other resolver-style accessor returns its documented
  # default when nothing is set.
  # ---------------------------------------------------------------------------

  describe "default values for remaining resolver-style accessors" do
    test "pool_size/1 defaults to 10" do
      Application.delete_env(:sorrel, :pool_size)
      assert Config.pool_size([]) === 10
    end

    test "pool_timeout/1 defaults to 5_000" do
      Application.delete_env(:sorrel, :pool_timeout)
      assert Config.pool_timeout([]) === 5_000
    end

    test "conn_max_idle_time/1 defaults to 30_000" do
      Application.delete_env(:sorrel, :conn_max_idle_time)
      assert Config.conn_max_idle_time([]) === 30_000
    end

    test "accept_timeout/1 defaults to 5_000" do
      Application.delete_env(:sorrel, :accept_timeout)
      assert Config.accept_timeout([]) === 5_000
    end

    test "channel_open_timeout/1 defaults to 10_000" do
      Application.delete_env(:sorrel, :channel_open_timeout)
      assert Config.channel_open_timeout([]) === 10_000
    end

    test "ssh_connect_timeout/1 defaults to 10_000" do
      Application.delete_env(:sorrel, :ssh_connect_timeout)
      assert Config.ssh_connect_timeout([]) === 10_000
    end
  end

  # ---------------------------------------------------------------------------
  # Bare-lookup accessors: ssh_auth/0, ssh_verify/0
  # ---------------------------------------------------------------------------

  describe "ssh_auth/0" do
    test "returns nil when nothing is set" do
      Application.delete_env(:sorrel, :ssh_auth)
      assert Config.ssh_auth() === nil
    end

    test "returns the raw value verbatim when set" do
      Application.put_env(:sorrel, :ssh_auth, [:agent])
      assert Config.ssh_auth() === [:agent]
    end

    test "performs no coercion: a string value is returned as-is" do
      # Proves bare-lookup path is wired (would have been parsed/normalized by
      # the resolver path).
      Application.put_env(:sorrel, :ssh_auth, "raw-string")
      assert Config.ssh_auth() === "raw-string"
    end
  end

  describe "ssh_verify/0" do
    test "returns nil when nothing is set" do
      Application.delete_env(:sorrel, :ssh_verify)
      assert Config.ssh_verify() === nil
    end

    test "returns the raw value verbatim when set" do
      Application.put_env(:sorrel, :ssh_verify, :verify_peer)
      assert Config.ssh_verify() === :verify_peer
    end

    test "performs no coercion: a string value is returned as-is" do
      Application.put_env(:sorrel, :ssh_verify, "raw-string")
      assert Config.ssh_verify() === "raw-string"
    end
  end
end

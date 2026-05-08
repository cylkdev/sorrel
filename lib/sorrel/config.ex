defmodule Sorrel.Config do
  @moduledoc """
  Configuration helper for Sorrel application.
  """

  @app :sorrel
  @default_user_agent "sorrel/#{Mix.Project.config()[:version]}"
  @default_connect_timeout 10_000
  @default_receive_timeout 15_000
  @default_pool_size 10
  @default_pool_timeout 5_000
  @default_conn_max_idle_time 30_000
  @default_accept_timeout 5_000
  @default_channel_open_timeout 10_000
  @default_ssh_connect_timeout 10_000

  def app, do: @app

  def user_agent(opts) do
    get(opts, :user_agent, @default_user_agent)
  end

  def connect_timeout(opts) do
    case get(opts, :connect_timeout, @default_connect_timeout) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_int!(value)
      value -> value
    end
  end

  def receive_timeout(opts) do
    case get(opts, :receive_timeout, @default_receive_timeout) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_int!(value)
      value -> value
    end
  end

  def pool_size(opts) do
    case get(opts, :pool_size, @default_pool_size) do
      size when is_integer(size) -> size
      size when is_binary(size) -> parse_int!(size)
      value -> value
    end
  end

  def pool_timeout(opts) do
    case get(opts, :pool_timeout, @default_pool_timeout) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_int!(value)
      value -> value
    end
  end

  def conn_max_idle_time(opts) do
    case get(opts, :conn_max_idle_time, @default_conn_max_idle_time) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_int!(value)
      value -> value
    end
  end

  def accept_timeout(opts) do
    case get(opts, :accept_timeout, @default_accept_timeout) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_int!(value)
      value -> value
    end
  end

  def channel_open_timeout(opts) do
    case get(opts, :channel_open_timeout, @default_channel_open_timeout) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_int!(value)
      value -> value
    end
  end

  def ssh_connect_timeout(opts) do
    case get(opts, :ssh_connect_timeout, @default_ssh_connect_timeout) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_int!(value)
      value -> value
    end
  end

  def ssh_auth, do: Application.get_env(@app, :ssh_auth)
  def ssh_verify, do: Application.get_env(@app, :ssh_verify)

  defp parse_int!(text) when is_binary(text) do
    case text |> String.trim() |> Integer.parse() do
      {int, ""} -> int
      _ -> raise ArgumentError, "expected an integer, got: #{inspect(text)}"
    end
  end

  defp get(opts, key, default) do
    opts
    |> source(key)
    |> Kernel.||(default)
    |> lookup(key, opts)
  end

  defp source(opts, key) do
    if Keyword.has_key?(opts, key) do
      Keyword.fetch!(opts, key)
    else
      Application.get_env(@app, key)
    end
  end

  defp lookup(value, key, opts) do
    value
    |> List.wrap()
    |> Enum.find_value(&resolve(&1, key, opts))
  end

  defp resolve(value, _key, _opts) when is_binary(value) and value !== "", do: value

  defp resolve({:system, env_var}, _key, _opts) do
    env_var |> System.get_env() |> normalize()
  end

  defp resolve(value, _key, _opts), do: normalize(value)

  defp normalize(nil), do: nil
  defp normalize(""), do: nil
  defp normalize(value) when is_binary(value), do: trim_or_nil(String.trim(value))
  defp normalize(value), do: value

  defp trim_or_nil(""), do: nil
  defp trim_or_nil(value), do: value
end

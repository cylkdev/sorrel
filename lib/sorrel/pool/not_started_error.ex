defmodule Sorrel.Pool.NotStartedError do
  @moduledoc """
  An exception that signals `Sorrel.Pool.checkout/3` tried to use
  a pool that has gone away.

  `Pool.checkout/3` lazily starts a pool on first use, so this
  exception is rare in practice - it is raised when a pool race is
  lost (the registry entry was cleared between lookup and checkout).
  The recovery is the same as before: call `Sorrel.Pool.start/2`
  for the endpoint and retry `checkout/3`.

  ## Fields

    * `:endpoint` - the `Sorrel.Endpoint` struct that was passed to
      `checkout/3`. Useful when a single function may talk to many
      endpoints and you need to know which one was missing.
    * `:message` - a human-readable explanation, including a pretty-
      printed copy of the endpoint and the recommended fix.

  ## When the exception is raised

      iex> ep = %Sorrel.Endpoint{transport: :unix, socket_path: "/tmp/myapp.sock"}
      iex> Sorrel.Pool.checkout(ep, fn _worker -> :ok end)
      ** (Sorrel.Pool.NotStartedError) No pool started for endpoint:

        %Sorrel.Endpoint{transport: :unix, socket_path: "/tmp/myapp.sock", ...}

      Call Sorrel.Pool.start(endpoint, opts) before Sorrel.Pool.checkout/3.

  ## Recovering

      try do
        Sorrel.Pool.checkout(endpoint, fn worker -> ... end)
      rescue
        Sorrel.Pool.NotStartedError ->
          {:ok, _name} = Sorrel.Pool.start(endpoint)
          Sorrel.Pool.checkout(endpoint, fn worker -> ... end)
      end

  In normal use, you do not need to catch this - `Sorrel.request/4`
  and `Sorrel.stream/4` call `Pool.start/2` themselves before any
  `checkout/3`. You will only see this exception if you are using
  `Pool.checkout/3` directly.
  """

  defexception [:endpoint, :message]

  @type t :: %__MODULE__{endpoint: Sorrel.Endpoint.t(), message: String.t()}

  @doc """
  Builds the exception struct from a keyword list carrying the offending
  endpoint.

  This is the callback Elixir invokes when you write
  `raise Sorrel.Pool.NotStartedError, endpoint: ep`. You normally
  do not call it directly - `Sorrel.Pool.checkout/3` raises the
  exception itself.

  ## Parameters

    * `opts` - `keyword()`. Must contain the key `:endpoint`. Anything
      else is ignored.

  ## Returns

  A `%Sorrel.Pool.NotStartedError{}` struct with `:endpoint` set to
  the value from `opts` and `:message` set to a human-readable
  multi-line string.

  ## Raises

    * `KeyError` - if `opts` does not contain the `:endpoint` key.

  ## Examples

      iex> ep = %Sorrel.Endpoint{transport: :unix, socket_path: "/tmp/myapp.sock"}
      iex> e = Sorrel.Pool.NotStartedError.exception(endpoint: ep)
      iex> e.endpoint == ep
      true
      iex> String.starts_with?(e.message, "No pool started for endpoint:")
      true
  """
  @impl true
  @spec exception(keyword()) :: t()
  def exception(opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)

    %__MODULE__{
      endpoint: endpoint,
      message: """
      No pool started for endpoint:

        #{inspect(endpoint)}

      Call Sorrel.Pool.start(endpoint, opts) before Sorrel.Pool.checkout/3.
      """
    }
  end
end

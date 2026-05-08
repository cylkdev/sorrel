defmodule Sorrel.Pool.ConnectError do
  @moduledoc """
  Carried out of `NimblePool.checkout!/4` when a worker fails to open
  its underlying connection during checkout.

  `Sorrel.Pool.checkout/3` catches this exception and surfaces the
  underlying reason (e.g. `:econnrefused`, `:enoent`, `%Mint.TransportError{}`)
  to the caller as `{:error, reason}`. Tests and callers should not see
  this exception directly; it exists so that NimblePool's `{:skip, exception, _}`
  return shape can carry the connect failure across the pool boundary.

  ## Fields

    * `:reason` - the underlying transport reason returned by
      `Sorrel.Transport.connect/2`.
  """

  defexception [:reason, :message]

  @type t :: %__MODULE__{reason: term(), message: String.t()}

  @impl true
  @spec exception(keyword()) :: t()
  def exception(opts) when is_list(opts) do
    reason = Keyword.fetch!(opts, :reason)
    %__MODULE__{reason: reason, message: "connect failed: #{inspect(reason)}"}
  end
end

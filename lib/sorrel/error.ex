defmodule Sorrel.Error do
  @moduledoc """
  An exception that signals a streaming HTTP response failed partway
  through.

  When you call `Sorrel.stream/4` and the server returns a 2xx
  status, you get back a lazy `Stream`. The bytes do not arrive yet - they
  arrive as you walk the stream with `Enum.*` or `Stream.*`. If the
  network drops, the server closes the socket, or a chunk arrives that the
  decoder cannot make sense of, that failure is **raised** as a
  `Sorrel.Error` while the caller is iterating. There is nowhere to
  return an error tuple to: the iteration is already in flight.

  ## Fields

    * `:reason` - the underlying cause. Comes straight through from the
      transport or decoder. Common values:

      | Value                              | What it means                                                                                       |
      | ---------------------------------- | --------------------------------------------------------------------------------------------------- |
      | `:closed`                          | The peer closed the connection in the middle of the response.                                       |
      | `:timeout`                         | A receive operation took longer than the configured `:receive_timeout`.                             |
      | `%Mint.TransportError{...}`        | A lower-level transport error (TCP reset, broken pipe, TLS alert).                                  |
      | `%JSON.DecodeError{...}`           | The stream is in `:ndjson` mode and a complete line was not valid JSON.                             |

    * `:message` - a human-readable string. Always begins with
      `"Sorrel stream failed: "` followed by `inspect(reason)`. For example:

          "Sorrel stream failed: :closed"
          "Sorrel stream failed: %Mint.TransportError{reason: :timeout}"

      Read this for logs and crash reports. Use `:reason` for control
      flow, since it is a stable Elixir term and `:message` is just text.

  ## Catching it

      {:ok, stream} = Sorrel.stream(:get, "/events", nil, endpoint: ep, into: :ndjson)

      try do
        Enum.each(stream, fn event -> handle(event) end)
      rescue
        e in Sorrel.Error ->
          case e.reason do
            :closed  -> Logger.warning("server hung up")
            :timeout -> Logger.warning("no events for too long")
            other    -> Logger.error("stream failed: \#{inspect(other)}")
          end
      end

  ## When this exception is **not** raised

    * The non-streaming `Sorrel.request/4` returns errors as
      `{:error, reason}` tuples. It does not raise this exception.
    * Errors that happen *before* `stream/4` returns (the connect failed,
      the response status was non-2xx, the headers never arrived) are
      returned as `{:error, _}` from `stream/4` itself. By the time you
      hold a stream value in your hand, the response head was good.
    * Calling `Stream.take/2` and discarding the rest is a clean
      cancellation, not a failure. No exception is raised in that case.
  """

  defexception [:reason, :message]

  @type t :: %__MODULE__{reason: term(), message: String.t()}

  @doc """
  Builds the exception struct from a reason term.

  This is the callback Elixir invokes when you write
  `raise Sorrel.Error, reason`. You normally do not call it
  directly.

  ## Parameters

    * `reason` - `term()`. Any Elixir value. Whatever you pass becomes
      `e.reason` and is also embedded in `e.message` via `inspect/1`.

  ## Returns

  A `%Sorrel.Error{}` struct with both fields filled in:

    * `:reason` is the term you passed.
    * `:message` is the string `"Sorrel stream failed: \#{inspect(reason)}"`.

  This function never raises.

  ## Examples

      iex> e = Sorrel.Error.exception(:closed)
      iex> e.reason
      :closed
      iex> e.message
      "Sorrel stream failed: :closed"
  """
  @impl true
  @spec exception(term()) :: t()
  def exception(reason) do
    %__MODULE__{reason: reason, message: "Sorrel stream failed: \#{inspect(reason)}"}
  end
end

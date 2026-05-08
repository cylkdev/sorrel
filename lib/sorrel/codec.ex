defmodule Sorrel.Codec do
  @moduledoc """
  A pair of small helpers that turn Elixir values into request bytes and
  raw response bytes back into Elixir values.

  Think of the codec as the "translator" between Sorrel's HTTP layer and
  Elixir-friendly shapes like `%{"key" => "value"}` JSON or NDJSON event
  streams. `Sorrel.request/4` and `Sorrel.stream/4` already
  call into this module on your behalf - most callers never touch it
  directly.

  ## When you would call this module yourself

    * You are wiring up your own HTTP loop on top of `Sorrel.Transport`
      and `Sorrel.Conn` and want consistent body encoding and decoding.
    * You are testing: building expected request bytes for an assertion,
      or simulating a chunked response decode.

  ## What it does

    * `encode/1` - accepts the four `Sorrel.body()` shapes (a binary,
      `nil`, `{:json, term}`, `{:tar, iodata}`) and returns a
      `{bytes, headers}` pair. The `headers` are a list of
      `{name, value}` strings carrying any content-type the encoding
      implies.
    * `decode_body/3` - accepts a complete response body as a binary, an
      `:into` mode (`:auto`, `:json`, or `:raw`), and the response
      headers, and returns whatever Elixir value the mode produces.
    * `decode_chunk/3` - accepts one piece of a streaming body, plus a
      `buffer` carried over from the previous call, plus an `:into` mode
      (`:ndjson` or `:raw`), and returns
      `{events_completed_so_far, leftover_buffer}`.

  ## A short example, end to end

      iex> {bytes, headers} = Sorrel.Codec.encode({:json, %{ok: true}})
      iex> bytes
      ~s({"ok":true})
      iex> headers
      [{"content-type", "application/json"}]

      iex> Sorrel.Codec.decode_body(
      ...>   ~s({"ok":true}),
      ...>   :auto,
      ...>   [{"content-type", "application/json"}]
      ...> )
      %{"ok" => true}
  """

  # What this module does:
  #   Stateless. Maps (body, content-type, into) into encoded iodata or
  #   decoded terms. No process state, no side effects, no I/O.
  #
  # Rules that always hold:
  #   1. encode/1 always returns {iodata, [{"content-type", _}, ...]} or
  #      {iodata, []} (when no encoding is implied).
  #   2. decode_body/3 with :raw returns the input binary unchanged.

  # Types are owned by `Sorrel`; this module references them so the
  # main entry and the codec stay in lockstep.

  @doc """
  Returns a `{bytes, headers}` pair ready to be put on the wire as an HTTP
  request body.

  Use this whenever you have a body in one of the four shapes Sorrel
  accepts and you need both the raw bytes to send *and* the content-type
  header (if any) that describes them.

  ## Parameters

    * `body` - `Sorrel.body()`. One of these four shapes:

      | Shape                 | Bytes returned                                 | Header returned                                  |
      | --------------------- | ---------------------------------------------- | ------------------------------------------------ |
      | `nil`                 | `""` (empty)                                   | `[]` (none)                                      |
      | a binary like `"hi"`  | the binary, sent unchanged                     | `[]` (none - caller adds one if needed)          |
      | an iolist             | the iolist, sent unchanged                     | `[]` (none - caller adds one if needed)          |
      | `{:json, term}`       | `term` encoded as JSON                         | `[{"content-type", "application/json"}]`         |
      | `{:tar, iodata}`      | the iodata, sent unchanged                     | `[{"content-type", "application/x-tar"}]`        |

      The "iolist" case accepts any nested list of binaries and integers
      in the 0..255 range. Validation is shallow - Sorrel does not walk
      every element. Bad iolists fail later, when Mint tries to send
      them.

    * `opts` - `keyword()`. Optional. Currently used only by the
      `{:json, term}` shape:

        * `opts[:json][:protocol_encode]` - a 2-arity function used to
          encode each term reachable from `term` to JSON. Defaults to
          `&JSON.protocol_encode/2`. Override this to support structs
          or other custom shapes that do not implement the default
          JSON protocol.

      Any other shape ignores `opts`.

  ## Returns

  A two-element tuple `{iodata, headers}`:

    * `iodata` - exactly what should go on the wire as the request body.
      Empty string for `nil`. The original bytes for raw iodata or `:tar`.
      A JSON-encoded binary for `:json`.
    * `headers` - a list of `{name, value}` string tuples. Empty for `nil`
      and raw iodata. A single content-type entry for `:json` and `:tar`.

  Header names are always lowercase. The list never contains anything
  other than the content-type derived from the body shape.

  ## Raises

    * `Protocol.UndefinedError` - when `body` is `{:json, term}` and
      `term` contains a value Elixir's JSON protocol cannot encode (a
      pid, port, reference, or struct that does not implement the JSON
      protocol). The exception comes straight through from `JSON.encode!/1`.

  ## Examples

      # No body - sends nothing, no extra headers:
      iex> Sorrel.Codec.encode(nil)
      {"", []}

      # A plain binary - sent as-is, no implied content-type:
      iex> Sorrel.Codec.encode("plain")
      {"plain", []}

      # JSON shape - encoded and tagged with the right content-type:
      iex> Sorrel.Codec.encode({:json, %{ok: true}})
      {~s({"ok":true}), [{"content-type", "application/json"}]}

      # Tarball shape - tagged but bytes pass through verbatim:
      iex> Sorrel.Codec.encode({:tar, "...tarbytes..."})
      {"...tarbytes...", [{"content-type", "application/x-tar"}]}

      # An iolist - also passes through verbatim:
      iex> Sorrel.Codec.encode(["hello", " ", "world"])
      {["hello", " ", "world"], []}
  """
  @spec encode(Sorrel.body(), keyword()) :: {iodata(), [{String.t(), String.t()}]}
  def encode(body, opts \\ [])
  def encode(nil, _opts), do: {"", []}

  def encode({:json, term}, opts) do
    encoder = opts[:json][:protocol_encode] || (&JSON.protocol_encode/2)
    {JSON.encode!(term, encoder), [{"content-type", "application/json"}]}
  end

  def encode({:tar, data}, _opts), do: {data, [{"content-type", "application/x-tar"}]}
  # `is_binary or is_list` is an approximate guard for `iodata()`. It accepts
  # binaries, iolists, the empty list, and chardata - all valid iodata. It
  # also accepts a few invalid lists (e.g. `[1.5]`); Mint will reject those
  # at send time. We do not try to validate iodata structurally because
  # iolists are recursive and a deep walk would change semantics from "pass
  # bytes through" to "consume bytes here".
  def encode(iodata, _opts) when is_binary(iodata) or is_list(iodata), do: {iodata, []}

  @doc """
  Returns the response body decoded into the Elixir shape requested by
  `into`.

  Use this when you have already received the full response body as a
  binary and want a friendlier value to hand back to a caller - a map for
  JSON, the bytes themselves for opaque payloads.

  ## Parameters

    * `body` - `binary()`. The complete response body. Streamed responses
      are not supported here; for those, use `decode_chunk/3`.

    * `into` - `Sorrel.into()`. One of:

      | Mode    | What you get back                                                                                                  |
      | ------- | ------------------------------------------------------------------------------------------------------------------ |
      | `:auto` | A map/list (decoded JSON) when the response headers say `Content-Type: application/json`, else the original bytes. |
      | `:json` | A map/list. Always tries to JSON-decode, even when the headers do not say JSON.                                    |
      | `:raw`  | The original bytes, untouched.                                                                                     |

      The `:auto` JSON detection is case-insensitive and matches when any
      `Content-Type` header value contains the substring
      `application/json` (so `application/json; charset=utf-8` counts).

    * `headers` - `list()` of `{name, value}` string tuples. Used only by
      `:auto`. Pass `[]` if you do not have headers and you are using
      `:json` or `:raw`.

  ## Returns

  The decoded value. Its shape depends on `into` and the body:

    * `:raw` - always the input binary, unchanged. Same length, same bytes.
    * `:json` - whatever `JSON.decode!/1` returns: a map, list, string,
      number, boolean, or `nil`.
    * `:auto` - same as `:json` when the headers say JSON; same as `:raw`
      otherwise.

  ## Raises

    * `JSON.DecodeError` - for `:json` whenever the body is not valid
      JSON, and for `:auto` when the headers say JSON but the body is
      malformed. `:raw` never raises.

  ## Examples

      # :auto with JSON headers - decoded to a map:
      iex> Sorrel.Codec.decode_body(
      ...>   ~s({"a":1}),
      ...>   :auto,
      ...>   [{"content-type", "application/json"}]
      ...> )
      %{"a" => 1}

      # :auto with non-JSON headers - bytes pass through:
      iex> Sorrel.Codec.decode_body("hello", :auto, [{"content-type", "text/plain"}])
      "hello"

      # :raw - bytes pass through no matter what the headers say:
      iex> Sorrel.Codec.decode_body("hello", :raw, [])
      "hello"

      # :json - decoded even with no headers:
      iex> Sorrel.Codec.decode_body(~s([1, 2, 3]), :json, [])
      [1, 2, 3]
  """
  @spec decode_body(binary(), Sorrel.into(), list()) :: term()
  def decode_body(body, into, headers)

  def decode_body(body, :raw, _headers) when is_binary(body), do: body
  def decode_body(body, :json, _headers) when is_binary(body), do: JSON.decode!(body)

  def decode_body(body, :auto, headers) when is_binary(body) do
    if json_content_type?(headers) do
      JSON.decode!(body)
    else
      body
    end
  end

  @doc """
  Returns the events finished by the new chunk plus the bytes that did not
  yet form a complete event.

  Use this when bytes arrive one piece at a time - for example from a
  long-running event endpoint that sends one JSON object per line. You
  call this once per arriving chunk, threading the leftover buffer
  through. `Sorrel.stream/4` does this for you under the covers.

  ## Parameters

    * `chunk` - `binary()`. The newly arrived bytes. May be empty.
    * `buffer` - `binary()`. Whatever was returned as `leftover_buffer`
      from the previous call. Pass `""` on the very first call.
    * `into` - `:ndjson | :raw`. The streaming decode mode:

      | Mode      | How the bytes are split                                                                                                                     | Events yielded                                                                              |
      | --------- | ------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
      | `:ndjson` | The combined `buffer <> chunk` is split on the newline character `"\\n"`. Empty lines and whitespace-only lines are dropped before decoding. | One event per non-empty line, where each event is the result of JSON-decoding that line.   |
      | `:raw`    | No splitting at all.                                                                                                                        | One event per non-empty chunk: the chunk itself, as a binary. Empty chunks yield nothing.   |

  ## Returns

  A two-element tuple `{events, leftover_buffer}`:

    * `events` - `list()`. The events that finished arriving in this call,
      in the order they arrived. May be empty if no full event has yet
      arrived. For `:ndjson`, each element is the decoded JSON value
      (typically a map). For `:raw`, each element is a binary - usually
      a single one per call.
    * `leftover_buffer` - `binary()`. The trailing bytes that did not
      form a complete event. For `:ndjson`, this is whatever came after
      the last `"\\n"`. For `:raw`, this is always `""`. Pass it back as
      `buffer` on the next call.

  ## Raises

    * `JSON.DecodeError` - for `:ndjson` when a complete line is not
      valid JSON.

  ## Examples

      # :ndjson - two complete events, no leftover:
      iex> Sorrel.Codec.decode_chunk(~s({"a":1}\\n{"b":2}\\n), "", :ndjson)
      {[%{"a" => 1}, %{"b" => 2}], ""}

      # :ndjson - one complete event, partial line saved for the next call:
      iex> Sorrel.Codec.decode_chunk(~s({"a":1}\\n{"b), "", :ndjson)
      {[%{"a" => 1}], ~s({"b)}

      # :ndjson - buffer threading across two calls. The first call
      # returns the partial; the second call concatenates and finishes it:
      iex> {[], leftover} = Sorrel.Codec.decode_chunk(~s({"a), "", :ndjson)
      iex> Sorrel.Codec.decode_chunk(~s(":1}\\n), leftover, :ndjson)
      {[%{"a" => 1}], ""}

      # :raw - chunks pass through one event each, no buffering:
      iex> Sorrel.Codec.decode_chunk("hello", "", :raw)
      {["hello"], ""}

      iex> Sorrel.Codec.decode_chunk("", "", :raw)
      {[], ""}
  """
  @spec decode_chunk(binary(), binary(), :ndjson | :raw) :: {list(), binary()}
  def decode_chunk(chunk, buffer, into)

  def decode_chunk(chunk, buffer, :ndjson) when is_binary(chunk) and is_binary(buffer) do
    # Match-first to avoid splitting and allocating a parts list when no
    # line boundary has arrived yet. The buffer-flatten copy is unavoidable
    # - the next call needs a single contiguous binary - but skipping the
    # split + per-line trim/reject pipeline matters on chunks that arrive
    # one TCP packet at a time mid-line.
    parts =
      case :binary.match(chunk, "\n") do
        :nomatch -> [<<buffer::binary, chunk::binary>>]
        _ -> :binary.split(<<buffer::binary, chunk::binary>>, "\n", [:global])
      end

    {complete, [leftover]} = Enum.split(parts, -1)

    # Single reduce: trim + reject empty + decode in one pass, prepending
    # to the accumulator (O(1)) and reversing once at the end.
    events =
      complete
      |> Enum.reduce([], fn line, acc ->
        case String.trim(line) do
          "" -> acc
          trimmed -> [JSON.decode!(trimmed) | acc]
        end
      end)
      |> Enum.reverse()

    {events, leftover}
  end

  def decode_chunk(chunk, _buffer, :raw) when is_binary(chunk) do
    case chunk do
      "" -> {[], ""}
      bytes -> {[bytes], ""}
    end
  end

  defp json_content_type?(headers) do
    Enum.any?(headers, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        String.downcase(name) === "content-type" and
          String.contains?(String.downcase(value), "application/json")

      _ ->
        false
    end)
  end
end

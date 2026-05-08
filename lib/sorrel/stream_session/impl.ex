defmodule Sorrel.StreamSession.Impl do
  @moduledoc """
  The pure logic that drives a `Sorrel.StreamSession`, kept
  separate from the live `GenServer` shell so it can be tested as plain
  functions.

  This module owns four jobs:

    * On startup, open a connection, send the request, and read the
      response status and headers (the "head") synchronously so the
      caller can see whether the response was 2xx before the server
      starts streaming bytes.
    * On a 2xx response, switch the underlying socket into active mode
      and prepare to receive event chunks as Erlang messages.
    * As bytes arrive, decode them according to the chosen `:into` mode
      (`:ndjson` or `:raw`), enqueue completed events, and if a caller
      is parked waiting for an event, hand them one immediately.
    * When the server closes the response, mark the stream as closed
      and clean up.

  No `GenServer` behaviour is mixed in here. Every function takes the
  state map (or parts of it) explicitly and returns the next state plus
  a `GenServer`-shaped reply tuple. The live `GenServer` shell -
  `Sorrel.StreamSession` - wires these pure functions to its
  callbacks.

  ## State shape

      %{
        conn:         nil | %Mint.HTTP1{...},   # the live connection, or nil after teardown
        ref:          reference() | nil,         # the Mint request reference for this response
        into:         :ndjson | :raw,            # decode mode for arriving chunks
        buffer:       binary(),                  # bytes received but not yet forming a complete event
        queue:        :queue.queue(),            # decoded events ready to be delivered
        waiter:       nil | GenServer.from(),    # a caller parked in recv/2, if any
        closed?:      boolean(),                 # has the server signalled end-of-response?
        conn_closed?: boolean(),                 # has the conn already been closed (e.g. on init for a fast 2xx)?
        args:         keyword()                  # original args from start_link/1, kept for retries and option lookups
      }

  ## Why the order in `init/1` is so strict

  Mint's `:passive` mode lets you read response bytes by calling
  `Mint.HTTP.recv/3`. Mint's `:active` mode delivers them as
  `:tcp` / `:ssl` messages to the owning process's mailbox. The
  initial `init/1` reads the response head with `recv` (passive), then
  switches the socket into active mode just before returning. If the
  switch happens before the head has been fully read, the head bytes
  are stuck in the mailbox and `recv` hangs.
  """

  # What each field means:
  #   `:conn`    - the live `Mint.HTTP.t()`, or `nil` after teardown.
  #   `:ref`     - the Mint request reference identifying the in-flight
  #                response. `nil` until the request is sent.
  #   `:into`    - decode mode for arriving chunks. `:ndjson` splits on
  #                newlines and JSON-decodes each line; `:raw` yields each
  #                chunk as a binary.
  #   `:buffer`  - bytes received but not yet a complete event. Carried
  #                across calls to `decode_chunk/3`.
  #   `:queue`   - `:queue.queue/0` of decoded events ready to deliver.
  #   `:waiter`  - `from` of a `recv/2` caller blocked waiting for the
  #                next event. At most one waiter at a time.
  #   `:closed?` - whether the server has signalled end-of-response.
  #
  # Rules that always hold:
  #   1. Events leave the queue in arrival order.
  #   2. After `closed?` becomes true, no further events are added to
  #      the queue except a possible final tail decoded from leftover
  #      buffer bytes.
  #   3. At most one waiter is parked at any time (`recv/2` is
  #      serialised by the GenServer mailbox).

  alias Sorrel.Codec
  alias Sorrel.Transport

  @type state :: %{
          conn: nil | Mint.HTTP.t(),
          ref: reference() | nil,
          into: :ndjson | :raw,
          buffer: binary(),
          queue: :queue.queue(),
          waiter: nil | GenServer.from(),
          closed?: boolean(),
          conn_closed?: boolean(),
          error: nil | term(),
          args: keyword()
        }

  @doc """
  Returns the initial state of the streaming server, after opening the
  connection, sending the request, and reading the response head.

  Called from the live `GenServer.init/1` callback. Synchronous -
  blocks until the response status and headers have been read or an
  error has occurred. After this function returns `{:ok, state}`, the
  underlying socket is in active mode and chunk messages will start
  arriving in the owning process's mailbox.

  ## Parameters

    * `args` - `keyword()`. Required keys:

      | Key         | Type                                | What it is                                                                |
      | ----------- | ----------------------------------- | ------------------------------------------------------------------------- |
      | `:endpoint` | `Sorrel.Endpoint.t()`         | Where to connect.                                                          |
      | `:method`   | `String.t()` (uppercase)            | HTTP method, e.g. `"GET"` or `"POST"`.                                     |
      | `:path`     | `String.t()`                        | Request path including query string.                                       |
      | `:into`     | `:ndjson | :raw`                    | How to decode arriving chunks.                                             |

      Optional keys:

      | Key                | Type                                | Default     | What it does                                                  |
      | ------------------ | ----------------------------------- | ----------- | ------------------------------------------------------------- |
      | `:headers`         | `list()` of `{name, value}` tuples  | `[]`         | Extra request headers.                                        |
      | `:body`            | `iodata()`                          | `""`         | Request body.                                                 |
      | `:connect_timeout` | `non_neg_integer()`                 | `10_000`     | Milliseconds to wait for the TCP/TLS handshake.                |
      | `:receive_timeout` | `non_neg_integer()` or `:infinity`  | `15_000`     | Milliseconds to wait per receive while reading the response head. |

  ## Returns

    * `{:ok, state}` - the response status was in 200..299 and the
      server is ready to deliver decoded events. The state's
      `:conn` is the live connection (now in active mode), `:ref` is
      Mint's request reference, `:queue` may already contain events
      decoded from any chunks that arrived during head drain, and
      `:closed?` may already be true if the server sent the entire
      response head and end-of-message in one go.

    * `{:stop, {:non_2xx, response}}` - the response status was outside
      200..299. `response` is a complete `%{status: integer, headers:
      list, body: term}` map with the body decoded according to
      `:into`. The connection has been closed by the time this is
      returned. Callers (notably `Sorrel.stream/4`) translate
      this stop reason into an `{:error, response}` tuple.

    * `{:stop, reason}` - a transport or protocol error happened
      before the response head was fully received. Common reasons:
      `:econnrefused`, `:enoent`, `:timeout`, `{:tls_alert, _}`,
      `%Mint.TransportError{...}`. Any partially-opened connection
      has been closed.

  ## Raises

    * `KeyError` - if any of the required keys (`:endpoint`,
      `:method`, `:path`, `:into`) is missing from `args`.
  """
  @spec init(keyword()) :: {:ok, state()} | {:stop, term()}
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def init(args) when is_list(args) do
    # Order matters: connect passive -> send request -> drain head with passive
    # Mint.HTTP.recv -> ONLY THEN set_mode :active -> return from init.
    # In active mode, Mint.HTTP.recv/3 stops working because chunks are
    # delivered as :tcp/:ssl messages instead. Switching modes too early
    # makes drain_head_passive/3 silently hang.
    endpoint = Keyword.fetch!(args, :endpoint)
    method = Keyword.fetch!(args, :method)
    path = Keyword.fetch!(args, :path)
    into = Keyword.fetch!(args, :into)
    headers = Keyword.get(args, :headers, [])
    body = Keyword.get(args, :body, "")
    connect_timeout = Sorrel.Config.connect_timeout(args)
    receive_timeout = Sorrel.Config.receive_timeout(args)

    with {:ok, conn} <-
           Transport.connect(endpoint, mode: :passive, connect_timeout: connect_timeout),
         {:ok, conn, ref} <- Mint.HTTP.request(conn, method, path, headers, body),
         {:ok, %{status: status, headers: response_headers}, conn, body_buf, done?} <-
           drain_head_passive(conn, ref, receive_timeout, args) do
      if status in 200..299 do
        on_2xx(conn, ref, into, body_buf, done?, args)
      else
        non_2xx_ctx = %{
          conn: conn,
          ref: ref,
          into: into,
          response_headers: response_headers,
          status: status,
          body_buf: body_buf,
          done?: done?,
          receive_timeout: receive_timeout
        }

        on_non_2xx(non_2xx_ctx, args)
      end
    else
      {:error, reason} -> {:stop, reason}
      {:error, reason, _conn} -> {:stop, reason}
    end
  end

  @doc """
  Decides what to reply to a `recv/2` call: an event, end-of-stream, or
  "wait - I'll send it later".

  Called from the live `GenServer.handle_call/3` callback for `:recv`.

  ## Parameters

    * `state` - the current server state map.
    * `from` - the `GenServer.from()` of the caller. If the call has
      to be parked (no event ready yet), this is stored in the state
      as `:waiter` and used later by `handle_transport_message/2` to
      reply when an event arrives.

  ## Returns

  Returns one of three `GenServer`-shaped tuples:

    * `{:reply, {:ok, event}, new_state}` - there was at least one
      event in the queue. The reply is the head of the queue; the
      new state has that event removed.

    * `{:reply, :end, state}` - the queue is empty *and* the stream
      has been closed by the server. The state is unchanged.

    * `{:noreply, new_state}` - the queue is empty and the stream is
      still open. The caller is parked: `new_state.waiter` is set to
      `from`. The reply will be sent later by
      `handle_transport_message/2` when an event arrives or the
      stream closes. At most one caller can be parked at a time -
      `recv/2` calls are serialised by the GenServer mailbox.

  This function does not raise.
  """
  @spec handle_recv(state(), GenServer.from()) ::
          {:reply, term(), state()} | {:noreply, state()}
  def handle_recv(%{queue: q, closed?: closed?, error: error} = state, from) do
    case :queue.out(q) do
      {{:value, event}, rest} ->
        {:reply, {:ok, event}, %{state | queue: rest}}

      {:empty, _empty_q} when not is_nil(error) ->
        # A previous transport error was deferred (no waiter at the
        # time). Serve it now and stop with `:normal` so the linked
        # consumer can convert the reply into a `raise` without an
        # EXIT signal interrupting it.
        _ = from
        {:stop, :normal, {:error, error}, state}

      {:empty, _empty_q} when closed? ->
        {:reply, :end, state}

      {:empty, _empty_q} ->
        {:noreply, %{state | waiter: from}}
    end
  end

  @doc """
  Processes one Erlang message from the active-mode socket and returns
  the next state plus the appropriate `GenServer` reply tuple.

  Called from the live `GenServer.handle_info/2` callback whenever the
  process's mailbox receives a `:tcp`, `:ssl`, `:tcp_closed`,
  `:ssl_closed`, `:tcp_error`, or `:ssl_error` message. Other messages
  are ignored.

  ## Parameters

    * `state` - the current server state map.
    * `msg` - any Erlang term from the mailbox. Tuples whose first
      element is one of the transport tags listed above are decoded;
      everything else is left untouched.

  ## Returns

  Returns one of two `GenServer`-shaped tuples:

    * `{:noreply, new_state}` - the message has been processed.
      Possible side effects baked into `new_state`:

      | What happened                                   | Effect on `new_state`                                                                          |
      | ----------------------------------------------- | ---------------------------------------------------------------------------------------------- |
      | New chunk arrived; produced one or more events  | Events appended to `:queue`. If a waiter was parked, the head event is delivered via `GenServer.reply/2` and the waiter slot is cleared. |
      | New chunk arrived; no complete event yet        | The bytes are appended to `:buffer`; the queue is unchanged.                                   |
      | The server signalled end-of-response            | `:closed?` becomes `true`. Any leftover-buffer event is decoded and queued. If a waiter is parked and the queue is now empty, the waiter is replied `:end`. |
      | The message was for a different request ref     | State unchanged.                                                                               |
      | The message tag was unknown to Mint             | State unchanged.                                                                               |

    * `{:stop, reason, new_state}` - a transport-level failure
      happened (Mint returned an error tuple from
      `Mint.HTTP.stream/2`). The connection is closed in `new_state`.
      If a waiter is parked, the failure is replied to them as
      `{:error, reason}` so consumers see the same reason that the
      `GenServer` exits with. Common reasons: `:closed`, `:timeout`,
      `%Mint.TransportError{...}`.

  This function does not raise.
  """
  @spec handle_transport_message(state(), term()) ::
          {:noreply, state()} | {:stop, term(), state()}
  def handle_transport_message(state, msg)
      when elem(msg, 0) in [:tcp, :ssl, :tcp_closed, :ssl_closed, :tcp_error, :ssl_error] do
    case Mint.HTTP.stream(state.conn, msg) do
      {:ok, conn, responses} ->
        on_responses(state, conn, responses, state.args)

      {:error, conn, error, _responses} ->
        on_transport_error(state, conn, error, state.args)

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_transport_message(state, _other_msg) do
    {:noreply, state}
  end

  @doc """
  Closes the underlying connection if there is one and returns `:ok`.

  Called from the live `GenServer.terminate/2` callback before the
  process exits. Safe to call when `state.conn` is `nil`.

  ## Parameters

    * `state` - the current server state map.

  ## Returns

  `:ok`. Always.
  """
  @spec terminate(state()) :: :ok
  def terminate(%{conn: nil}) do
    :ok
  end

  def terminate(%{conn_closed?: true}) do
    # The conn was already closed earlier in the lifecycle (e.g. on_2xx with
    # done? = true). Closing a Mint conn twice is currently tolerated but
    # not contractual; skipping the second close avoids relying on that.
    :ok
  end

  def terminate(%{conn: conn}) do
    _ = safe_close(conn)
    :ok
  end

  # Best-effort `Mint.HTTP.close/1`. Mint documents `{:ok, conn}` as the
  # only return, but the underlying socket may already be torn down by
  # the kernel, in which case Mint can return `{:error, _}` or raise.
  # An assertive match here would crash terminate/2 and propagate an
  # abnormal exit to the linked consumer; that's worth avoiding for a
  # call whose only purpose is releasing OS resources.
  @spec safe_close(Mint.HTTP.t()) :: Mint.HTTP.t()
  defp safe_close(conn) do
    {:ok, closed} = Mint.HTTP.close(conn)
    closed
  rescue
    _ -> conn
  end

  # ---------------------------------------------------------------------------
  # Init helpers
  # ---------------------------------------------------------------------------

  # 2xx + already-done: server closed before we could switch modes. Decode
  # buffered bytes, mark closed, and start in a state that will immediately
  # return :end on first recv/2.
  defp on_2xx(conn, ref, into, body_buf, true = _done?, opts) do
    {events, leftover} = decode_initial_buffer(body_buf, into)
    closed_conn = safe_close(conn)

    {:ok, build_state(closed_conn, ref, into, leftover, events, true, opts, _conn_closed? = true)}
  end

  # 2xx + not done: switch to active mode so chunk arrivals are delivered as
  # :tcp/:ssl messages. Any body bytes that arrived alongside the head are
  # already buffered.
  defp on_2xx(conn, ref, into, body_buf, false = _done?, opts) do
    case Mint.HTTP.set_mode(conn, :active) do
      {:ok, conn} ->
        {events, leftover} = decode_initial_buffer(body_buf, into)
        {:ok, build_state(conn, ref, into, leftover, events, false, opts, _conn_closed? = false)}

      {:error, reason} ->
        _ = safe_close(conn)
        {:stop, reason}
    end
  end

  # Non-2xx: drain whatever body remains in passive mode, decode it, close,
  # and stop with a {:non_2xx, response} reason that `Sorrel.stream/4`
  # converts into {:error, response} for the caller.
  defp on_non_2xx(ctx, opts) do
    {full_body, conn} =
      if ctx.done? do
        {ctx.body_buf, ctx.conn}
      else
        drain_body_passive(ctx.conn, ctx.ref, ctx.body_buf, ctx.receive_timeout, opts)
      end

    decoded = Codec.decode_body(full_body, decode_into_for_body(ctx.into), ctx.response_headers)
    _ = safe_close(conn)
    {:stop, {:non_2xx, %{status: ctx.status, headers: ctx.response_headers, body: decoded}}}
  end

  defp build_state(conn, ref, into, buffer, events, closed?, opts, conn_closed?) do
    %{
      conn: conn,
      ref: ref,
      into: into,
      buffer: buffer,
      queue: events_to_queue(events),
      waiter: nil,
      closed?: closed?,
      conn_closed?: conn_closed?,
      error: nil,
      args: opts
    }
  end

  # Drain status + headers in passive mode. Also captures any early body
  # bytes that arrived in the same recv call.
  defp drain_head_passive(conn, ref, timeout, _opts) do
    drain_head_loop(conn, ref, timeout, %{status: nil, headers: []}, [], false)
  end

  defp drain_head_loop(conn, ref, timeout, head, body_acc, done?, headers_seen? \\ false) do
    case Mint.HTTP.recv(conn, 0, timeout) do
      {:ok, conn, responses} ->
        {head, body_acc, done?, headers_seen?} =
          absorb_head(responses, ref, head, body_acc, done?, headers_seen?)

        complete? = head_complete?(head, done?, headers_seen?)

        cond do
          complete? and (done? or body_acc !== []) ->
            {:ok, head, conn, IO.iodata_to_binary(body_acc), done?}

          complete? ->
            # Head fully received, no body bytes yet - return now so the
            # caller can switch to active mode before any body chunks arrive.
            {:ok, head, conn, "", false}

          true ->
            drain_head_loop(conn, ref, timeout, head, body_acc, done?, headers_seen?)
        end

      {:error, _conn, reason, _responses} ->
        {:error, reason}
    end
  end

  defp absorb_head(responses, ref, head, body_acc, done?, headers_seen?) do
    Enum.reduce(responses, {head, body_acc, done?, headers_seen?}, fn
      {:status, ^ref, status}, {head, body_acc, done?, hs?} ->
        {%{head | status: status}, body_acc, done?, hs?}

      {:headers, ^ref, hs}, {head, body_acc, done?, _hs?} ->
        {%{head | headers: head.headers ++ hs}, body_acc, done?, true}

      {:data, ^ref, chunk}, {head, body_acc, done?, hs?} ->
        {head, [body_acc, chunk], done?, hs?}

      {:done, ^ref}, {head, body_acc, _done?, hs?} ->
        {head, body_acc, true, hs?}

      _other, acc ->
        acc
    end)
  end

  # The head is "complete" once we've seen :done (the rare zero-headers
  # case that never gets a :headers event before close), or once we've
  # seen both a status and at least one :headers event from Mint. Using
  # `headers !== []` here was wrong: a response with zero headers (or
  # one whose :done arrives in a separate Mint recv batch from :headers)
  # would loop until receive_timeout fires.
  defp head_complete?(%{status: status}, done?, headers_seen?) do
    done? or (headers_seen? and not is_nil(status))
  end

  # Drain the rest of a non-2xx body in passive mode after the head has
  # already been read. Returns {full_body_binary, conn}.
  defp drain_body_passive(conn, ref, prefix, timeout, opts) do
    drain_body_loop(conn, ref, timeout, [prefix], opts)
  end

  defp drain_body_loop(conn, ref, timeout, acc, opts) do
    case Mint.HTTP.recv(conn, 0, timeout) do
      {:ok, conn, responses} ->
        {acc, done?} = collect_body_chunks(responses, ref, acc, opts)

        if done? do
          {IO.iodata_to_binary(acc), conn}
        else
          drain_body_loop(conn, ref, timeout, acc, opts)
        end

      {:error, conn, _reason, _responses} ->
        {IO.iodata_to_binary(acc), conn}
    end
  end

  defp collect_body_chunks(responses, ref, acc, _opts) do
    Enum.reduce(responses, {acc, false}, fn
      {:data, ^ref, chunk}, {acc, done?} -> {[acc, chunk], done?}
      {:done, ^ref}, {acc, _done?} -> {acc, true}
      _other, state -> state
    end)
  end

  # If body bytes arrived alongside the head, decode them through the chunk
  # codec. The leftover string becomes the new buffer.
  defp decode_initial_buffer("", _into) do
    {[], ""}
  end

  defp decode_initial_buffer(buffer, into) do
    Codec.decode_chunk(buffer, "", into)
  end

  # ---------------------------------------------------------------------------
  # Active-mode message handling helpers
  # ---------------------------------------------------------------------------

  defp on_responses(state, conn, responses, _opts) do
    {events, new_buffer, done?} =
      consume_responses(responses, state.ref, state.buffer, state.into)

    new_q = enqueue_all(state.queue, events)
    new_state = %{state | conn: conn, queue: new_q, buffer: new_buffer}

    new_state =
      if done? do
        finalise_state_on_done(new_state)
      else
        new_state
      end

    deliver(new_state)
  end

  defp finalise_state_on_done(new_state) do
    # Try one final decode of trailing buffer bytes (e.g. a final ndjson line
    # with no newline). Only emit complete events.
    {tail_events, _leftover} = Codec.decode_chunk(new_state.buffer, "", new_state.into)
    final_q = enqueue_all(new_state.queue, tail_events)
    %{new_state | queue: final_q, buffer: "", closed?: true}
  end

  defp on_transport_error(state, conn, error, _opts) do
    if state.closed? do
      # If the stream already ended cleanly, a subsequent transport-closed
      # message from the peer is benign.
      {:noreply, %{state | conn: conn}}
    else
      new_state = %{state | conn: conn, closed?: true}
      deliver_error(new_state, error)
    end
  end

  # Pulls events out of a list of Mint responses (data + done), updating the
  # decode buffer as we go. Events are accumulated as a list of lists in
  # reverse order and flattened once at the end - appending with `++` per
  # chunk would be O(n²) in the number of decoded events across a batch.
  defp consume_responses(responses, ref, buffer, into) do
    {evs_acc, new_buf, done?} =
      Enum.reduce(responses, {[], buffer, false}, fn
        {:data, ^ref, chunk}, {evs_acc, buf, done?} ->
          {new_evs, new_buf} = Codec.decode_chunk(chunk, buf, into)
          {[new_evs | evs_acc], new_buf, done?}

        {:done, ^ref}, {evs_acc, buf, _done?} ->
          {evs_acc, buf, true}

        _other, acc ->
          acc
      end)

    events = evs_acc |> Enum.reverse() |> List.flatten()
    {events, new_buf, done?}
  end

  defp enqueue_all(queue, events) do
    Enum.reduce(events, queue, &:queue.in(&1, &2))
  end

  defp events_to_queue(events) do
    enqueue_all(:queue.new(), events)
  end

  # If a waiter is waiting and we have an event, deliver one. If a waiter is
  # waiting and the stream is closed and there's nothing left, deliver :end.
  defp deliver(%{waiter: nil} = state) do
    {:noreply, state}
  end

  defp deliver(%{waiter: from, queue: q, closed?: closed?} = state) do
    case :queue.out(q) do
      {{:value, event}, rest} ->
        GenServer.reply(from, {:ok, event})
        {:noreply, %{state | queue: rest, waiter: nil}}

      {:empty, _empty_q} when closed? ->
        GenServer.reply(from, :end)
        {:noreply, %{state | waiter: nil}}

      {:empty, _empty_q} ->
        {:noreply, state}
    end
  end

  # Transport error: surface it to a waiting recv/2 if any, then stop.
  # No consumer is currently blocked on `recv/2`. Defer the error to
  # the consumer's next recv. We do NOT stop with the error as the
  # stop reason - that would deliver an EXIT signal to the linked
  # consumer and bypass the `{:error, _}` branch in
  # `Sorrel.stream/5`'s Stream.resource pull function. Instead,
  # park the error in state; `handle_recv/2` will serve it.
  defp deliver_error(%{waiter: nil} = state, error) do
    {:noreply, %{state | error: error}}
  end

  # A consumer is blocked on `recv/2`. Reply with the error
  # synchronously, then stop with `:normal`. Stopping `:normal` means
  # the consumer's link sees a benign EXIT that does not kill it -
  # giving the just-delivered `{:error, _}` reply time to be
  # processed and turned into a `raise Sorrel.Error` upstream.
  defp deliver_error(%{waiter: from} = state, error) do
    GenServer.reply(from, {:error, error})
    {:stop, :normal, %{state | waiter: nil, error: error}}
  end

  # For non-2xx body decoding the streaming `:into` modes do not all line up
  # with `Codec.decode_body/3` (e.g. `:ndjson`). Map them to the closest
  # one-shot decoder.
  defp decode_into_for_body(:raw) do
    :raw
  end

  defp decode_into_for_body(:ndjson) do
    :raw
  end
end

defmodule Sorrel.StreamSession.ImplTest do
  use ExUnit.Case, async: true

  alias Sorrel.StreamSession.Impl

  defp blank_state(closed?, events, into \\ :ndjson) do
    %{
      conn: nil,
      ref: make_ref(),
      into: into,
      buffer: "",
      queue: events_to_queue(events),
      waiter: nil,
      closed?: closed?,
      conn_closed?: false,
      error: nil
    }
  end

  defp events_to_queue(events) do
    Enum.reduce(events, :queue.new(), &:queue.in(&1, &2))
  end

  describe "handle_recv/2" do
    test "replies with a queued event when one is available" do
      state = blank_state(false, [%{"a" => 1}, %{"b" => 2}])
      from = {self(), make_ref()}

      assert {:reply, {:ok, %{"a" => 1}}, new_state} = Impl.handle_recv(state, from)
      assert :queue.len(new_state.queue) === 1
      assert new_state.waiter === nil
    end

    test "replies :end when queue is empty and stream is closed" do
      state = blank_state(true, [])
      from = {self(), make_ref()}

      assert {:reply, :end, ^state} = Impl.handle_recv(state, from)
    end

    test "parks the waiter when queue is empty and stream is open" do
      state = blank_state(false, [])
      from = {self(), make_ref()}

      assert {:noreply, new_state} = Impl.handle_recv(state, from)
      assert new_state.waiter === from
    end
  end

  describe "handle_transport_message/2" do
    test "ignores non-transport messages" do
      state = blank_state(false, [])

      assert {:noreply, ^state} =
               Impl.handle_transport_message(state, {:not_a_transport_msg, :ok})
    end
  end

  describe "terminate/1" do
    test "is :ok when conn is nil" do
      state = blank_state(false, [])
      assert :ok = Impl.terminate(state)
    end
  end

  describe "init/1" do
    test "stops with a transport-ish reason on missing endpoint required keys" do
      assert_raise KeyError, fn -> Impl.init([]) end
    end
  end
end

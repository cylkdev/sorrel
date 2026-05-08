defmodule Sorrel.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Sorrel.Pool.Registry},
      {DynamicSupervisor, name: Sorrel.Pool.DynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Sorrel.Supervisor)
  end
end

defmodule Arena.Application do
  use Application
  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Arena.PubSub},
      {Registry, keys: :unique, name: Arena.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Arena.LobbySupervisor},
      ArenaWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Arena.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed), do: ArenaWeb.Endpoint.config_change(changed, removed)
end

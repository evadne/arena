defmodule ArenaWeb.UserSocket do
  use Phoenix.Socket
  channel("lobby:*", ArenaWeb.LobbyChannel)
  @impl true
  def connect(_params, socket, _connect_info) do
    id = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    {:ok, assign(socket, :user_id, id)}
  end

  @impl true
  def id(socket), do: "user:#{socket.assigns.user_id}"
end

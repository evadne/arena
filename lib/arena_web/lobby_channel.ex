defmodule ArenaWeb.LobbyChannel do
  use Phoenix.Channel
  @impl true
  def join("lobby:" <> code, payload, socket) do
    with {:ok, pid} <- Arena.Lobbies.ensure(code),
         :ok <- Phoenix.PubSub.subscribe(Arena.PubSub, "session:#{code}"),
         {:ok, reply} <-
           Arena.Lobby.join(
             pid,
             socket.assigns.user_id,
             Map.get(payload, "name", "Operator"),
             self()
           ) do
      Process.monitor(pid)
      {:ok, reply, assign(socket, :lobby_pid, pid)}
    else
      {:error, reason} when is_binary(reason) -> {:error, %{reason: reason}}
      _ -> {:error, %{reason: "Could not join lobby."}}
    end
  end

  @impl true
  def handle_in("input", payload, socket) do
    input = %{
      x: number(payload["x"], -1, 1),
      y: number(payload["y"], -1, 1),
      aim: number(payload["aim"], -1000, 1000),
      shoot: payload["shoot"] == true,
      reload: payload["reload"] == true
    }

    Arena.Lobby.input(socket.assigns.lobby_pid, socket.assigns.user_id, input)
    {:noreply, socket}
  end

  def handle_in(event, payload, socket)
      when event in ["chat", "start", "transfer", "slot", "formation", "order", "reset"] do
    case Arena.Lobby.action(socket.assigns.lobby_pid, socket.assigns.user_id, event, payload) do
      {:ok, reply} -> {:reply, {:ok, reply}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in(_, _, socket), do: {:reply, {:error, %{reason: "Unknown action."}}, socket}
  @impl true
  def handle_info({:game_snapshot, game}, socket) do
    push(socket, "snapshot", Arena.Game.public(game, socket.assigns.user_id))
    {:noreply, socket}
  end

  def handle_info({event, payload}, socket) when event in [:lobby, :chat] do
    push(socket, Atom.to_string(event), payload)
    {:noreply, socket}
  end

  def handle_info({:DOWN, _, :process, _, _}, socket), do: {:stop, :normal, socket}
  defp number(v, lo, hi) when is_number(v), do: v |> max(lo) |> min(hi)
  defp number(_, _, _), do: 0
end

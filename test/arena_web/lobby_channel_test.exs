defmodule ArenaWeb.LobbyChannelTest do
  use ExUnit.Case, async: true
  import Phoenix.ChannelTest
  @endpoint ArenaWeb.Endpoint

  setup do
    code =
      ("C" <> Integer.to_string(System.unique_integer([:positive]), 36))
      |> String.pad_trailing(6, "Z")

    {:ok, socket} = connect(ArenaWeb.UserSocket, %{})

    on_exit(fn ->
      case Registry.lookup(Arena.Registry, code) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(Arena.LobbySupervisor, pid)
        [] -> :ok
      end
    end)

    %{socket: socket, code: code}
  end

  test "join assigns server identity and pushes text chat", %{socket: socket, code: code} do
    {:ok, reply, socket} =
      subscribe_and_join(socket, ArenaWeb.LobbyChannel, "lobby:#{code}", %{"name" => "Echo"})

    assert reply.user_id == socket.assigns.user_id
    assert reply.lobby.leader_id == reply.user_id
    assert reply.game == nil
    ref = push(socket, "chat", %{"text" => "Breach ready."})
    assert_reply(ref, :ok)
    assert_push("chat", %{text: "Breach ready.", name: "Echo"})
  end

  test "invalid room and unauthorized events return errors", %{socket: socket, code: code} do
    assert {:error, _} = subscribe_and_join(socket, ArenaWeb.LobbyChannel, "lobby:bad!", %{})
    {:ok, _, socket} = subscribe_and_join(socket, ArenaWeb.LobbyChannel, "lobby:#{code}", %{})
    ref = push(socket, "teleport", %{"x" => 200})
    assert_reply(ref, :error)
    ref = push(socket, "slot", %{"slot" => 900})
    assert_reply(ref, :error)
  end
end

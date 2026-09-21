defmodule Arena.OrderTest do
  use ExUnit.Case, async: true

  setup do
    code =
      ("O" <> Integer.to_string(System.unique_integer([:positive]), 36))
      |> String.pad_trailing(6, "Q")

    {:ok, pid} = Arena.Lobbies.ensure(code)
    {:ok, _} = Arena.Lobby.join(pid, "leader", "Alpha", self())
    {:ok, _} = Arena.Lobby.join(pid, "teammate", "Bravo", self())

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(Arena.LobbySupervisor, pid)
    end)

    %{pid: pid}
  end

  test "any living human can issue each squad order without being lobby leader", %{pid: pid} do
    assert {:ok, _} = Arena.Lobby.action(pid, "leader", "start", %{})

    for order <- ["hold", "form_up", "aggro", "auto"] do
      assert {:ok, _} = Arena.Lobby.action(pid, "teammate", "order", %{"order" => order})
      state = :sys.get_state(pid)
      assert Arena.Game.public(state.game, "teammate").order == order
      assert state.leader_id == "leader"
    end
  end

  test "dead spectators cannot command bots or impersonate a living operator", %{pid: pid} do
    assert {:ok, _} = Arena.Lobby.action(pid, "leader", "start", %{})
    assert {:ok, _} = Arena.Lobby.action(pid, "leader", "order", %{"order" => "hold"})

    :sys.replace_state(pid, fn state ->
      players =
        Enum.map(state.game.players, fn player ->
          if player.id == "teammate", do: %{player | hp: 0}, else: player
        end)

      %{state | game: %{state.game | players: players}}
    end)

    assert {:error, _} =
             Arena.Lobby.action(pid, "teammate", "order", %{
               "order" => "aggro",
               "user_id" => "leader"
             })

    assert Arena.Game.public(:sys.get_state(pid).game, "teammate").spectator
    assert Arena.Game.public(:sys.get_state(pid).game, "leader").order == "hold"
  end

  test "orders reject invalid values, outsiders and inappropriate mission phases", %{pid: pid} do
    assert {:error, _} = Arena.Lobby.action(pid, "teammate", "order", %{"order" => "hold"})
    assert {:ok, _} = Arena.Lobby.action(pid, "leader", "start", %{})
    assert {:ok, _} = Arena.Lobby.action(pid, "teammate", "order", %{"order" => "hold"})

    for payload <- [%{}, %{"order" => nil}, %{"order" => 1}, %{"order" => "teleport"}] do
      assert {:error, _} = Arena.Lobby.action(pid, "teammate", "order", payload)
    end

    assert {:error, _} = Arena.Lobby.action(pid, "outsider", "order", %{"order" => "auto"})
    assert Arena.Game.public(:sys.get_state(pid).game, "teammate").order == "hold"

    :sys.replace_state(pid, fn state ->
      %{state | status: "won", game: %{state.game | status: "won"}}
    end)

    assert {:error, _} = Arena.Lobby.action(pid, "leader", "order", %{"order" => "aggro"})
  end
end

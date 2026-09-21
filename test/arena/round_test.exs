defmodule Arena.RoundTest do
  use ExUnit.Case, async: true

  setup do
    code =
      ("R" <> Integer.to_string(System.unique_integer([:positive]), 36))
      |> String.pad_trailing(6, "Q")

    {:ok, pid} = Arena.Lobbies.ensure(code)

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(Arena.LobbySupervisor, pid)
    end)

    %{pid: pid, code: code}
  end

  test "solo starts with bots; combat chat denied; next round requires leader and terminal state",
       %{pid: pid} do
    Arena.Lobby.join(pid, "human", "Alpha", self())
    assert {:ok, _} = Arena.Lobby.action(pid, "human", "start", %{})
    state = :sys.get_state(pid)
    assert length(state.game.players) == 4
    assert Enum.count(state.game.players, & &1.bot) == 3
    assert {:error, _} = Arena.Lobby.action(pid, "human", "chat", %{"text" => "No combat chat"})
    assert {:error, _} = Arena.Lobby.action(pid, "human", "reset", %{})
    :sys.replace_state(pid, fn s -> %{s | status: "won", game: %{s.game | status: "won"}} end)
    assert {:ok, _} = Arena.Lobby.action(pid, "human", "reset", %{})
    assert Arena.Lobby.state(pid).status == "waiting"
    assert {:ok, _} = Arena.Lobby.action(pid, "human", "chat", %{"text" => "Back at staging"})
    assert {:ok, _} = Arena.Lobby.action(pid, "human", "start", %{})
    assert Enum.all?(:sys.get_state(pid).game.players, &(&1.hp > 0))
  end

  test "last human leaves: lobby terminates and code can be reused", %{pid: pid, code: code} do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    Arena.Lobby.join(pid, "human", "Alpha", owner)
    monitor = Process.monitor(pid)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    {:ok, new_pid} = Arena.Lobbies.ensure(code)
    assert new_pid != pid
    assert Arena.Lobby.state(new_pid).members == []
    DynamicSupervisor.terminate_child(Arena.LobbySupervisor, new_pid)
  end

  test "a quick press and release between ticks still fires once", %{pid: pid} do
    Arena.Lobby.join(pid, "human", "Alpha", self())
    Arena.Lobby.action(pid, "human", "start", %{})
    input = %{x: 0, y: 0, aim: 0, shoot: true, reload: false}
    Arena.Lobby.input(pid, "human", input)
    Arena.Lobby.input(pid, "human", %{input | shoot: false})
    send(pid, :tick)
    state = :sys.get_state(pid)
    assert Enum.find(state.game.players, &(&1.id == "human")).ammo == 19
    send(pid, :tick)
    state = :sys.get_state(pid)
    assert Enum.find(state.game.players, &(&1.id == "human")).ammo == 19
  end

  test "leadership passes to the next arrival during a mission", %{pid: pid} do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    Arena.Lobby.join(pid, "a", "Alpha", owner)
    Arena.Lobby.join(pid, "b", "Bravo", self())
    Arena.Lobby.join(pid, "c", "Charlie", self())
    Arena.Lobby.action(pid, "a", "start", %{})
    Process.exit(owner, :kill)
    eventually(fn -> Arena.Lobby.state(pid).leader_id == "b" end)
    state = :sys.get_state(pid)
    assert state.status == "playing"
    assert Enum.count(state.game.players, & &1.bot) == 2
  end

  defp eventually(fun, n \\ 30)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, n) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, n - 1)
        )
  end
end

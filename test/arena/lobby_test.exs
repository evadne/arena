defmodule Arena.LobbyTest do
  use ExUnit.Case, async: true

  defp lobby do
    code =
      ("T" <> Integer.to_string(System.unique_integer([:positive]), 36))
      |> String.pad_trailing(6, "X")

    {:ok, pid} = Arena.Lobbies.ensure(code)

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(Arena.LobbySupervisor, pid)
    end)

    pid
  end

  defp owner,
    do:
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

  test "first member leads and manual leadership transfer is unavailable" do
    p = lobby()
    assert {:ok, %{lobby: %{leader_id: "a"}}} = Arena.Lobby.join(p, "a", "Alpha", self())
    assert {:ok, _} = Arena.Lobby.join(p, "b", "Bravo", self())
    assert {:error, _} = Arena.Lobby.action(p, "b", "transfer", %{"user_id" => "b"})
    assert {:error, _} = Arena.Lobby.action(p, "a", "transfer", %{"user_id" => "missing"})
    assert {:error, _} = Arena.Lobby.action(p, "a", "transfer", %{"user_id" => "b"})
    assert Arena.Lobby.state(p).leader_id == "a"
  end

  test "four join-order slots, bounded lobby and no manual slot or formation selection" do
    p = lobby()
    for n <- 0..3, do: assert({:ok, _} = Arena.Lobby.join(p, "u#{n}", "Unit", self()))
    assert Enum.map(Arena.Lobby.state(p).members, & &1.slot) == [0, 1, 2, 3]
    assert {:error, _} = Arena.Lobby.join(p, "extra", "Extra", self())
    assert {:error, _} = Arena.Lobby.action(p, "u0", "slot", %{"slot" => 1})
    assert {:error, _} = Arena.Lobby.action(p, "u1", "formation", %{"formation" => "wedge"})
    assert {:error, _} = Arena.Lobby.action(p, "u0", "formation", %{"formation" => "wedge"})
    refute Map.has_key?(Arena.Lobby.state(p), :formation)
  end

  test "staging departures close gaps and new arrivals follow the remaining join order" do
    p = lobby()
    departing = owner()
    Arena.Lobby.join(p, "a", "Alpha", self())
    Arena.Lobby.join(p, "b", "Bravo", departing)
    Arena.Lobby.join(p, "c", "Charlie", self())
    Process.exit(departing, :kill)
    eventually(fn -> length(Arena.Lobby.state(p).members) == 2 end)
    assert Enum.map(Arena.Lobby.state(p).members, &{&1.id, &1.slot}) == [{"a", 0}, {"c", 1}]
    assert {:ok, _} = Arena.Lobby.join(p, "d", "Delta", self())

    assert Enum.map(Arena.Lobby.state(p).members, &{&1.id, &1.slot}) == [
             {"a", 0},
             {"c", 1},
             {"d", 2}
           ]

    assert {:error, _} = Arena.Lobby.action(p, "a", "slot", %{"slot" => 3})
    assert {:ok, _} = Arena.Lobby.action(p, "a", "start", %{})
    players = :sys.get_state(p).game.players

    assert Enum.map(players, &{&1.id, &1.slot, &1.bot}) == [
             {"a", 0, false},
             {"c", 1, false},
             {"d", 2, false},
             {"bot-3", 3, true}
           ]
  end

  test "a returning briefing restores join-order slots without moving surviving actors mid-round" do
    p = lobby()
    departing = owner()
    Arena.Lobby.join(p, "a", "Alpha", self())
    Arena.Lobby.join(p, "b", "Bravo", departing)
    Arena.Lobby.join(p, "c", "Charlie", self())
    Arena.Lobby.action(p, "a", "start", %{})
    original = Enum.find(:sys.get_state(p).game.players, &(&1.id == "c"))
    Process.exit(departing, :kill)
    eventually(fn -> length(Arena.Lobby.state(p).members) == 2 end)
    remaining = Enum.find(:sys.get_state(p).game.players, &(&1.id == "c"))
    assert {remaining.slot, remaining.x, remaining.y} == {original.slot, original.x, original.y}
    assert {:ok, _} = Arena.Lobby.join(p, "d", "Delta", self())

    assert Enum.map(Arena.Lobby.state(p).members, &{&1.id, &1.slot}) == [
             {"a", 0},
             {"c", 2},
             {"d", 1}
           ]

    :sys.replace_state(p, fn state ->
      %{state | status: "won", game: %{state.game | status: "won"}}
    end)

    assert {:ok, _} = Arena.Lobby.action(p, "a", "reset", %{})

    assert Enum.map(Arena.Lobby.state(p).members, &{&1.id, &1.slot}) == [
             {"a", 0},
             {"c", 1},
             {"d", 2}
           ]
  end

  test "leader disconnection elects a remaining member" do
    p = lobby()
    owner = owner()
    Arena.Lobby.join(p, "a", "Alpha", owner)
    Arena.Lobby.join(p, "b", "Bravo", self())
    Arena.Lobby.join(p, "c", "Charlie", self())
    Process.exit(owner, :kill)
    eventually(fn -> Arena.Lobby.state(p).leader_id == "b" end)
    assert Enum.map(Arena.Lobby.state(p).members, &{&1.id, &1.slot}) == [{"b", 0}, {"c", 1}]
  end

  test "chat uses isolated PubSub topic and rejects empty or rapid messages" do
    a = lobby()
    b = lobby()
    Arena.Lobby.join(a, "a", "Alpha", self())
    Arena.Lobby.join(b, "b", "Bravo", self())
    Phoenix.PubSub.subscribe(Arena.PubSub, "session:#{Arena.Lobby.state(a).code}")
    assert {:ok, _} = Arena.Lobby.action(a, "a", "chat", %{"text" => "<b>literal text</b>"})
    assert_receive {:chat, %{text: "<b>literal text</b>"}}
    assert Arena.Lobby.state(b).chat == []
    assert {:error, _} = Arena.Lobby.action(a, "a", "chat", %{"text" => "rapid"})
    assert {:error, _} = Arena.Lobby.action(a, "a", "chat", %{"text" => "  "})
  end

  test "lobby code validation excludes arbitrary topics" do
    for code <- ["a", "FOO:BAR", "../../etc", "TOOLONGLOBBYNAME", nil],
        do: assert({:error, _} = Arena.Lobbies.ensure(code))
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

defmodule ArenaWeb.SnapshotDeltaTest do
  use ExUnit.Case, async: true
  alias ArenaWeb.SnapshotDelta

  defp snapshot do
    %{
      seed: 42,
      tick: 1,
      elapsed_ms: 50,
      status: "playing",
      spectator: false,
      order: "auto",
      enemies_remaining: 2,
      enemies_total: 2,
      map: %{width: 1024, height: 704, walls: [[1, 1]]},
      players: [%{id: "user", x: 10.0, y: 20.0, angle: 0.0, hp: 100, ammo: 20, bot: false}],
      enemies: [%{id: "enemy-1", x: 40.0, y: 50.0, angle: 1.0, hp: 100, state: "patrol"}],
      visible_tiles: [[2, 2], [2, 3]],
      explored_tiles: [[1, 2], [2, 2], [2, 3]],
      shots: [%{id: 1, x1: 10.0, x2: 40.0, team: "friendly"}],
      events: [%{id: 1, type: "shot", volume: 1.0}]
    }
  end

  test "initial and different-round snapshots are complete baselines" do
    current = snapshot()
    assert SnapshotDelta.encode(current, nil, 1, nil) == %{seq: 1, base: nil, full: current}
    previous = %{current | seed: 41}
    assert SnapshotDelta.encode(current, previous, 8, 7) == %{seq: 8, base: nil, full: current}
  end

  test "unchanged snapshots contain only sequence and baseline identifiers" do
    current = snapshot()
    assert SnapshotDelta.encode(current, current, 9, 8) == %{seq: 9, base: 8}
  end

  test "actor updates are sparse, while newly visible actors are complete" do
    previous = snapshot()
    moved = hd(previous.players) |> Map.merge(%{x: 10.1256789, ammo: 19})
    revealed = %{id: "enemy-2", x: 80.0, y: 90.0, angle: 0.0, hp: 84, state: "engage"}
    current = %{previous | tick: 2, elapsed_ms: 100, players: [moved], enemies: [revealed]}
    frame = SnapshotDelta.encode(current, previous, 2, 1)
    assert frame.changes == %{tick: 2, elapsed_ms: 100}
    assert frame.players == %{upsert: [%{id: "user", x: 10.1256789, ammo: 19}], remove: []}
    assert frame.enemies == %{upsert: [revealed], remove: ["enemy-1"]}
    refute Map.has_key?(frame, :map)
    refute Map.has_key?(frame, :shots)
    refute Map.has_key?(frame, :events)
    assert persistent(reconstruct(previous, frame)) == persistent(current)
  end

  test "fog and actor removals clear stale visibility, including spectator transitions" do
    previous = snapshot()

    current = %{
      previous
      | visible_tiles: [[2, 3], [3, 3]],
        explored_tiles: previous.explored_tiles ++ [[3, 3]],
        enemies: []
    }

    frame = SnapshotDelta.encode(current, previous, 2, 1)
    assert frame.visible_tiles == %{add: [[3, 3]], remove: [[2, 2]]}
    assert frame.explored_tiles == %{add: [[3, 3]], remove: []}
    assert frame.enemies == %{upsert: [], remove: ["enemy-1"]}
    assert persistent(reconstruct(previous, frame)) == persistent(current)

    spectator = %{previous | spectator: true, visible_tiles: previous.explored_tiles}
    death = SnapshotDelta.encode(spectator, current, 3, 2)
    assert death.changes == %{spectator: true}
    assert death.enemies.upsert == previous.enemies
    assert persistent(reconstruct(current, death)) == persistent(spectator)
  end

  test "transient shot and sound IDs are emitted once against the acknowledged baseline" do
    previous = snapshot()
    shot = %{id: 2, x1: 20.0, x2: 90.0, team: "enemy"}
    sound = %{id: 2, type: "hit", volume: 0.5}
    current = %{previous | shots: [shot | previous.shots], events: [sound | previous.events]}
    frame = SnapshotDelta.encode(current, previous, 2, 1)
    assert frame.shots == [shot]
    assert frame.events == [sound]
    assert SnapshotDelta.encode(current, current, 3, 2) == %{seq: 3, base: 2}
    expired = %{current | shots: [], events: []}
    assert SnapshotDelta.encode(expired, current, 4, 3) == %{seq: 4, base: 3}
  end

  test "real simulation deltas reconstruct persistent state without changing precision" do
    game = Arena.Game.new([%{id: "user", name: "User", slot: 0}], 7)
    initial = Arena.Game.public(game, "user")

    Enum.reduce(1..100, {game, initial}, fn seq, {game, previous} ->
      game =
        Arena.Game.step(game, %{
          "user" => %{x: 0.3, y: -0.4, aim: seq / 17, shoot: rem(seq, 7) == 0}
        })

      current = Arena.Game.public(game, "user")
      frame = SnapshotDelta.encode(current, previous, seq + 1, seq)
      assert persistent(reconstruct(previous, frame)) == persistent(current)
      refute Map.has_key?(frame, :map)
      assert Jason.decode!(Jason.encode!(frame))["base"] == seq
      {game, current}
    end)
  end

  test "sparse frames substantially reduce payload even against map-free snapshots" do
    game = Arena.Game.new([%{id: "user", name: "User", slot: 0}], 7)
    previous = Arena.Game.public(game, "user")
    current = game |> Arena.Game.step(%{}) |> Arena.Game.public("user")
    frame = SnapshotDelta.encode(current, previous, 2, 1)
    encoded_bytes = byte_size(Jason.encode!(frame))
    assert encoded_bytes < byte_size(Jason.encode!(Map.delete(current, :map))) / 2
    assert encoded_bytes < byte_size(Jason.encode!(current)) / 5
  end

  # Independent decoder exercising the wire contract; lists with IDs/coordinates are sets.
  defp reconstruct(_previous, %{full: snapshot}), do: snapshot

  defp reconstruct(previous, frame) do
    snapshot = Map.merge(previous, Map.get(frame, :changes, %{}))

    snapshot =
      Enum.reduce([:players, :enemies], snapshot, fn key, state ->
        delta = Map.get(frame, key, %{upsert: [], remove: []})
        actors = Map.new(state[key], &{&1.id, &1}) |> Map.drop(delta.remove)

        actors =
          Enum.reduce(delta.upsert, actors, fn actor, actors ->
            Map.update(actors, actor.id, actor, &Map.merge(&1, actor))
          end)

        Map.put(state, key, Map.values(actors))
      end)

    Enum.reduce([:visible_tiles, :explored_tiles], snapshot, fn key, state ->
      delta = Map.get(frame, key, %{add: [], remove: []})

      tiles =
        MapSet.new(state[key])
        |> MapSet.difference(MapSet.new(delta.remove))
        |> MapSet.union(MapSet.new(delta.add))

      Map.put(state, key, MapSet.to_list(tiles))
    end)
  end

  defp persistent(snapshot) do
    snapshot = Map.drop(snapshot, [:shots, :events])

    snapshot =
      Enum.reduce([:players, :enemies], snapshot, fn key, state ->
        Map.update!(state, key, &Enum.sort_by(&1, fn actor -> actor.id end))
      end)

    Enum.reduce([:visible_tiles, :explored_tiles], snapshot, fn key, state ->
      Map.update!(state, key, &Enum.sort/1)
    end)
  end
end

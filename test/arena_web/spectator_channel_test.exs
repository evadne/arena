defmodule ArenaWeb.SpectatorChannelTest do
  use ExUnit.Case, async: true
  import Phoenix.ChannelTest
  @endpoint ArenaWeb.Endpoint

  test "the same lobby tick reveals the whole mission only to its dead viewer" do
    code =
      ("V" <> Integer.to_string(System.unique_integer([:positive]), 36))
      |> String.pad_trailing(6, "Z")

    {:ok, dead_socket} = connect(ArenaWeb.UserSocket, %{})

    {:ok, dead_join, dead_socket} =
      subscribe_and_join(dead_socket, ArenaWeb.LobbyChannel, "lobby:#{code}", %{
        "name" => "Spectator"
      })

    {:ok, live_socket} = connect(ArenaWeb.UserSocket, %{})

    {:ok, live_join, live_socket} =
      subscribe_and_join(live_socket, ArenaWeb.LobbyChannel, "lobby:#{code}", %{
        "name" => "Survivor"
      })

    [{lobby, _}] = Registry.lookup(Arena.Registry, code)

    on_exit(fn ->
      if Process.alive?(lobby),
        do: DynamicSupervisor.terminate_child(Arena.LobbySupervisor, lobby)
    end)

    # Place an otherwise normal mission at a deterministic death transition. The
    # real lobby tick, PubSub delivery and both Channel serializers remain in use.
    game = Arena.Game.new(live_join.lobby.members, 7)
    # Select by distance from the actual generated entry, regardless of the
    # irregular premises' footprint or which side contains the squad entrance.
    distance_from_squad = fn tile ->
      {x, y} = Arena.Game.Map.center(tile)

      game.players
      |> Enum.reject(&(&1.id == dead_join.user_id))
      |> Enum.map(fn player -> :math.sqrt((x - player.x) ** 2 + (y - player.y) ** 2) end)
      |> Enum.min()
    end

    enemy_count = length(game.enemies)
    assert enemy_count in 12..20
    far_tiles = Enum.sort_by(game.map.floor, distance_from_squad, :desc) |> Enum.take(enemy_count)
    assert length(far_tiles) == enemy_count
    assert length(Enum.uniq(far_tiles)) == enemy_count
    assert Enum.all?(far_tiles, &(distance_from_squad.(&1) > 450))

    enemies =
      game.enemies
      |> Enum.zip(far_tiles)
      |> Enum.map(fn {enemy, tile} ->
        {x, y} = Arena.Game.Map.center(tile)
        %{enemy | x: x, y: y, home: {x, y}}
      end)

    players =
      Enum.map(game.players, fn player ->
        if player.id == dead_join.user_id, do: %{player | hp: 0}, else: player
      end)

    distant = hd(enemies)

    game = %{
      game
      | players: players,
        enemies: enemies,
        events: [%{id: 9001, type: "shot", x: distant.x, y: distant.y, team: "enemy", at: 0}],
        event_seq: 9001,
        shots: [
          %{
            id: 9001,
            x1: distant.x,
            y1: distant.y,
            x2: distant.x + 10,
            y2: distant.y,
            team: "enemy",
            at: 0
          }
        ]
    }

    :sys.replace_state(lobby, fn state -> %{state | game: game, status: "playing"} end)
    send(lobby, :tick)

    dead_ref = dead_socket.join_ref
    live_ref = live_socket.join_ref

    assert_receive %Phoenix.Socket.Message{
                     event: "snapshot",
                     join_ref: ^dead_ref,
                     payload: %{spectator: true, tick: 1} = spectator
                   },
                   1000

    assert_receive %Phoenix.Socket.Message{
                     event: "snapshot",
                     join_ref: ^live_ref,
                     payload: %{spectator: false, tick: 1} = survivor
                   },
                   1000

    assert length(spectator.players) == 4
    assert length(spectator.enemies) == enemy_count
    assert spectator.enemies_total == enemy_count
    assert length(spectator.visible_tiles) == length(game.map.floor)
    assert length(spectator.explored_tiles) == length(game.map.floor)
    assert Enum.any?(spectator.events, &(&1.id == 9001))
    assert Enum.any?(spectator.shots, &(&1.id == 9001))

    assert survivor.enemies == []
    assert survivor.enemies_remaining == enemy_count
    assert survivor.enemies_total == enemy_count
    assert length(survivor.visible_tiles) < length(game.map.floor)
    refute Enum.any?(survivor.events, &(&1.id == 9001))
    refute Enum.any?(survivor.shots, &(&1.id == 9001))
    refute Enum.any?(spectator.enemies, &Map.has_key?(&1, :memory))
  end
end

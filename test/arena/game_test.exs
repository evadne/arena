defmodule Arena.GameTest do
  use ExUnit.Case, async: true
  alias Arena.Game
  alias Arena.Game.Map, as: World

  defp humans, do: for(slot <- 0..3, do: %{id: "user-#{slot}", name: "User #{slot}", slot: slot})
  defp base(seed \\ 7), do: Game.new(humans(), seed)

  defp set_player(game, slot, changes) do
    %{
      game
      | players:
          Enum.map(game.players, fn p -> if p.slot == slot, do: Map.merge(p, changes), else: p end)
    }
  end

  defp set_enemy(game, index, changes) do
    %{game | enemies: List.update_at(game.enemies, index, &Map.merge(&1, changes))}
  end

  defp wall_arena(game) do
    grid =
      for x <- 0..31, y <- 0..21, x in [0, 10, 31] or y in [0, 21], into: MapSet.new(), do: {x, y}

    floor = for x <- 1..30, y <- 1..20, not MapSet.member?(grid, {x, y}), do: {x, y}

    players =
      Enum.map(game.players, fn p ->
        %{p | x: 80.0 + rem(p.slot, 2) * 34, y: 80.0 + div(p.slot, 2) * 34}
      end)

    enemies =
      game.enemies
      |> Enum.with_index()
      |> Enum.map(fn {e, i} ->
        x = 520.0 + rem(i, 5) * 80
        y = 340.0 + div(i, 5) * 48
        %{e | x: x, y: y, home: {x, y}, reaction_delay: 650}
      end)

    %{
      game
      | map: %{game.map | grid: grid, floor: floor, width: 1024, height: 704},
        players: players,
        enemies: enemies
    }
  end

  test "seeded layouts are reproducible and every floor tile and enemy is reachable" do
    Enum.each(1..100, fn seed ->
      map = World.generate(seed)
      assert map == World.generate(seed)
      reached = flood(map, [World.tile({map.spawn.x, map.spawn.y})], MapSet.new())
      assert MapSet.size(reached) == length(map.floor)
      assert length(map.rooms) in 8..12
      assert map.archetype in ["house", "office", "workshop"]
      assert map.entry.label != ""
      assert World.fits?(map, {map.entry.x, map.entry.y})
      game = Game.new([hd(humans())], seed)
      assert length(game.players) == 4
      assert Enum.count(game.players, & &1.bot) == 3
      assert length(game.enemies) in 12..20
      assert Game.public(game).enemies_total == length(game.enemies)
      assert Enum.uniq_by(game.enemies, &{&1.x, &1.y}) == game.enemies
      assert Enum.all?(game.enemies, &MapSet.member?(reached, World.tile({&1.x, &1.y})))
      assert Enum.all?(game.enemies, &World.fits?(map, {&1.x, &1.y}))
      assert Enum.all?(game.players, &World.fits?(map, {&1.x, &1.y}))
    end)

    refute World.generate(3).grid == World.generate(4).grid

    assert MapSet.new(Enum.map(1..30, &World.generate(&1).archetype)) ==
             MapSet.new(["house", "office", "workshop"])
  end

  test "circle movement cannot penetrate or tunnel through walls and slides along them" do
    game = base() |> wall_arena()
    assert {310.0, 160.0} == World.move(game.map, {310.0, 160.0}, {80.0, 0.0})
    {x, y} = World.move(game.map, {310.0, 160.0}, {80.0, 50.0})
    assert x == 310.0
    assert_in_delta y, 210.0, 0.001
    {x, _y} = World.move(game.map, {80.0, 160.0}, {1000.0, 0.0})
    assert x <= 310
    assert World.fits?(game.map, {x, 160})
  end

  test "exact wall rays stop bullets including diagonal corner crossings" do
    map = (base() |> wall_arena()).map
    assert {{320.0, 160.0}, true} = World.ray(map, {80.0, 160.0}, {700.0, 160.0})
    refute World.clear?(map, {80.0, 160.0}, {700.0, 160.0})
    assert World.clear?(map, {80.0, 160.0}, {300.0, 160.0})
    corner = %{map | grid: MapSet.put(map.grid, {3, 2})}
    assert {_point, true} = World.ray(corner, {80.0, 80.0}, {144.0, 144.0})
  end

  test "hitscan consumes ammunition, damages only the first target, and stops at walls" do
    game =
      base()
      |> wall_arena()
      |> set_player(0, %{x: 80.0, y: 160.0, angle: 0.0})
      |> set_enemy(0, %{x: 180.0, y: 160.0})
      |> set_enemy(1, %{x: 240.0, y: 160.0})

    game = Game.step(game, %{"user-0" => %{aim: 0.0, shoot: true}})
    assert hd(game.players).ammo == 19
    assert hd(game.enemies).hp == 66
    assert Enum.at(game.enemies, 1).hp == 100
    shot = hd(game.shots)
    assert_in_delta shot.x2, 169, 0.001

    game =
      base()
      |> wall_arena()
      |> set_player(0, %{x: 80.0, y: 160.0, angle: 0.0})
      |> set_enemy(0, %{x: 420.0, y: 160.0})
      |> set_enemy(1, %{hp: 0})

    game = Game.step(game, %{"user-0" => %{aim: 0.0, shoot: true}})
    assert hd(game.enemies).hp == 100
    assert hd(game.shots).x2 == 320.0
  end

  test "human trigger remains immediate with unchanged damage and fire rate" do
    game =
      base()
      |> wall_arena()
      |> set_player(0, %{x: 80.0, y: 160.0, angle: 0.0})
      |> set_enemy(0, %{x: 180.0, y: 160.0})

    trigger = %{"user-0" => %{aim: 0.0, shoot: true}}
    first = Game.step(game, trigger)
    assert hd(first.players).ammo == 19
    assert hd(first.players).cooldown_ms == 180
    assert hd(first.enemies).hp == 66
    before_next = Enum.reduce(1..3, first, fn _, state -> Game.step(state, trigger) end)
    assert hd(before_next.players).ammo == 19
    assert hd(Game.step(before_next, trigger).players).ammo == 18
  end

  test "a reload pressed with the first shot is retained after the full magazine fires" do
    game = base() |> wall_arena()
    shot = Game.step(game, %{"user-0" => %{aim: -1.57, shoot: true, reload: true}})
    assert hd(shot.players).ammo == 19
    assert hd(shot.players).reload_ms == 1500
    assert hd(Game.step(shot, %{"user-0" => %{shoot: true}}).players).ammo == 19
  end

  test "bots need time to acquire a visible target and obey the weapon cooldown" do
    game =
      Game.new([hd(humans())], 7)
      |> wall_arena()
      |> set_player(1, %{x: 80.0, y: 160.0, angle: 0.0})
      |> set_player(2, %{hp: 0})
      |> set_player(3, %{hp: 0})
      |> set_enemy(0, %{x: 220.0, y: 160.0, angle: 0.0, reaction_delay: 10_000})

    before_acquisition = Enum.reduce(1..6, game, fn _, state -> Game.step(state, %{}) end)
    assert Enum.at(before_acquisition.players, 1).ammo == 20
    first = Game.step(before_acquisition, %{})
    assert Enum.at(first.players, 1).ammo == 19
    assert Enum.at(first.players, 1).cooldown_ms == 180
    pause = Enum.reduce(1..3, first, fn _, state -> Game.step(state, %{}) end)
    assert Enum.at(pause.players, 1).ammo == 19
    assert Enum.at(Game.step(pause, %{}).players, 1).ammo == 18
  end

  test "bots cannot acquire enemies beyond the enemy engagement range" do
    game =
      Game.new([hd(humans())], 7)
      |> wall_arena()
      |> set_player(0, %{hp: 0})
      |> set_player(1, %{x: 400.0, y: 160.0, angle: 0.0})
      |> set_player(2, %{hp: 0})
      |> set_player(3, %{hp: 0})
      |> set_enemy(0, %{x: 780.0, y: 160.0, angle: :math.pi()})

    game = %{game | enemies: Enum.take(game.enemies, 1)}
    assert Game.sees?(game.map, Enum.at(game.players, 1), {780.0, 160.0})
    next = Game.step(game, %{})
    assert Enum.at(next.players, 1).aim_target == nil
    assert Enum.at(next.players, 1).ammo == 20
    assert hd(next.enemies).target_id == nil
  end

  test "an alerted enemy retains acquisition through a brief occlusion without firing blind" do
    game =
      base()
      |> wall_arena()
      |> set_player(0, %{x: 80.0, y: 160.0})
      |> set_player(1, %{hp: 0})
      |> set_player(2, %{hp: 0})
      |> set_player(3, %{hp: 0})
      |> set_enemy(0, %{x: 220.0, y: 160.0, angle: :math.pi()})

    engaged = Enum.reduce(1..13, game, fn _, state -> Game.step(state, %{}) end)
    assert hd(engaged.enemies).ammo == 19
    hidden = set_player(engaged, 0, %{x: 420.0, y: 160.0})
    hidden = Enum.reduce(1..4, hidden, fn _, state -> Game.step(state, %{}) end)
    assert hd(hidden.enemies).ammo == 19
    assert hd(hidden.enemies).memory == {80.0, 160.0}
    returned = hidden |> set_player(0, %{x: 80.0, y: 160.0}) |> Game.step(%{})
    assert hd(returned.enemies).ammo == 18
  end

  test "20 round magazines reload indefinitely and a partial reload is timed" do
    game = base() |> wall_arena() |> set_player(0, %{ammo: 1, angle: -1.57})
    game = Game.step(game, %{"user-0" => %{aim: -1.57, shoot: true}})
    assert hd(game.players).ammo == 0
    assert hd(game.players).reload_ms == 1500
    game = Enum.reduce(1..29, game, fn _, g -> Game.step(g, %{}) end)
    assert hd(game.players).ammo == 0
    game = Game.step(game, %{})
    assert hd(game.players).ammo == 20
    assert hd(game.players).reload_ms == 0
    game = set_player(game, 0, %{ammo: 12}) |> Game.step(%{"user-0" => %{reload: true}})
    assert hd(game.players).reload_ms == 1500
    game = Enum.reduce(1..30, game, fn _, g -> Game.step(g, %{}) end)
    assert hd(game.players).ammo == 20
  end

  test "public snapshots share team sight but omit hidden enemies and their shot origins" do
    game =
      base()
      |> wall_arena()
      |> set_player(0, %{x: 80.0, y: 160.0, angle: 0.0})
      |> set_enemy(0, %{x: 220.0, y: 160.0})
      |> set_enemy(1, %{x: 420.0, y: 160.0})

    game = %{
      game
      | shots: [%{id: 1, x1: 420.0, y1: 160.0, x2: 500.0, y2: 160.0, team: "enemy", at: 0}]
    }

    public = Game.public(game)
    assert Enum.any?(public.enemies, &(&1.id == "hostile-0"))
    refute Enum.any?(public.enemies, &(&1.id == "hostile-1"))
    assert public.shots == []
    refute Map.has_key?(public.map, :grid)
    refute Map.has_key?(hd(public.enemies), :memory)
    assert public.enemies_remaining == length(game.enemies)
    behind = %{hd(game.players) | angle: :math.pi()}
    refute Game.sees?(game.map, behind, {220.0, 160.0})
  end

  test "enemy acquisition has a reaction delay and cannot see or fire through walls" do
    game =
      base()
      |> wall_arena()
      |> set_player(0, %{x: 80.0, y: 160.0})
      |> set_player(1, %{hp: 0})
      |> set_player(2, %{hp: 0})
      |> set_player(3, %{hp: 0})
      |> set_enemy(0, %{x: 220.0, y: 160.0, angle: :math.pi()})

    game = Enum.reduce(1..12, game, fn _, g -> Game.step(g, %{}) end)
    assert hd(game.players).hp == 100
    assert hd(game.enemies).ammo == 20
    game = Game.step(game, %{})
    assert hd(game.players).hp == 84
    assert hd(game.enemies).ammo == 19

    game =
      base()
      |> wall_arena()
      |> set_enemy(0, %{x: 420.0, y: 80.0, home: {420.0, 80.0}, angle: :math.pi()})

    game = Enum.reduce(1..45, game, fn _, g -> Game.step(g, %{}) end)
    assert hd(game.enemies).ammo == 20
    assert hd(game.enemies).target_id == nil
    assert hd(game.enemies).memory == nil
    assert Enum.all?(game.players, &(&1.hp == 100))
  end

  test "hearing remembers a finite last known position instead of tracking an unseen player" do
    game =
      base()
      |> wall_arena()
      |> set_player(0, %{x: 285.0, y: 160.0, angle: :math.pi()})
      |> set_enemy(0, %{x: 420.0, y: 160.0, home: {420.0, 160.0}, angle: 0.0})

    game = Game.step(game, %{"user-0" => %{aim: :math.pi(), shoot: true}})
    assert hd(game.enemies).memory == {285.0, 160.0}
    assert hd(game.enemies).state == "search"
    game = set_player(game, 0, %{x: 80.0, y: 80.0})
    game = Enum.reduce(1..20, game, fn _, g -> Game.step(g, %{}) end)
    assert hd(game.enemies).memory == {285.0, 160.0}
    game = Enum.reduce(1..125, game, fn _, g -> Game.step(g, %{}) end)
    assert hd(game.enemies).memory == nil
    assert hd(game.enemies).ammo == 20
  end

  test "disconnect preserves operator position and health as an AI replacement" do
    game = base() |> set_player(0, %{hp: 76, ammo: 8})
    before = hd(game.players)
    after_player = Game.disconnect(game, before.id).players |> hd()
    assert after_player.bot
    assert Map.drop(after_player, [:bot]) == Map.drop(before, [:bot])
  end

  test "a dead human spectates all actors and the whole map without revealing them to survivors" do
    game =
      base()
      |> wall_arena()
      |> set_player(0, %{hp: 0})
      |> set_enemy(0, %{x: 420.0, y: 160.0})

    dead = Game.public(game, "user-0")
    survivor = Game.public(game, "user-1")
    assert dead.spectator
    assert length(dead.enemies) == length(game.enemies)
    assert length(dead.visible_tiles) == length(game.map.floor)
    refute survivor.spectator
    refute Enum.any?(survivor.enemies, &(&1.id == "hostile-0"))
    refute Game.public(base(), "user-0").spectator
  end

  test "sound events are authoritative, stable, spatial, and filtered by finite audibility" do
    game =
      base()
      |> wall_arena()
      |> set_player(0, %{x: 80.0, y: 160.0})
      |> set_player(1, %{x: 900.0, y: 600.0})
      |> set_player(2, %{x: 420.0, y: 160.0})

    game = Game.step(game, %{"user-0" => %{aim: :math.pi(), shoot: true}})
    events = Game.public(game, "user-0").events
    assert Enum.any?(events, &(&1.type == "shot" and &1.volume == 1.0))
    assert Game.public(game, "user-1").events == []
    assert Game.public(game, "user-2").events == []
    same = Game.step(game, %{}) |> Game.public("user-0")
    assert Enum.map(same.events, & &1.id) == Enum.map(events, & &1.id)
    refute Enum.any?(events, &Map.has_key?(&1, :actor_id))
    game = set_player(game, 2, %{x: 360.0, y: 160.0})
    quiet = Game.public(game, "user-2").events |> Enum.find(&(&1.type == "shot"))
    assert quiet.occluded
    assert quiet.volume < 0.1
    game = Game.step(game, %{"user-0" => %{reload: true}})
    assert Enum.any?(Game.public(game, "user-0").events, &(&1.type == "reload"))
  end

  test "mission outcomes are authoritative" do
    game = base()
    won = %{game | enemies: Enum.map(game.enemies, &%{&1 | hp: 0})} |> Game.step(%{})
    assert won.status == "won"
    assert Game.step(won, %{}) == won
    lost = %{game | players: Enum.map(game.players, &%{&1 | hp: 0})} |> Game.step(%{})
    assert lost.status == "lost"
  end

  test "AI survivors sweep the known rooms and finish the mission after their human dies" do
    Enum.each([{1, "hold"}, {3, "form_up"}, {42, "auto"}, {17, "aggro"}], fn {seed, order} ->
      game =
        Game.new([hd(humans())], seed)
        |> Game.set_order(order, "user-0")
        |> set_player(0, %{hp: 0})

      final =
        Enum.reduce_while(1..3600, game, fn _, state ->
          next = Game.step(state, %{})
          assert Enum.all?(next.players, &World.fits?(next.map, {&1.x, &1.y}))
          assert Enum.all?(next.enemies, &World.fits?(next.map, {&1.x, &1.y}))
          if next.status == "playing", do: {:cont, next}, else: {:halt, next}
        end)

      assert final.status in ["won", "lost"]
      assert final.elapsed_ms < 180_000
    end)
  end

  test "team orders require a living human and hold anchors yield to self-defense" do
    game = Game.new([hd(humans())], 7) |> wall_arena() |> set_player(1, %{x: 180.0, y: 160.0})
    assert Game.set_order(game, "hold", "bot-1") == game
    assert Game.set_order(game, "unknown", "user-0") == game
    dead = set_player(game, 0, %{hp: 0})
    assert Game.set_order(dead, "hold", "user-0") == dead
    game = Game.set_order(game, "hold", "user-0")
    assert Game.public(game).order == "hold"
    assert Enum.at(game.players, 1).hold_anchor == {180.0, 160.0}
    idle = Game.step(game, %{})
    assert {Enum.at(idle.players, 1).x, Enum.at(idle.players, 1).y} == {180.0, 160.0}
    hurt = game |> set_player(1, %{hp: 88}) |> Game.step(%{})
    defender = Enum.at(hurt.players, 1)
    assert {defender.x, defender.y} != {180.0, 160.0}
    assert World.fits?(game.map, {defender.x, defender.y})
    assert defender.hold_anchor == {180.0, 160.0}

    combat = game |> set_enemy(0, %{x: 245.0, y: 160.0, home: {245.0, 160.0}}) |> Game.step(%{})
    defender = Enum.at(combat.players, 1)
    assert {defender.x, defender.y} != {180.0, 160.0}
    assert defender.ammo == 20
    combat = Enum.reduce(1..9, combat, fn _, g -> Game.step(g, %{}) end)
    assert Enum.at(combat.players, 1).ammo < 20
  end

  test "form up follows the issuing human instead of the first roster entry" do
    members = [Enum.at(humans(), 0), Enum.at(humans(), 2)]

    game =
      Game.new(members, 7)
      |> wall_arena()
      |> set_player(0, %{x: 60.0, y: 80.0, angle: 0.0})
      |> set_player(2, %{x: 270.0, y: 240.0, angle: 0.0})
      |> set_player(1, %{x: 80.0, y: 240.0, angle: 0.0})
      |> Game.set_order("form_up", "user-2")
      |> Game.step(%{})

    bot = Enum.at(game.players, 1)
    assert bot.x > 80
    assert_in_delta bot.y, 240, 2
  end

  test "aggressive bots investigate heard positions but never navigate using hidden enemy coordinates" do
    game = Game.new([hd(humans())], 17) |> Game.set_order("aggro", "user-0")
    changed = %{game | enemies: Enum.reverse(game.enemies)}
    original_bots = Game.step(game, %{}).players
    changed_bots = Game.step(changed, %{}).players
    assert original_bots == changed_bots
    assert Enum.all?(Enum.filter(original_bots, & &1.bot), &is_nil(&1.threat))

    game =
      Game.new([hd(humans())], 7)
      |> wall_arena()
      |> set_player(1, %{x: 280.0, y: 160.0, angle: 0.0})
      |> Game.set_order("aggro", "user-0")

    game = %{
      game
      | shots: [%{id: 999, x1: 420.0, y1: 160.0, x2: 450.0, y2: 160.0, team: "enemy", at: 0}]
    }

    game = Game.step(game, %{})
    assert Enum.at(game.players, 1).threat == {420.0, 160.0}
    assert Enum.at(game.players, 1).ammo == 20
    game = %{game | shots: []} |> set_enemy(0, %{x: 800.0, y: 400.0}) |> Game.step(%{})
    assert Enum.at(game.players, 1).threat == {420.0, 160.0}
  end

  defp compensated_scene do
    past =
      base()
      |> wall_arena()
      |> set_player(0, %{x: 80.0, y: 160.0})
      |> set_enemy(0, %{x: 220.0, y: 160.0, reaction_delay: 10_000})
      |> Arena.Game.LagCompensation.record()

    current = past |> set_enemy(0, %{y: 205.0})

    request = %{
      round_id: current.round_id,
      view_ms: 0,
      seen_tick: 0,
      rtt_ms: 60,
      received_at: System.monotonic_time(:millisecond)
    }

    {current, request}
  end

  test "shared history hits the displayed target while damage and positions remain current" do
    {game, view} = compensated_scene()
    input = %{aim: 0.0, shoot: true, effect_id: 1, shot_view: view}
    assert hd(Game.step(game, %{"user-0" => Map.delete(input, :shot_view)}).enemies).hp == 100
    hit = Game.step(game, %{"user-0" => input})
    assert hd(hit.enemies).hp == 66
    assert hd(hit.enemies).y > 190
    assert hd(hit.players).ammo == 19
    repeated = Enum.reduce(1..5, hit, fn _, g -> Game.step(g, %{"user-0" => input}) end)
    assert hd(repeated.players).ammo == 19
    assert hd(repeated.enemies).hp == 66
    assert Enum.any?(Game.public(hit, "user-0").shots, &(&1.local and &1.effect_id == 1))

    assert Enum.any?(
             Game.public(hit, "user-0").events,
             &(&1.type == "shot" and &1.local and &1.effect_id == 1)
           )

    refute Enum.any?(Game.public(hit, "user-1").shots, & &1.local)
  end

  test "rewind preserves walls, shared visibility, current death and weapon rules" do
    {game, view} = compensated_scene()

    for changed <- [
          set_player(game, 0, %{reload_ms: 500}),
          set_player(game, 0, %{cooldown_ms: 150}),
          set_player(game, 0, %{hp: 0})
        ] do
      assert hd(
               Game.step(changed, %{"user-0" => %{aim: 0.0, shoot: true, shot_view: view}}).enemies
             ).hp == 100
    end

    dead =
      set_enemy(game, 0, %{hp: 0})
      |> Game.step(%{"user-0" => %{aim: 0.0, shoot: true, shot_view: view}})

    assert hd(dead.enemies).hp == 0

    hidden =
      update_in(game.history, fn frames ->
        Enum.map(frames, &put_in(&1, [:enemies, "hostile-0", :visible], false))
      end)

    assert hd(Game.step(hidden, %{"user-0" => %{aim: 0.0, shoot: true, shot_view: view}}).enemies).hp ==
             100

    blocked = set_player(game, 0, %{x: 380.0})
    result = Game.step(blocked, %{"user-0" => %{aim: :math.pi(), shoot: true, shot_view: view}})
    assert hd(result.enemies).hp == 100
    assert hd(result.shots).x2 == 352.0
  end

  test "stale commands and previous rounds cannot rewind; shooter origin remains authoritative" do
    {game, view} = compensated_scene()

    for changes <- [
          %{round_id: -1},
          %{received_at: System.monotonic_time(:millisecond) - 300},
          %{seen_tick: 999}
        ] do
      input = %{aim: 0.0, shoot: true, shot_view: Map.merge(view, changes)}
      assert hd(Game.step(game, %{"user-0" => input}).enemies).hp == 100
    end

    moved = set_player(game, 0, %{y: 170.0})

    result =
      Game.step(moved, %{
        "user-0" => %{aim: 0.0, aim_point: {220.0, 160.0}, shoot: true, shot_view: view}
      })

    assert hd(result.enemies).hp == 66
    assert hd(result.shots).y1 == 170.0
  end

  defp flood(_map, [], seen), do: seen

  defp flood(map, [{x, y} = cell | rest], seen) do
    if MapSet.member?(seen, cell) or World.solid?(map, cell) do
      flood(map, rest, seen)
    else
      flood(map, [{x + 1, y}, {x - 1, y}, {x, y + 1}, {x, y - 1} | rest], MapSet.put(seen, cell))
    end
  end
end

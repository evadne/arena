defmodule Arena.Game do
  @moduledoc "Authoritative 20 Hz cooperative tactical simulation. AI acts only on sight and sound."
  alias Arena.Game.Map, as: World
  @pi :math.pi()
  @speed 140
  @reload 1500

  def new(members, seed, bot_names \\ nil) do
    map = World.generate(seed)

    players =
      for slot <- 0..3 do
        member = Enum.find(members, &(get(&1, :slot, -1) == slot))
        id = if member, do: get(member, :id, "operator-#{slot}"), else: "bot-#{slot}"

        name =
          if member,
            do: get(member, :name, "Operator"),
            else: Enum.at(bot_names || Arena.Callsigns.bot_names("TRAINING"), slot)

        actor(id, map.spawn.x + rem(slot, 2) * 34, map.spawn.y + div(slot, 2) * 34)
        |> Map.merge(%{name: name, slot: slot, bot: is_nil(member), angle: 0.3})
      end

    candidates =
      Enum.filter(map.floor, fn cell ->
        {x, y} = World.center(cell)

        distance({x, y}, {map.spawn.x, map.spawn.y}) > 390 and x > map.entry.x + 64 and
          Enum.all?(players, fn p ->
            distance(pos(p), {x, y}) > 440 or not World.clear?(map, pos(p), {x, y})
          end)
      end)

    # One guard per room plus a reserve: three to five enemies per operator.
    # The previous doubled room count made larger premises disproportionately hard.
    enemy_count = min(20, max(12, length(map.rooms) + 4 + World.random(seed, :enemy_count, 5)))

    occupied_rooms =
      Enum.filter(map.rooms, fn room ->
        Enum.any?(candidates, &inside_room?(World.center(&1), room))
      end)

    {enemies, _} =
      Enum.map_reduce(0..(enemy_count - 1), [], fn i, taken ->
        room = Enum.at(occupied_rooms, rem(i, length(occupied_rooms)))

        options =
          Enum.filter(candidates, fn cell ->
            inside_room?(World.center(cell), room) and
              Enum.all?(taken, &(distance(World.center(cell), World.center(&1)) >= 60))
          end)

        options =
          if options == [],
            do:
              Enum.filter(candidates, fn cell ->
                Enum.all?(taken, &(distance(World.center(cell), World.center(&1)) >= 60))
              end),
            else: options

        options = if options == [], do: Enum.reject(candidates, &(&1 in taken)), else: options

        cell = Enum.at(options, World.random(seed, {:enemy, i}, length(options)))
        {x, y} = World.center(cell)

        enemy =
          actor("hostile-#{i}", x, y)
          |> Map.merge(%{
            angle: World.random(seed, {:angle, i}, 628) / 100,
            home: {x, y},
            state: "patrol",
            memory: nil,
            memory_at: -10000,
            target_id: nil,
            reaction_ms: 0,
            reaction_delay: 500 + World.random(seed, {:reaction, i}, 201)
          })

        {enemy, [cell | taken]}
      end)

    %{
      seed: seed,
      round_id: System.unique_integer([:positive, :monotonic]),
      controls: %{},
      history: [],
      status: "playing",
      tick: 0,
      elapsed_ms: 0,
      map: map,
      players: players,
      enemies: enemies,
      order: "auto",
      order_by: nil,
      shots: [],
      shot_seq: 0,
      events: [],
      event_seq: 0,
      visible_tiles: MapSet.new(),
      explored_tiles: MapSet.new()
    }
    |> update_vision()
    |> Arena.Game.LagCompensation.record()
  end

  defp actor(id, x, y),
    do: %{
      id: id,
      x: x,
      y: y,
      angle: 0.0,
      hp: 100,
      ammo: 20,
      last_effect_id: 0,
      reload_ms: 0,
      cooldown_ms: 0,
      path: [],
      nav_goal: nil,
      nav_ms: 0,
      sweep_index: 0,
      sweep_until: 0,
      hold_anchor: nil,
      threat: nil,
      threat_at: -10000,
      hurt_at: -10000,
      previous_hp: 100,
      aim_target: nil,
      aim_ms: 0,
      burst_left: 2
    }

  def disconnect(game, user_id) do
    %{
      game
      | players:
          Enum.map(game.players, fn p -> if p.id == user_id, do: %{p | bot: true}, else: p end)
    }
  end

  def set_order(game, order, requester_id) when order in ["hold", "form_up", "aggro", "auto"] do
    if game.status == "playing" and
         Enum.any?(game.players, &(&1.id == requester_id and &1.hp > 0 and not &1.bot)) do
      players =
        Enum.map(game.players, fn p ->
          %{p | hold_anchor: if(order == "hold", do: pos(p), else: nil), nav_ms: 0}
        end)

      %{game | order: order, order_by: requester_id, players: players}
    else
      game
    end
  end

  def set_order(game, _order, _requester_id), do: game

  def step(game, inputs, dt_ms \\ 50)
  def step(%{status: status} = game, _inputs, _dt_ms) when status != "playing", do: game

  def step(game, inputs, dt_ms) do
    previous = game
    dt = max(1, min(100, dt_ms))
    now = game.elapsed_ms + dt

    game = %{
      game
      | elapsed_ms: now,
        tick: game.tick + 1,
        shots: Enum.filter(game.shots, &(now - &1.at < 160)),
        events: Enum.filter(game.events, &(now - &1.at < 200)),
        players: Enum.map(game.players, &timers(&1, dt)),
        enemies: Enum.map(game.enemies, &timers(&1, dt))
    }

    {players, actions} =
      Enum.map_reduce(game.players, %{}, fn player, actions ->
        if player.hp <= 0 do
          {player, actions}
        else
          {player, input} =
            if player.bot,
              do: teammate(player, game, dt),
              else: {player, Map.get(inputs, player.id, %{})}

          aim = number(get(input, :aim, player.angle), player.angle)
          x = number(get(input, :x, 0), 0) |> clamp(-1, 1)
          y = number(get(input, :y, 0), 0) |> clamp(-1, 1)
          norm = max(1.0, :math.sqrt(x * x + y * y))

          {px, py} =
            World.move(
              game.map,
              pos(player),
              {x / norm * @speed * dt / 1000, y / norm * @speed * dt / 1000}
            )

          player =
            %{player | x: px, y: py, angle: normalize(aim)}
            |> maybe_reload(get(input, :reload, false) == true)

          {player, Map.put(actions, player.id, input)}
        end
      end)

    controls = Map.new(inputs, fn {id, input} -> {id, Map.take(input, [:x, :y])} end)
    game = %{game | players: players, controls: controls}

    game =
      Enum.reduce(players, game, fn p, state ->
        input = Map.get(actions, p.id, %{})
        if get(input, :shoot, false) == true, do: shoot(state, :players, p.id, input), else: state
      end)

    game =
      Enum.reduce(Enum.map(game.enemies, & &1.id), game, fn id, state ->
        enemy = Enum.find(state.enemies, &(&1.id == id))

        if enemy.hp <= 0 do
          state
        else
          {enemy, fire?} = adversary(enemy, state, dt)
          state = %{state | enemies: replace(state.enemies, enemy)}
          if fire?, do: shoot(state, :enemies, id), else: state
        end
      end)

    status =
      cond do
        Enum.all?(game.enemies, &(&1.hp <= 0)) -> "won"
        Enum.all?(game.players, &(&1.hp <= 0)) -> "lost"
        true -> "playing"
      end

    game = %{game | status: status} |> transition_sounds(previous)

    game =
      if status != "playing",
        do:
          sound(game, "round_end", {512, 352}, if(status == "won", do: "friendly", else: "enemy")),
        else: game

    game |> update_vision() |> Arena.Game.LagCompensation.record()
  end

  defp timers(actor, dt) do
    ammo = if actor.reload_ms > 0 and actor.reload_ms <= dt, do: 20, else: actor.ammo

    %{
      actor
      | ammo: ammo,
        reload_ms: max(0, actor.reload_ms - dt),
        cooldown_ms: max(0, actor.cooldown_ms - dt),
        nav_ms: max(0, actor.nav_ms - dt)
    }
  end

  defp maybe_reload(p, reload?) do
    if p.reload_ms == 0 and p.ammo < 20 and (reload? or p.ammo == 0),
      do: %{p | reload_ms: @reload},
      else: p
  end

  defp shoot(game, side, id, input \\ %{}) do
    source = Enum.find(Map.fetch!(game, side), &(&1.id == id))

    effect_id = Map.get(input, :effect_id)

    cond do
      is_integer(effect_id) and effect_id <= source.last_effect_id ->
        game

      source.hp <= 0 or source.reload_ms > 0 or source.cooldown_ms > 0 ->
        game

      source.ammo == 0 ->
        Map.update!(game, side, &replace(&1, maybe_reload(source, true)))

      true ->
        opposite = if side == :players, do: :enemies, else: :players
        a = pos(source)

        candidates =
          if side == :players,
            do: Arena.Game.LagCompensation.targets(game, source, Map.get(input, :shot_view)),
            else: game.players

        spread =
          if side == :enemies,
            do:
              (World.random(game.seed, {:enemy_spread, id, game.shot_seq}, 2001) / 1000 - 1) *
                0.04,
            else: 0

        angle =
          case Map.get(input, :aim_point) do
            {x, y} when side == :players and not source.bot ->
              :math.atan2(y - source.y, x - source.x)

            _ ->
              Map.get(input, :shot_aim) || source.angle
          end

        angle = angle + spread
        {ax, ay} = a
        endpoint = {ax + :math.cos(angle) * 1100, ay + :math.sin(angle) * 1100}
        {wall_end, _} = World.ray(game.map, a, endpoint)
        wall_distance = distance(a, wall_end)

        target =
          candidates
          |> Enum.filter(&(&1.hp > 0))
          |> Enum.map(fn target -> {target, ray_circle(a, angle, pos(target), 11)} end)
          |> Enum.filter(fn {_t, d} -> is_number(d) and d < wall_distance end)
          |> Enum.min_by(&elem(&1, 1), fn -> nil end)

        {targets, finish} =
          case target do
            nil ->
              {Map.fetch!(game, opposite), wall_end}

            {victim, d} ->
              damage = if side == :players, do: 34, else: 16

              current = Enum.find(Map.fetch!(game, opposite), &(&1.id == victim.id))

              {replace(Map.fetch!(game, opposite), %{current | hp: max(0, current.hp - damage)}),
               {ax + :math.cos(angle) * d, ay + :math.sin(angle) * d}}
          end

        cooldown =
          if side == :players, do: 180, else: if(source.burst_left > 1, do: 160, else: 1000)

        burst =
          if side == :enemies,
            do: if(source.burst_left > 1, do: source.burst_left - 1, else: 2),
            else: source.burst_left

        source =
          %{
            source
            | ammo: source.ammo - 1,
              cooldown_ms: cooldown,
              burst_left: burst,
              last_effect_id: effect_id || source.last_effect_id
          }
          |> maybe_reload(get(input, :reload, false) == true)

        {fx, fy} = finish

        shot = %{
          id: game.shot_seq + 1,
          x1: ax,
          y1: ay,
          actor_id: source.id,
          effect_id: effect_id,
          x2: fx,
          y2: fy,
          team: if(side == :players, do: "friendly", else: "enemy"),
          at: game.elapsed_ms
        }

        game
        |> Map.put(opposite, targets)
        |> Map.update!(side, &replace(&1, source))
        |> Map.put(:shot_seq, shot.id)
        |> Map.update!(:shots, &[shot | &1])
        |> sound("shot", a, shot.team, %{actor_id: source.id, effect_id: effect_id})
    end
  end

  defp ray_circle({ax, ay}, angle, {tx, ty}, radius) do
    dx = tx - ax
    dy = ty - ay
    projection = dx * :math.cos(angle) + dy * :math.sin(angle)
    perpendicular_sq = max(0, dx * dx + dy * dy - projection * projection)

    if projection >= 0 and perpendicular_sq <= radius * radius,
      do: max(0, projection - :math.sqrt(radius * radius - perpendicular_sq)),
      else: nil
  end

  defp teammate(player, game, dt) do
    hurt? = player.hp < player.previous_hp

    player = %{
      player
      | previous_hp: player.hp,
        hurt_at: if(hurt?, do: game.elapsed_ms, else: player.hurt_at)
    }

    targets =
      Enum.filter(game.enemies, &(&1.hp > 0 and sees?(game.map, player, pos(&1), 360, 1.15, 65)))

    target = Enum.min_by(targets, &distance(pos(player), pos(&1)), fn -> nil end)

    heard =
      Enum.find(game.shots, fn shot ->
        location = {shot.x1, shot.y1}
        radius = if World.clear?(game.map, pos(player), location), do: 360, else: 220

        shot.team == "enemy" and game.elapsed_ms - shot.at < 150 and
          distance(pos(player), location) < radius
      end)

    player =
      cond do
        target -> %{player | threat: pos(target), threat_at: game.elapsed_ms}
        heard -> %{player | threat: {heard.x1, heard.y1}, threat_at: game.elapsed_ms}
        game.elapsed_ms - player.threat_at >= 6000 -> %{player | threat: nil}
        true -> player
      end

    player =
      if target,
        do: %{
          player
          | aim_target: target.id,
            aim_ms: if(player.aim_target == target.id, do: player.aim_ms + dt, else: dt)
        },
        else: %{player | aim_target: nil, aim_ms: 0}

    cond do
      target ->
        {dx, dy} = combat_movement(player, pos(target), game)

        spread =
          (World.random(game.seed, {:bot_spread, player.id, div(game.elapsed_ms, 230)}, 2001) /
             1000 - 1) * (0.052 + player.slot * 0.012)

        desired = heading(pos(player), pos(target)) + spread
        aim = player.angle + clamp(normalize(desired - player.angle), -dt * 0.005, dt * 0.005)
        fire? = player.aim_ms >= 250 + player.slot * 60 and abs(normalize(desired - aim)) < 0.12
        {player, %{x: dx, y: dy, aim: aim, shoot: fire?}}

      game.elapsed_ms - player.hurt_at < 1500 ->
        threat =
          player.threat ||
            {player.x + :math.cos(player.angle) * 100, player.y + :math.sin(player.angle) * 100}

        {dx, dy} = combat_movement(player, threat, game)
        {player, %{x: dx, y: dy, aim: heading(pos(player), threat)}}

      game.order == "hold" and Enum.any?(game.players, &(&1.hp > 0 and not &1.bot)) ->
        anchor = player.hold_anchor || pos(player)
        {player, {dx, dy}} = navigate(player, anchor, game.map, 14)
        {player, %{x: dx * 0.7, y: dy * 0.7, aim: player.angle + 0.035}}

      game.order == "aggro" ->
        if player.threat do
          {player, {dx, dy}} = navigate(player, player.threat, game.map, 30)

          if distance(pos(player), player.threat) < 35 do
            sweep(%{player | threat: nil}, game)
          else
            {player, %{x: dx, y: dy, aim: heading(pos(player), player.threat)}}
          end
        else
          sweep(player, game)
        end

      true ->
        issuer =
          if game.order == "form_up",
            do: Enum.find(game.players, &(&1.id == game.order_by and &1.hp > 0 and not &1.bot)),
            else: nil

        leader =
          issuer || Enum.find(game.players, &(&1.hp > 0 and not &1.bot)) ||
            Enum.find(game.players, &(&1.hp > 0))

        if leader && leader.id != player.id do
          offset = formation_offset(player.slot)
          {ox, oy} = rotate(offset, leader.angle)
          preferred = {leader.x + ox, leader.y + oy}
          goal = if World.fits?(game.map, preferred), do: preferred, else: pos(leader)
          {player, {dx, dy}} = navigate(player, goal, game.map, 30)

          angle =
            if abs(dx) + abs(dy) > 0.1,
              do: :math.atan2(dy, dx),
              else: leader.angle + :math.sin(game.elapsed_ms / 1600 + player.slot) * 0.8

          {player, %{x: dx * 0.95, y: dy * 0.95, aim: angle}}
        else
          sweep(player, game)
        end
    end
  end

  # Orders are intent, not a command to stand still under fire. Choose reachable nearby cover
  # using only the observed threat; reloads and recent damage favor breaking its line of sight.
  defp combat_movement(player, threat, game) do
    aim = heading(pos(player), threat)
    sign = if rem(player.slot + div(game.elapsed_ms, 1100), 2) == 0, do: 1, else: -1
    cover? = game.elapsed_ms - player.hurt_at < 1800 or player.reload_ms > 0 or player.hp < 35
    offsets = [{0, sign * 45}, {-40, sign * 36}, {-50, 0}, {0, -sign * 45}, {-40, -sign * 36}]

    candidates =
      Enum.map(offsets, fn offset ->
        {x, y} = rotate(offset, aim)
        {player.x + x, player.y + y}
      end)
      |> Enum.filter(&(World.fits?(game.map, &1) and corridor_clear?(game.map, pos(player), &1)))

    goal =
      if cover?,
        do:
          Enum.max_by(
            candidates,
            fn point ->
              if(World.clear?(game.map, point, threat), do: 0, else: 1000) +
                distance(point, threat)
            end,
            fn -> nil end
          ),
        else: List.first(candidates)

    if goal do
      {dx, dy} = direction(pos(player), goal)
      speed = if cover?, do: 0.8, else: 0.24
      {dx * speed, dy * speed}
    else
      {0.0, 0.0}
    end
  end

  # With no living humans, the senior bot methodically clears the blueprint, never enemy coordinates.
  defp sweep(player, game) do
    offset = if game.order == "aggro", do: player.slot * 2, else: 0
    room = Enum.at(game.map.rooms, rem(player.sweep_index + offset, length(game.map.rooms)))
    goal = {room.x + room.w / 2, room.y + room.h / 2}

    cond do
      player.sweep_until > game.elapsed_ms ->
        {player, %{aim: player.angle + 0.13}}

      distance(pos(player), goal) < 22 ->
        {%{player | sweep_index: player.sweep_index + 1, sweep_until: game.elapsed_ms + 2500},
         %{aim: player.angle + 0.13}}

      true ->
        {player, {dx, dy}} = navigate(player, goal, game.map, 18)
        {player, %{x: dx * 0.8, y: dy * 0.8, aim: :math.atan2(dy, dx)}}
    end
  end

  defp formation_offset(slot),
    do: {-48.0 - slot * 29, if(rem(slot, 2) == 0, do: -12.0, else: 12.0)}

  defp adversary(enemy, game, dt) do
    visible =
      Enum.filter(game.players, &(&1.hp > 0 and sees?(game.map, enemy, pos(&1), 360, 0.87, 42)))

    seen = Enum.min_by(visible, &distance(pos(enemy), pos(&1)), fn -> nil end)

    if seen do
      reaction = if enemy.target_id == seen.id, do: enemy.reaction_ms + dt, else: dt

      enemy = %{
        enemy
        | angle: heading(pos(enemy), pos(seen)),
          memory: pos(seen),
          memory_at: game.elapsed_ms,
          target_id: seen.id,
          reaction_ms: reaction,
          state: "engage"
      }

      # A continuous, readable acquisition delay precedes each new target. No movement while firing.
      {enemy, reaction >= enemy.reaction_delay}
    else
      heard =
        Enum.find(game.shots, fn shot ->
          location = {shot.x1, shot.y1}
          radius = if World.clear?(game.map, pos(enemy), location), do: 440, else: 250

          shot.team == "friendly" and game.elapsed_ms - shot.at <= dt and
            distance(pos(enemy), location) <= radius
        end)

      enemy =
        if heard,
          do: %{enemy | memory: {heard.x1, heard.y1}, memory_at: game.elapsed_ms},
          else: enemy

      # A brief occlusion does not make an already alerted guard forget how to shoot.
      # This retains only acquisition readiness; positions still come from sight/sound.
      enemy =
        if game.elapsed_ms - enemy.memory_at <= 800,
          do: enemy,
          else: %{enemy | target_id: nil, reaction_ms: 0}

      remembered? = enemy.memory != nil and game.elapsed_ms - enemy.memory_at < 6000
      goal = if remembered?, do: enemy.memory, else: patrol_goal(enemy, game)
      {enemy, {dx, dy}} = navigate(enemy, goal, game.map, 15)
      speed = if remembered?, do: 105, else: 48
      {x, y} = World.move(game.map, pos(enemy), {dx * speed * dt / 1000, dy * speed * dt / 1000})
      moving? = abs(dx) + abs(dy) > 0.1
      angle = if moving?, do: :math.atan2(dy, dx), else: normalize(enemy.angle + dt / 1500)

      state =
        cond do
          remembered? and moving? -> "alert"
          remembered? -> "search"
          true -> "patrol"
        end

      {%{
         enemy
         | x: x,
           y: y,
           angle: angle,
           state: state,
           memory: if(remembered?, do: enemy.memory, else: nil)
       }, false}
    end
  end

  defp patrol_goal(enemy, game) do
    choices = Enum.filter(game.map.floor, &(distance(World.center(&1), enemy.home) < 125))
    index = World.random(game.seed, {enemy.id, div(game.elapsed_ms, 5500)}, length(choices))
    World.center(Enum.at(choices, index))
  end

  defp navigate(actor, goal, map, stop_distance) do
    cond do
      distance(pos(actor), goal) < stop_distance ->
        {actor, {0.0, 0.0}}

      corridor_clear?(map, pos(actor), goal) ->
        {actor, direction(pos(actor), goal)}

      true ->
        refresh? = actor.nav_ms == 0 or actor.nav_goal != World.tile(goal) or actor.path == []

        actor =
          if refresh?,
            do: %{
              actor
              | path: World.path(map, pos(actor), goal),
                nav_goal: World.tile(goal),
                nav_ms: 600
            },
            else: actor

        path = Enum.drop_while(actor.path, &(distance(pos(actor), &1) < 7))
        actor = %{actor | path: path}

        case path do
          [] -> {actor, {0.0, 0.0}}
          [next | _] -> {actor, direction(pos(actor), next)}
        end
    end
  end

  defp corridor_clear?(map, {ax, ay}, {bx, by}) do
    {dx, dy} = direction({ax, ay}, {bx, by})

    World.clear?(map, {ax, ay}, {bx, by}) and
      World.clear?(map, {ax - dy * 11, ay + dx * 11}, {bx - dy * 11, by + dx * 11}) and
      World.clear?(map, {ax + dy * 11, ay - dx * 11}, {bx + dy * 11, by - dx * 11})
  end

  def sees?(map, observer, point, range \\ 410, half_angle \\ 1.05, near \\ 64) do
    d = distance(pos(observer), point)

    observer.hp > 0 and d <= range and
      (d <= near or abs(normalize(heading(pos(observer), point) - observer.angle)) <= half_angle) and
      World.clear?(map, pos(observer), point)
  end

  defp team_sees?(game, point), do: Enum.any?(game.players, &sees?(game.map, &1, point))

  defp update_vision(game) do
    visible = game.map.floor |> Enum.filter(&team_sees?(game, World.center(&1))) |> MapSet.new()
    %{game | visible_tiles: visible, explored_tiles: MapSet.union(game.explored_tiles, visible)}
  end

  def public(game, user_id \\ nil) do
    listener = Enum.find(game.players, &(&1.id == user_id))
    spectator = listener != nil and listener.hp <= 0
    visible_tiles = if spectator, do: game.map.floor, else: game.visible_tiles
    explored_tiles = if spectator, do: game.map.floor, else: game.explored_tiles

    %{
      seed: game.seed,
      round_id: game.round_id,
      control: Map.get(game.controls, user_id, %{x: 0, y: 0}),
      status: game.status,
      order: game.order,
      tick: game.tick,
      elapsed_ms: game.elapsed_ms,
      spectator: spectator,
      map: World.public(game.map),
      players:
        Enum.map(
          game.players,
          &Map.take(&1, [
            :id,
            :name,
            :slot,
            :x,
            :y,
            :angle,
            :hp,
            :ammo,
            :reload_ms,
            :bot,
            :last_effect_id
          ])
        ),
      enemies:
        game.enemies
        |> Enum.filter(&(spectator or (&1.hp > 0 and team_sees?(game, pos(&1)))))
        |> Enum.map(&Map.take(&1, [:id, :x, :y, :angle, :hp, :state])),
      enemies_remaining: Enum.count(game.enemies, &(&1.hp > 0)),
      enemies_total: length(game.enemies),
      shots:
        game.shots
        |> Enum.filter(&(spectator or &1.team == "friendly" or team_sees?(game, {&1.x1, &1.y1})))
        |> Enum.map(
          &(Map.drop(&1, [:at, :actor_id])
            |> Map.put(:local, Map.get(&1, :actor_id) == user_id))
        ),
      events: audible_events(game, listener, spectator),
      visible_tiles: Enum.map(visible_tiles, fn {x, y} -> [x, y] end),
      explored_tiles: Enum.map(explored_tiles, fn {x, y} -> [x, y] end)
    }
  end

  defp sound(game, type, {x, y}, team, metadata \\ %{}) do
    event =
      Map.merge(
        %{id: game.event_seq + 1, type: type, x: x, y: y, team: team, at: game.elapsed_ms},
        metadata
      )

    %{game | event_seq: event.id, events: [event | game.events]}
  end

  defp transition_sounds(game, previous) do
    Enum.reduce([{:players, "friendly"}, {:enemies, "enemy"}], game, fn {side, team}, state ->
      Enum.reduce(Map.fetch!(state, side), state, fn actor, state ->
        before = Enum.find(Map.fetch!(previous, side), &(&1.id == actor.id))

        state =
          if before.reload_ms == 0 and actor.reload_ms > 0,
            do: sound(state, "reload", pos(actor), team),
            else: state

        state = if actor.hp < before.hp, do: sound(state, "hit", pos(actor), team), else: state

        if actor.hp == 0 and before.hp > 0,
          do: sound(state, "death", pos(actor), team),
          else: state
      end)
    end)
  end

  defp audible_events(game, listener, spectator) do
    listeners = if listener, do: [listener], else: Enum.filter(game.players, &(&1.hp > 0))

    Enum.flat_map(game.events, fn event ->
      nearest = Enum.min_by(listeners, &distance(pos(&1), {event.x, event.y}), fn -> nil end)

      cond do
        event.type == "round_end" ->
          [Map.drop(event, [:at]) |> Map.merge(%{volume: 0.7, occluded: false})]

        nearest == nil ->
          []

        true ->
          d = distance(pos(nearest), {event.x, event.y})
          occluded = not World.clear?(game.map, pos(nearest), {event.x, event.y})
          radius = if event.type == "shot", do: 440, else: 210
          radius = if occluded, do: radius * 0.65, else: radius

          if spectator or d < radius do
            volume = if spectator, do: max(0.15, 1 - d / 1200), else: max(0.03, 1 - d / radius)
            volume = if occluded and not spectator, do: volume * 0.45, else: volume

            [
              Map.drop(event, [:at, :actor_id])
              |> Map.put(:local, listener != nil and Map.get(event, :actor_id) == listener.id)
              |> Map.merge(%{volume: volume, occluded: occluded and not spectator})
            ]
          else
            []
          end
      end
    end)
  end

  defp replace(actors, actor),
    do: Enum.map(actors, fn a -> if a.id == actor.id, do: actor, else: a end)

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp number(n, _default) when is_number(n), do: n
  defp number(_, default), do: default
  defp clamp(n, low, high), do: max(low, min(high, n))
  defp pos(actor), do: {actor.x, actor.y}

  defp inside_room?({x, y}, room),
    do: x >= room.x and y >= room.y and x < room.x + room.w and y < room.y + room.h

  defp heading({ax, ay}, {bx, by}), do: :math.atan2(by - ay, bx - ax)
  defp distance({ax, ay}, {bx, by}), do: :math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by))

  defp direction(a, b) do
    d = max(0.00001, distance(a, b))
    {(elem(b, 0) - elem(a, 0)) / d, (elem(b, 1) - elem(a, 1)) / d}
  end

  defp rotate({x, y}, a),
    do: {x * :math.cos(a) - y * :math.sin(a), x * :math.sin(a) + y * :math.cos(a)}

  defp normalize(a), do: a - 2 * @pi * floor((a + @pi) / (2 * @pi))
end

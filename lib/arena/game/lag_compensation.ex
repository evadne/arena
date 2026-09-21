defmodule Arena.Game.LagCompensation do
  @moduledoc "Shared per-round actor history; timing is specific to the firing connection."
  @max_rewind 1000
  @interpolation 100
  @tolerance 200

  def record(game) do
    enemies =
      Map.new(game.enemies, fn e ->
        visible =
          e.hp > 0 and Enum.any?(game.players, &Arena.Game.sees?(game.map, &1, {e.x, e.y}))

        {e.id, Map.take(e, [:id, :x, :y, :hp]) |> Map.put(:visible, visible)}
      end)

    frame = %{tick: game.tick, time: game.elapsed_ms, enemies: enemies}

    history =
      [frame | Enum.reject(game.history, &(&1.time >= frame.time))]
      |> Enum.filter(&(frame.time - &1.time <= @max_rewind))
      |> Enum.take(21)

    %{game | history: history}
  end

  # Our render clock is anchored to snapshot arrival, so its age at command
  # execution includes the outward frame leg AND inward input leg (ACK RTT),
  # plus the 100ms remote interpolation. Do not halve RTT or add reaction time.
  def target_time(now_ms, request, queued_ms) do
    correct = min(@max_rewind, max(0, request.rtt_ms) + @interpolation + max(0, queued_ms))
    claimed = request.view_ms

    if claimed >= 0 and claimed <= now_ms and now_ms - claimed <= @max_rewind and
         abs(correct - (now_ms - claimed)) <= @tolerance,
       do: claimed,
       else: max(0, now_ms - correct)
  end

  def targets(game, source, %{round_id: round} = request) when round == game.round_id do
    queued = System.monotonic_time(:millisecond) - request.received_at

    with true <- not source.bot and source.hp > 0 and queued >= 0 and queued <= 250,
         seen when not is_nil(seen) <- Enum.find(game.history, &(&1.tick == request.seen_tick)),
         time = target_time(game.elapsed_ms, request, queued),
         true <- time <= seen.time,
         {before, after_frame} <- bracket(game.history, time) do
      fraction =
        if after_frame.time == before.time,
          do: 0,
          else: (time - before.time) / (after_frame.time - before.time)

      for current <- game.enemies,
          current.hp > 0,
          shown = seen.enemies[current.id],
          shown != nil and shown.visible,
          a = before.enemies[current.id],
          b = after_frame.enemies[current.id],
          a != nil and b != nil and a.hp > 0 and b.hp > 0,
          continuous?(game.history, current, time) do
        # Newly visible actors bypass interpolation in the browser too.
        point =
          if a.visible and b.visible,
            do: %{x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction},
            else: shown

        %{current | x: point.x, y: point.y}
      end
    else
      _ -> game.enemies
    end
  end

  def targets(game, _, _), do: game.enemies

  defp bracket(history, time) do
    before = Enum.find(history, &(&1.time <= time))
    after_frame = history |> Enum.reverse() |> Enum.find(&(&1.time >= time))
    if before && after_frame, do: {before, after_frame}, else: nil
  end

  # Do not interpolate across death or teleport-like discontinuities. This is
  # checked over the whole interval, not just the two bracketing positions.
  defp continuous?(history, current, time) do
    history
    |> Enum.take_while(&(&1.time >= time - 50))
    |> Enum.reduce_while(current, fn frame, previous ->
      case frame.enemies[current.id] do
        %{hp: hp} = actor when hp > 0 ->
          if (actor.x - previous.x) ** 2 + (actor.y - previous.y) ** 2 <= 64 * 64,
            do: {:cont, actor},
            else: {:halt, false}

        _ ->
          {:halt, false}
      end
    end)
    |> then(&(&1 != false))
  end
end

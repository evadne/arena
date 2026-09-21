# mix run --no-start scripts/balance.exs [seed_count] [seconds]
# Deterministic, server-authoritative unattended squad benchmark, not a human win-rate estimate.
count = System.argv() |> Enum.at(0, "12") |> String.to_integer()
seconds = System.argv() |> Enum.at(1, "180") |> String.to_integer()

results =
  for scenario <- [:idle_human_aggro, :dead_human_auto], seed <- 1..count do
    game = Arena.Game.new([%{id: "human", name: "Human", slot: 0}], seed)

    game =
      case scenario do
        :idle_human_aggro ->
          Arena.Game.set_order(game, "aggro", "human")

        :dead_human_auto ->
          %{
            game
            | players: Enum.map(game.players, fn p -> if p.bot, do: p, else: %{p | hp: 0} end)
          }
      end

    final =
      Enum.reduce_while(1..div(seconds * 1000, 50), game, fn _, state ->
        next = Arena.Game.step(state, %{})
        if next.status == "playing", do: {:cont, next}, else: {:halt, next}
      end)

    result = %{
      scenario: scenario,
      seed: seed,
      result: final.status,
      seconds: final.elapsed_ms / 1000,
      killed: Enum.count(final.enemies, &(&1.hp == 0)),
      enemies: length(final.enemies),
      bot_hp: final.players |> Enum.filter(& &1.bot) |> Enum.map(& &1.hp) |> Enum.sum(),
      human_hp: hd(final.players).hp,
      squad_hp: final.players |> Enum.map(& &1.hp) |> Enum.sum()
    }

    IO.puts(Jason.encode!(result))
    result
  end

Enum.each(Enum.group_by(results, & &1.scenario), fn {scenario, runs} ->
  avg = fn key -> Enum.sum(Enum.map(runs, &Map.fetch!(&1, key))) / length(runs) end

  IO.puts(
    Jason.encode!(%{
      summary: scenario,
      runs: length(runs),
      wins: Enum.count(runs, &(&1.result == "won")),
      losses: Enum.count(runs, &(&1.result == "lost")),
      stalls: Enum.count(runs, &(&1.result == "playing")),
      average_killed: avg.(:killed),
      average_enemies: avg.(:enemies),
      average_bot_hp: avg.(:bot_hp),
      average_squad_hp: avg.(:squad_hp)
    })
  )
end)

defmodule Arena.LagCompensationTest do
  use ExUnit.Case, async: true
  alias Arena.Game.LagCompensation, as: Lag

  test "command time is checked against observed latency plus interpolation, not human reaction" do
    request = %{rtt_ms: 120, view_ms: 750}
    assert Lag.target_time(1000, request, 30) == 750
    # A fabricated command far in the past/future uses the measured estimate.
    assert Lag.target_time(1000, %{request | view_ms: 0}, 30) == 750
    assert Lag.target_time(1000, %{request | view_ms: 1200}, 30) == 750
    assert Lag.target_time(2000, %{rtt_ms: 5000, view_ms: 0}, 0) == 1000
  end

  test "one common history is bounded to one second and excluded from public snapshots" do
    game = Arena.Game.new([%{id: "me", slot: 0, name: "Me"}], 7)

    final =
      Enum.reduce(1..100, game, fn tick, state ->
        Lag.record(%{state | tick: tick, elapsed_ms: tick * 50})
      end)

    assert length(final.history) == 21
    assert hd(final.history).time == 5000
    assert List.last(final.history).time == 4000
    assert length(Lag.record(final).history) == 21
    refute Map.has_key?(Arena.Game.public(final, "me"), :history)
    refute Map.has_key?(hd(final.history), :map)
    new = Arena.Game.new([%{id: "me", slot: 0, name: "Me"}], 7)
    assert length(new.history) == 1
    assert new.round_id != game.round_id
  end

  test "fractional history sampling rejects death and teleport discontinuities" do
    source = %{id: "me", hp: 100, bot: false}
    enemy = %{id: "target", hp: 100, x: 100.0, y: 120.0}

    frame = fn time, y, hp ->
      %{
        tick: div(time, 50),
        time: time,
        enemies: %{"target" => %{enemy | y: y, hp: hp} |> Map.put(:visible, true)}
      }
    end

    game = %{
      round_id: 1,
      elapsed_ms: 200,
      enemies: [enemy],
      history: [frame.(150, 120.0, 100), frame.(100, 110.0, 100), frame.(50, 100.0, 100)]
    }

    view = %{
      round_id: 1,
      view_ms: 75,
      seen_tick: 3,
      rtt_ms: 25,
      received_at: System.monotonic_time(:millisecond)
    }

    assert [%{y: 105.0}] = Lag.targets(game, source, view)
    teleported = %{game | enemies: [%{enemy | x: 500.0}]}
    assert Lag.targets(teleported, source, view) == []

    dead_history = %{
      game
      | history: [frame.(150, 120.0, 100), frame.(100, 110.0, 0), frame.(50, 100.0, 100)]
    }

    assert Lag.targets(dead_history, source, view) == []
  end
end

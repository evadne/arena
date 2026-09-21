# Emit authoritative collision fixtures for the browser parity test.
alias Arena.Game.Map, as: World
fixtures = for seed <- [7, 19, 42], {x, y} <- Enum.take_every(World.generate(seed).floor, 7), {dx, dy} <- [{7, 0}, {0, -7}, {4.9497474683, 4.9497474683}, {-17, 23}, {80, -40}] do
  map = World.generate(seed)
  origin = World.center({x, y})
  {px, py} = World.move(map, origin, {dx, dy})
  %{seed: seed, origin: Tuple.to_list(origin), delta: [dx, dy], expected: [px, py]}
end
# Tangency, negative/out-of-bounds and a narrow opening against a known grid.
map = World.generate(7)
edge = for origin <- [{-1.0, 32.0}, {0.0, 0.0}, {42.0, 42.0}, {22.0, 22.0}], delta <- [{1, 1}, {32, -32}] do
  {x, y} = World.move(map, origin, delta)
  %{seed: 7, origin: Tuple.to_list(origin), delta: Tuple.to_list(delta), expected: [x, y]}
end
IO.puts(Jason.encode!(%{maps: Map.new([7, 19, 42], &{&1, World.public(World.generate(&1))}), cases: fixtures ++ edge}))

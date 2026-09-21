defmodule Arena.Game.Map do
  @moduledoc "Seeded, connected room layouts and authoritative geometry. All positions are pixels."
  @tile 32
  @cols 44
  @rows 32

  def generate(seed) do
    archetype = Enum.at(["house", "office", "workshop"], random(seed, :archetype, 3))
    count = 8 + random(seed, :room_count, 5)
    first = %{x: 7, y: 13, w: 5 + random(seed, :foyer_w, 3), h: 5 + random(seed, :foyer_h, 2)}
    {packed, doors} = pack(seed, archetype, count, first, 0)
    # Every new room attaches to an existing room through a two-tile doorway.
    # This grows an irregular footprint instead of subdividing a rectangular box.
    interior =
      Enum.reduce(packed, MapSet.new(), fn room, cells ->
        Enum.reduce(room.y..(room.y + room.h - 1), cells, fn y, cells ->
          Enum.reduce(room.x..(room.x + room.w - 1), cells, &MapSet.put(&2, {&1, y}))
        end)
      end)

    staging = for x <- 2..5, y <- 14..18, do: {x, y}
    floor_set = Enum.reduce(staging ++ [{6, 15}, {6, 16}] ++ doors, interior, &MapSet.put(&2, &1))
    floor = Enum.sort(floor_set)

    grid =
      for x <- 0..(@cols - 1),
          y <- 0..(@rows - 1),
          not MapSet.member?(floor_set, {x, y}),
          into: MapSet.new(),
          do: {x, y}

    walls =
      grid
      |> Enum.filter(fn {x, y} ->
        Enum.any?(
          for(dx <- -1..1, dy <- -1..1, do: {x + dx, y + dy}),
          &MapSet.member?(floor_set, &1)
        )
      end)
      |> Enum.sort()
      |> Enum.map(fn {x, y} -> %{x: x * @tile, y: y * @tile, w: @tile, h: @tile} end)

    labels = labels(archetype)

    rooms =
      packed
      |> Enum.with_index()
      |> Enum.map(fn {r, i} ->
        %{
          x: r.x * @tile,
          y: r.y * @tile,
          w: r.w * @tile,
          h: r.h * @tile,
          label: Enum.at(labels, i)
        }
      end)

    entry_label =
      case archetype do
        "house" ->
          Enum.at(["FRONT DOOR", "GARAGE ENTRY", "WINDOW BREACH"], random(seed, :entry, 3))

        "office" ->
          "SERVICE ENTRANCE"

        "workshop" ->
          "LOADING DOOR"
      end

    %{
      width: @cols * @tile,
      height: @rows * @tile,
      tile_size: @tile,
      walls: walls,
      rooms: rooms,
      archetype: archetype,
      entry: %{x: 6.5 * @tile, y: 16 * @tile, label: entry_label},
      spawn: %{x: 3.5 * @tile, y: 15.5 * @tile},
      grid: grid,
      floor: floor,
      floor_tiles: Enum.map(floor, fn {x, y} -> [x, y] end),
      exterior_tiles: Enum.map(staging, fn {x, y} -> [x, y] end)
    }
  end

  defp pack(seed, archetype, count, first, retry) do
    {rooms, doors} = grow({seed, retry}, archetype, count, [first], [], 0)

    if length(rooms) == count,
      do: {rooms, doors},
      else: pack(seed, archetype, count, first, retry + 1)
  end

  defp grow(_seed, _type, count, rooms, doors, _attempt) when length(rooms) >= count,
    do: {rooms, doors}

  defp grow(_seed, _type, _count, rooms, doors, 4000), do: {rooms, doors}

  defp grow(seed, type, count, rooms, doors, attempt) do
    parent = Enum.at(rooms, random(seed, {:parent, attempt}, length(rooms)))
    side = Enum.at([:east, :north, :south, :west], random(seed, {:side, attempt}, 4))
    index = length(rooms)
    # Halls are long and narrow; other rooms vary by premises and seed.
    hall? = index in [1, 6]
    w = if hall?, do: 3, else: 4 + random(seed, {:width, attempt, type}, 5)

    h =
      if hall?,
        do: 6 + random(seed, {:hall, attempt}, 3),
        else: 4 + random(seed, {:height, attempt, type}, 4)

    {w, h} = if hall? and side in [:east, :west], do: {h, w}, else: {w, h}

    {x, y} =
      case side do
        :east ->
          {parent.x + parent.w + 1,
           parent.y - h + 2 + random(seed, {:offset, attempt}, h + parent.h - 3)}

        :west ->
          {parent.x - w - 1,
           parent.y - h + 2 + random(seed, {:offset, attempt}, h + parent.h - 3)}

        :south ->
          {parent.x - w + 2 + random(seed, {:offset, attempt}, w + parent.w - 3),
           parent.y + parent.h + 1}

        :north ->
          {parent.x - w + 2 + random(seed, {:offset, attempt}, w + parent.w - 3),
           parent.y - h - 1}
      end

    room = %{x: x, y: y, w: w, h: h}

    valid =
      x >= 7 and y >= 2 and x + w < @cols - 1 and y + h < @rows - 1 and
        Enum.all?(rooms, fn other ->
          x > other.x + other.w or other.x > x + w or y > other.y + other.h or other.y > y + h
        end)

    if valid do
      doorway =
        case side do
          horizontal when horizontal in [:east, :west] ->
            low = max(y, parent.y)
            high = min(y + h, parent.y + parent.h) - 2
            at = low + random(seed, {:door, attempt}, high - low + 1)
            wall_x = if side == :east, do: x - 1, else: parent.x - 1
            [{wall_x, at}, {wall_x, at + 1}]

          _ ->
            low = max(x, parent.x)
            high = min(x + w, parent.x + parent.w) - 2
            at = low + random(seed, {:door, attempt}, high - low + 1)
            wall_y = if side == :south, do: y - 1, else: parent.y - 1
            [{at, wall_y}, {at + 1, wall_y}]
        end

      grow(seed, type, count, rooms ++ [room], doorway ++ doors, attempt + 1)
    else
      grow(seed, type, count, rooms, doors, attempt + 1)
    end
  end

  defp labels("house"),
    do: [
      "FOYER",
      "HALLWAY",
      "LIVING ROOM",
      "KITCHEN",
      "BEDROOM",
      "BATHROOM",
      "SIDE HALL",
      "STUDY",
      "UTILITY",
      "GARAGE",
      "GUEST ROOM",
      "PANTRY"
    ]

  defp labels("office"),
    do: [
      "RECEPTION",
      "CORRIDOR",
      "OPEN OFFICE",
      "MEETING ROOM",
      "DIRECTOR",
      "RECORDS",
      "SIDE HALL",
      "SERVER ROOM",
      "KITCHENETTE",
      "COPY ROOM",
      "BREAK ROOM",
      "ARCHIVE"
    ]

  defp labels("workshop"),
    do: [
      "LOADING BAY",
      "SERVICE HALL",
      "WORKSHOP",
      "PARTS STORE",
      "OFFICE",
      "MACHINE ROOM",
      "SIDE HALL",
      "TOOL ROOM",
      "DISPATCH",
      "ASSEMBLY",
      "PAINT ROOM",
      "UTILITY"
    ]

  def random(seed, key, count), do: :erlang.phash2({seed, key}, max(count, 1))
  def tile({x, y}), do: {floor(x / @tile), floor(y / @tile)}
  def center({x, y}), do: {x * @tile + @tile / 2, y * @tile + @tile / 2}

  def solid?(map, {x, y}),
    do:
      x < 0 or y < 0 or x >= div(map.width, @tile) or y >= div(map.height, @tile) or
        MapSet.member?(map.grid, {x, y})

  def clear?(map, a, b), do: not elem(ray(map, a, b), 1)

  # Exact grid traversal: returns the first wall intersection, never a sample beyond a wall.
  def ray(map, {ax, ay} = a, {bx, by} = b) do
    dx = bx - ax
    dy = by - ay
    {cx, cy} = tile(a)

    if solid?(map, {cx, cy}) do
      {a, true}
    else
      sx = if dx >= 0, do: 1, else: -1
      sy = if dy >= 0, do: 1, else: -1

      tx =
        if abs(dx) < 0.000001,
          do: 1.0e20,
          else: (if(sx > 0, do: cx + 1, else: cx) * @tile - ax) / dx

      ty =
        if abs(dy) < 0.000001,
          do: 1.0e20,
          else: (if(sy > 0, do: cy + 1, else: cy) * @tile - ay) / dy

      dtx = if abs(dx) < 0.000001, do: 1.0e20, else: @tile / abs(dx)
      dty = if abs(dy) < 0.000001, do: 1.0e20, else: @tile / abs(dy)
      traverse(map, a, b, {cx, cy}, {sx, sy}, {tx, ty}, {dtx, dty}, 0)
    end
  end

  defp traverse(_map, _a, b, _cell, _step, _next, _delta, 100), do: {b, false}

  defp traverse(
         map,
         {ax, ay} = a,
         {bx, by} = b,
         {cx, cy},
         {sx, sy} = step,
         {tx, ty},
         {dtx, dty} = delta,
         n
       ) do
    t = min(tx, ty)

    cond do
      t > 1 ->
        {b, false}

      abs(tx - ty) < 0.0000001 ->
        hit =
          solid?(map, {cx + sx, cy}) or solid?(map, {cx, cy + sy}) or
            solid?(map, {cx + sx, cy + sy})

        if hit,
          do: {{ax + (bx - ax) * t, ay + (by - ay) * t}, true},
          else: traverse(map, a, b, {cx + sx, cy + sy}, step, {tx + dtx, ty + dty}, delta, n + 1)

      tx < ty ->
        if solid?(map, {cx + sx, cy}),
          do: {{ax + (bx - ax) * t, ay + (by - ay) * t}, true},
          else: traverse(map, a, b, {cx + sx, cy}, step, {tx + dtx, ty}, delta, n + 1)

      true ->
        if solid?(map, {cx, cy + sy}),
          do: {{ax + (bx - ax) * t, ay + (by - ay) * t}, true},
          else: traverse(map, a, b, {cx, cy + sy}, step, {tx, ty + dty}, delta, n + 1)
    end
  end

  def fits?(map, {x, y}, radius \\ 10) do
    {lx, ly} = tile({x - radius, y - radius})
    {hx, hy} = tile({x + radius, y + radius})

    Enum.all?(for(cx <- lx..hx, cy <- ly..hy, do: {cx, cy}), fn {cx, cy} = cell ->
      nx = max(cx * @tile, min(x, (cx + 1) * @tile))
      ny = max(cy * @tile, min(y, (cy + 1) * @tile))
      not solid?(map, cell) or (x - nx) * (x - nx) + (y - ny) * (y - ny) >= radius * radius
    end)
  end

  def move(map, {x, y}, {dx, dy}) do
    count = max(1, ceil(max(abs(dx), abs(dy)) / 6))

    Enum.reduce(1..count, {x, y}, fn _, {px, py} ->
      nx = if fits?(map, {px + dx / count, py}), do: px + dx / count, else: px
      ny = if fits?(map, {nx, py + dy / count}), do: py + dy / count, else: py
      {nx, ny}
    end)
  end

  def path(map, start, goal) do
    start = tile(start)
    goal = tile(goal)
    if solid?(map, goal), do: [], else: bfs(map, :queue.from_list([start]), %{start => nil}, goal)
  end

  defp bfs(map, queue, seen, goal) do
    case :queue.out(queue) do
      {:empty, _} ->
        []

      {{:value, ^goal}, _} ->
        reconstruct(seen, goal, []) |> Enum.drop(1) |> Enum.map(&center/1)

      {{:value, {x, y} = cell}, queue} ->
        {queue, seen} =
          Enum.reduce([{x + 1, y}, {x - 1, y}, {x, y + 1}, {x, y - 1}], {queue, seen}, fn next,
                                                                                          {q, s} ->
            if solid?(map, next) or Map.has_key?(s, next),
              do: {q, s},
              else: {:queue.in(next, q), Map.put(s, next, cell)}
          end)

        bfs(map, queue, seen, goal)
    end
  end

  defp reconstruct(_seen, nil, acc), do: acc
  defp reconstruct(seen, cell, acc), do: reconstruct(seen, Map.get(seen, cell), [cell | acc])

  def public(map),
    do:
      Map.take(map, [
        :width,
        :height,
        :tile_size,
        :walls,
        :rooms,
        :spawn,
        :archetype,
        :entry,
        :floor_tiles,
        :exterior_tiles
      ])
end

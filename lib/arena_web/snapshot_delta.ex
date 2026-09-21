defmodule ArenaWeb.SnapshotDelta do
  @moduledoc """
  Pure encoding of personalized snapshots against the previous sent baseline.

  Geometry is immutable within a seed. Actor and tile collections are keyed by
  ID and coordinate respectively. Shots and sounds are transient new-ID emissions,
  not persistent collections to merge into the baseline.
  """

  @collections [:map, :players, :enemies, :visible_tiles, :explored_tiles, :shots, :events]

  def encode(current, baseline, seq, base_seq) do
    if is_nil(baseline) or current.seed != baseline.seed do
      %{seq: seq, base: nil, full: current}
    else
      %{seq: seq, base: base_seq}
      |> put_changes(:changes, changed_fields(Map.drop(current, @collections), baseline))
      |> put_changes(:players, actors(current.players, baseline.players))
      |> put_changes(:enemies, actors(current.enemies, baseline.enemies))
      |> put_changes(:visible_tiles, tiles(current.visible_tiles, baseline.visible_tiles))
      |> put_changes(:explored_tiles, tiles(current.explored_tiles, baseline.explored_tiles))
      |> put_changes(:shots, new_events(current.shots, baseline.shots))
      |> put_changes(:events, new_events(current.events, baseline.events))
    end
  end

  defp changed_fields(current, baseline) do
    Enum.reduce(current, %{}, fn {key, value}, changes ->
      if Map.fetch(baseline, key) == {:ok, value},
        do: changes,
        else: Map.put(changes, key, value)
    end)
  end

  defp actors(current, baseline) do
    previous = Map.new(baseline, &{&1.id, &1})
    current_ids = MapSet.new(current, & &1.id)

    upsert =
      Enum.flat_map(current, fn actor ->
        case Map.fetch(previous, actor.id) do
          :error ->
            [actor]

          {:ok, before} ->
            changes = changed_fields(actor, before)
            if map_size(changes) == 0, do: [], else: [Map.put(changes, :id, actor.id)]
        end
      end)

    remove = for actor <- baseline, not MapSet.member?(current_ids, actor.id), do: actor.id
    if upsert == [] and remove == [], do: %{}, else: %{upsert: upsert, remove: remove}
  end

  defp tiles(current, baseline) do
    current_set = MapSet.new(current)
    previous_set = MapSet.new(baseline)
    add = Enum.reject(current, &MapSet.member?(previous_set, &1))
    remove = Enum.reject(baseline, &MapSet.member?(current_set, &1))
    if add == [] and remove == [], do: %{}, else: %{add: add, remove: remove}
  end

  defp new_events(current, baseline) do
    previous_ids = MapSet.new(baseline, & &1.id)
    Enum.reject(current, &MapSet.member?(previous_ids, &1.id))
  end

  defp put_changes(frame, _key, empty) when empty == %{} or empty == [], do: frame
  defp put_changes(frame, key, changes), do: Map.put(frame, key, changes)
end

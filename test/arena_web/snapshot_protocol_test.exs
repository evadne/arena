defmodule ArenaWeb.SnapshotProtocolTest do
  use ExUnit.Case, async: true
  import Phoenix.ChannelTest
  @endpoint ArenaWeb.Endpoint

  defp join(protocol) do
    code =
      ("P" <> Integer.to_string(System.unique_integer([:positive]), 36))
      |> String.pad_trailing(6, "X")

    {:ok, socket} = connect(ArenaWeb.UserSocket, %{})

    {:ok, reply, socket} =
      subscribe_and_join(socket, ArenaWeb.LobbyChannel, "lobby:#{code}", %{
        "name" => "Protocol",
        "protocol" => protocol
      })

    [{pid, _}] = Registry.lookup(Arena.Registry, code)

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(Arena.LobbySupervisor, pid)
    end)

    {socket, reply, pid}
  end

  test "protocol 2 sends geometry once, refreshes it for next round, and retains dynamic vision" do
    {socket, reply, _} = join(2)
    game = Arena.Game.new(reply.lobby.members, 7)
    send(socket.channel_pid, {:game_snapshot, game})
    assert_push("snapshot", %{map: map, visible_tiles: tiles, tick: 0})
    assert map.width > 0
    assert tiles != []
    send(socket.channel_pid, {:game_snapshot, %{game | tick: 1}})
    assert_push("snapshot", next)
    refute Map.has_key?(next, :map)
    assert next.visible_tiles == tiles
    assert length(next.players) == 4
    send(socket.channel_pid, {:lobby, reply.lobby})
    send(socket.channel_pid, {:game_snapshot, game})
    assert_push("snapshot", %{map: ^map, tick: 0})
  end

  test "legacy clients continue receiving complete snapshots" do
    {socket, reply, _} = join(1)
    game = Arena.Game.new(reply.lobby.members, 9)
    send(socket.channel_pid, {:game_snapshot, game})
    assert_push("snapshot", %{map: map})
    send(socket.channel_pid, {:game_snapshot, %{game | tick: 1}})
    assert_push("snapshot", %{map: ^map})
  end

  test "late join reply contains geometry before compact updates" do
    {socket, reply, pid} = join(2)
    game = Arena.Game.new(reply.lobby.members, 11)
    :sys.replace_state(pid, &%{&1 | status: "playing", game: game})
    {:ok, peer} = connect(ArenaWeb.UserSocket, %{})

    {:ok, joined, peer} =
      subscribe_and_join(peer, ArenaWeb.LobbyChannel, socket.topic, %{
        "name" => "Late",
        "protocol" => 2
      })

    assert joined.game.map.width > 0
    send(peer.channel_pid, {:game_snapshot, game})
    assert_push("snapshot", next)
    refute Map.has_key?(next, :map)
  end

  test "protocol 3 keeps one frame in flight and coalesces slow-client ticks against its ACK" do
    {socket, reply, _} = join(3)
    game = Arena.Game.new(reply.lobby.members, 7)
    send(socket.channel_pid, {:game_snapshot, game})
    assert %{seq: 1, base: nil, full: %{tick: 0, map: map}} = frame(socket)
    assert map.width > 0
    first_sent_at = stream(socket).sent_at

    for tick <- 1..100, do: send(socket.channel_pid, {:game_snapshot, %{game | tick: tick}})
    assert %{seq: 1, inflight: %{seq: 1}, pending: %{tick: 100}, baseline: nil} = stream(socket)
    refute_push("frame", _, 60)

    push(socket, "frame_ack", %{"seq" => 999})
    assert stream(socket).inflight.seq == 1
    push(socket, "frame_ack", %{"seq" => 1})
    assert %{seq: 2, base: 1, changes: %{tick: 100}} = delta = frame(socket)
    refute Map.has_key?(delta, :full)
    refute Map.has_key?(delta, :map)
    assert stream(socket).sent_at - first_sent_at >= 50
    assert stream(socket).pending == nil

    send(socket.channel_pid, {:game_snapshot, %{game | tick: 101}})
    push(socket, "frame_ack", %{"seq" => 1})
    assert %{inflight: %{seq: 2}, baseline: {1, _}, pending: %{tick: 101}} = stream(socket)
    refute_push("frame", _, 60)
    push(socket, "frame_ack", %{"seq" => 2})
    assert %{seq: 3, base: 2, changes: %{tick: 101}} = frame(socket)
  end

  test "fast acknowledgements never bypass the 50 ms frame interval" do
    {socket, reply, _} = join(3)
    game = Arena.Game.new(reply.lobby.members, 7)
    send(socket.channel_pid, {:game_snapshot, game})
    assert %{seq: 1} = frame(socket)
    sent_at = stream(socket).sent_at

    Enum.reduce(2..4, sent_at, fn seq, previous_sent_at ->
      send(socket.channel_pid, {:game_snapshot, %{game | tick: seq}})
      push(socket, "frame_ack", %{"seq" => seq - 1})
      assert %{seq: ^seq, changes: %{tick: ^seq}} = frame(socket)
      current_sent_at = stream(socket).sent_at
      assert current_sent_at - previous_sent_at >= 50
      current_sent_at
    end)
  end

  test "resync recovers with newest full state and repeated requests are throttled" do
    {socket, reply, _} = join(3)
    game = Arena.Game.new(reply.lobby.members, 7)
    send(socket.channel_pid, {:game_snapshot, game})
    assert %{seq: 1} = frame(socket)
    send(socket.channel_pid, {:game_snapshot, %{game | tick: 20}})
    push(socket, "frame_resync", %{})
    assert %{seq: 2, base: nil, full: %{tick: 20, map: map}} = frame(socket)
    assert map == Arena.Game.public(game, reply.user_id).map

    push(socket, "frame_ack", %{"seq" => 1})
    push(socket, "frame_resync", %{})
    assert %{seq: 2, inflight: %{seq: 2}, baseline: nil} = stream(socket)
    refute_push("frame", _, 60)

    push(socket, "frame_ack", %{"seq" => 2})
    send(socket.channel_pid, {:game_snapshot, %{game | tick: 21}})
    assert %{seq: 3, base: 2, changes: %{tick: 21}} = frame(socket)
  end

  test "waiting invalidates the baseline and next round sends geometry with monotonic sequence" do
    {socket, reply, _} = join(3)
    game = Arena.Game.new(reply.lobby.members, 7)
    send(socket.channel_pid, {:game_snapshot, game})
    assert %{seq: 1, base: nil} = frame(socket)
    push(socket, "frame_ack", %{"seq" => 1})
    send(socket.channel_pid, {:game_snapshot, %{game | tick: 99}})
    assert %{seq: 2, base: 1} = frame(socket)

    send(socket.channel_pid, {:lobby, reply.lobby})
    assert %{seq: 2, baseline: nil, inflight: nil, pending: nil, latest: nil} = stream(socket)
    # Reusing a seed must still restore the map after the client cleared its round.
    send(socket.channel_pid, {:game_snapshot, game})
    assert %{seq: 3, base: nil, full: %{tick: 0, map: map}} = frame(socket)
    assert map == Arena.Game.public(game, reply.user_id).map
    send(socket.channel_pid, {:frame_timeout, 2})
    push(socket, "frame_ack", %{"seq" => 2})
    assert stream(socket).inflight.seq == 3
  end

  @tag capture_log: true
  test "old timeout messages are harmless but the current unacknowledged frame closes the channel" do
    {socket, reply, _} = join(3)
    game = Arena.Game.new(reply.lobby.members, 7)
    send(socket.channel_pid, {:game_snapshot, game})
    assert %{seq: 1} = frame(socket)
    push(socket, "frame_ack", %{"seq" => 1})
    send(socket.channel_pid, {:game_snapshot, %{game | tick: 1}})
    assert %{seq: 2} = frame(socket)
    send(socket.channel_pid, {:frame_timeout, 1})
    assert stream(socket).inflight.seq == 2

    # Exercise the expiry handler directly instead of making the suite wait 15 s.
    Process.unlink(socket.channel_pid)
    monitor = Process.monitor(socket.channel_pid)
    send(socket.channel_pid, {:frame_timeout, 2})
    assert_receive {:DOWN, ^monitor, :process, _, :frame_ack_timeout}, 1000
  end

  test "personalized deltas remove unseen enemies and reveal them only when that viewer dies" do
    {socket, reply, _} = join(3)
    game = Arena.Game.new(reply.lobby.members, 7)
    player = Enum.find(game.players, &(&1.id == reply.user_id))
    [enemy | other_enemies] = game.enemies
    visible_enemy = %{enemy | x: player.x + 20, y: player.y}
    game = %{game | enemies: [visible_enemy | other_enemies]}
    send(socket.channel_pid, {:game_snapshot, game})
    assert %{seq: 1, full: first} = frame(socket)
    refute first.spectator
    assert Enum.any?(first.enemies, &(&1.id == enemy.id))
    push(socket, "frame_ack", %{"seq" => 1})

    distant_cell =
      Enum.max_by(game.map.floor, fn tile ->
        {x, y} = Arena.Game.Map.center(tile)
        (x - player.x) ** 2 + (y - player.y) ** 2
      end)

    {x, y} = Arena.Game.Map.center(distant_cell)
    hidden_enemy = %{visible_enemy | x: x, y: y}
    hidden_game = %{game | tick: 1, enemies: [hidden_enemy | other_enemies]}
    send(socket.channel_pid, {:game_snapshot, hidden_game})
    assert %{seq: 2, base: 1, enemies: %{remove: removed}} = hidden_frame = frame(socket)
    assert enemy.id in removed
    refute Enum.any?(Map.get(hidden_frame.enemies, :upsert, []), &(&1.id == enemy.id))
    push(socket, "frame_ack", %{"seq" => 2})

    dead_players =
      Enum.map(game.players, fn p -> if p.id == reply.user_id, do: %{p | hp: 0}, else: p end)

    send(socket.channel_pid, {:game_snapshot, %{hidden_game | tick: 2, players: dead_players}})

    assert %{seq: 3, base: 2, changes: %{spectator: true}, enemies: %{upsert: revealed}} =
             frame(socket)

    assert Enum.any?(revealed, &(&1.id == enemy.id and &1.x == x and &1.y == y))
    refute Enum.any?(revealed, &Map.has_key?(&1, :memory))
  end

  defp stream(socket), do: Phoenix.Channel.Server.socket(socket.channel_pid).assigns.stream

  defp frame(socket) do
    join_ref = socket.join_ref

    assert_receive %Phoenix.Socket.Message{event: "frame", join_ref: ^join_ref, payload: payload},
                   1000

    payload
  end
end

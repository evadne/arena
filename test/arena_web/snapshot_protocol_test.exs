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

  test "four unacknowledged frames flow at 20 Hz, then only the newest stalled tick survives" do
    {socket, reply, _} = join(3)
    game = Arena.Game.new(reply.lobby.members, 7)

    sent_at =
      Enum.reduce(1..4, nil, fn seq, previous_sent_at ->
        send(socket.channel_pid, {:game_snapshot, %{game | tick: seq - 1}})
        received = frame(socket)
        assert received.seq == seq

        if seq == 1 do
          assert %{base: nil, full: %{tick: 0, map: map}} = received
          assert map.width > 0
        else
          assert received.base == seq - 1
          assert received.changes.tick == seq - 1
          refute Map.has_key?(received, :full)
        end

        current_sent_at = stream(socket).sent_at
        if previous_sent_at, do: assert(current_sent_at - previous_sent_at >= 50)
        current_sent_at
      end)

    assert inflight_seqs(socket) == [1, 2, 3, 4]
    assert {4, %{tick: 3}} = stream(socket).last_sent
    for tick <- 4..100, do: send(socket.channel_pid, {:game_snapshot, %{game | tick: tick}})
    assert %{seq: 4, pending: %{tick: 100}} = stream(socket)
    refute_push("frame", _, 60)

    push(socket, "frame_ack", %{"seq" => 999})
    push(socket, "frame_ack", %{"seq" => 0})
    assert inflight_seqs(socket) == [1, 2, 3, 4]
    timers = stream(socket).inflight |> Enum.map(& &1.timer)

    # Receiving seq 3 proves the client reconstructed all preceding frames.
    push(socket, "frame_ack", %{"seq" => 3})
    assert %{seq: 5, base: 4, changes: %{tick: 100}} = frame(socket)
    assert inflight_seqs(socket) == [4, 5]
    assert Enum.all?(Enum.take(timers, 3), &(Process.read_timer(&1) == false))
    assert is_integer(Process.read_timer(Enum.at(timers, 3)))
    assert stream(socket).sent_at - sent_at >= 50
    assert stream(socket).pending == nil
    refute_push("frame", _, 60)

    push(socket, "frame_ack", %{"seq" => 2})
    assert inflight_seqs(socket) == [4, 5]
    assert {5, %{tick: 100}} = stream(socket).last_sent
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

  test "resync clears the whole outstanding window and repeated requests are throttled" do
    {socket, reply, _} = join(3)
    game = Arena.Game.new(reply.lobby.members, 7)

    for seq <- 1..4 do
      send(socket.channel_pid, {:game_snapshot, %{game | tick: seq - 1}})
      assert %{seq: ^seq} = frame(socket)
    end

    old_timers = Enum.map(stream(socket).inflight, & &1.timer)
    send(socket.channel_pid, {:game_snapshot, %{game | tick: 20}})
    push(socket, "frame_resync", %{})
    assert %{seq: 5, base: nil, full: %{tick: 20, map: map}} = frame(socket)
    assert map == Arena.Game.public(game, reply.user_id).map
    assert Enum.all?(old_timers, &(Process.read_timer(&1) == false))

    for seq <- 1..4 do
      push(socket, "frame_ack", %{"seq" => seq})
      send(socket.channel_pid, {:frame_timeout, seq})
    end

    push(socket, "frame_resync", %{})
    assert inflight_seqs(socket) == [5]
    assert {5, %{tick: 20}} = stream(socket).last_sent
    refute_push("frame", _, 60)

    send(socket.channel_pid, {:game_snapshot, %{game | tick: 21}})
    assert %{seq: 6, base: 5, changes: %{tick: 21}} = frame(socket)
    assert inflight_seqs(socket) == [5, 6]
  end

  test "waiting clears every outstanding frame and restarts geometry with monotonic sequence" do
    {socket, reply, _} = join(3)
    game = Arena.Game.new(reply.lobby.members, 7)

    for seq <- 1..4 do
      send(socket.channel_pid, {:game_snapshot, %{game | tick: seq - 1}})
      assert %{seq: ^seq} = frame(socket)
    end

    old_timers = Enum.map(stream(socket).inflight, & &1.timer)
    send(socket.channel_pid, {:game_snapshot, %{game | tick: 99}})
    assert stream(socket).pending.tick == 99
    send(socket.channel_pid, {:lobby, reply.lobby})
    assert %{seq: 4, last_sent: nil, inflight: [], pending: nil, latest: nil} = stream(socket)
    assert Enum.all?(old_timers, &(Process.read_timer(&1) == false))

    # Reusing a seed must still restore the map after the client cleared its round.
    send(socket.channel_pid, {:game_snapshot, game})
    assert %{seq: 5, base: nil, full: %{tick: 0, map: map}} = frame(socket)
    assert map == Arena.Game.public(game, reply.user_id).map

    for seq <- 1..4 do
      send(socket.channel_pid, {:frame_timeout, seq})
      push(socket, "frame_ack", %{"seq" => seq})
    end

    assert inflight_seqs(socket) == [5]
    send(socket.channel_pid, {:game_snapshot, %{game | tick: 1}})
    assert %{seq: 6, base: 5, changes: %{tick: 1}} = frame(socket)
  end

  test "a new seed pipelines a full keyframe before its dependent deltas" do
    {socket, reply, _} = join(3)
    old_game = Arena.Game.new(reply.lobby.members, 7)
    new_game = Arena.Game.new(reply.lobby.members, 9)
    send(socket.channel_pid, {:game_snapshot, old_game})
    assert %{seq: 1, base: nil} = frame(socket)
    send(socket.channel_pid, {:game_snapshot, new_game})
    assert %{seq: 2, base: nil, full: %{seed: 9, map: map}} = frame(socket)
    assert map == Arena.Game.public(new_game, reply.user_id).map
    send(socket.channel_pid, {:game_snapshot, %{new_game | tick: 1}})
    assert %{seq: 3, base: 2, changes: %{tick: 1}} = frame(socket)
    assert inflight_seqs(socket) == [1, 2, 3]
  end

  @tag capture_log: true
  test "only the oldest outstanding frame timeout closes the channel" do
    {socket, reply, _} = join(3)
    game = Arena.Game.new(reply.lobby.members, 7)

    for seq <- 1..4 do
      send(socket.channel_pid, {:game_snapshot, %{game | tick: seq - 1}})
      assert %{seq: ^seq} = frame(socket)
    end

    [first, second, third, fourth] = stream(socket).inflight
    assert is_integer(Process.read_timer(first.timer))
    push(socket, "frame_ack", %{"seq" => 2})
    send(socket.channel_pid, {:frame_timeout, 1})
    send(socket.channel_pid, {:frame_timeout, 2})
    send(socket.channel_pid, {:frame_timeout, 4})
    assert inflight_seqs(socket) == [3, 4]
    assert Process.read_timer(first.timer) == false
    assert Process.read_timer(second.timer) == false
    assert is_integer(Process.read_timer(third.timer))
    assert is_integer(Process.read_timer(fourth.timer))

    # Exercise the expiry handler directly instead of making the suite wait 15 s.
    Process.unlink(socket.channel_pid)
    monitor = Process.monitor(socket.channel_pid)
    send(socket.channel_pid, {:frame_timeout, 3})
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

    dead_players =
      Enum.map(game.players, fn p -> if p.id == reply.user_id, do: %{p | hp: 0}, else: p end)

    send(socket.channel_pid, {:game_snapshot, %{hidden_game | tick: 2, players: dead_players}})

    assert %{seq: 3, base: 2, changes: %{spectator: true}, enemies: %{upsert: revealed}} =
             frame(socket)

    assert Enum.any?(revealed, &(&1.id == enemy.id and &1.x == x and &1.y == y))
    refute Enum.any?(revealed, &Map.has_key?(&1, :memory))
  end

  test "shot timing uses ACK latency and keeps the original trigger through keepalive and release" do
    {socket, reply, pid} = join(3)
    past = Arena.Game.new(reply.lobby.members, 7)
    player = hd(past.players)
    [enemy | others] = past.enemies
    enemy = %{enemy | x: player.x + 28, y: player.y, reaction_delay: 10_000}
    past = %{past | enemies: [enemy | others]} |> Arena.Game.LagCompensation.record()
    current = %{past | enemies: [%{enemy | y: enemy.y + 40} | others]}
    :sys.replace_state(pid, &%{&1 | game: current, status: "playing"})
    send(socket.channel_pid, {:game_snapshot, past})
    assert %{seq: 1} = frame(socket)
    push(socket, "frame_ack", %{"seq" => 1})
    assert length(stream(socket).rtts) == 1

    input = %{
      "x" => 0,
      "y" => 0,
      "aim" => 0,
      "shot_aim" => 0,
      "aim_point" => %{"x" => enemy.x, "y" => enemy.y},
      "shoot" => true,
      "round_id" => past.round_id,
      "effect_id" => 1,
      "view_ms" => 0,
      "seen_tick" => 0
    }

    push(socket, "input", input)
    first = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.shot_command
    assert first.shot_view.rtt_ms >= 0
    assert first.shot_view.seen_tick == 0
    push(socket, "input", %{input | "shot_aim" => 2, "view_ms" => 9999})
    assert Phoenix.Channel.Server.socket(socket.channel_pid).assigns.shot_command == first

    push(socket, "input", %{
      "x" => 0,
      "y" => 0,
      "aim" => 2,
      "shoot" => false,
      "round_id" => past.round_id
    })

    Phoenix.Channel.Server.socket(socket.channel_pid)
    send(pid, :tick)
    state = :sys.get_state(pid)
    assert hd(state.game.enemies).hp == 66
    assert hd(state.game.enemies).y > enemy.y + 20
    assert hd(state.game.players).ammo == 19
    assert hd(state.game.players).last_effect_id == 1
    assert length(state.game.history) == 2
    refute Map.has_key?(stream(socket), :history)
    previous = state.inputs
    push(socket, "input", %{input | "round_id" => -1, "effect_id" => 2})
    Phoenix.Channel.Server.socket(socket.channel_pid)
    assert :sys.get_state(pid).inputs == previous
  end

  defp inflight_seqs(socket), do: Enum.map(stream(socket).inflight, & &1.seq)

  defp stream(socket), do: Phoenix.Channel.Server.socket(socket.channel_pid).assigns.stream

  defp frame(socket) do
    join_ref = socket.join_ref

    assert_receive %Phoenix.Socket.Message{event: "frame", join_ref: ^join_ref, payload: payload},
                   1000

    payload
  end
end

defmodule ArenaWeb.LobbyChannel do
  use Phoenix.Channel
  @frame_interval 50
  @frame_window 4
  @ack_timeout 15_000
  @impl true
  def join("lobby:" <> code, payload, socket) do
    with {:ok, pid} <- Arena.Lobbies.ensure(code),
         :ok <- Phoenix.PubSub.subscribe(Arena.PubSub, "session:#{code}"),
         {:ok, reply} <-
           Arena.Lobby.join(
             pid,
             socket.assigns.user_id,
             Map.get(payload, "name", "Operator"),
             self()
           ) do
      Process.monitor(pid)

      socket =
        socket
        |> assign(:shot_command, nil)
        |> assign(:lobby_pid, pid)
        |> assign(:protocol, if(payload["protocol"] in [2, 3], do: payload["protocol"], else: 1))
        |> assign(:snapshot_seed, reply.game && reply.game.seed)
        |> assign(:snapshot_tick, reply.game && reply.game.tick)
        |> assign(:stream, %{
          seq: 0,
          rtts: [],
          last_sent: nil,
          inflight: [],
          pending: nil,
          latest: nil,
          sent_at: nil,
          flush: nil,
          resync_at: nil
        })

      {:ok, reply, socket}
    else
      {:error, reason} when is_binary(reason) -> {:error, %{reason: reason}}
      _ -> {:error, %{reason: "Could not join lobby."}}
    end
  end

  @impl true
  def handle_in("ping", _, socket), do: {:reply, {:ok, %{}}, socket}

  def handle_in("input", payload, socket) do
    input = %{
      x: number(payload["x"], -1, 1),
      y: number(payload["y"], -1, 1),
      aim: number(payload["aim"], -1000, 1000),
      shot_aim:
        if(is_number(payload["shot_aim"]),
          do: number(payload["shot_aim"], -1000, 1000),
          else: nil
        ),
      shoot: payload["shoot"] == true,
      reload: payload["reload"] == true,
      round_id: payload["round_id"],
      effect_id: effect_id(payload["effect_id"]),
      aim_point: point(payload["aim_point"]),
      shot_view: shot_timing(socket, payload)
    }

    {input, socket} = preserve_shot(input, socket)
    Arena.Lobby.input(socket.assigns.lobby_pid, socket.assigns.user_id, input)
    {:noreply, socket}
  end

  def handle_in("frame_ack", %{"seq" => seq}, %{assigns: %{protocol: 3}} = socket) do
    stream = socket.assigns.stream

    # ACKs are cumulative, but only an actually outstanding sequence can release
    # window capacity. Future and old ACKs must not alter the ordered delta chain.
    if Enum.any?(stream.inflight, &(&1.seq === seq)) do
      {acked, outstanding} = Enum.split_while(stream.inflight, &(&1.seq <= seq))
      Enum.each(acked, &Process.cancel_timer(&1.timer))
      now = System.monotonic_time(:millisecond)
      sample = now - List.last(acked).sent_at
      stream = %{stream | inflight: outstanding, rtts: Enum.take([sample | stream.rtts], 32)}
      {:noreply, schedule_frame(assign(socket, :stream, stream))}
    else
      {:noreply, socket}
    end
  end

  def handle_in("frame_resync", _, %{assigns: %{protocol: 3}} = socket) do
    stream = socket.assigns.stream
    now = System.monotonic_time(:millisecond)

    if is_nil(stream.resync_at) or now - stream.resync_at >= 1000 do
      latest = stream.latest
      stream = clear_stream(stream)
      stream = %{stream | pending: latest, latest: latest, resync_at: now}
      {:noreply, schedule_frame(assign(socket, :stream, stream))}
    else
      {:noreply, socket}
    end
  end

  def handle_in(event, payload, socket)
      when event in ["chat", "start", "order", "reset"] do
    case Arena.Lobby.action(socket.assigns.lobby_pid, socket.assigns.user_id, event, payload) do
      {:ok, reply} -> {:reply, {:ok, reply}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in(_, _, socket), do: {:reply, {:error, %{reason: "Unknown action."}}, socket}
  @impl true
  def handle_info({:game_snapshot, game}, %{assigns: %{protocol: 3}} = socket) do
    # A small window keeps 20 Hz updates flowing across normal network latency.
    # Beyond that window only the newest state survives; never queue old ticks.
    stream = %{socket.assigns.stream | pending: game, latest: game}
    {:noreply, schedule_frame(assign(socket, :stream, stream))}
  end

  def handle_info({:flush_frame, token}, socket) do
    case socket.assigns.stream.flush do
      {^token, _timer} ->
        stream = %{socket.assigns.stream | flush: nil}
        {:noreply, schedule_frame(assign(socket, :stream, stream))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:frame_timeout, seq}, socket) do
    case socket.assigns.stream.inflight do
      [%{seq: ^seq} | _] -> {:stop, :frame_ack_timeout, socket}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:game_snapshot, game}, socket) do
    snapshot = Arena.Game.public(game, socket.assigns.user_id)

    # The floorplan does not change during a round. Protocol 2 clients cache it;
    # old clients keep receiving full snapshots so open tabs remain compatible.
    cached? =
      socket.assigns.protocol == 2 and socket.assigns.snapshot_seed == game.seed and
        is_integer(socket.assigns.snapshot_tick) and game.tick >= socket.assigns.snapshot_tick

    push(socket, "snapshot", if(cached?, do: Map.delete(snapshot, :map), else: snapshot))

    {:noreply, socket |> assign(:snapshot_seed, game.seed) |> assign(:snapshot_tick, game.tick)}
  end

  def handle_info({:lobby, %{status: "waiting"} = payload}, socket) do
    push(socket, "lobby", payload)
    stream = clear_stream(socket.assigns.stream)

    {:noreply,
     socket
     |> assign(:snapshot_seed, nil)
     |> assign(:snapshot_tick, nil)
     |> assign(:stream, stream)}
  end

  def handle_info({event, payload}, socket) when event in [:lobby, :chat] do
    push(socket, Atom.to_string(event), payload)
    {:noreply, socket}
  end

  def handle_info({:DOWN, _, :process, _, _}, socket), do: {:stop, :normal, socket}

  defp schedule_frame(socket) do
    stream = socket.assigns.stream
    now = System.monotonic_time(:millisecond)
    remaining = if stream.sent_at, do: max(0, @frame_interval - (now - stream.sent_at)), else: 0

    cond do
      length(stream.inflight) >= @frame_window or stream.pending == nil or stream.flush != nil ->
        socket

      remaining > 0 ->
        token = make_ref()
        timer = Process.send_after(self(), {:flush_frame, token}, remaining)
        assign(socket, :stream, %{stream | flush: {token, timer}})

      true ->
        snapshot = Arena.Game.public(stream.pending, socket.assigns.user_id)
        # WebSocket delivery is reliable and ordered. Each delta chains from the
        # last sent frame, even while its ACK is still travelling back to us.
        {base_seq, baseline} = stream.last_sent || {nil, nil}
        seq = stream.seq + 1
        frame = ArenaWeb.SnapshotDelta.encode(snapshot, baseline, seq, base_seq)
        push(socket, "frame", frame)
        timer = Process.send_after(self(), {:frame_timeout, seq}, @ack_timeout)
        inflight = stream.inflight ++ [%{seq: seq, timer: timer, sent_at: now}]

        assign(socket, :stream, %{
          stream
          | seq: seq,
            last_sent: {seq, snapshot},
            inflight: inflight,
            pending: nil,
            sent_at: now
        })
    end
  end

  defp clear_stream(stream) do
    Enum.each(stream.inflight, &Process.cancel_timer(&1.timer))
    if stream.flush, do: Process.cancel_timer(elem(stream.flush, 1))

    %{
      stream
      | last_sent: nil,
        inflight: [],
        pending: nil,
        latest: nil,
        flush: nil
    }
  end

  defp preserve_shot(%{effect_id: nil} = input, socket), do: {input, socket}

  defp preserve_shot(input, socket) do
    case socket.assigns.shot_command do
      %{effect_id: id, round_id: round} = previous
      when id == input.effect_id and round == input.round_id ->
        {Map.merge(input, Map.take(previous, [:shot_aim, :aim_point, :shot_view])), socket}

      _ ->
        {input, assign(socket, :shot_command, input)}
    end
  end

  defp shot_timing(socket, %{"view_ms" => time, "seen_tick" => seen, "round_id" => round})
       when is_number(time) and time >= 0 and is_integer(seen) and seen >= 0 do
    case socket.assigns.stream.last_sent do
      {_, %{round_id: ^round, tick: tick}} when seen <= tick ->
        samples = socket.assigns.stream.rtts
        rtt = if samples == [], do: 0, else: Enum.min(samples)

        %{
          round_id: round,
          view_ms: time,
          seen_tick: seen,
          rtt_ms: rtt,
          received_at: System.monotonic_time(:millisecond)
        }

      _ ->
        nil
    end
  end

  defp shot_timing(_, _), do: nil

  defp point(%{"x" => x, "y" => y})
       when is_number(x) and is_number(y) and abs(x) <= 100_000 and abs(y) <= 100_000, do: {x, y}

  defp point(_), do: nil

  defp effect_id(v) when is_integer(v) and v > 0 and v <= 2_147_483_647, do: v
  defp effect_id(_), do: nil

  defp number(v, lo, hi) when is_number(v), do: v |> max(lo) |> min(hi)
  defp number(_, _, _), do: 0
end

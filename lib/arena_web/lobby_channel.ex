defmodule ArenaWeb.LobbyChannel do
  use Phoenix.Channel
  @frame_interval 50
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
        |> assign(:lobby_pid, pid)
        |> assign(:protocol, if(payload["protocol"] in [2, 3], do: payload["protocol"], else: 1))
        |> assign(:snapshot_seed, reply.game && reply.game.seed)
        |> assign(:snapshot_tick, reply.game && reply.game.tick)
        |> assign(:stream, %{
          seq: 0,
          baseline: nil,
          inflight: nil,
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
  def handle_in("input", payload, socket) do
    input = %{
      x: number(payload["x"], -1, 1),
      y: number(payload["y"], -1, 1),
      aim: number(payload["aim"], -1000, 1000),
      shoot: payload["shoot"] == true,
      reload: payload["reload"] == true
    }

    Arena.Lobby.input(socket.assigns.lobby_pid, socket.assigns.user_id, input)
    {:noreply, socket}
  end

  def handle_in("frame_ack", %{"seq" => seq}, %{assigns: %{protocol: 3}} = socket) do
    stream = socket.assigns.stream

    case stream.inflight do
      %{seq: ^seq, snapshot: snapshot, timer: timer} ->
        Process.cancel_timer(timer)
        stream = %{stream | baseline: {seq, snapshot}, inflight: nil}
        {:noreply, schedule_frame(assign(socket, :stream, stream))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_in("frame_resync", _, %{assigns: %{protocol: 3}} = socket) do
    stream = socket.assigns.stream
    now = System.monotonic_time(:millisecond)

    if is_nil(stream.resync_at) or now - stream.resync_at >= 1000 do
      if stream.inflight, do: Process.cancel_timer(stream.inflight.timer)
      stream = %{stream | baseline: nil, inflight: nil, pending: stream.latest, resync_at: now}
      {:noreply, schedule_frame(assign(socket, :stream, stream))}
    else
      {:noreply, socket}
    end
  end

  def handle_in(event, payload, socket)
      when event in ["chat", "start", "transfer", "slot", "formation", "order", "reset"] do
    case Arena.Lobby.action(socket.assigns.lobby_pid, socket.assigns.user_id, event, payload) do
      {:ok, reply} -> {:reply, {:ok, reply}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in(_, _, socket), do: {:reply, {:error, %{reason: "Unknown action."}}, socket}
  @impl true
  def handle_info({:game_snapshot, game}, %{assigns: %{protocol: 3}} = socket) do
    # Coalesce before personalization and encoding: a slow reader holds just one
    # sent frame and the newest simulation state, never a queue of old updates.
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
      %{seq: ^seq} -> {:stop, :frame_ack_timeout, socket}
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
    stream = socket.assigns.stream
    if stream.inflight, do: Process.cancel_timer(stream.inflight.timer)
    if stream.flush, do: Process.cancel_timer(elem(stream.flush, 1))
    stream = %{stream | baseline: nil, inflight: nil, pending: nil, latest: nil, flush: nil}

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
      stream.inflight != nil or stream.pending == nil or stream.flush != nil ->
        socket

      remaining > 0 ->
        token = make_ref()
        timer = Process.send_after(self(), {:flush_frame, token}, remaining)
        assign(socket, :stream, %{stream | flush: {token, timer}})

      true ->
        snapshot = Arena.Game.public(stream.pending, socket.assigns.user_id)
        {base_seq, baseline} = stream.baseline || {nil, nil}
        seq = stream.seq + 1
        frame = ArenaWeb.SnapshotDelta.encode(snapshot, baseline, seq, base_seq)
        push(socket, "frame", frame)
        timer = Process.send_after(self(), {:frame_timeout, seq}, @ack_timeout)
        inflight = %{seq: seq, snapshot: snapshot, timer: timer}

        assign(socket, :stream, %{
          stream
          | seq: seq,
            inflight: inflight,
            pending: nil,
            sent_at: now
        })
    end
  end

  defp number(v, lo, hi) when is_number(v), do: v |> max(lo) |> min(hi)
  defp number(_, _, _), do: 0
end

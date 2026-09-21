defmodule Arena.Lobby do
  @moduledoc "One isolated, server-authoritative session per lobby code."
  use GenServer, restart: :temporary
  @tick_ms 50
  def start_link(code),
    do: GenServer.start_link(__MODULE__, code, name: {:via, Registry, {Arena.Registry, code}})

  def join(pid, id, name, owner), do: GenServer.call(pid, {:join, id, name, owner})
  def action(pid, id, event, payload), do: GenServer.call(pid, {:action, id, event, payload})
  def input(pid, id, input), do: GenServer.cast(pid, {:input, id, input})
  def state(pid), do: GenServer.call(pid, :state)
  @impl true
  def init(code) do
    Process.send_after(self(), :cleanup, 60_000)

    {:ok,
     %{
       code: code,
       members: [],
       leader_id: nil,
       formation: "stack",
       status: "waiting",
       game: nil,
       inputs: %{},
       monitors: %{},
       chat: [],
       last_chat: %{}
     }}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, public(state), state}

  def handle_call({:join, id, name, owner}, _from, state) do
    cond do
      Enum.any?(state.members, &(&1.id == id)) ->
        {:reply, {:error, "Already connected to this lobby."}, state}

      length(state.members) >= 4 ->
        {:reply, {:error, "This lobby is full (4/4)."}, state}

      true ->
        slot = Enum.find(0..3, fn n -> not Enum.any?(state.members, &(&1.slot == n)) end)
        member = %{id: id, name: clean_name(name), slot: slot}
        ref = Process.monitor(owner)

        game =
          if state.game do
            players =
              Enum.map(state.game.players, fn p ->
                if p.slot == slot, do: %{p | id: id, name: member.name, bot: false}, else: p
              end)

            %{state.game | players: players}
          end

        state = %{
          state
          | members: state.members ++ [member],
            leader_id: state.leader_id || id,
            monitors: Map.put(state.monitors, ref, id),
            game: game
        }

        broadcast_lobby(state)
        {:reply, {:ok, %{user_id: id, lobby: public(state), game: game_public(state, id)}}, state}
    end
  end

  def handle_call({:action, id, event, payload}, _from, state) do
    if Enum.any?(state.members, &(&1.id == id)) do
      {reply, state} = perform(event, payload, id, state)
      {:reply, reply, state}
    else
      {:reply, {:error, "Join the lobby first."}, state}
    end
  end

  @impl true
  def handle_cast({:input, id, input}, state) do
    if state.status == "playing" and Enum.any?(state.members, &(&1.id == id)) and
         (is_nil(Map.get(input, :round_id)) or input.round_id == state.game.round_id) do
      {_, _, pending} = Map.get(state.inputs, id, {input, 0, %{shoot: false, reload: false}})

      pending = %{
        shoot: pending.shoot or input.shoot,
        reload: pending.reload or input.reload,
        shot_input: if(input.shoot, do: input, else: Map.get(pending, :shot_input))
      }

      {:noreply,
       %{
         state
         | inputs:
             Map.put(state.inputs, id, {input, System.monotonic_time(:millisecond), pending})
       }}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:tick, %{status: "playing"} = state) do
    now = System.monotonic_time(:millisecond)

    inputs =
      Map.new(state.inputs, fn {id, {input, at, pending}} ->
        {id,
         if(now - at < 250,
           do:
             input
             |> Map.merge(
               Map.take(Map.get(pending, :shot_input) || %{}, [
                 :aim,
                 :shot_aim,
                 :aim_point,
                 :shot_view,
                 :effect_id
               ])
             )
             |> Map.merge(%{
               shoot: input.shoot or pending.shoot,
               reload: input.reload or pending.reload
             }),
           else: %{x: 0, y: 0, aim: input.aim, shoot: false, reload: false}
         )}
      end)

    game = Arena.Game.step(state.game, inputs, @tick_ms)
    changed = game.status != state.status

    cleared_inputs =
      Map.new(state.inputs, fn {id, {input, at, _}} ->
        {id, {input, at, %{shoot: false, reload: false}}}
      end)

    state = %{state | game: game, status: game.status, inputs: cleared_inputs}
    Phoenix.PubSub.broadcast(Arena.PubSub, topic(state), {:game_snapshot, %{game | history: []}})
    if changed, do: broadcast_lobby(state)

    if game.status == "playing" do
      # Include computation in the 50ms budget instead of adding it to every tick.
      # Only one timer is outstanding, so an overloaded lobby cannot build a backlog.
      remaining = max(1, @tick_ms - (System.monotonic_time(:millisecond) - now))
      Process.send_after(self(), :tick, remaining)
    end

    {:noreply, state}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {id, monitors} ->
        members = Enum.reject(state.members, &(&1.id == id))

        leader =
          if state.leader_id == id, do: random_leader(members), else: state.leader_id

        game = if state.game, do: Arena.Game.disconnect(state.game, id)

        state = %{
          state
          | members: members,
            leader_id: leader,
            monitors: monitors,
            game: game,
            inputs: Map.delete(state.inputs, id),
            last_chat: Map.delete(state.last_chat, id)
        }

        broadcast_lobby(state)
        if members == [], do: {:stop, :normal, state}, else: {:noreply, state}
    end
  end

  def handle_info(:cleanup, %{members: []} = state), do: {:stop, :normal, state}
  def handle_info(:cleanup, state), do: {:noreply, state}

  defp perform("chat", _, _, %{status: "playing"} = state),
    do: {{:error, "Radio silence: chat is disabled during the mission."}, state}

  defp perform("chat", %{"text" => text}, id, state) when is_binary(text) do
    text = text |> String.trim() |> String.slice(0, 280)
    now = System.monotonic_time(:millisecond)

    cond do
      text == "" ->
        {{:error, "Enter a message."}, state}

      now - Map.get(state.last_chat, id, now - 1000) < 400 ->
        {{:error, "Messages are limited to a few per second."}, state}

      true ->
        member = Enum.find(state.members, &(&1.id == id))

        message = %{
          id: System.unique_integer([:positive]),
          name: member.name,
          text: text,
          at: System.system_time(:millisecond)
        }

        state = %{
          state
          | chat: Enum.take(state.chat ++ [message], -60),
            last_chat: Map.put(state.last_chat, id, now)
        }

        Phoenix.PubSub.broadcast(Arena.PubSub, topic(state), {:chat, message})
        {{:ok, %{}}, state}
    end
  end

  defp perform("slot", %{"slot" => slot}, id, %{status: "waiting"} = state)
       when is_integer(slot) and slot in 0..3 do
    if Enum.any?(state.members, &(&1.slot == slot and &1.id != id)) do
      {{:error, "That position is occupied."}, state}
    else
      state = %{
        state
        | members:
            Enum.map(state.members, fn m -> if m.id == id, do: %{m | slot: slot}, else: m end)
      }

      broadcast_lobby(state)
      {{:ok, %{}}, state}
    end
  end

  defp perform("order", %{"order" => order}, id, %{status: "playing"} = state)
       when order in ["hold", "form_up", "aggro", "auto"] do
    if Enum.any?(state.game.players, &(&1.id == id and &1.hp > 0 and not &1.bot)) do
      game = Arena.Game.set_order(state.game, order, id)
      state = %{state | game: game}

      Phoenix.PubSub.broadcast(
        Arena.PubSub,
        topic(state),
        {:game_snapshot, %{game | history: []}}
      )

      {{:ok, %{}}, state}
    else
      {{:error, "Only living operators can issue squad orders."}, state}
    end
  end

  defp perform(event, payload, id, state)
       when event in ["start", "reset", "transfer", "formation"] do
    if id == state.leader_id,
      do: leader_action(event, payload, state),
      else: {{:error, "Only the lobby leader can do that."}, state}
  end

  defp perform(_, _, _, state), do: {{:error, "That action is not available."}, state}

  defp leader_action("start", _, %{status: "waiting"} = state) do
    seed = :rand.uniform(999_999)

    game =
      Arena.Game.new(state.members, seed, state.formation, Arena.Callsigns.bot_names(state.code))

    state = %{state | game: game, status: "playing", inputs: %{}}
    broadcast_lobby(state)
    Phoenix.PubSub.broadcast(Arena.PubSub, topic(state), {:game_snapshot, %{game | history: []}})
    Process.send_after(self(), :tick, @tick_ms)
    {{:ok, %{}}, state}
  end

  defp leader_action("reset", _, %{status: status} = state) when status in ["won", "lost"] do
    state = %{state | game: nil, status: "waiting", inputs: %{}}
    broadcast_lobby(state)
    {{:ok, %{}}, state}
  end

  defp leader_action("transfer", %{"user_id" => id}, state) do
    if Enum.any?(state.members, &(&1.id == id)) do
      state = %{state | leader_id: id}
      broadcast_lobby(state)
      {{:ok, %{}}, state}
    else
      {{:error, "Select a connected teammate."}, state}
    end
  end

  defp leader_action("formation", %{"formation" => f}, %{status: "waiting"} = state)
       when f in ["stack", "wedge", "line"] do
    state = %{state | formation: f}
    broadcast_lobby(state)
    {{:ok, %{}}, state}
  end

  defp leader_action(_, _, state),
    do: {{:error, "That action is not available during this phase."}, state}

  defp public(state),
    do:
      state
      |> Map.take([:code, :members, :leader_id, :formation, :status, :chat])
      |> Map.put(:bot_names, Arena.Callsigns.bot_names(state.code))

  defp game_public(%{game: nil}, _id), do: nil
  defp game_public(state, id), do: Arena.Game.public(state.game, id)
  defp random_leader([]), do: nil
  defp random_leader(members), do: Enum.random(members).id
  defp topic(state), do: "session:#{state.code}"

  defp broadcast_lobby(state),
    do: Phoenix.PubSub.broadcast(Arena.PubSub, topic(state), {:lobby, public(state)})

  defp clean_name(name) when is_binary(name) do
    case name
         |> String.replace(~r/[\x00-\x1F\x7F]/u, "")
         |> String.trim()
         |> String.slice(0, 20) do
      "" -> "Operator"
      value -> value
    end
  end

  defp clean_name(_), do: "Operator"
end

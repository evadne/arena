defmodule Arena.Lobbies do
  def valid_code?(code), do: is_binary(code) and Regex.match?(~r/^[A-Z0-9]{4,12}$/, code)

  def ensure(code) do
    if valid_code?(code),
      do: ensure_live(code, 20),
      else: {:error, "Use a lobby code of 4–12 letters or numbers."}
  end

  defp ensure_live(_code, 0), do: {:error, "Lobby is closing. Please try again."}

  defp ensure_live(code, attempts) do
    result =
      case Registry.lookup(Arena.Registry, code) do
        [{pid, _}] ->
          {:ok, pid}

        [] ->
          case DynamicSupervisor.start_child(Arena.LobbySupervisor, {Arena.Lobby, code}) do
            {:error, {:already_started, pid}} -> {:ok, pid}
            result -> result
          end
      end

    case result do
      {:ok, pid} ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          # Registry removes dead owners asynchronously. Never return a stale lobby.
          Process.sleep(2)
          ensure_live(code, attempts - 1)
        end

      other ->
        other
    end
  end
end

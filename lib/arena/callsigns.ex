defmodule Arena.Callsigns do
  @moduledoc "A stable, shared repertoire for AI teammates in each operation."
  @names ~w(Jason Morgan Riley Alex Nina Theo Sam Casey Jordan Robin Ellis Jamie)

  def bot_names(code) do
    @names
    |> Enum.sort_by(&:erlang.phash2({code, &1}))
    |> Enum.take(4)
  end
end

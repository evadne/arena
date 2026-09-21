defmodule Arena.MixProject do
  use Mix.Project

  def project,
    do: [
      app: :arena,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: ["lib"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: [setup: ["deps.get"]]
    ]

  def application,
    do: [mod: {Arena.Application, []}, extra_applications: [:logger, :runtime_tools]]

  defp deps, do: [{:phoenix, "~> 1.8.0"}, {:bandit, "~> 1.0"}, {:jason, "~> 1.4"}]
end

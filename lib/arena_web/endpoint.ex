defmodule ArenaWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :arena
  socket("/socket", ArenaWeb.UserSocket, websocket: [timeout: 45_000], longpoll: false)
  plug(Plug.Static, at: "/", from: :arena, gzip: false, only: ~w(assets favicon.svg))
  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])
  plug(ArenaWeb.Router)
end

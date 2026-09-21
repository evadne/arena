import Config

config :arena, ArenaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: ArenaWeb.ErrorJSON], layout: false],
  pubsub_server: Arena.PubSub,
  secret_key_base:
    "arena_local_development_secret_not_for_deployment_0123456789abcdef0123456789abcdef",
  http: [ip: {0, 0, 0, 0}, port: 4000],
  check_origin: false,
  server: true

config :phoenix, :json_library, Jason
config :logger, :console, format: "$time $metadata[$level] $message\n"
import_config "#{config_env()}.exs"

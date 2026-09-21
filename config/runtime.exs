import Config

if config_env() == :prod do
  secret = System.fetch_env!("SECRET_KEY_BASE")
  host = System.get_env("HOST", "localhost")

  config :arena, ArenaWeb.Endpoint,
    secret_key_base: secret,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: ["https://#{host}", "http://#{host}"],
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))]
else
  config :arena, ArenaWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))]
end

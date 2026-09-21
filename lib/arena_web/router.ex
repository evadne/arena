defmodule ArenaWeb.Router do
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_file(200, Application.app_dir(:arena, "priv/static/index.html"))
  end

  match(_, do: send_resp(conn, 404, "Not found"))
end

defmodule ArenaWeb.ErrorJSON do
  def render(template, _assigns),
    do: %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
end

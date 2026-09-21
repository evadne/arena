defmodule ArenaWeb.PreviewMapTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  test "each uncached preview contains fresh public geometry without creating a lobby" do
    previews =
      for _ <- 1..3 do
        response = ArenaWeb.Router.call(conn(:get, "/preview-map"), [])
        assert response.status == 200
        assert get_resp_header(response, "cache-control") == ["no-store"]
        assert get_resp_header(response, "content-type") == ["application/json; charset=utf-8"]
        assert %{"map" => map} = Jason.decode!(response.resp_body)
        assert length(map["rooms"]) in 8..12
        assert length(map["walls"]) > 0
        assert length(map["floor_tiles"]) > 0
        refute Map.has_key?(map, "grid")
        refute Map.has_key?(map, "players")
        refute Map.has_key?(map, "enemies")
        map
      end

    assert length(Enum.uniq(previews)) == 3
  end
end

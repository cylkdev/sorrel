defmodule FakeHttpServer.ImplTest do
  use ExUnit.Case, async: true

  alias FakeHttpServer.Impl

  describe "parse_request/1" do
    test "returns :need_more when the head is incomplete" do
      assert {:need_more, "GET /x"} = Impl.parse_request("GET /x")
    end

    test "parses a simple GET with no body" do
      raw = "GET /_ping HTTP/1.1\r\nHost: localhost\r\n\r\n"
      assert {:ok, req, ""} = Impl.parse_request(raw)
      assert req.method === "GET"
      assert req.path === "/_ping"
      assert {"host", "localhost"} in req.headers
      assert req.body === ""
    end

    test "parses a POST with content-length and leaves leftover bytes" do
      raw =
        "POST /x HTTP/1.1\r\nContent-Length: 3\r\n\r\n" <>
          "abc" <> "GET /next HTTP/1.1\r\n\r\n"

      assert {:ok, req, leftover} = Impl.parse_request(raw)
      assert req.method === "POST"
      assert req.body === "abc"
      assert leftover === "GET /next HTTP/1.1\r\n\r\n"
    end

    test "returns :need_more when content-length exceeds available body" do
      raw = "POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\nab"
      assert {:need_more, ^raw} = Impl.parse_request(raw)
    end
  end

  describe "classify_responder_result/1" do
    test "returns {:close_after, iodata}" do
      assert {:close_after, "x"} = Impl.classify_responder_result({:close_after, "x"})
    end

    test "returns {:script, steps} for a list of steps" do
      assert {:script, [:close]} = Impl.classify_responder_result({:script, [:close]})
    end

    test "returns {:keep_alive, iodata} for a binary" do
      assert {:keep_alive, "x"} = Impl.classify_responder_result("x")
    end

    test "returns {:keep_alive, iodata} for an iolist" do
      assert {:keep_alive, ["x", "y"]} = Impl.classify_responder_result(["x", "y"])
    end
  end

  describe "content_length/1" do
    test "reads the value when the header is present" do
      assert 7 = Impl.content_length([{"content-length", "7"}])
    end

    test "is zero when the header is absent" do
      assert 0 = Impl.content_length([{"host", "x"}])
    end
  end
end

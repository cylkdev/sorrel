defmodule Sorrel.CodecTest do
  use ExUnit.Case, async: true

  alias Sorrel.Codec

  describe "encode/1" do
    test "nil body becomes empty bytes with no headers" do
      assert Codec.encode(nil) === {"", []}
    end

    test "binary body passes through verbatim with no headers" do
      assert Codec.encode("plain") === {"plain", []}
    end

    test "iolist body passes through verbatim with no headers" do
      iolist = [?a, "bc", ?d]
      assert Codec.encode(iolist) === {iolist, []}
    end

    test "{:json, term} encodes as JSON and adds application/json content-type" do
      {bytes, headers} = Codec.encode({:json, %{a: 1}})

      assert headers === [{"content-type", "application/json"}]
      assert JSON.decode!(bytes) === %{"a" => 1}
    end

    test "{:tar, bytes} passes through verbatim and adds application/x-tar content-type" do
      assert Codec.encode({:tar, "...tar bytes..."}) ===
               {"...tar bytes...", [{"content-type", "application/x-tar"}]}
    end

    test "{:json, non-encodable} raises Protocol.UndefinedError" do
      assert_raise Protocol.UndefinedError, fn ->
        Codec.encode({:json, fn -> :x end})
      end
    end
  end

  describe "decode_body/3" do
    test ":auto with JSON content-type decodes JSON" do
      assert Codec.decode_body(~s({"a":1}), :auto, [{"content-type", "application/json"}]) ===
               %{"a" => 1}
    end

    test ":auto with non-JSON content-type returns the binary unchanged" do
      assert Codec.decode_body("hello", :auto, [{"content-type", "text/plain"}]) === "hello"
    end

    test ":auto with JSON content-type and malformed body raises JSON.DecodeError" do
      assert_raise JSON.DecodeError, fn ->
        Codec.decode_body("not json", :auto, [{"content-type", "application/json"}])
      end
    end

    test ":json always JSON-decodes" do
      assert Codec.decode_body(~s({"a":1}), :json, []) === %{"a" => 1}
    end

    test ":json raises JSON.DecodeError on malformed body" do
      assert_raise JSON.DecodeError, fn ->
        Codec.decode_body("not json", :json, [])
      end
    end

    test ":raw always returns the binary unchanged" do
      assert Codec.decode_body("hello", :raw, []) === "hello"
      assert Codec.decode_body("hello", :raw, [{"content-type", "application/json"}]) === "hello"
    end
  end

  describe "decode_chunk/3 :ndjson" do
    test "decodes a single complete chunk with two events" do
      assert Codec.decode_chunk(~s({"a":1}\n{"b":2}\n), "", :ndjson) ===
               {[%{"a" => 1}, %{"b" => 2}], ""}
    end

    test "carries an incomplete trailing line as leftover_buffer" do
      assert Codec.decode_chunk(~s({"a":1}\n{"b), "", :ndjson) ===
               {[%{"a" => 1}], ~s({"b)}
    end

    test "skips empty lines between events" do
      assert Codec.decode_chunk(~s({"a":1}\n\n{"b":2}\n), "", :ndjson) ===
               {[%{"a" => 1}, %{"b" => 2}], ""}
    end

    test "raises JSON.DecodeError on a malformed line" do
      assert_raise JSON.DecodeError, fn ->
        Codec.decode_chunk(~s(not json\n), "", :ndjson)
      end
    end

    test "joins a non-empty buffer with the new chunk before splitting" do
      assert Codec.decode_chunk("3}\n", ~s({"a":), :ndjson) === {[%{"a" => 3}], ""}
    end
  end

  describe "decode_chunk/3 :raw" do
    test "non-empty chunk becomes one event with empty leftover" do
      assert Codec.decode_chunk("hello", "", :raw) === {["hello"], ""}
    end

    test "empty chunk produces no events and empty leftover" do
      assert Codec.decode_chunk("", "", :raw) === {[], ""}
    end
  end
end

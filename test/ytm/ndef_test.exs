defmodule Ytm.NDEFTest do
  use ExUnit.Case, async: true

  alias Ytm.NDEF
  alias Ytm.NDEF.Record

  describe "decode/1" do
    test "extracts the NDEF message from a single-byte-length TLV" do
      message = <<0xD1, 0x01, 0x03, 0x54, 0x02, 0x65, 0x6E>>
      data = <<0x03, byte_size(message), message::binary, 0xFE>>

      assert NDEF.decode(data) == {:ok, message}
    end

    test "extracts the NDEF message from a three-byte-length TLV" do
      message = :binary.copy(<<0xAA>>, 300)
      data = <<0x03, 0xFF, byte_size(message)::big-16, message::binary, 0xFE>>

      assert NDEF.decode(data) == {:ok, message}
    end

    test "skips leading NULL TLVs" do
      message = <<0xD1, 0x01, 0x00, 0x54>>
      data = <<0x00, 0x00, 0x03, byte_size(message), message::binary, 0xFE>>

      assert NDEF.decode(data) == {:ok, message}
    end

    test "skips over other TLVs (e.g. Lock Control) before the NDEF Message TLV" do
      message = <<0xD1, 0x01, 0x00, 0x54>>
      lock_control = <<0x01, 0x02>>

      data =
        <<0x01, byte_size(lock_control), lock_control::binary, 0x03, byte_size(message),
          message::binary>>

      assert NDEF.decode(data) == {:ok, message}
    end

    test "errors when the terminator TLV is reached with no NDEF Message TLV" do
      assert NDEF.decode(<<0xFE>>) == {:error, :no_ndef_tlv}
    end

    test "errors when data runs out with no NDEF Message TLV" do
      assert NDEF.decode(<<0x00, 0x00>>) == {:error, :no_ndef_tlv}
    end

    test "errors on a truncated TLV (tag with no length byte)" do
      assert NDEF.decode(<<0x03>>) == {:error, :truncated}
    end

    test "errors when the declared length exceeds the available data" do
      assert NDEF.decode(<<0x03, 10, 0x01, 0x02>>) == {:error, :truncated}
    end
  end

  describe "decode_records/1" do
    test "decodes a well-known Text record (short record, no id)" do
      message = <<0xD1, 0x01, 0x08, "T", 0x02, "en", "Hello">>

      assert NDEF.decode_records(message) ==
               {:ok,
                [%Record{tnf: :well_known, type: "T", id: <<>>, payload: <<0x02, "en", "Hello">>}]}
    end

    test "decodes a well-known URI record" do
      message = <<0xD1, 0x01, 0x0C, "U", 0x04, "example.com">>

      assert {:ok, [record]} = NDEF.decode_records(message)
      assert record.tnf == :well_known
      assert record.type == "U"
      assert NDEF.decode_uri(record) == {:ok, "https://example.com"}
    end

    test "decodes a record with an ID field present" do
      message = <<0xDC, 1, 1, 1, "X", "i", "Z">>

      assert NDEF.decode_records(message) ==
               {:ok, [%Record{tnf: :external, type: "X", id: "i", payload: "Z"}]}
    end

    test "decodes a long record (SR unset, 4-byte payload length)" do
      payload = :binary.copy(<<0xBB>>, 300)
      message = <<0xC2, 1, byte_size(payload)::big-32, "M", payload::binary>>

      assert NDEF.decode_records(message) ==
               {:ok, [%Record{tnf: :mime_media, type: "M", id: <<>>, payload: payload}]}
    end

    test "decodes multiple records in one message" do
      text_record = <<0x91, 0x01, 0x08, "T", 0x02, "en", "Hello">>
      uri_record = <<0x51, 0x01, 0x0C, "U", 0x04, "example.com">>

      assert {:ok, [first, second]} = NDEF.decode_records(text_record <> uri_record)
      assert first.type == "T"
      assert second.type == "U"
    end

    test "errors on a chunked record" do
      assert NDEF.decode_records(<<0xA1, 0x01, 0x01, "T", "x">>) == {:error, :chunked_record}
    end

    test "errors on a truncated record header" do
      assert NDEF.decode_records(<<0xD1, 0x01>>) == {:error, :truncated}
    end

    test "errors when type/id/payload run past the available data" do
      assert NDEF.decode_records(<<0xD1, 0x01, 0x08, "T">>) == {:error, :truncated}
    end
  end

  describe "decode_text/1" do
    test "decodes a UTF-8 text payload" do
      record = %Record{tnf: :well_known, type: "T", id: <<>>, payload: <<0x02, "en", "Hello">>}

      assert NDEF.decode_text(record) == {:ok, {"en", "Hello"}}
    end

    test "decodes a UTF-16BE text payload with a BOM" do
      payload = <<0x82, "en", 0xFE, 0xFF, 0x00, 0x48, 0x00, 0x69>>
      record = %Record{tnf: :well_known, type: "T", id: <<>>, payload: payload}

      assert NDEF.decode_text(record) == {:ok, {"en", "Hi"}}
    end

    test "errors on a non-text record" do
      record = %Record{tnf: :well_known, type: "U", id: <<>>, payload: <<0x00, "x">>}

      assert NDEF.decode_text(record) == {:error, :not_a_text_record}
    end
  end

  describe "decode_uri/1" do
    test "expands a known prefix code" do
      record = %Record{tnf: :well_known, type: "U", id: <<>>, payload: <<0x01, "example.com">>}

      assert NDEF.decode_uri(record) == {:ok, "http://www.example.com"}
    end

    test "passes through an unabbreviated URI (prefix code 0x00)" do
      record = %Record{tnf: :well_known, type: "U", id: <<>>, payload: <<0x00, "urn:foo:bar">>}

      assert NDEF.decode_uri(record) == {:ok, "urn:foo:bar"}
    end

    test "errors on a non-uri record" do
      record = %Record{tnf: :well_known, type: "T", id: <<>>, payload: <<0x02, "en", "Hello">>}

      assert NDEF.decode_uri(record) == {:error, :not_a_uri_record}
    end
  end
end

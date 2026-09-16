defmodule Ytm.NDEFTest do
  use ExUnit.Case, async: true

  alias Ytm.NDEF

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
end

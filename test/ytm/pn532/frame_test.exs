defmodule Ytm.PN532.FrameTest do
  use ExUnit.Case, async: true

  alias Ytm.PN532.Frame

  describe "encode/2" do
    test "matches the known GetFirmwareVersion command frame" do
      assert Frame.encode(0x02) == <<0x00, 0x00, 0xFF, 0x02, 0xFE, 0xD4, 0x02, 0x2A, 0x00>>
    end

    test "includes params in the length and checksum" do
      frame = Frame.encode(0x4A, <<0x01, 0x00>>)

      assert frame == <<0x00, 0x00, 0xFF, 0x04, 0xFC, 0xD4, 0x4A, 0x01, 0x00, 0xE1, 0x00>>
    end
  end

  describe "ack_frame/0 and ack?/1" do
    test "ack_frame is the fixed 6-byte sequence" do
      assert Frame.ack_frame() == <<0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00>>
    end

    test "ack?/1 matches only the exact ack frame" do
      assert Frame.ack?(Frame.ack_frame())
      refute Frame.ack?(<<0x00, 0x00, 0xFF, 0x00, 0xFF, 0x01>>)
    end
  end

  describe "decode/1" do
    test "round-trips a well-formed response frame" do
      # PN532 -> host, echoing GetFirmwareVersion (0x02+1 = 0x03),
      # params [ic_version: 0x32, version: 1, revision: 6, support: 7].
      frame = <<0x00, 0x00, 0xFF, 0x06, 0xFA, 0xD5, 0x03, 0x32, 0x01, 0x06, 0x07, 0xE8, 0x00>>

      assert {:ok, payload} = Frame.decode(frame)
      assert payload == <<0xD5, 0x03, 0x32, 0x01, 0x06, 0x07>>
      assert Frame.response_to?(payload, 0x02)
      refute Frame.response_to?(payload, 0x4A)
      assert Frame.response_data(payload) == <<0x32, 0x01, 0x06, 0x07>>
    end

    test "skips leading zero padding before the start code" do
      frame = <<0x00, 0x00, 0x00, 0xFF, 0x02, 0xFE, 0xD5, 0x15, 0x16, 0x00>>

      assert {:ok, <<0xD5, 0x15>>} = Frame.decode(frame)
    end

    test "rejects a frame with no 0x00FF start code" do
      assert Frame.decode(<<0x01, 0x02, 0x03>>) == {:error, :invalid_preamble}
    end

    test "rejects a length/LCS mismatch" do
      frame = <<0x00, 0x00, 0xFF, 0x02, 0x00, 0xD5, 0x15, 0xEC, 0x00>>

      assert Frame.decode(frame) == {:error, :length_checksum_mismatch}
    end

    test "rejects a data checksum mismatch" do
      frame = <<0x00, 0x00, 0xFF, 0x02, 0xFE, 0xD5, 0x15, 0x00, 0x00>>

      assert Frame.decode(frame) == {:error, :data_checksum_mismatch}
    end

    test "rejects a truncated frame" do
      assert Frame.decode(<<0x00, 0x00, 0xFF, 0x02, 0xFE, 0xD5>>) == {:error, :truncated}
    end
  end
end

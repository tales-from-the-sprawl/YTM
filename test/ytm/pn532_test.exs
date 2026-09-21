defmodule Ytm.PN532Test do
  use ExUnit.Case, async: true

  alias Ytm.PN532

  describe "chunk_padded/2" do
    test "splits data that's already a multiple of chunk_size with no padding" do
      data = <<1, 2, 3, 4, 5, 6, 7, 8>>

      assert PN532.chunk_padded(data, 4) == [<<1, 2, 3, 4>>, <<5, 6, 7, 8>>]
    end

    test "zero-pads the last chunk when data isn't a multiple of chunk_size" do
      data = <<1, 2, 3, 4, 5>>

      assert PN532.chunk_padded(data, 4) == [<<1, 2, 3, 4>>, <<5, 0, 0, 0>>]
    end

    test "returns an empty list for empty data" do
      assert PN532.chunk_padded(<<>>, 4) == []
    end

    test "handles a 16-byte chunk size (Mifare Classic blocks)" do
      data = :binary.copy(<<0xAA>>, 20)

      assert [first, second] = PN532.chunk_padded(data, 16)
      assert byte_size(first) == 16
      assert byte_size(second) == 16
      assert second == :binary.copy(<<0xAA>>, 4) <> :binary.copy(<<0>>, 12)
    end
  end
end

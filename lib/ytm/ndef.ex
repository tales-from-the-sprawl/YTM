defmodule Ytm.NDEF do
  @moduledoc """
  Parsing for the NFC Forum Type 2 Tag TLV block structure (see the NFC
  Forum "Type 2 Tag Operation" technical specification, §2.3): locates the
  NDEF Message TLV among a tag's TLV blocks and returns its raw value bytes.

  Only unwraps the TLV envelope; the NDEF message itself (records and their
  payloads) is left undecoded.
  """

  @tlv_null 0x00
  @tlv_ndef_message 0x03
  @tlv_terminator 0xFE
  @tlv_three_byte_length 0xFF

  @type reason :: :no_ndef_tlv | :truncated

  @doc """
  Extracts the raw NDEF message bytes from a tag's TLV-encoded memory, as
  read starting from the first user memory page (page 4 on NTAG21x).
  """
  @spec decode(binary()) :: {:ok, binary()} | {:error, reason()}
  def decode(data) when is_binary(data), do: decode_tlv(data)

  @spec decode_tlv(binary()) :: {:ok, binary()} | {:error, reason()}
  defp decode_tlv(<<@tlv_null, rest::binary>>), do: decode_tlv(rest)
  defp decode_tlv(<<@tlv_terminator, _rest::binary>>), do: {:error, :no_ndef_tlv}

  defp decode_tlv(<<@tlv_ndef_message, @tlv_three_byte_length, length::big-16, rest::binary>>),
    do: take_value(rest, length)

  defp decode_tlv(<<@tlv_ndef_message, length, rest::binary>>), do: take_value(rest, length)

  defp decode_tlv(<<_tag, @tlv_three_byte_length, length::big-16, rest::binary>>),
    do: skip_value(rest, length)

  defp decode_tlv(<<_tag, length, rest::binary>>), do: skip_value(rest, length)
  defp decode_tlv(<<>>), do: {:error, :no_ndef_tlv}
  defp decode_tlv(<<_tag>>), do: {:error, :truncated}

  @spec take_value(binary(), non_neg_integer()) :: {:ok, binary()} | {:error, reason()}
  defp take_value(data, length) when byte_size(data) >= length do
    <<value::binary-size(^length), _rest::binary>> = data
    {:ok, value}
  end

  defp take_value(_data, _length), do: {:error, :truncated}

  @spec skip_value(binary(), non_neg_integer()) :: {:ok, binary()} | {:error, reason()}
  defp skip_value(data, length) when byte_size(data) >= length do
    <<_skipped::binary-size(^length), rest::binary>> = data
    decode_tlv(rest)
  end

  defp skip_value(_data, _length), do: {:error, :truncated}
end

defmodule Ytm.NDEF do
  @moduledoc """
  Parsing for NDEF (NFC Data Exchange Format) data read from a tag.

  `decode/1` unwraps the NFC Forum Type 2 Tag TLV block structure (see the
  NFC Forum "Type 2 Tag Operation" technical specification, §2.3) to find
  the NDEF Message TLV and return its raw bytes. `decode_records/1` then
  parses that message into its individual `Ytm.NDEF.Record` structs (NFC
  Forum "NDEF" technical specification, §2.3), and `decode_text/1` /
  `decode_uri/1` decode the two most common well-known record payloads.
  """

  alias Ytm.NDEF.Record

  @tlv_null 0x00
  @tlv_ndef_message 0x03
  @tlv_terminator 0xFE
  @tlv_three_byte_length 0xFF

  @uri_prefixes %{
    0x00 => "",
    0x01 => "http://www.",
    0x02 => "https://www.",
    0x03 => "http://",
    0x04 => "https://",
    0x05 => "tel:",
    0x06 => "mailto:",
    0x07 => "ftp://anonymous:anonymous@",
    0x08 => "ftp://ftp.",
    0x09 => "ftps://",
    0x0A => "sftp://",
    0x0B => "smb://",
    0x0C => "nfs://",
    0x0D => "ftp://",
    0x0E => "dav://",
    0x0F => "news:",
    0x10 => "telnet://",
    0x11 => "imap:",
    0x12 => "rtsp://",
    0x13 => "urn:",
    0x14 => "pop:",
    0x15 => "sip:",
    0x16 => "sips:",
    0x17 => "tftp:",
    0x18 => "btspp://",
    0x19 => "btl2cap://",
    0x1A => "btgoep://",
    0x1B => "tcpobex://",
    0x1C => "irdaobex://",
    0x1D => "file://",
    0x1E => "urn:epc:id:",
    0x1F => "urn:epc:tag:",
    0x20 => "urn:epc:pat:",
    0x21 => "urn:epc:raw:",
    0x22 => "urn:epc:",
    0x23 => "urn:nfc:"
  }

  @type reason :: :no_ndef_tlv | :truncated | :chunked_record

  @doc """
  Extracts the raw NDEF message bytes from a tag's TLV-encoded memory, as
  read starting from the first user memory page (page 4 on NTAG21x).
  """
  @spec decode(binary()) :: {:ok, binary()} | {:error, reason()}
  def decode(data) when is_binary(data), do: decode_tlv(data)

  @doc """
  Parses a raw NDEF message (as returned by `decode/1`) into its records.

  Chunked records (`CF` flag set) are not supported and return
  `{:error, :chunked_record}`.
  """
  @spec decode_records(binary()) :: {:ok, [Record.t()]} | {:error, reason()}
  def decode_records(message) when is_binary(message), do: decode_record(message, [])

  @doc """
  Decodes a well-known Text record's payload into its `{language, text}`
  parts (NFC Forum "Text Record Type Definition").
  """
  @spec decode_text(Record.t()) :: {:ok, {String.t(), String.t()}} | {:error, :not_a_text_record}
  def decode_text(%Record{tnf: :well_known, type: "T", payload: <<status, rest::binary>>}) do
    language_length = Bitwise.band(status, 0x3F)
    encoding = if Bitwise.band(status, 0x80) == 0x80, do: :utf16, else: :utf8

    case rest do
      <<language::binary-size(^language_length), text::binary>> ->
        {:ok, {language, decode_text_bytes(text, encoding)}}

      _rest ->
        {:error, :not_a_text_record}
    end
  end

  def decode_text(%Record{}), do: {:error, :not_a_text_record}

  @doc """
  Decodes a well-known URI record's payload into the full URI string,
  expanding the abbreviated prefix code (NFC Forum "URI Record Type
  Definition").
  """
  @spec decode_uri(Record.t()) :: {:ok, String.t()} | {:error, :not_a_uri_record}
  def decode_uri(%Record{tnf: :well_known, type: "U", payload: <<prefix_code, rest::binary>>}) do
    {:ok, Map.get(@uri_prefixes, prefix_code, "") <> rest}
  end

  def decode_uri(%Record{}), do: {:error, :not_a_uri_record}

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

  @spec decode_record(binary(), [Record.t()]) :: {:ok, [Record.t()]} | {:error, reason()}
  defp decode_record(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_record(<<_mb::1, _me::1, 1::1, _sr::1, _il::1, _tnf::3, _rest::binary>>, _acc) do
    {:error, :chunked_record}
  end

  defp decode_record(
         <<_mb::1, _me::1, 0::1, 1::1, il::1, tnf::3, type_length, payload_length, rest::binary>>,
         acc
       ) do
    take_record(rest, tnf, il, type_length, payload_length, acc)
  end

  defp decode_record(
         <<_mb::1, _me::1, 0::1, 0::1, il::1, tnf::3, type_length, payload_length::big-32,
           rest::binary>>,
         acc
       ) do
    take_record(rest, tnf, il, type_length, payload_length, acc)
  end

  defp decode_record(_binary, _acc), do: {:error, :truncated}

  @spec take_record(binary(), 0..7, 0 | 1, byte(), non_neg_integer(), [Record.t()]) ::
          {:ok, [Record.t()]} | {:error, reason()}
  defp take_record(<<id_length, rest::binary>>, tnf, 1, type_length, payload_length, acc) do
    take_record_fields(rest, tnf, type_length, id_length, payload_length, acc)
  end

  defp take_record(_data, _tnf, 1, _type_length, _payload_length, _acc), do: {:error, :truncated}

  defp take_record(data, tnf, 0, type_length, payload_length, acc) do
    take_record_fields(data, tnf, type_length, 0, payload_length, acc)
  end

  @spec take_record_fields(binary(), 0..7, byte(), byte(), non_neg_integer(), [Record.t()]) ::
          {:ok, [Record.t()]} | {:error, reason()}
  defp take_record_fields(data, tnf, type_length, id_length, payload_length, acc)
       when byte_size(data) >= type_length + id_length + payload_length do
    <<type::binary-size(^type_length), id::binary-size(^id_length),
      payload::binary-size(^payload_length), rest::binary>> = data

    record = %Record{tnf: tnf_atom(tnf), type: type, id: id, payload: payload}
    decode_record(rest, [record | acc])
  end

  defp take_record_fields(_data, _tnf, _type_length, _id_length, _payload_length, _acc),
    do: {:error, :truncated}

  @spec tnf_atom(0..7) :: Record.tnf()
  defp tnf_atom(0x00), do: :empty
  defp tnf_atom(0x01), do: :well_known
  defp tnf_atom(0x02), do: :mime_media
  defp tnf_atom(0x03), do: :absolute_uri
  defp tnf_atom(0x04), do: :external
  defp tnf_atom(0x05), do: :unknown
  defp tnf_atom(0x06), do: :unchanged
  defp tnf_atom(0x07), do: :reserved

  @spec decode_text_bytes(binary(), :utf8 | :utf16) :: String.t()
  defp decode_text_bytes(bytes, :utf8), do: bytes
  defp decode_text_bytes(<<0xFE, 0xFF, rest::binary>>, :utf16), do: utf16_to_utf8(rest, :big)
  defp decode_text_bytes(<<0xFF, 0xFE, rest::binary>>, :utf16), do: utf16_to_utf8(rest, :little)
  defp decode_text_bytes(bytes, :utf16), do: utf16_to_utf8(bytes, :big)

  @spec utf16_to_utf8(binary(), :big | :little) :: String.t()
  defp utf16_to_utf8(bytes, endianness) do
    case :unicode.characters_to_binary(bytes, {:utf16, endianness}, :utf8) do
      text when is_binary(text) -> text
      _error -> bytes
    end
  end
end

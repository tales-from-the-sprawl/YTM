defmodule Ytm.PN532 do
  @moduledoc """
  Driver for the PN532 NFC/RFID reader IC over SPI (see NXP UM0701-02).

  Port of Adafruit's CircuitPython `adafruit_pn532` driver's SPI backend,
  built on `Ytm.PN532.SPI` (bus transport) and `Ytm.PN532.Frame` (protocol
  framing). Only the commands the reference driver implements are covered:
  firmware/SAM setup, ISO14443A passive target detection, and Mifare
  Classic/NTAG2xx block access.

  Every public function returns `{:ok, result} | {:error, reason}` for
  expected hardware/protocol failures (bus errors, timeouts, malformed
  frames, a card rejecting a Mifare command); only genuinely invalid
  arguments (wrong block-data size) raise, via function guards.
  """

  alias Ytm.NDEF
  alias Ytm.PN532.Frame
  alias Ytm.PN532.SPI

  @enforce_keys [:spi]
  defstruct [:spi, :reset_gpio]

  @type t :: %__MODULE__{spi: SPI.t(), reset_gpio: Circuits.GPIO.Handle.t() | nil}

  @type error ::
          :timeout
          | :bad_ack
          | :unexpected_response
          | Frame.reason()
          | {:spi_error, any()}

  @command_get_firmware_version 0x02
  @command_sam_configuration 0x14
  @command_power_down 0x16
  @command_in_list_passive_target 0x4A
  @command_in_data_exchange 0x40

  @mifare_cmd_read 0x30
  @mifare_cmd_write 0xA0
  @mifare_cmd_transfer 0xB0
  @mifare_cmd_decrement 0xC0
  @mifare_cmd_increment 0xC1
  @ntag_ultralight_cmd_write 0xA2

  @mifare_iso14443a 0x00

  @default_timeout_ms 1000
  @firmware_timeout_ms 500

  @ndef_start_page 4
  @ndef_max_pages 231

  @doc """
  Opens the SPI bus, resets and wakes the PN532, puts it in normal (SAM)
  mode, and confirms it's alive by reading its firmware version.

  `opts`:
  * `:speed_hz` - SPI clock speed, defaults to 500 kHz.
  * `:reset_gpio` - an already-open `Circuits.GPIO` handle wired to the
    PN532's `RSTPDN` pin. When given, it's pulsed low then high around the
    wakeup, matching the reset sequence in the reference driver. Omit if
    no reset pin is wired.
  """
  @spec open(binary(), keyword()) :: {:ok, t()} | {:error, error()}
  def open(bus_name, opts \\ []) when is_binary(bus_name) do
    reset_gpio = Keyword.get(opts, :reset_gpio)
    spi_opts = Keyword.take(opts, [:speed_hz])

    with {:ok, spi} <- SPI.open(bus_name, spi_opts),
         pn532 = %__MODULE__{spi: spi, reset_gpio: reset_gpio},
         :ok <- reset(pn532),
         :ok <- SPI.wakeup(spi),
         :ok <- sam_configuration(pn532),
         {:ok, _version} <- firmware_version(pn532) do
      {:ok, pn532}
    end
  end

  @doc "Releases the underlying SPI bus."
  @spec close(t()) :: :ok
  def close(pn532), do: Circuits.SPI.close(pn532.spi)

  @doc "Reads the chip's IC/firmware/revision/support byte tuple."
  @spec firmware_version(t()) :: {:ok, {byte(), byte(), byte(), byte()}} | {:error, error()}
  def firmware_version(pn532) do
    with {:ok, <<ic, version, revision, support>>} <-
           call_function(pn532, @command_get_firmware_version, <<>>, 4, @firmware_timeout_ms) do
      {:ok, {ic, version, revision, support}}
    end
  end

  @doc "Puts the PN532 in normal SAM mode (as opposed to virtual card/multicard mode)."
  @spec sam_configuration(t()) :: :ok | {:error, error()}
  def sam_configuration(pn532) do
    with {:ok, _response} <-
           call_function(pn532, @command_sam_configuration, <<0x01, 0x14, 0x01>>, 0) do
      :ok
    end
  end

  @doc "Requests a soft power-down, with wakeup enabled on SPI. Returns whether the chip accepted it."
  @spec power_down(t()) :: {:ok, boolean()} | {:error, error()}
  def power_down(pn532) do
    with {:ok, <<status, _rest::binary>>} <-
           call_function(pn532, @command_power_down, <<0xB0, 0x00>>, 1) do
      {:ok, status == 0}
    end
  end

  @doc "Starts listening for a single passive ISO14443A target; call `get_passive_target/2` to retrieve it."
  @spec listen_for_passive_target(t(), byte()) :: :ok | {:error, error()}
  def listen_for_passive_target(pn532, card_baud \\ @mifare_iso14443a) do
    send_command(pn532, @command_in_list_passive_target, <<0x01, card_baud>>, @default_timeout_ms)
  end

  @doc "Retrieves the UID of a target found after `listen_for_passive_target/2`."
  @spec get_passive_target(t(), non_neg_integer()) ::
          {:ok, binary()} | {:error, error() | :no_target_found | :too_many_cards | :uid_too_long}
  def get_passive_target(pn532, timeout_ms \\ @default_timeout_ms) do
    with {:ok, response} <-
           process_response(pn532, @command_in_list_passive_target, 64, timeout_ms) do
      parse_passive_target(response)
    end
  end

  @doc "Combines `listen_for_passive_target/2` and `get_passive_target/2` into a single call."
  @spec read_passive_target(t(), byte(), non_neg_integer()) ::
          {:ok, binary()} | {:error, error() | :no_target_found | :too_many_cards | :uid_too_long}
  def read_passive_target(
        pn532,
        card_baud \\ @mifare_iso14443a,
        timeout_ms \\ @default_timeout_ms
      ) do
    with :ok <- listen_for_passive_target(pn532, card_baud) do
      get_passive_target(pn532, timeout_ms)
    end
  end

  @doc "Authenticates a Mifare Classic block with a key, ahead of a read or write."
  @spec mifare_classic_authenticate_block(t(), binary(), byte(), byte(), binary()) ::
          {:ok, boolean()} | {:error, error()}
  def mifare_classic_authenticate_block(pn532, uid, block_number, key_number, key) do
    params = <<0x01, key_number, block_number, key::binary, uid::binary>>

    with {:ok, <<status, _rest::binary>>} <-
           call_function(pn532, @command_in_data_exchange, params, 1) do
      {:ok, status == 0}
    end
  end

  @doc "Reads a 16-byte Mifare Classic block. The block must already be authenticated."
  @spec mifare_classic_read_block(t(), byte()) :: {:ok, binary()} | {:error, error()}
  def mifare_classic_read_block(pn532, block_number) do
    params = <<0x01, @mifare_cmd_read, block_number>>

    case call_function(pn532, @command_in_data_exchange, params, 17) do
      {:ok, <<0, data::binary-size(16)>>} -> {:ok, data}
      {:ok, <<status, _rest::binary>>} -> {:error, {:mifare_status, status}}
      error -> error
    end
  end

  @doc "Writes a 16-byte Mifare Classic block. The block must already be authenticated."
  @spec mifare_classic_write_block(t(), byte(), binary()) :: {:ok, boolean()} | {:error, error()}
  def mifare_classic_write_block(pn532, block_number, data) when byte_size(data) == 16 do
    params = <<0x01, @mifare_cmd_write, block_number, data::binary>>

    with {:ok, <<status, _rest::binary>>} <-
           call_function(pn532, @command_in_data_exchange, params, 1) do
      {:ok, status == 0}
    end
  end

  @doc "Subtracts `amount` from a Mifare Classic value block and commits it via TRANSFER."
  @spec mifare_classic_sub_value_block(t(), byte(), integer()) ::
          {:ok, boolean()} | {:error, error()}
  def mifare_classic_sub_value_block(pn532, block_number, amount) do
    value_op(pn532, @mifare_cmd_decrement, block_number, amount)
  end

  @doc "Adds `amount` to a Mifare Classic value block and commits it via TRANSFER."
  @spec mifare_classic_add_value_block(t(), byte(), integer()) ::
          {:ok, boolean()} | {:error, error()}
  def mifare_classic_add_value_block(pn532, block_number, amount) do
    value_op(pn532, @mifare_cmd_increment, block_number, amount)
  end

  @doc "Reads and validates a Mifare Classic value block, returning its signed integer value."
  @spec mifare_classic_get_value_block(t(), byte()) ::
          {:ok, integer()} | {:error, error() | :invalid_value_block}
  def mifare_classic_get_value_block(pn532, block_number) do
    with {:ok, block} <- mifare_classic_read_block(pn532, block_number) do
      parse_value_block(block)
    end
  end

  @doc "Formats a Mifare Classic block as a value block holding `initial_value`."
  @spec mifare_classic_fmt_value_block(t(), byte(), integer(), byte()) ::
          {:ok, boolean()} | {:error, error()}
  def mifare_classic_fmt_value_block(pn532, block_number, initial_value, address_block \\ 0) do
    value_bytes = <<initial_value::little-signed-32>>
    address_check = Bitwise.bxor(address_block, 0xFF)

    data =
      value_bytes <>
        invert(value_bytes) <>
        value_bytes <> <<address_block, address_check, address_block, address_check>>

    mifare_classic_write_block(pn532, block_number, data)
  end

  @doc "Reads a 4-byte NTAG2xx page."
  @spec ntag2xx_read_block(t(), byte()) :: {:ok, binary()} | {:error, error()}
  def ntag2xx_read_block(pn532, block_number) do
    with {:ok, <<page::binary-size(4), _rest::binary>>} <-
           mifare_classic_read_block(pn532, block_number) do
      {:ok, page}
    end
  end

  @doc "Writes a 4-byte NTAG2xx page."
  @spec ntag2xx_write_block(t(), byte(), binary()) :: {:ok, boolean()} | {:error, error()}
  def ntag2xx_write_block(pn532, block_number, data) when byte_size(data) == 4 do
    params = <<0x01, @ntag_ultralight_cmd_write, block_number, data::binary>>

    with {:ok, <<status, _rest::binary>>} <-
           call_function(pn532, @command_in_data_exchange, params, 1) do
      {:ok, status == 0}
    end
  end

  @doc """
  Reads the raw NDEF message from an NTAG21x tag's user memory, starting at
  page 4 and unwrapping the TLV block structure. Reads stop as soon as the
  tag reports an out-of-bounds block (end of its memory) or the NDEF
  message has been found.
  """
  @spec read_ndef(t()) :: {:ok, binary()} | {:error, error() | NDEF.reason()}
  def read_ndef(pn532) do
    with {:ok, data} <- read_pages(pn532, @ndef_start_page, @ndef_max_pages, <<>>) do
      NDEF.decode(data)
    end
  end

  @spec read_pages(t(), byte(), non_neg_integer(), binary()) ::
          {:ok, binary()} | {:error, error()}
  defp read_pages(_pn532, _page, 0, acc), do: {:ok, acc}

  defp read_pages(pn532, page, remaining, acc) do
    case ntag2xx_read_block(pn532, page) do
      {:ok, data} -> read_pages(pn532, page + 1, remaining - 1, acc <> data)
      {:error, {:mifare_status, _status}} -> {:ok, acc}
      {:error, _reason} = error -> error
    end
  end

  @spec reset(t()) :: :ok
  defp reset(%__MODULE__{reset_gpio: nil}), do: :ok

  defp reset(%__MODULE__{reset_gpio: gpio}) do
    :ok = Circuits.GPIO.write(gpio, 0)
    Process.sleep(100)
    :ok = Circuits.GPIO.write(gpio, 1)
    Process.sleep(100)
    :ok
  end

  @spec value_op(t(), byte(), byte(), integer()) :: {:ok, boolean()} | {:error, error()}
  defp value_op(pn532, op, block_number, amount) do
    params = <<0x01, op, block_number, amount::little-signed-32>>

    case call_function(pn532, @command_in_data_exchange, params, 1) do
      {:ok, <<0, _rest::binary>>} -> transfer(pn532, block_number)
      {:ok, <<_status, _rest::binary>>} -> {:ok, false}
      error -> error
    end
  end

  @spec transfer(t(), byte()) :: {:ok, boolean()} | {:error, error()}
  defp transfer(pn532, block_number) do
    params = <<0x01, @mifare_cmd_transfer, block_number>>

    with {:ok, <<status, _rest::binary>>} <-
           call_function(pn532, @command_in_data_exchange, params, 1) do
      {:ok, status == 0}
    end
  end

  @spec parse_passive_target(binary()) ::
          {:ok, binary()} | {:error, :no_target_found | :too_many_cards | :uid_too_long}
  defp parse_passive_target(
         <<1, _tg, _sens_res::binary-size(2), _sel_res, uid_len, rest::binary>>
       )
       when uid_len <= 7 do
    <<uid::binary-size(^uid_len), _rest::binary>> = rest
    {:ok, uid}
  end

  defp parse_passive_target(<<1, _rest::binary>>), do: {:error, :uid_too_long}
  defp parse_passive_target(<<0, _rest::binary>>), do: {:error, :no_target_found}
  defp parse_passive_target(_response), do: {:error, :too_many_cards}

  @spec parse_value_block(binary()) :: {:ok, integer()} | {:error, :invalid_value_block}
  defp parse_value_block(
         <<value_bytes::binary-size(4), inv_bytes::binary-size(4), dup_bytes::binary-size(4),
           _address::binary-size(4)>>
       ) do
    if dup_bytes == value_bytes and inv_bytes == invert(value_bytes) do
      <<value::little-signed-32>> = value_bytes
      {:ok, value}
    else
      {:error, :invalid_value_block}
    end
  end

  @spec invert(binary()) :: binary()
  defp invert(bytes), do: for(<<byte <- bytes>>, into: <<>>, do: <<Bitwise.bxor(byte, 0xFF)>>)

  @spec send_command(t(), byte(), binary(), non_neg_integer()) :: :ok | {:error, error()}
  defp send_command(pn532, command, params, timeout_ms) do
    frame = Frame.encode(command, params)
    ack_size = byte_size(Frame.ack_frame())

    with :ok <- SPI.write_data(pn532.spi, frame),
         :ok <- SPI.wait_ready(pn532.spi, timeout_ms),
         {:ok, ack} <- SPI.read_data(pn532.spi, ack_size) do
      if Frame.ack?(ack), do: :ok, else: {:error, :bad_ack}
    end
  end

  @spec process_response(t(), byte(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, error()}
  defp process_response(pn532, command, response_length, timeout_ms) do
    with :ok <- SPI.wait_ready(pn532.spi, timeout_ms),
         {:ok, raw} <- SPI.read_data(pn532.spi, response_length + 9),
         {:ok, payload} <- Frame.decode(raw) do
      if Frame.response_to?(payload, command) do
        {:ok, Frame.response_data(payload)}
      else
        {:error, :unexpected_response}
      end
    end
  end

  @spec call_function(t(), byte(), binary(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, error()}
  defp call_function(pn532, command, params, response_length, timeout_ms \\ @default_timeout_ms) do
    with :ok <- send_command(pn532, command, params, timeout_ms) do
      process_response(pn532, command, response_length, timeout_ms)
    end
  end
end

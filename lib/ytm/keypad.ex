defmodule Ytm.Keypad do
  @moduledoc """
  GenServer driver for a 4x4 matrix keypad (12-key keypad plus `A`/`B`/`C`/`D`
  keys) wired to GPIO rows 6/13/19/26 and columns 12/16/20/21.

  Rows are opened as inputs with an internal pull-up and interrupts on the
  falling edge; columns are opened as outputs, driven high one at a time to
  scan for which row went low. On a debounced keypress, broadcasts, over
  `Ytm.PubSub` on `#{inspect(__MODULE__)}.topic/0`, a `{:keypad, key}`
  message.
  """

  use GenServer

  alias Circuits.GPIO

  @row_pins [6, 13, 19, 26]
  @col_pins [12, 16, 20, 21]
  @debounce_interval_ms 100
  @topic "keypad"

  @matrix [
    ["1", "2", "3", "A"],
    ["4", "5", "6", "B"],
    ["7", "8", "9", "C"],
    ["*", "0", "#", "D"]
  ]

  defstruct row_pins: [], col_pins: [], last_press_at: 0

  @doc "PubSub topic broadcasting `{:keypad, key}` for every keypress."
  @spec topic() :: String.t()
  def topic(), do: @topic

  @spec start_link([GenServer.option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl GenServer
  def init([]) do
    state = %__MODULE__{
      row_pins: Enum.map(@row_pins, &open_row_pin!/1),
      col_pins: Enum.map(@col_pins, &open_col_pin!/1)
    }

    {:ok, state}
  end

  @spec open_row_pin!(pos_integer()) :: {pos_integer(), GPIO.Handle.t()}
  defp open_row_pin!(pin_num) do
    {:ok, pin} = GPIO.open(pin_num, :input, pull_mode: :pullup)
    {:ok, ^pin_num} = GPIO.subscribe(pin, trigger: :falling, tag: pin_num)
    {pin_num, pin}
  end

  @spec open_col_pin!(pos_integer()) :: GPIO.Handle.t()
  defp open_col_pin!(pin_num) do
    {:ok, pin} = GPIO.open(pin_num, :output, initial_value: 0)
    pin
  end

  defguardp debounced?(current, prev) when (current - prev) / 1.0e6 > @debounce_interval_ms

  @impl GenServer
  def handle_info(
        {:circuits_gpio, %{ref: pin_num, timestamp: timestamp, value: 0}},
        %__MODULE__{last_press_at: prev} = state
      )
      when debounced?(timestamp, prev) do
    {{_pin_num, row_pin}, row_index} =
      state.row_pins
      |> Enum.with_index()
      |> Enum.find(fn {{row_pin_num, _pin}, _index} -> row_pin_num == pin_num end)

    key =
      state.col_pins
      |> Enum.with_index()
      |> Enum.reduce_while(nil, fn {col, col_index}, nil ->
        # Drive the column high, then read the row pin again - if it reads
        # high, we've found which column the press belongs to.
        GPIO.write(col, 1)
        row_val = GPIO.read(row_pin)
        GPIO.write(col, 0)

        case row_val do
          1 -> {:halt, @matrix |> Enum.at(row_index) |> Enum.at(col_index)}
          0 -> {:cont, nil}
        end
      end)

    if key, do: Phoenix.PubSub.broadcast(Ytm.PubSub, @topic, {:keypad, key})

    {:noreply, %{state | last_press_at: timestamp}}
  end

  # ignore messages that are too quick, or on button release
  @impl GenServer
  def handle_info({:circuits_gpio, %{}}, state), do: {:noreply, state}
end

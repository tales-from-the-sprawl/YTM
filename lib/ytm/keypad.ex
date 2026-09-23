defmodule Ytm.Keypad do
  @moduledoc """
  GenServer driver for a 4x4 matrix keypad (12-key keypad plus `A`/`B`/`C`/`D`
  keys) wired to GPIO rows 6/13/19/26 and columns 12/16/20/21.

  Rows are opened as inputs with an internal pull-up and interrupts on the
  falling edge; columns are opened as outputs, driven high one at a time to
  scan for which row went low. On a debounced keypress, `{:keypad, key}` is
  sent to the owning process (the caller of `start_link/1`, by default).

  `start_link/1` accepts an `:owner` option: the process to send
  `{:keypad, key}` messages to. Defaults to the caller of `start_link/1`.
  """

  use GenServer

  alias Circuits.GPIO

  @row_pins [6, 13, 19, 26]
  @col_pins [12, 16, 20, 21]
  @debounce_interval_ms 100

  @matrix [
    ["1", "2", "3", "A"],
    ["4", "5", "6", "B"],
    ["7", "8", "9", "C"],
    ["*", "0", "#", "D"]
  ]

  defstruct [:owner, row_pins: [], col_pins: [], last_press_at: 0]

  @type start_opt :: {:owner, pid()}

  @spec start_link([start_opt() | GenServer.option()]) :: GenServer.on_start()
  def start_link(opts) do
    {genserver_opts, keypad_opts} = Keyword.split(opts, [:name, :timeout, :debug, :spawn_opt])
    GenServer.start_link(__MODULE__, {self(), keypad_opts}, genserver_opts)
  end

  @impl GenServer
  def init({caller, opts}) do
    state = %__MODULE__{
      owner: Keyword.get(opts, :owner, caller),
      row_pins: Enum.map(@row_pins, &open_row_pin!/1),
      col_pins: Enum.map(@col_pins, &open_col_pin!/1)
    }

    {:ok, state}
  end

  @spec open_row_pin!(pos_integer()) :: {pos_integer(), GPIO.Handle.t()}
  defp open_row_pin!(pin_num) do
    {:ok, pin} = GPIO.open(pin_num, :input, pull_mode: :pullup)
    :ok = GPIO.set_interrupts(pin, :falling)
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
        {:circuits_gpio, pin_num, timestamp, 0},
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

    if key, do: send(state.owner, {:keypad, key})

    {:noreply, %{state | last_press_at: timestamp}}
  end

  # ignore messages that are too quick, or on button release
  @impl GenServer
  def handle_info({:circuits_gpio, _pin_num, _timestamp, _value}, state), do: {:noreply, state}
end

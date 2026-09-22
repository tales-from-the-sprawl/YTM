defmodule Ytm.Keypad do
  @moduledoc """
  GenServer driver for a matrix keypad (e.g. a 4x4 12-key keypad with
  `A`/`B`/`C`/`D` keys) wired to GPIO rows and columns.

  Rows are opened as inputs with an internal pull-up and interrupts on the
  falling edge; columns are opened as outputs, driven high one at a time to
  scan for which row went low. On a debounced keypress, `{:keypad, key}` is
  sent to the owning process (the caller of `start_link/1`, by default).

  At minimum, pass either `:size` or `:matrix` to `start_link/1`:

  * `:size` - selects a built-in matrix: `:four_by_four`/`"4x4"` (standard
    12-key keypad plus `A`/`B`/`C`/`D`), `:four_by_three`/`"4x3"` (standard
    12-key keypad), or `:one_by_four`/`"1x4"`.
  * `:matrix` - a custom `row x col` matrix of key values, e.g.
    `[["1", "2"], ["3", "4"]]`. Takes precedence over `:size` if given.
  * `:row_pins` - GPIO pins for keypad rows, opened as inputs
    (`pull_mode: :pullup`). Defaults to `[17, 27, 23, 24]`.
  * `:col_pins` - GPIO pins for keypad columns, opened as outputs.
    Defaults to `[5, 6, 13, 26]`.
  * `:owner` - process to send `{:keypad, key}` messages to. Defaults to
    the caller of `start_link/1`.
  """

  use GenServer

  alias Circuits.GPIO

  @default_row_pins [6, 13, 19, 26]
  @default_col_pins [12, 16, 20, 21]
  # @default_row_pins [17, 27, 23, 24]
  # @default_col_pins [5, 6, 13, 26]
  @debounce_interval_ms 100

  @matrix_4x4 [
    ["1", "2", "3", "A"],
    ["4", "5", "6", "B"],
    ["7", "8", "9", "C"],
    ["*", "0", "#", "D"]
  ]

  @matrix_4x3 [
    ["1", "2", "3"],
    ["4", "5", "6"],
    ["7", "8", "9"],
    ["*", "0", "#"]
  ]

  @matrix_1x4 [["1", "2", "3", "4"]]

  defstruct [:owner, :matrix, row_pins: [], col_pins: [], last_press_at: 0]

  @type matrix :: [[term()]]
  @type size :: :four_by_four | :four_by_three | :one_by_four | String.t()

  @type start_opt ::
          {:size, size()}
          | {:matrix, matrix()}
          | {:row_pins, [pos_integer()]}
          | {:col_pins, [pos_integer()]}
          | {:owner, pid()}

  @spec start_link([start_opt() | GenServer.option()]) :: GenServer.on_start()
  def start_link(opts) do
    {genserver_opts, keypad_opts} = Keyword.split(opts, [:name, :timeout, :debug, :spawn_opt])
    GenServer.start_link(__MODULE__, {self(), keypad_opts}, genserver_opts)
  end

  @impl GenServer
  def init({caller, opts}) do
    matrix = matrix_from_opts(opts)
    row_pins = Keyword.get(opts, :row_pins, @default_row_pins)
    col_pins = Keyword.get(opts, :col_pins, @default_col_pins)

    validate_dimensions!(matrix, row_pins, col_pins)

    state = %__MODULE__{
      owner: Keyword.get(opts, :owner, caller),
      matrix: matrix,
      row_pins: Enum.map(row_pins, &open_row_pin!/1),
      col_pins: Enum.map(col_pins, &open_col_pin!/1)
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
          1 -> {:halt, state.matrix |> Enum.at(row_index) |> Enum.at(col_index)}
          0 -> {:cont, nil}
        end
      end)

    if key, do: send(state.owner, {:keypad, key})

    {:noreply, %{state | last_press_at: timestamp}}
  end

  # ignore messages that are too quick, or on button release
  @impl GenServer
  def handle_info({:circuits_gpio, _pin_num, _timestamp, _value}, state), do: {:noreply, state}

  @spec matrix_from_opts(keyword()) :: matrix()
  defp matrix_from_opts(opts) do
    case Keyword.get(opts, :matrix) do
      matrix when is_list(matrix) -> validate_matrix!(matrix)
      nil -> matrix_for_size(Keyword.get(opts, :size))
    end
  end

  @spec validate_matrix!(matrix()) :: matrix()
  defp validate_matrix!(matrix) do
    case matrix |> Enum.map(&length/1) |> Enum.uniq() do
      [_] -> matrix
      _ -> raise ArgumentError, "matrix columns must be equal\n#{inspect(matrix)}"
    end
  end

  @spec validate_dimensions!(matrix(), [pos_integer()], [pos_integer()]) :: :ok
  defp validate_dimensions!(matrix, row_pins, col_pins) do
    row_count = length(matrix)
    col_count = matrix |> List.first() |> length()

    if row_count != length(row_pins),
      do:
        raise(
          ArgumentError,
          "expected #{row_count} row pins but only #{length(row_pins)} were given"
        )

    if col_count != length(col_pins),
      do:
        raise(
          ArgumentError,
          "expected #{col_count} column pins but only #{length(col_pins)} were given"
        )

    :ok
  end

  @spec matrix_for_size(size() | nil) :: matrix()
  defp matrix_for_size(:four_by_four), do: matrix_for_size("4x4")
  defp matrix_for_size(:four_by_three), do: matrix_for_size("4x3")
  defp matrix_for_size(:one_by_four), do: matrix_for_size("1x4")
  defp matrix_for_size("4x4"), do: @matrix_4x4
  defp matrix_for_size("4x3"), do: @matrix_4x3
  defp matrix_for_size("1x4"), do: @matrix_1x4
  defp matrix_for_size(nil), do: raise(ArgumentError, "must provide a keypad size or matrix")

  defp matrix_for_size(size),
    do: raise(ArgumentError, "unsupported matrix size: #{inspect(size)}")
end

defmodule Ytm.CardButton.Server do
  @moduledoc """
  Watches one GPIO wired to a pull-up push button that closes to ground when
  a card is inserted into the NFC reader on `bus_name`, and broadcasts, over
  `Ytm.PubSub` on `#{inspect(__MODULE__)}.topic/0`, a `{:card_button_pressed,
  bus_name}` message for each falling edge and a `{:card_button_released,
  bus_name}` message for each rising edge, both debounced. The current level
  can also be queried with `pressed?/1`, e.g. to initialise a view on mount.

  Reconnection is always-on and has no manual override, mirroring
  `Ytm.PN532.Server`: a GPIO that fails to open (or a bus error) is retried on
  `@retry_interval_ms` forever.
  """

  use GenServer

  alias Circuits.GPIO

  require Logger

  @retry_interval_ms 5_000
  @debounce_ms 200
  @topic "nfc:card_button"

  @type status :: :connected | :disconnected

  @type t :: %__MODULE__{
          pin: non_neg_integer(),
          bus_name: String.t(),
          gpio: GPIO.Handle.t() | nil,
          status: status(),
          error: term(),
          pressed: boolean(),
          last_pressed_at: integer() | nil,
          last_released_at: integer() | nil
        }

  @enforce_keys [:pin, :bus_name]
  defstruct pin: nil,
            bus_name: nil,
            gpio: nil,
            status: :disconnected,
            error: nil,
            pressed: false,
            last_pressed_at: nil,
            last_released_at: nil

  @spec start_link({non_neg_integer(), String.t()}) :: GenServer.on_start()
  def start_link({pin, bus_name}) do
    GenServer.start_link(__MODULE__, {pin, bus_name}, name: via(bus_name))
  end

  @doc """
  Whether the button for `bus_name` is currently held down (card inserted).
  Returns `false` if no button is configured for that bus or its GPIO isn't
  open, since an unreadable button can't report a card.
  """
  @spec pressed?(String.t()) :: boolean()
  def pressed?(bus_name) do
    case Registry.lookup(Ytm.CardButton.Registry, bus_name) do
      [{pid, _value}] -> GenServer.call(pid, :pressed?)
      [] -> false
    end
  end

  defp via(bus_name), do: {:via, Registry, {Ytm.CardButton.Registry, bus_name}}

  @doc """
  PubSub topic broadcasting `{:card_button_pressed, bus_name}` and
  `{:card_button_released, bus_name}` for every configured button.
  """
  @spec topic() :: String.t()
  def topic(), do: @topic

  @impl GenServer
  def init({pin, bus_name}) do
    Logger.metadata(card_button_pin: pin, card_button_bus: bus_name)
    {:ok, %__MODULE__{pin: pin, bus_name: bus_name}, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state), do: {:noreply, attempt_connect(state)}

  @impl GenServer
  def handle_call(:pressed?, _from, state) do
    {:reply, state.status == :connected and state.pressed, state}
  end

  @impl GenServer
  def handle_info(:retry_connect, state), do: {:noreply, attempt_connect(state)}

  def handle_info(
        {:circuits_gpio, %{ref: bus_name, value: 0}},
        %__MODULE__{bus_name: bus_name} = state
      ) do
    {:noreply, maybe_broadcast_press(%{state | pressed: true})}
  end

  def handle_info(
        {:circuits_gpio, %{ref: bus_name, value: 1}},
        %__MODULE__{bus_name: bus_name} = state
      ) do
    {:noreply, maybe_broadcast_release(%{state | pressed: false})}
  end

  def handle_info({:circuits_gpio, %{}}, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if state.gpio, do: GPIO.close(state.gpio)
    :ok
  end

  defp attempt_connect(state) do
    case open_and_subscribe(state.pin, state.bus_name) do
      {:ok, gpio} ->
        Logger.info("connected")
        # Pull-up: the button reads 0 while held closed to ground.
        %{state | gpio: gpio, status: :connected, error: nil, pressed: GPIO.read(gpio) == 0}

      {:error, reason} ->
        if state.status == :connected do
          Logger.warning("lost connection: #{inspect(reason)}")
        end

        Process.send_after(self(), :retry_connect, @retry_interval_ms)
        %{state | gpio: nil, status: :disconnected, error: reason}
    end
  end

  defp open_and_subscribe(pin, bus_name) do
    with {:ok, gpio} <- GPIO.open(pin, :input, pull_mode: :pullup),
         {:ok, _ref} <- GPIO.subscribe(gpio, trigger: :both, tag: bus_name) do
      {:ok, gpio}
    else
      {:error, reason} = error ->
        Logger.error("failed to arm button: #{inspect(reason)}")
        error
    end
  end

  defp maybe_broadcast_press(state) do
    now = System.monotonic_time(:millisecond)

    if state.last_pressed_at == nil or now - state.last_pressed_at >= @debounce_ms do
      Logger.info("pressed")
      Phoenix.PubSub.broadcast(Ytm.PubSub, @topic, {:card_button_pressed, state.bus_name})
      %{state | last_pressed_at: now}
    else
      state
    end
  end

  defp maybe_broadcast_release(state) do
    now = System.monotonic_time(:millisecond)

    if state.last_released_at == nil or now - state.last_released_at >= @debounce_ms do
      Logger.info("released")
      Phoenix.PubSub.broadcast(Ytm.PubSub, @topic, {:card_button_released, state.bus_name})
      %{state | last_released_at: now}
    else
      state
    end
  end
end

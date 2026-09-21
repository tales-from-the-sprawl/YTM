defmodule Ytm.PN532.Server do
  @moduledoc """
  Owns one PN532's SPI connection on behalf of all callers, so processes
  share a connection instead of each opening its own raw SPI handle, and
  reconnects automatically after failures or crashes instead of leaving a
  stale handle that blocks every future `Ytm.PN532.open/2` on that bus.

  Request/response only: this process does not poll for tags itself, it
  just serializes access to the bus and keeps the connection alive.
  Reconnection is always-on and has no manual override — a bus that goes
  away (unplugged, or a crash) is retried on `@retry_interval_ms` forever.
  """

  use GenServer

  alias Ytm.PN532

  require Logger

  @retry_interval_ms 5_000
  @call_timeout 10_000
  @status_call_timeout 5_000

  @type status :: :connected | :disconnected

  @type t :: %__MODULE__{
          bus_name: String.t(),
          pn532: PN532.t() | nil,
          status: status(),
          error: term(),
          firmware_version: {byte(), byte(), byte(), byte()} | nil
        }

  @enforce_keys [:bus_name]
  defstruct bus_name: nil,
            pn532: nil,
            status: :disconnected,
            error: nil,
            firmware_version: nil

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(bus_name) when is_binary(bus_name) do
    GenServer.start_link(__MODULE__, bus_name, name: via(bus_name))
  end

  @doc "Current connection status, cached firmware version, and last error (if any)."
  @spec status(String.t()) ::
          {status(), firmware_version :: {byte(), byte(), byte(), byte()} | nil, error :: term()}
          | {:error, :not_started}
  def status(bus_name), do: call(bus_name, :status, @status_call_timeout)

  @doc "Waits for a passive target and reads its NDEF message, mirroring the driver's own composition."
  @spec scan(String.t()) ::
          {:ok, {uid :: binary(), sak :: byte(), ndef :: {:ok, binary()} | {:error, term()}}}
          | {:error, :not_connected | :not_started | term()}
  def scan(bus_name), do: call(bus_name, :scan, @call_timeout)

  @spec write_ndef(String.t(), binary(), byte(), binary()) ::
          :ok | {:error, :not_connected | :not_started | term()}
  def write_ndef(bus_name, uid, sak, message) do
    call(bus_name, {:write_ndef, uid, sak, message}, @call_timeout)
  end

  defp call(bus_name, message, timeout) do
    case Registry.lookup(Ytm.PN532.Registry, bus_name) do
      [{pid, _value}] -> GenServer.call(pid, message, timeout)
      [] -> {:error, :not_started}
    end
  end

  defp via(bus_name), do: {:via, Registry, {Ytm.PN532.Registry, bus_name}}

  @impl GenServer
  def init(bus_name) do
    Logger.metadata(pn532_bus: bus_name)
    {:ok, %__MODULE__{bus_name: bus_name}, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state), do: {:noreply, attempt_connect(state)}

  @impl GenServer
  def handle_info(:retry_connect, state), do: {:noreply, attempt_connect(state)}

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, {state.status, state.firmware_version, state.error}, state}
  end

  def handle_call(_message, _from, %__MODULE__{status: :disconnected} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:scan, _from, state) do
    result =
      with {:ok, {uid, sak}} <- PN532.read_passive_target(state.pn532) do
        {:ok, {uid, sak, PN532.read_ndef(state.pn532, uid, sak)}}
      end

    {:reply, result, state}
  end

  def handle_call({:write_ndef, uid, sak, message}, _from, state) do
    {:reply, PN532.write_ndef(state.pn532, uid, sak, message), state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.pn532, do: PN532.close(state.pn532)
    :ok
  end

  defp attempt_connect(state) do
    case PN532.open(state.bus_name) do
      {:ok, pn532} ->
        Logger.info("connected")

        firmware_version =
          case PN532.firmware_version(pn532) do
            {:ok, version} -> version
            {:error, _reason} -> nil
          end

        %{
          state
          | pn532: pn532,
            status: :connected,
            error: nil,
            firmware_version: firmware_version
        }

      {:error, reason} ->
        if state.status == :connected do
          Logger.warning("lost connection: #{inspect(reason)}")
        end

        Process.send_after(self(), :retry_connect, @retry_interval_ms)
        %{state | pn532: nil, status: :disconnected, error: reason, firmware_version: nil}
    end
  end
end

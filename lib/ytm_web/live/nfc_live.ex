defmodule YtmWeb.NFCLive do
  @moduledoc """
  Debug page for the PN532 NFC readers, connected via SPI0 (`spidev0.0` and
  `spidev0.1`, i.e. both chip-selects on the bus).

  Talks to `Ytm.PN532.Server`, a supervised connection per bus that's
  shared with any other process and reconnects automatically after
  failures or crashes - this LiveView never opens/closes a bus itself.
  """

  use YtmWeb, :live_view

  alias Ytm.NDEF
  alias Ytm.PN532.Server, as: PN532Server

  @bus_names ["spidev0.0", "spidev0.1"]

  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col bg-base-200">
      <div class="bg-base-100 border-b border-base-300 px-4 py-3 flex items-center gap-3 shadow-sm">
        <a href="/" class="btn btn-sm btn-primary gap-2">
          <.icon name="hero-home" class="size-4" /> Home
        </a>
        <span class="text-lg font-semibold">PN532 NFC Debug</span>
      </div>

      <div class="px-4 py-6 overflow-auto">
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <div :for={bus_name <- @bus_names} class="card bg-base-100 border border-base-300 shadow-md">
            <div class="card-body">
              <div class="flex items-center justify-between">
                <h2 class="card-title font-mono">{bus_name}</h2>
                <.bus_status_badge bus={@buses[bus_name]} />
              </div>

              <% bus = @buses[bus_name] %>

              <div :if={bus.status == :error} class="alert alert-error text-sm">
                <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
                <span>{inspect(bus.error)}</span>
              </div>

              <div class="card-actions mt-2">
                <button
                  :if={bus.status == :open}
                  phx-click="scan"
                  phx-value-bus={bus_name}
                  class="btn btn-sm btn-secondary"
                >
                  <.icon name="hero-credit-card" class="size-4" /> Scan for Card
                </button>
              </div>

              <div :if={bus.firmware_version} class="text-xs opacity-70 font-mono mt-2">
                Firmware: {inspect(bus.firmware_version)}
              </div>

              <div :if={bus.scan} class="mt-4 bg-base-200 rounded-lg p-3 text-sm space-y-2">
                <.scan_result scan={bus.scan} />
              </div>

              <form
                :if={match?({:ok, _uid, _sak, _ndef}, bus.scan)}
                phx-submit="write"
                phx-value-bus={bus_name}
                class="mt-4 flex gap-2"
              >
                <input
                  type="text"
                  name="text"
                  placeholder="Text to write"
                  class="input input-sm input-bordered flex-1"
                  required
                />
                <button type="submit" class="btn btn-sm btn-accent">
                  <.icon name="hero-pencil-square" class="size-4" /> Write
                </button>
              </form>

              <div :if={bus.write_result} class="mt-2 text-sm">
                <.write_result result={bus.write_result} />
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp bus_status_badge(%{bus: %{status: :closed}} = assigns) do
    ~H"""
    <span class="badge badge-ghost">Not connected</span>
    """
  end

  defp bus_status_badge(%{bus: %{status: :open}} = assigns) do
    ~H"""
    <span class="badge badge-success">Connected</span>
    """
  end

  defp bus_status_badge(%{bus: %{status: :error}} = assigns) do
    ~H"""
    <span class="badge badge-error">Error</span>
    """
  end

  defp scan_result(%{scan: {:error, reason}} = assigns) do
    assigns = assign(assigns, :reason, reason)

    ~H"""
    <p class="text-error font-mono text-xs">No card: {inspect(@reason)}</p>
    """
  end

  defp scan_result(%{scan: {:ok, uid, sak, ndef}} = assigns) do
    assigns =
      assign(assigns,
        uid: Base.encode16(uid),
        sak: Integer.to_string(sak, 16),
        ndef_lines: describe_ndef(ndef)
      )

    ~H"""
    <p><span class="font-semibold">UID:</span> <span class="font-mono">{@uid}</span></p>
    <p><span class="font-semibold">SAK:</span> <span class="font-mono">0x{@sak}</span></p>
    <div class="border-t border-base-300 pt-2">
      <p class="font-semibold mb-1">NDEF</p>
      <p :for={line <- @ndef_lines} class="font-mono text-xs">{line}</p>
    </div>
    """
  end

  defp write_result(%{result: :ok} = assigns) do
    ~H"""
    <p class="text-success font-mono text-xs">Write succeeded.</p>
    """
  end

  defp write_result(%{result: {:error, reason}} = assigns) do
    assigns = assign(assigns, :reason, reason)

    ~H"""
    <p class="text-error font-mono text-xs">Write failed: {inspect(@reason)}</p>
    """
  end

  def mount(_params, _session, socket) do
    buses = Map.new(@bus_names, &{&1, bus_from_status(PN532Server.status(&1))})
    {:ok, assign(socket, buses: buses, bus_names: @bus_names)}
  end

  def handle_event("scan", %{"bus" => bus_name}, socket) do
    {:noreply, update_bus(socket, bus_name, &scan_bus(bus_name, &1))}
  end

  def handle_event("write", %{"bus" => bus_name, "text" => text}, socket) do
    {:noreply, update_bus(socket, bus_name, &write_bus(bus_name, &1, text))}
  end

  def handle_event("myelin:" <> _event, _params, socket) do
    {:noreply, socket}
  end

  defp bus_from_status({:connected, firmware_version, _error}) do
    %{status: :open, error: nil, firmware_version: firmware_version, scan: nil, write_result: nil}
  end

  defp bus_from_status({:disconnected, _firmware_version, nil}) do
    %{status: :closed, error: nil, firmware_version: nil, scan: nil, write_result: nil}
  end

  defp bus_from_status({:disconnected, _firmware_version, reason}) do
    %{status: :error, error: reason, firmware_version: nil, scan: nil, write_result: nil}
  end

  defp bus_from_status({:error, :not_started}) do
    %{status: :closed, error: nil, firmware_version: nil, scan: nil, write_result: nil}
  end

  defp update_bus(socket, bus_name, fun) do
    assign(socket, :buses, Map.update!(socket.assigns.buses, bus_name, fun))
  end

  defp scan_bus(bus_name, %{status: :open} = bus) do
    scan =
      case PN532Server.scan(bus_name) do
        {:ok, {uid, sak, ndef}} -> {:ok, uid, sak, ndef}
        {:error, reason} -> {:error, reason}
      end

    %{bus | scan: scan, write_result: nil}
  end

  defp scan_bus(_bus_name, bus), do: bus

  defp write_bus(bus_name, %{status: :open, scan: {:ok, uid, sak, _ndef}} = bus, text) do
    message = text |> NDEF.encode_text() |> List.wrap() |> NDEF.encode_records()
    %{bus | write_result: PN532Server.write_ndef(bus_name, uid, sak, message)}
  end

  defp write_bus(_bus_name, bus, _text), do: bus

  defp describe_ndef({:error, reason}), do: ["Failed to read NDEF message: #{inspect(reason)}"]

  defp describe_ndef({:ok, message}) do
    case NDEF.decode_records(message) do
      {:ok, records} -> Enum.map(records, &describe_record/1)
      {:error, reason} -> ["Failed to parse records: #{inspect(reason)}"]
    end
  end

  defp describe_record(%NDEF.Record{tnf: :well_known, type: "T"} = record) do
    case NDEF.decode_text(record) do
      {:ok, {language, text}} -> "Text (#{language}): #{text}"
      {:error, _reason} -> "Text record (unparseable payload)"
    end
  end

  defp describe_record(%NDEF.Record{tnf: :well_known, type: "U"} = record) do
    case NDEF.decode_uri(record) do
      {:ok, uri} -> "URI: #{uri}"
      {:error, _reason} -> "URI record (unparseable payload)"
    end
  end

  defp describe_record(%NDEF.Record{} = record) do
    "#{record.tnf}/#{inspect(record.type)}: #{byte_size(record.payload)} byte payload"
  end
end

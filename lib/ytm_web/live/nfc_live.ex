defmodule YtmWeb.NFCLive do
  @moduledoc """
  Debug page for the PN532 NFC reader (connected via SPI0).

  Exercises `PN532.Client` directly: firmware/status queries, target
  detection start/stop, and a live view of currently/last detected cards.
  Only meaningful on target - the PN532 client is not started on `:host`.
  """

  use YtmWeb, :live_view

  @poll_interval 1000

  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col bg-base-200">
      <div class="bg-base-100 border-b border-base-300 px-4 py-3 flex items-center gap-3 shadow-sm">
        <a href="/" class="btn btn-sm btn-primary gap-2">
          <.icon name="hero-home" class="size-4" /> Home
        </a>
        <span class="text-lg font-semibold">PN532 NFC Debug</span>
      </div>

      <div class="px-4 py-6 overflow-auto space-y-6">
        <%= if not @available do %>
          <div class="alert alert-warning">
            <div class="flex items-start gap-3">
              <.icon
                name="hero-exclamation-triangle"
                class="size-5 mt-0.5 flex-shrink-0"
              />
              <div class="text-sm">
                <p class="font-semibold mb-1">PN532 client is not running</p>
                <p>
                  The PN532 client only starts on the `:rpi4` target. On `:host` there is no SPI
                  bus to talk to, so this page has nothing to exercise.
                </p>
              </div>
            </div>
          </div>
        <% else %>
          <div class="alert alert-info">
            <div class="flex items-start gap-3">
              <.icon name="hero-information-circle" class="size-5 mt-0.5 flex-shrink-0" />
              <div class="text-sm">
                <p class="font-semibold mb-1">NFC Debug Panel</p>
                <p>
                  Talks directly to <code>PN532.Client</code>, connected over SPI0. Use the
                  buttons below to query the reader and toggle target detection.
                </p>
              </div>
            </div>
          </div>

          <div class="bg-base-100 border border-base-300 rounded-box p-4">
            <h2 class="text-lg font-bold mb-4">
              <.icon name="hero-wrench-screwdriver" class="size-5 inline" /> Diagnostics
            </h2>

            <div class="flex flex-wrap gap-3 mb-4">
              <button
                phx-click="get_firmware_version"
                class="btn btn-primary"
              >
                Get Firmware Version
              </button>
              <button
                phx-click="get_general_status"
                class="btn btn-primary"
              >
                Get General Status
              </button>
              <button
                phx-click={if @detecting, do: "stop_detection", else: "start_detection"}
                class="btn btn-success aria-pressed:btn-error"
                aria-pressed={"#{@detecting}"}
              >
                {if @detecting, do: "Stop Target Detection", else: "Start Target Detection"}
              </button>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div class="bg-base-200 border border-base-300 rounded-box p-4">
                <p class="text-sm font-semibold mb-2">Firmware Version</p>
                <pre class="text-xs font-mono whitespace-pre-wrap">{inspect(@firmware_version, pretty: true)}</pre>
              </div>
              <div class="bg-base-200 border border-base-300 rounded-box p-4">
                <p class="text-sm font-semibold mb-2">General Status</p>
                <pre class="text-xs font-mono whitespace-pre-wrap">{inspect(@general_status, pretty: true)}</pre>
              </div>
            </div>
          </div>

          <div class="bg-base-100 border border-base-300 rounded-box p-4">
            <h2 class="text-lg font-bold mb-4">
              <.icon name="hero-credit-card" class="size-5 inline" />
              Target Detection {if @detecting, do: "(active)", else: "(stopped)"}
            </h2>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div class="bg-base-200 border border-base-300 rounded-box p-4">
                <p class="text-sm font-semibold mb-2">Current Cards</p>
                <%= if @current_cards in [nil, []] do %>
                  <p class="text-sm italic">None</p>
                <% else %>
                  <div class="space-y-2">
                    <%= for card <- @current_cards do %>
                      <div class="text-xs font-mono bg-white border border-base-300 rounded-field p-2">
                        {format_card(card)}
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
              <div class="bg-base-200 border border-base-300 rounded-box p-4">
                <p class="text-sm font-semibold mb-2">Detected Cards</p>
                <%= if @detected_cards in [nil, []] do %>
                  <p class="text-sm italic">None</p>
                <% else %>
                  <div class="space-y-2">
                    <%= for card <- @detected_cards do %>
                      <div class="text-xs font-mono bg-white border border-base-300 rounded-field p-2">
                        {format_card(card)}
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    available = client_available?()

    if connected?(socket) and available do
      _ = Process.send_after(self(), :poll_cards, @poll_interval)
      :ok
    end

    {:ok,
     assign(socket,
       available: available,
       detecting: false,
       firmware_version: nil,
       general_status: nil,
       current_cards: nil,
       detected_cards: nil
     )}
  end

  def handle_event("get_firmware_version", _params, socket) do
    {:noreply, assign(socket, :firmware_version, PN532.Client.get_firmware_version())}
  end

  def handle_event("get_general_status", _params, socket) do
    {:noreply, assign(socket, :general_status, PN532.Client.get_general_status())}
  end

  def handle_event("start_detection", _params, socket) do
    :ok = PN532.Client.start_target_detection()
    {:noreply, assign(socket, :detecting, true)}
  end

  def handle_event("stop_detection", _params, socket) do
    :ok = PN532.Client.stop_target_detection()
    {:noreply, assign(socket, detecting: false, current_cards: nil, detected_cards: nil)}
  end

  def handle_event("myelin:" <> _event, _params, socket) do
    {:noreply, socket}
  end

  def handle_info(:poll_cards, socket) do
    Process.send_after(self(), :poll_cards, @poll_interval)

    socket =
      with true <- socket.assigns.available,
           {:ok, current_cards} <- PN532.Client.get_current_cards(),
           {:ok, detected_cards} <- PN532.Client.get_detected_cards() do
        assign(socket, current_cards: current_cards, detected_cards: detected_cards)
      else
        _ -> socket
      end

    {:noreply, socket}
  end

  defp client_available?() do
    Process.whereis(PN532.Client) != nil
  end

  defp format_card(card) when is_map(card) do
    card
    |> Enum.map(fn
      {key, value} when is_binary(value) -> "#{key}: #{Base.encode16(value)}"
      {key, value} -> "#{key}: #{inspect(value)}"
    end)
    |> Enum.join(", ")
  end

  defp format_card(other), do: inspect(other)
end

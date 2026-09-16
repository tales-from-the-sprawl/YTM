defmodule YtmWeb.NFCLive do
  @moduledoc """
  Debug page for the PN532 NFC reader (connected via SPI0).

  Disabled for now: the previous `PN532.Client` GenStateMachine backend this
  page talked to has been replaced by `Ytm.PN532`, a stateless driver module
  with no supervised connection/detection process yet. Rebuild this page
  once such a process exists.
  """

  use YtmWeb, :live_view

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
        <div class="alert alert-warning">
          <div class="flex items-start gap-3">
            <.icon name="hero-exclamation-triangle" class="size-5 mt-0.5 flex-shrink-0" />
            <div class="text-sm">
              <p class="font-semibold mb-1">PN532 debug panel unavailable</p>
              <p>
                This page is disabled while the PN532 driver is being rebuilt as <code>Ytm.PN532</code>. It will come back once a supervised connection is in place.
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  def handle_event("myelin:" <> _event, _params, socket) do
    {:noreply, socket}
  end
end

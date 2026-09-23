defmodule YtmWeb.TransferLive do
  use YtmWeb, :live_view
  alias Ytm.CardButton.Server, as: CardButtonServer

  def render(assigns) do
    ~H"""
    <main class="grid place-content-center h-screen">
      <div class="flex flex-col gap-10">
        <div>
          <p class="text-2xl font-mono text-center">Transfer Funds</p>
          <p class="text-lg font-mono text-center">Check Balance [B]</p>
        </div>

        <div class="flex flex-col min-w-xl">
          <div class="aura aura-glow">
            <input
              type="text"
              placeholder="No refunds"
              class="input input-xl w-full text-center font-mono"
            />
          </div>

          <div :if={@success} class="aura aura-glow text-success">
            <p class="text-lg font-mono text-center bg-base-100 rounded-box px-1.5">
              Transfer Successful
            </p>
          </div>

          <div :if={@error} class="aura aura-glow text-error">
            <p class="text-lg font-mono text-center bg-base-100 rounded-box px-1.5">
              ERROR: {@error}
            </p>
          </div>

          <div :if={false} class="aura aura-glow text-error">
            <p class="text-lg font-mono text-center bg-base-100 rounded-box px-1.5">
              ERROR: Left Transfer Slot Empty
            </p>
          </div>
          <div :if={false} class="aura aura-glow text-error">
            <p class="text-lg font-mono text-center bg-base-100 rounded-box px-1.5">
              ERROR: Transfer Failed
            </p>
          </div>
        </div>
      </div>

      <.cred_stick class="left-32" active={@left} glow={false} />

      <.sin_card class="right-32" active={@right} glow={false} />
    </main>
    """
  end

  attr :class, :string, default: nil
  attr :glow, :boolean, default: false
  attr :active, :boolean, default: false

  defp cred_stick(assigns) do
    ~H"""
    <div class={["absolute bottom-0 pb-0", if(@glow, do: "aura aura-gold"), @class]}>
      <div class="bg-base-100">
        <div class={[
          "h-32 w-16 border-4 border-b-0",
          if(@active,
            do: "bg-yellow-500 border-yellow-600 border-solid",
            else: "bg-base-100 border-yellow-500 border-dashed"
          )
        ]}>
        </div>
      </div>
    </div>
    """
  end

  attr :class, :string, default: nil
  attr :glow, :boolean, default: false
  attr :active, :boolean, default: false

  defp sin_card(assigns) do
    ~H"""
    <div class={["absolute bottom-0 pb-0", if(@glow, do: "aura aura-silver"), @class]}>
      <div class={[
        "h-24 w-24 border-4 border-b-0",
        if(@active,
          do: "bg-slate-100 border-slate-400 border-solid",
          else: "bg-base-100 border-slate-100 border-dashed"
        )
      ]}>
      </div>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Ytm.PubSub, CardButtonServer.topic())
    end

    socket =
      socket
      |> assign(left: false, right: false, success: false, error: false)

    {:ok, socket}
  end

  def handle_info({:card_button_pressed, bus_name}, socket) do
    {:noreply, assign(socket, bus_side(bus_name), true)}
  end

  def handle_info({:card_button_released, bus_name}, socket) do
    {:noreply, assign(socket, bus_side(bus_name), false)}
  end

  defp bus_side(bus_name) do
    case bus_name do
      "spidev0.0" -> :right
      "spidev0.1" -> :left
    end
  end

  def handle_event("myelin:" <> _event, _params, socket) do
    {:noreply, socket}
  end
end

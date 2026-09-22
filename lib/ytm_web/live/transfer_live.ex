defmodule YtmWeb.TransferLive do
  use YtmWeb, :live_view
  alias Ytm.CardButton.Server, as: CardButtonServer

  def render(assigns) do
    ~H"""
    <main class="h-screen">
      <p class="text-6xl font-mono text-center mt-64">Transfer funds</p>

      <.cred_stick class="left-48" active={@left} />

      <.sin_card class="right-48" active={@right} />
    </main>
    """
  end

  defp cred_stick(assigns) do
    ~H"""
    <div class={[
      "absolute bottom-0 h-116 w-48 border-8 border-b-0 p-2 pb-0",
      if(@active,
        do: "bg-yellow-500 border-yellow-600 border-solid",
        else: "border-yellow-500 border-dashed"
      ),
      @class
    ]}>
    </div>
    """
  end

  defp sin_card(assigns) do
    ~H"""
    <div class={[
      "absolute bottom-0 h-96 w-96 border-8 border-b-0 p-2 pb-0",
      if(@active,
        do: "bg-slate-100 border-slate-400 border-solid",
        else: "border-slate-100 border-dashed"
      ),
      @class
    ]}>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Ytm.PubSub, CardButtonServer.topic())
    end

    socket =
      socket
      |> assign(left: false, right: false)

    {:ok, socket}
  end

  def handle_info({:card_button_pressed, bus_name}, socket) do
    side =
      case bus_name do
        "spidev0.0" -> :left
        "spidev0.1" -> :right
      end

    {:noreply, assign(socket, side, true)}
  end

  def handle_event("myelin:" <> _event, _params, socket) do
    {:noreply, socket}
  end
end

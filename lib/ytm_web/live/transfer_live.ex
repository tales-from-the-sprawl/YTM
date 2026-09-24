defmodule YtmWeb.TransferLive do
  use YtmWeb, :live_view
  alias Ytm.CardButton.Server, as: CardButtonServer
  alias Ytm.Finance
  alias Ytm.PN532.Server, as: PN532Server
  require Logger

  @bus_names ["spidev0.0", "spidev0.1"]
  @read_attempts 8
  @read_retry_interval_ms 500

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
              inputmode="none"
              readonly
              value={@amount}
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

      <.card_slot class="left-32" active={@left} card={@left_card} default={:unknown} />

      <.card_slot class="right-32" active={@right} card={@right_card} default={:unknown} />
    </main>
    """
  end

  attr :class, :string, default: nil
  attr :active, :boolean, default: false

  attr :card, :any,
    default: nil,
    doc:
      "the parsed `Ytm.Finance.card/0`, or the read status: `:reading`, `:not_found` " <>
        "(no tag detected), `:unknown` (tag detected but not recognised) or `nil` if unread"

  attr :default, :atom,
    values: [:unknown, :cred, :sin],
    doc: "shape to show until a card has been read"

  # Shows the slot's card as whichever type was actually read from it, falling
  # back to the slot's default shape while empty, still being read, or unrecognised.
  defp card_slot(assigns) do
    assigns = assign(assigns, :type, card_type(assigns.card, assigns.default))

    ~H"""
    <.prompt :if={@type == :unknown} class={@class} active={@active} status={@card} />
    <.cred_stick :if={@type == :cred} class={@class} active={@active} />
    <.sin_card :if={@type == :sin} class={@class} active={@active} />
    """
  end

  defp card_type({type, _value}, _default), do: type
  defp card_type(_card, default), do: default

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

  attr :class, :string, default: nil
  attr :active, :boolean, default: false
  attr :status, :atom, values: [nil, :reading, :not_found, :unknown], default: nil

  defp prompt(assigns) do
    ~H"""
    <div class={["absolute bottom-4 pb-0", @class]}>
      <div :if={not @active} class="flex flex-col gap-4 items-center">
        <span>Insert card</span>
        <.icon
          name="hero-chevron-double-down"
          class="size-14 animate-[bounce_1.5s_infinite]"
        />
      </div>
      <div :if={@active and @status in [nil, :reading]} class="flex flex-col gap-4 items-center">
        <span>Reading card</span>
        <.icon name="hero-arrow-path" class="size-14 animate-spin" />
      </div>
      <div :if={@active and @status == :not_found} class="flex flex-col gap-4 items-center text-error">
        <span>No card found</span>
        <.icon name="hero-x-circle" class="size-14" />
      </div>
      <div :if={@active and @status == :unknown} class="flex flex-col gap-4 items-center text-warning">
        <span>Unknown card</span>
        <.icon name="hero-exclamation-triangle" class="size-14" />
      </div>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Ytm.PubSub, CardButtonServer.topic())
      Phoenix.PubSub.subscribe(Ytm.PubSub, Ytm.Keypad.topic())
    end

    # Read after subscribing so an edge in between isn't missed.
    socket =
      socket
      |> assign(
        left: CardButtonServer.pressed?("spidev0.1"),
        right: CardButtonServer.pressed?("spidev0.0"),
        left_card: nil,
        right_card: nil,
        success: false,
        error: false,
        amount: ""
      )

    socket =
      if connected?(socket) do
        Enum.reduce(@bus_names, socket, fn bus_name, socket ->
          if socket.assigns[bus_side(bus_name)], do: start_read(socket, bus_name), else: socket
        end)
      else
        socket
      end

    {:ok, socket}
  end

  def handle_info({:card_button_pressed, bus_name}, socket) do
    socket =
      socket
      |> assign(bus_side(bus_name), true)
      |> start_read(bus_name)

    {:noreply, socket}
  end

  def handle_info({:card_button_released, bus_name}, socket) do
    side = bus_side(bus_name)

    socket =
      socket
      |> cancel_async({:read_card, bus_name})
      |> assign([{side, false}, {card_assign(side), nil}])

    {:noreply, socket}
  end

  def handle_info({:keypad, key}, socket) do
    {:noreply, update(socket, :amount, &keypad_input(&1, key))}
  end

  # Digits append, `*` deletes the last character, `C` clears; other keys are ignored.
  defp keypad_input(amount, key) when key in ~w(0 1 2 3 4 5 6 7 8 9), do: amount <> key
  defp keypad_input(amount, "*"), do: String.slice(amount, 0..-2//1)
  defp keypad_input(_amount, "C"), do: ""
  defp keypad_input(amount, _key), do: amount

  def handle_async({:read_card, bus_name}, {:ok, card}, socket) do
    {:noreply, assign(socket, card_assign(bus_side(bus_name)), card)}
  end

  def handle_async({:read_card, bus_name}, {:exit, _reason}, socket) do
    card_assign = card_assign(bus_side(bus_name))

    # Only a read still in flight failed; a cancelled one was already reset.
    socket =
      if socket.assigns[card_assign] == :reading,
        do: assign(socket, card_assign, :not_found),
        else: socket

    {:noreply, socket}
  end

  # Reads the card off the bus in the background so a slow scan doesn't stall
  # keypad input. Restarting an in-flight read replaces it.
  defp start_read(socket, bus_name) do
    socket
    |> assign(card_assign(bus_side(bus_name)), :reading)
    |> start_async({:read_card, bus_name}, fn -> read_card(bus_name, @read_attempts) end)
  end

  # The button closes slightly before the card is seated over the antenna, so
  # retry a few times before giving up. Gives up with `:not_found` if the last
  # attempt detected no tag at all, or `:unknown` if it found one it couldn't decode.
  defp read_card(bus_name, attempts_left) do
    result =
      with {:ok, {_uid, _sak, ndef}} <- PN532Server.scan(bus_name) do
        case Finance.decode_card(ndef) do
          {:ok, card} ->
            card

          {:error, reason} ->
            Logger.warning("Card decode failed: #{inspect(reason)}")
            :unknown
        end
      else
        error ->
          Logger.warning("No card found: #{inspect(error)}")
          :not_found
      end

    if result in [:not_found, :unknown] and attempts_left > 1 do
      Process.sleep(@read_retry_interval_ms)
      read_card(bus_name, attempts_left - 1)
    else
      result
    end
  end

  defp card_assign(:left), do: :left_card
  defp card_assign(:right), do: :right_card

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

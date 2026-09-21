defmodule Ytm.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    setup_wifi()

    children =
      [
        # Children for all targets
        Ytm.PN532.Supervisor
      ] ++ phoenix_children() ++ children()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Ytm.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # List all child processes to be supervised
  if Mix.target() == :host do
    defp children() do
      [
        # Children that only run on the host
        # Starts a worker by calling: Ytm.Worker.start_link(arg)
        # {Ytm.Worker, arg},
      ]
    end
  else
    defp children() do
      # NOTE: work around to stop watchers on targets
      Application.get_env(:ytm, YtmWeb.Endpoint)
      |> Keyword.put(:watchers, [])
      |> then(&Application.put_env(:ytm, YtmWeb.Endpoint, &1))

      [
        # Children for all targets except host
        # Starts a worker by calling: Ytm.Worker.start_link(arg)
        # {Ytm.Worker, arg},
        {Ytm.UdevdServer, []},
        {Ytm.KioskSupervisor, []},
        {Task, &start_node/0}
      ]
    end

    defp start_node() do
      {_, 0} = System.cmd("epmd", ~w"-daemon")
      _ = Node.start(:"ytm@nerves.local")
      Node.set_cookie(Application.get_env(:mix_tasks_upload_hotswap, :cookie))
    end
  end

  defp phoenix_children() do
    [
      YtmWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:ytm, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Ytm.PubSub},
      # Start a worker by calling: Ytm.Worker.start_link(arg)
      # {Ytm.Worker, arg},
      # Start to serve requests, typically the last entry
      YtmWeb.Endpoint
    ]
  end

  if Mix.target() == :host do
    defp setup_wifi() do
      :ok
    end
  else
    defp setup_wifi() do
      alias Nerves.Runtime.KV
      kv = KV.get_all()

      if true?(kv["wifi_force"]) or not wlan0_configured?() do
        ssid = kv["wifi_ssid"]
        passphrase = kv["wifi_passphrase"]

        if not empty?(ssid) do
          _ = VintageNetWiFi.quick_configure(ssid, passphrase)
          :ok
        end
      end
    end

    defp wlan0_configured?() do
      VintageNet.get_configuration("wlan0") |> VintageNetWiFi.network_configured?()
    catch
      _, _ -> false
    end

    defp true?(""), do: false
    defp true?(nil), do: false
    defp true?("false"), do: false
    defp true?("FALSE"), do: false
    defp true?(_), do: true

    defp empty?(""), do: true
    defp empty?(nil), do: true
    defp empty?(_), do: false
  end
end

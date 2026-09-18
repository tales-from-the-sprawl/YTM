defmodule Ytm.KioskSupervisor do
  @moduledoc false
  use Supervisor

  @runtime_dir "/run"
  @poll_ms 500
  @max_retries 20
  @drm_sys_class_dir "/sys/class/drm"
  @drm_connector_pattern ~r/^card[0-9]+-.+$/
  @dbus_socket_path "/run/dbus-session-bus"
  @dbus_session_bus_address "unix:path=#{@dbus_socket_path}"

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl Supervisor
  def init(_args) do
    configure_dbus_session_bus()

    cog_env =
      [
        {"XDG_RUNTIME_DIR", @runtime_dir},
        {"DBUS_SESSION_BUS_ADDRESS", @dbus_session_bus_address}
      ] ++ Myelin.browser_env()

    children = [
      Supervisor.child_spec(
        {MuonTrap.Daemon,
         [
           "dbus-daemon",
           [
             "--session",
             "--address=#{@dbus_session_bus_address}",
             "--nofork",
             "--syslog-only"
           ],
           [
             stderr_to_stdout: true,
             log_output: :info,
             log_prefix: "dbus: "
           ]
         ]},
        id: :dbus
      ),
      Supervisor.child_spec(
        {MuonTrap.Daemon,
         [
           "cog",
           ["--platform=drm", "--platform-params=renderer=gles", "http://localhost:4000/"] ++
             Myelin.browser_args(),
           [
             env: cog_env,
             stderr_to_stdout: true,
             log_output: :info,
             log_prefix: "cog: ",
             wait_for: fn ->
               wait_for_path(@dbus_socket_path)
               wait_for_connected_display()
             end
           ]
         ]},
        id: :cog
      )
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # The :dbus library defaults the EXTERNAL SASL "cookie" to UID 1000; on Nerves
  # we run as root (UID 0). Also point the BEAM at the socket dbus-daemon is
  # about to serve on so :dbus clients reach the same bus as cog.
  defp configure_dbus_session_bus() do
    System.put_env("DBUS_SESSION_BUS_ADDRESS", @dbus_session_bus_address)
    Application.put_env(:dbus, :external_cookie, external_auth_cookie())
  end

  defp external_auth_cookie() do
    uid()
    |> Integer.to_string()
    |> Base.encode16(case: :lower)
  end

  defp uid() do
    with {:ok, content} <- File.read("/proc/self/status"),
         [_, uid] <- Regex.run(~r/^Uid:\s+(\d+)/m, content) do
      String.to_integer(uid)
    else
      _ -> 0
    end
  end

  defp wait_for_path(path, retries \\ @max_retries)

  defp wait_for_path(path, 0),
    do: raise(RuntimeError, "#{path} did not appear in time")

  defp wait_for_path(path, retries) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(@poll_ms)
      wait_for_path(path, retries - 1)
    end
  end

  # Waiting for a /dev/dri/cardN node to exist isn't enough: the RPi4 exposes
  # both vc4 (display) and v3d (render-only, no connectors) as separate DRM
  # devices, and vc4's connector goes through async hotplug/EDID detection
  # after its card node appears. Launching cog before a connector reports
  # "connected" makes its DRM backend init fail intermittently, so wait on
  # sysfs connector status instead.
  defp wait_for_connected_display(retries \\ @max_retries)

  defp wait_for_connected_display(0),
    do: raise(RuntimeError, "no connected DRM display appeared in time")

  defp wait_for_connected_display(retries) do
    if connected_display?() do
      :ok
    else
      Process.sleep(@poll_ms)
      wait_for_connected_display(retries - 1)
    end
  end

  defp connected_display?() do
    case File.ls(@drm_sys_class_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Regex.match?(@drm_connector_pattern, &1))
        |> Enum.any?(&connector_connected?/1)

      {:error, _} ->
        false
    end
  end

  defp connector_connected?(entry) do
    case File.read(Path.join([@drm_sys_class_dir, entry, "status"])) do
      {:ok, status} -> String.trim(status) == "connected"
      {:error, _} -> false
    end
  end
end

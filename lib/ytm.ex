defmodule Ytm do
  @moduledoc """
  Kiosk demo top-level helpers.
  """

  alias Ytm.Cog

  @doc """
  Go to the main page
  """
  @spec home() :: :ok | {:error, term()}
  def home() do
    change_url("http://localhost:4000/")
  end

  @doc """
  Go to the gpio page
  """
  @spec gpio() :: :ok | {:error, term()}
  def gpio() do
    change_url("http://localhost:4000/gpio")
  end

  @doc """
  Go to the Phoenix LiveDashboard
  """
  @spec live_dashboard() :: :ok | {:error, term()}
  def live_dashboard() do
    change_url("http://localhost:4000/dev/dashboard/home/")
  end

  @doc """
  Go to the Nerves home page
  """
  @spec nerves_project_org() :: :ok | {:error, term()}
  def nerves_project_org() do
    change_url("https://nerves-project.org/")
  end

  @doc """
  Go to the Phoenix Framework home page
  """
  @spec phoenixframework_org() :: :ok | {:error, term()}
  def phoenixframework_org() do
    change_url("https://www.phoenixframework.org/")
  end

  @doc """
  Show a jellyfish animation
  """
  @spec jellyfish() :: :ok | {:error, term()}
  def jellyfish() do
    change_url("https://akirodic.com/p/jellyfish/")
  end

  @doc """
  Change to the specified URL, showing a loading spinner during the transition.
  """
  @spec change_url(String.t()) :: :ok | {:error, term()}
  def change_url(url) when is_binary(url) do
    loading_url =
      YtmWeb.Endpoint.url() <> "/loading?" <> URI.encode_query(next: url)

    Cog.open_url(loading_url)
  end
end

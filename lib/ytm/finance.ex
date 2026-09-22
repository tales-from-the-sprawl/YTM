defmodule Ytm.Finance do
  def parse_card({_, "sin:" <> id}) do
    {:ok, {:sin, id}}
  end

  def parse_card({_, content}) do
    case Integer.parse(content) do
      :error -> {:error, "Card not recognized"}
      {val, ""} -> {:ok, {:cred, val}}
      {_, _} -> {:error, "Card not recognized"}
    end
  end

  def transfer() do
  end
end

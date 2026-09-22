defmodule Ytm.FinanceTest do
  use ExUnit.Case, async: true

  alias Ytm.Finance
  alias Ytm.NDEF

  describe "parse_card/1" do
    test "recognizes a sincard handle" do
      assert Finance.parse_card({"en", "sin:1234"}) == {:ok, {:sin, "1234"}}
    end

    test "recognizes a credstick's plain integer balance" do
      assert Finance.parse_card({"en", "500"}) == {:ok, {:cred, 500}}
    end

    test "rejects unrecognized content" do
      assert Finance.parse_card({"en", "not-a-card"}) == {:error, :card_not_recognized}
    end

    test "rejects an integer with trailing garbage" do
      assert Finance.parse_card({"en", "500abc"}) == {:error, :card_not_recognized}
    end
  end

  describe "decode_card/1" do
    test "passes a scan-level NDEF read error through unchanged" do
      assert Finance.decode_card({:error, :no_target_found}) == {:error, :no_target_found}
    end

    test "decodes a real encoded sincard message" do
      message = NDEF.encode_records([NDEF.encode_text("sin:1234")])
      assert Finance.decode_card({:ok, message}) == {:ok, {:sin, "1234"}}
    end

    test "decodes a real encoded credstick message" do
      message = NDEF.encode_records([NDEF.encode_text("500")])
      assert Finance.decode_card({:ok, message}) == {:ok, {:cred, 500}}
    end

    test "reports a message with no text record" do
      message = NDEF.encode_records([NDEF.encode_uri("https://example.com")])
      assert Finance.decode_card({:ok, message}) == {:error, :no_text_record}
    end
  end

  describe "plan_transfer/3" do
    test "sin -> sin is a single bot_transfer step" do
      assert Finance.plan_transfer({:sin, "1234"}, {:sin, "5678"}, 100) ==
               {:ok, [{:bot_transfer, "sin:1234", "sin:5678", 100}]}
    end

    test "sin -> cred destroys on the sin side and credits the credstick's new balance" do
      assert Finance.plan_transfer({:sin, "1234"}, {:cred, 500}, 100) ==
               {:ok,
                [
                  {:bot_transfer, "sin:1234", nil, 100},
                  {:write_balance, :receiver, 600, 500}
                ]}
    end

    test "cred -> sin debits the credstick then creates money on the sin side" do
      assert Finance.plan_transfer({:cred, 500}, {:sin, "5678"}, 100) ==
               {:ok,
                [
                  {:write_balance, :sender, 400, 500},
                  {:bot_transfer, nil, "sin:5678", 100}
                ]}
    end

    test "cred -> cred moves balance directly between two credsticks" do
      assert Finance.plan_transfer({:cred, 500}, {:cred, 200}, 100) ==
               {:ok,
                [
                  {:write_balance, :sender, 400, 500},
                  {:write_balance, :receiver, 300, 200}
                ]}
    end

    test "cred -> sin fails closed on insufficient funds without any steps" do
      assert Finance.plan_transfer({:cred, 50}, {:sin, "5678"}, 100) ==
               {:error, :insufficient_funds}
    end

    test "cred -> cred fails closed on insufficient funds" do
      assert Finance.plan_transfer({:cred, 50}, {:cred, 200}, 100) ==
               {:error, :insufficient_funds}
    end

    test "allows a transfer of exactly the sender's full credstick balance" do
      assert Finance.plan_transfer({:cred, 100}, {:cred, 0}, 100) ==
               {:ok,
                [
                  {:write_balance, :sender, 0, 100},
                  {:write_balance, :receiver, 100, 0}
                ]}
    end

    test "rejects a zero amount regardless of card types" do
      assert Finance.plan_transfer({:sin, "1234"}, {:sin, "5678"}, 0) == {:error, :invalid_amount}
    end

    test "rejects a negative amount" do
      assert Finance.plan_transfer({:cred, 500}, {:cred, 200}, -1) == {:error, :invalid_amount}
    end
  end
end

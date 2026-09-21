import Config

# Configure the network using vintage_net
# See https://github.com/nerves-networking/vintage_net for more information
config :vintage_net,
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth0", %{type: VintageNetEthernet, ipv4: %{method: :dhcp}}},
    {"wlan0", %{type: VintageNetWiFi}}
  ]

# PN532 NFC readers on SPI0, one per chip-select.
config :ytm, Ytm.PN532.Supervisor, buses: ["spidev0.0", "spidev0.1"]

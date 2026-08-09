# Everything else about the router (WAN, LAN bridge/DHCP, firewall) is
# configured manually via Winbox, not Terraform - see router/README.md.
# Terraform's scope here is deliberately just WireGuard: the bridge, the LAN
# interface list, and the firewall rule it references already exist and were
# created by hand, not by this config.

variable "router_address" {
  description = "Address Terraform uses to reach the router's REST API (https://<address>) - the router's WAN-side address, set manually"
  type        = string
  default     = "192.168.1.5"
}

variable "wireguard_interface_address" {
  description = "Router's own address on the WireGuard interface, in CIDR notation. Deliberately a separate subnet from the LAN (10.200.0.0/24) so tunnel and LAN addresses never collide - the router routes between the two."
  type        = string
  default     = "10.200.255.1/24"
}

variable "lan_interface_list" {
  description = "Name of the router's existing LAN interface list (created manually) - WireGuard is added here too, see main.tf's comment on why"
  type        = string
  default     = "LAN"
}

variable "wireguard_port" {
  description = "UDP listen port for the router's WireGuard interface"
  type        = number
  default     = 51820
}

# public_key is not secret and lives here in plain sight; the matching
# private key stays on the device itself and is never entered anywhere in
# this repo. address is a static /32 out of the WireGuard subnet
# (10.200.255.0/24, not the LAN subnet - see wireguard_interface_address).
variable "wireguard_peers" {
  description = "Road-warrior WireGuard peers keyed by device name."
  type = map(object({
    public_key = string
    address    = string
  }))
  default = {
    mac = {
      public_key = "ndx1PnprfzZpolWrBGlQHwk1jyjq35Hg5zxBCBk3VkE="
      address    = "10.200.255.2/32"
    }
  }
}

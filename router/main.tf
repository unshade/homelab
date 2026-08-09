locals {
  wg_private_key = data.sops_file.router_credentials.data["secrets.wg_private_key"]
}

resource "routeros_interface_wireguard" "wg" {
  name        = "wireguard1"
  private_key = local.wg_private_key
  listen_port = var.wireguard_port
  comment     = "home-access"
}

# NOT bridged into the LAN bridge - RouterOS doesn't allow that for any
# WireGuard interface, on any version. WireGuard only carries raw IP packets
# (L3), never Ethernet frames, so there's no MAC address for a bridge to
# learn/forward - confirmed directly against this router's REST API, which
# rejects `POST /interface/bridge/port` for a wg-type interface outright.
# Routing (a small dedicated subnet, routed to/from the LAN by the router)
# is the only way this works - same as any other WireGuard road-warrior
# setup, RouterOS or otherwise.
resource "routeros_ip_address" "wg_address" {
  address   = var.wireguard_interface_address
  interface = routeros_interface_wireguard.wg.name
  comment   = "home-access"
}

# RouterOS doesn't turn a peer's allowed-address into a route by itself, so
# without this the router would fall back to its default route for traffic
# addressed to a peer, sending it out sfp1 instead of into the tunnel.
resource "routeros_ip_route" "peer_routes" {
  for_each = var.wireguard_peers

  dst_address = each.value.address
  gateway     = routeros_interface_wireguard.wg.name
  comment     = "wireguard: ${each.key}"

  depends_on = [routeros_interface_wireguard_peer.peers]
}

# Without this, traffic FROM a WireGuard peer TO the router itself (e.g.
# managing it over the tunnel) hits the manually-configured "drop all not
# coming from LAN" input rule. RouterOS attributes input-chain traffic
# terminating at the router's own IP to the packet's actual ingress
# interface (wireguard1), not the bridge it's a member of - so bridge
# membership alone isn't enough, it also needs to be in the LAN list, same
# as ether2-5 already are.
resource "routeros_interface_list_member" "wg_lan" {
  interface = routeros_interface_wireguard.wg.name
  list      = var.lan_interface_list
  comment   = "home-access (WireGuard)"
}

# The WireGuard handshake itself arrives on sfp1 (WAN) as plain UDP before
# any tunnel exists, so it's subject to the same manually-configured "drop
# all not coming from LAN" input rule - this explicitly allows it through,
# inserted before that rule. place_before is hardcoded to that rule's
# current id (*5, "defconf: drop all not coming from LAN") since it's a
# manually-created rule outside Terraform's management - check
# `/ip firewall filter print` for its current id if this ever needs
# updating (e.g. after another full router reset).
resource "routeros_ip_firewall_filter" "accept_wireguard" {
  chain        = "input"
  action       = "accept"
  protocol     = "udp"
  dst_port     = tostring(var.wireguard_port)
  comment      = "accept WireGuard (home-access)"
  place_before = "*5"
}

resource "routeros_interface_wireguard_peer" "peers" {
  for_each = var.wireguard_peers

  interface  = routeros_interface_wireguard.wg.name
  public_key = each.value.public_key
  comment    = each.key

  # No persistent_keepalive or endpoint needed - this peer dials the
  # router, not the other way around.
  allowed_address = [each.value.address]
}

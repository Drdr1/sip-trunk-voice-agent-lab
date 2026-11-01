#!/usr/bin/env bash
# Builds the lab network with Linux network namespaces.
#
#   ns carrier  10.20.0.2  ── private circuit (stands in for the operator L3 VLAN) ──  10.20.0.1  ns sbc
#   ns sbc      203.0.113.1 ── "internet" bridge ──┬── 203.0.113.10  ns agent-a  (primary voice platform)
#                                                   └── 203.0.113.11  ns agent-b  (secondary region / overflow)
#
# The carrier namespace has NO route to 203.0.113.0/24, the same way an operator
# circuit usually only reaches the customer's hand-off IP. Everything to the voice
# platform has to go through the bridge.
set -euo pipefail

up() {
  for ns in carrier sbc agent-a agent-b; do ip netns add "$ns"; ip -n "$ns" link set lo up; done

  # private circuit carrier <-> sbc
  ip link add veth-car type veth peer name veth-trunk
  ip link set veth-car netns carrier
  ip link set veth-trunk netns sbc
  ip -n carrier addr add 10.20.0.2/30 dev veth-car;  ip -n carrier link set veth-car up
  ip -n sbc     addr add 10.20.0.1/30 dev veth-trunk; ip -n sbc link set veth-trunk up

  # public side: a bridge inside the sbc namespace with the agent namespaces hanging off it
  ip -n sbc link add br-pub type bridge
  ip -n sbc addr add 203.0.113.1/24 dev br-pub
  ip -n sbc link set br-pub up
  local i=10
  for ns in agent-a agent-b; do
    ip link add "v-$ns" type veth peer name "p-$ns"
    ip link set "v-$ns" netns "$ns"
    ip link set "p-$ns" netns sbc
    ip -n sbc link set "p-$ns" master br-pub
    ip -n sbc link set "p-$ns" up
    ip -n "$ns" addr add "203.0.113.$i/24" dev "v-$ns"
    ip -n "$ns" link set "v-$ns" up
    i=$((i + 1))
  done
  # the sbc must not route between the circuit and the internet: media is anchored, never forwarded
  ip netns exec sbc sysctl -qw net.ipv4.ip_forward=0
}

down() {
  for ns in carrier sbc agent-a agent-b; do ip netns del "$ns" 2>/dev/null || true; done
}

latency() {
  # emulate the path to the voice platform: $1 = one-way delay e.g. 40ms (KSA -> Frankfurt ~ 40-50ms one way)
  local d="${1:-40ms}"
  for p in p-agent-a p-agent-b; do ip netns exec sbc tc qdisc replace dev "$p" root netem delay "$d"; done
}

"${1:-up}" "${@:2}"

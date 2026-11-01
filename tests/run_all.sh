#!/usr/bin/env bash
# End-to-end scenarios. Each one places a real call from the carrier namespace,
# captures the trunk leg and the platform leg on the bridge, and checks the result
# from the packets and the SIP logs rather than from what the config "should" do.
# Needs root (network namespaces), asterisk, sipp, tcpdump, tshark.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAB="$ROOT/lab"; OUT="${OUT:-$ROOT/tests/out}"
mkdir -p "$OUT"; rm -f "$OUT"/*
PASS=0; FAIL=0
ok()   { echo "  PASS  $*"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }
check(){ local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

cli() { bash "$LAB/run.sh" cli "$@"; }
start() { bash "$LAB/run.sh" start "$1"; }
stop()  { bash "$LAB/run.sh" stop "$1"; }

contact_status() { cli sbc "pjsip show contacts" | awk -v a="$1" '$2 ~ "^"a"/" {print $4}'; }
wait_status() { # aor wanted timeout_s
  for _ in $(seq 1 $(( $3 * 2 ))); do [ "$(contact_status "$1")" = "$2" ] && return 0; sleep 0.5; done; return 1
}

# place one call; leaves $OUT/<name>.trunk.pcap, $OUT/<name>.pub.pcap, $OUT/<name>.sipp.log
call() {
  local name="$1"
  ip netns exec sbc timeout 25 tcpdump -i veth-trunk -nn -U -w "$OUT/$name.trunk.pcap" >/dev/null 2>&1 &
  local t1=$!
  ip netns exec sbc timeout 25 tcpdump -i br-pub -nn -U -w "$OUT/$name.pub.pcap" >/dev/null 2>&1 &
  local t2=$!
  sleep 1
  ( cd "$OUT" && ip netns exec carrier timeout 40 sipp -sf "$ROOT/carrier/uac_pcma.xml" -s 920000000 \
      -i 10.20.0.2 -p 5060 -mi 10.20.0.2 -min_rtp_port 6000 -max_rtp_port 6100 \
      -m 1 -l 1 -trace_logs -log_file "$name.sipp.log" -nostdin 10.20.0.1:5060 >/dev/null 2>&1 )
  SIPP_RC=$?
  sleep 1; kill "$t1" "$t2" 2>/dev/null; wait "$t1" "$t2" 2>/dev/null
}

# RTP packet count on the trunk leg in one direction
rtp_count() { # pcap src dst
  tshark -r "$1" -d udp.port==6000-6100,rtp -Y "rtp && ip.src==$2 && ip.dst==$3 && rtp.p_type==8" 2>/dev/null | wc -l
}
# seconds from INVITE to the final 200 on the trunk leg (post-dial delay as the caller feels it)
pdd() {
  tshark -r "$1" -Y 'sip.Method=="INVITE" || (sip.Status-Code==200 && sip.CSeq.method=="INVITE")' \
    -T fields -e frame.time_relative 2>/dev/null | awk 'NR==1{a=$1} END{printf "%.2f", $1-a}'
}
answered_by() { # which instance logged the call
  grep -l "AGENT .* got +966920000000" "$LAB/run/agent-a/log/full" "$LAB/run/agent-b/log/full" 2>/dev/null \
    | sed -E 's#.*/run/([^/]+)/log/full#\1#' | tr '\n' ' '
}
reset_logs() { for i in sbc agent-a agent-b; do : > "$LAB/run/$i/log/full" 2>/dev/null; cli "$i" "logger reload" >/dev/null 2>&1; done; }
lt() { [ "$(echo "$1 < $2" | bc)" = 1 ]; }

boot() {
  bash "$LAB/topology.sh" down; bash "$LAB/topology.sh" up
  bash "$LAB/certs.sh" "$LAB/run/certs"
  start agent-a; start agent-b; start sbc
  wait_status agent-a Avail 20 && wait_status agent-b Avail 20
}

echo "== boot"
check "bridge reaches both platform targets over TLS (OPTIONS qualify)" boot

# ---------------------------------------------------------------------------
echo "== 1. normal call: operator A-law in, platform over TLS + SRTP, two-way audio"
reset_logs; call happy
check "call completes (INVITE/200/ACK/BYE)" test "$SIPP_RC" = 0
check "answered by primary (agent-a)" test "$(answered_by)" = "agent-a "
check "audio carrier -> bridge on the circuit"  test "$(rtp_count "$OUT/happy.trunk.pcap" 10.20.0.2 10.20.0.1)" -gt 150
check "audio bridge -> carrier on the circuit (agent echo came back)" test "$(rtp_count "$OUT/happy.trunk.pcap" 10.20.0.1 10.20.0.2)" -gt 150
check "bridge answer SDP gives the carrier the circuit address" grep -q "ANSWER_SDP_C=10.20.0.1" "$OUT/happy.sipp.log"
check "no cleartext SIP on the public side"  test "$(tshark -r "$OUT/happy.pub.pcap" -Y sip 2>/dev/null | wc -l)" = 0
check "signalling to the platform is TLS on 5061" test "$(tshark -r "$OUT/happy.pub.pcap" -Y 'tcp.port==5061 && tls.record' 2>/dev/null | wc -l)" -gt 0
check "platform leg offered SRTP (RTP/SAVP + a=crypto)" grep -qE "m=audio [0-9]+ RTP/SAVP" "$LAB/run/agent-a/log/full"
check "no transcoding: platform leg negotiated PCMA too" grep -qE "a=rtpmap:8 PCMA/8000" "$LAB/run/agent-a/log/full"
check "E.164 number reaches the platform (+966920000000)" grep -q "got +966920000000" "$LAB/run/agent-a/log/full"
check "caller ID passed as X-Caller-ID header" grep -q "caller=+966501234567" "$LAB/run/agent-a/log/full"
cp "$LAB/run/sbc/log/full" "$OUT/happy.sbc.log"
echo "       post-dial delay: $(pdd "$OUT/happy.trunk.pcap")s"

# ---------------------------------------------------------------------------
echo "== 2. primary platform dies mid-day; qualify has already noticed"
stop agent-a
check "qualify marks agent-a Unavail" wait_status agent-a Unavail 20
reset_logs; call failover_known
check "call completes" test "$SIPP_RC" = 0
check "answered by secondary (agent-b)" test "$(answered_by)" = "agent-b "
check "primary skipped without an attempt" grep -q "SKIP agent-a" "$LAB/run/sbc/log/full"
check "two-way audio after failover" test "$(rtp_count "$OUT/failover_known.trunk.pcap" 10.20.0.1 10.20.0.2)" -gt 150
d=$(pdd "$OUT/failover_known.trunk.pcap"); echo "       post-dial delay: ${d}s"
check "failover adds no noticeable delay (< 1s to answer)" lt "$d" 1

# ---------------------------------------------------------------------------
echo "== 3a. primary process dies seconds before the call (TLS connect refused)"
start agent-a; wait_status agent-a Avail 20
stop agent-a     # immediately: qualify still says Avail
reset_logs; call failover_refused
check "call completes" test "$SIPP_RC" = 0
check "answered by secondary (agent-b)" test "$(answered_by)" = "agent-b "
check "primary was attempted, failed, dialplan moved on" grep -qE "RESULT agent-a DIALSTATUS=" "$LAB/run/sbc/log/full"
d=$(pdd "$OUT/failover_refused.trunk.pcap"); echo "       post-dial delay: ${d}s"
# observed both 0.01s and 6.4s across runs: the refusal is not always surfaced to the
# INVITE transaction, so the guarantee is the timer-B bound, not the fast path
check "refused connect: failover bounded by timer B = 6.4s" lt "$d" 7

# ---------------------------------------------------------------------------
echo "== 3b. primary goes silent (blackhole: region outage, dropped route) before qualify notices"
start agent-a; wait_status agent-a Avail 20
ip netns exec sbc iptables -A OUTPUT -d 203.0.113.10 -j DROP
reset_logs; call failover_blackhole
check "call completes" test "$SIPP_RC" = 0
check "answered by secondary (agent-b)" test "$(answered_by)" = "agent-b "
d=$(pdd "$OUT/failover_blackhole.trunk.pcap"); echo "       post-dial delay: ${d}s"
check "silent target: failover bounded by timer B = 6.4s (default 32s)" lt "$d" 7
ip netns exec sbc iptables -F OUTPUT
stop agent-a

# ---------------------------------------------------------------------------
echo "== 4. both platform targets down: the published number still answers"
stop agent-b
wait_status agent-a Unavail 20; wait_status agent-b Unavail 20
reset_logs; call total_outage
check "call is answered locally (200 OK), not rejected" grep -q "ANSWER_SDP_C=10.20.0.1" "$OUT/total_outage.sipp.log"
check "fallback branch taken" grep -q "FAILOVER=local" "$LAB/run/sbc/log/full"
check "caller hears the fallback prompt (bridge -> carrier audio)" test "$(rtp_count "$OUT/total_outage.trunk.pcap" 10.20.0.1 10.20.0.2)" -gt 50

# ---------------------------------------------------------------------------
echo "== 5. one-way audio: 'the agent can't hear the caller'"
# Classic cause: the bridge's RTP port range is not open on the circuit interface
# (host firewall, cloud security group, or the operator's ACL in the other direction).
# Signalling is fine, so the call connects and looks healthy in every SIP log.
start agent-a; start agent-b; wait_status agent-a Avail 20
ip netns exec sbc iptables -A INPUT -i veth-trunk -p udp --dport 10000:10999 -j DROP
reset_logs; call one_way
check "call connects normally (200 OK, clean BYE)" test "$SIPP_RC" = 0
check "on the wire: carrier -> bridge audio arrives" test "$(rtp_count "$OUT/one_way.trunk.pcap" 10.20.0.2 10.20.0.1)" -gt 150
fwd=$(tshark -r "$OUT/one_way.pub.pcap" -Y "udp && ip.src==203.0.113.1 && udp.srcport>=10000 && udp.srcport<=10999" 2>/dev/null | wc -l)
check "symptom: nothing forwarded to the agent (it hears silence)" test "$fwd" = 0
drops=$(ip netns exec sbc iptables -L INPUT -v -n -x | awk '/DROP/ && /10000:10999/ {print $1}')
check "cause: packets dropped before reaching the media engine ($drops dropped)" test "${drops:-0}" -gt 150
ip netns exec sbc iptables -F INPUT

# ---------------------------------------------------------------------------
echo
echo "passed: $PASS   failed: $FAIL"
for i in sbc agent-a agent-b; do stop "$i"; done
bash "$LAB/topology.sh" down
[ "$FAIL" = 0 ]

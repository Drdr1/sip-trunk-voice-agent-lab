# sip-trunk-voice-agent-lab

A reproducible lab of the telephony layer under an AI voice agent:

```
operator SIP trunk            bridge PBX (Asterisk/PJSIP)         voice-agent platform
private circuit, UDP,   ───►  anchors media, E.164,         ───►  SIP over TLS 5061,
G.711 A-law, IP auth          failover, X- headers                SRTP required
10.20.0.2                     10.20.0.1 | 203.0.113.1              203.0.113.10 (primary)
                                                                   203.0.113.11 (secondary)
```

Each box runs in its own Linux network namespace. The carrier namespace has no route to the internet side, so everything has to go through the bridge, the way it does on a real private circuit.

**Scope, plainly:** the operator is simulated with SIPp, and the platform is simulated with an Asterisk instance that behaves like the real one (TLS only, SRTP required, E.164 numbers, PCMA/G.722). Nothing here has been run against a real operator or a real voice platform. The configs are the starting point for that, and the tests are what to re-run during turn-up.

The answers to the design questions (operator questions, hosting, latency, codecs, failover, and whether to use a CPaaS instead) are in **[DESIGN.md](DESIGN.md)**.

## What the tests prove

`sudo bash tests/run_all.sh` places real calls and checks packets and SIP logs, not the config:

| # | Scenario | Result (last run) |
|---|---|---|
| 1 | Normal call | Answered in 0.01 s. Two-way PCMA audio on the circuit. TLS 5061 and SRTP (`RTP/SAVP`, `a=crypto`) on the platform leg. No cleartext SIP on the public side. No transcoding. E.164 number and caller ID header reach the agent. |
| 2 | Primary down, already detected by OPTIONS | Primary skipped, secondary answers in 0.01 s |
| 3a | Primary process killed seconds before the call | Secondary answers. Usually 0.01 s, but some runs take 6.4 s: the refused connect isn't always surfaced to the INVITE, so timer B is what bounds it |
| 3b | Primary goes **silent** (blackhole) | Secondary answers in **6.41 s**. Default SIP timers would leave the caller in silence for up to 32 s; see below |
| 4 | Both platform targets down | The number still answers and plays a prompt |
| 5 | "The agent can't hear the caller" | Call connects normally. Caller audio reaches the bridge interface but is dropped by the firewall before the media engine, so the agent hears nothing. The test shows how to see it in the capture and counters |

All 32 checks pass. Every scenario leaves a pcap of both legs in `tests/out/`, and CI uploads them.

### The failure worth knowing about (3a/3b)

When the primary target silently stops answering (and, in some runs, even when its port refuses the connection), the INVITE gets no response and the bridge waits for SIP timer B: 64 × T1, **32 s by default**. Asterisk refuses to set timer B below 64 × T1, so the fix is `timer_t1=100`, which gives a 6.4 s worst case. A 5 s OPTIONS qualify keeps most outages on the zero-delay path of scenario 2.

## Layout

```
bridge/pjsip.conf        trunk + platform endpoints, transports, timers   (the deliverable config)
bridge/extensions.conf   E.164 normalisation, primary -> secondary -> fallback
agent/                   simulated voice platform
carrier/uac_pcma.xml     SIPp: operator INVITE with PCMA-only SDP, real A-law audio
lab/topology.sh          namespaces, veths, optional netem latency
lab/run.sh               render configs per instance, start/stop, CLI
tests/run_all.sh         the scenarios above
DESIGN.md                design answers and the operator question list
```

## Run it

Ubuntu 24.04, root:

```bash
sudo apt-get install -y asterisk asterisk-modules sip-tester tcpdump tshark bc iptables
sudo bash tests/run_all.sh
```

To try a latency before buying hosting: `sudo bash lab/topology.sh latency 60ms` after bringing the topology up.

## Moving it to production

- Replace the lab IPs with the hand-off details from the operator (DESIGN.md has the question list).
- Use a publicly trusted cert for the bridge FQDN, and add that FQDN to the platform's "Remote domains".
- Add `outbound_auth` with the digest credentials set on the imported number.
- Set `external_media_address` and `external_signaling_address` if the bridge sits behind 1:1 NAT.
- Point `agent-a` and `agent-b` at the platform endpoints you measured as nearest.
- Replace the fallback prompt with a forward to a human number.

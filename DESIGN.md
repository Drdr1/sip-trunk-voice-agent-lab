# Design notes: operator SIP trunk on a private circuit → AI voice agent

Target: `9200 UAN → operator SIP trunk (managed L3, private VLAN) → bridge → voice-agent platform over SIP/TLS 5061`.

These notes answer the five questions that decide whether this works, in the order they block you.
Platform facts are from the ElevenLabs SIP reference and SIP trunking pages (checked Nov 2026).
Anything marked **ask** has to come from the operator; it is not something to guess.

---

## 1. Can the operator VLAN reach a public SIP endpoint abroad?

Plan on **no**, and design so it doesn't matter.

A managed L3 SIP trunk is normally a routed link between the operator's SBC and *your* hand-off
subnet. It is not internet transit. Even if it would route to `sip.rtc.elevenlabs.io`, you would
still need a box in the middle, because the two sides don't speak the same thing:

| | Operator leg | Platform leg |
|---|---|---|
| Signalling | UDP 5060, cleartext | TCP or TLS 5061 (UDP is experimental on the platform side) |
| Media | RTP | SRTP if you set encryption to Required |
| Auth | IP-based on the circuit | Digest (recommended) or IP ACL |
| Number format | national (`920000000`) | E.164 (`+966920000000`), must match the imported number |

So the bridge is not optional. The real question for the operator is **where the circuit can be
delivered**, because the bridge has to sit where the circuit lands *and* have an internet uplink.

The other half of "make-or-break" is not routing but **policy**: whether caller audio may be relayed to a
platform outside the Kingdom. ElevenLabs' regional static-IP endpoints are `eu`, `in` and `sg`; none
is in KSA. That is a question for your counsel (PDPL cross-border transfer) and for the operator's
terms of service. It is not something an engineer should answer for you.

## 2. Where to host the bridge, and the latency budget

**Host it where the circuit is delivered, in KSA.** In order of preference:

1. A KSA cloud region where the operator can deliver the trunk VLAN over a cross-connect or partner interconnect (**ask**).
2. A colocation rack in a Riyadh or Jeddah DC where the circuit is terminated, with its own internet uplink.
3. Your office, only as a pilot. It becomes the single point of failure for a published number.

The bridge leg to the platform then runs over the internet with TLS/SRTP.

**Latency budget.** The caller notices the *turn gap*: from end of speech to the agent's first audio.
That is dominated by the platform (endpointing + LLM + TTS), commonly hundreds of ms to over a second.
The network adds one round trip per turn on top of that:

| Segment | Expected | How to keep it there |
|---|---|---|
| Operator network + circuit | ~10–30 ms one-way | nothing to tune |
| Bridge | < 5 ms | no transcoding, no jitter buffer, media anchored but passed through |
| Bridge → platform | **measure it** | pick the nearest platform endpoint; measure RTT from the bridge to each candidate |
| Platform turn time | 500 ms+ | agent/LLM/TTS choice, not telephony |

Rule of thumb from ITU-T G.114: keep one-way network delay under 150 ms. If bridge → platform RTT
is well under 200 ms you are fine; past that, the agent starts to feel slow and barge-in gets worse.
Measure from the actual bridge host before committing: `tc netem` in the lab (`lab/topology.sh latency 40ms`)
lets you hear a given delay before buying the hosting.

## 3. Codec and media

- **Use G.711 A-law end to end.** The operator gives PCMA 8 kHz and the platform accepts PCMA, so the bridge
  relays packets without decoding them. The lab confirms PCMA is negotiated on both legs.
- **G.722 end to end is not achievable**: the PSTN side is narrowband. Transcoding PCMA → G.722 upsamples
  8 kHz audio to 16 kHz. It costs a little CPU, adds a little delay, and adds no audio information.
  G.722 only helps if the caller's side is wideband, which a 9200 call from the PSTN is not.
- **SRTP**: the operator leg stays RTP. That is normal on a private circuit. The platform leg uses SDES-SRTP
  (`a=crypto`). The platform docs don't list crypto suites. Follow their own advice: set Allowed, confirm
  `RTP/SAVP` in the SDP, then switch to Required.
- **DTMF**: RFC 4733 (`telephone-event`) on both legs. Confirm the payload type the operator uses (**ask**).

## 4. Failover: it is the main published number

Failover has to exist at three layers. The lab tests the bridge and platform layers; the operator layer can only be configured by the operator.

1. **Operator layer.** This is the only thing that helps when the bridge itself is down.
   - **Ask** for two hand-off IPs, so two bridges can run active/standby.
   - **Ask** how the operator SBC detects a dead hand-off (OPTIONS? timeout?).
   - **Ask** for a backup destination on the 9200 routing plan (a mobile, landline or call centre number) when your side doesn't answer.
2. **Bridge → platform** (`bridge/extensions.conf`, scenarios 2–4):
   - The OPTIONS qualify runs every 5 s. A target already marked down is skipped with no delay (0.01 s in the lab).
   - A refused connect usually fails over immediately, but not always: in some lab runs the refusal wasn't surfaced to the INVITE and it waited on timer B.
   - A *silent* target (dropped route, region outage) is the dangerous one. See the finding below.
   - If both targets are down, the bridge still answers and plays a prompt; in production it would forward to a human number. The caller never hears a dead line.
3. **Monitoring.** Watch for:
   - OPTIONS state on both legs.
   - Answer-seizure ratio.
   - **Calls with zero RTP in one direction**, which catches one-way audio before customers report it.
   - TLS cert expiry.
   - Platform concurrency (enable call queueing on the platform so overflow queues instead of failing).

**Finding from the lab (scenarios 3a and 3b).** When the primary target goes silent, the INVITE gets no response.
The bridge waits for SIP timer B, which defaults to 64 × T1 = **32 s**, or for the Dial timeout if that is shorter.
The caller hears nothing for that whole time. Asterisk won't set timer B below 64 × T1, so the fix is to lower T1 to 100 ms.
That makes timer B 6.4 s; the lab measures 6.41 s to answer on the secondary. The short qualify interval narrows the window in which a dead target is still marked up.

## 5. Are you overcomplicating it?

The bridge isn't the overcomplication. With a private-circuit trunk it is required: TLS/SRTP, number
normalisation and failover all have to happen somewhere. What's worth questioning is **the circuit**:

- **Ask the operator** whether the same 9200 can be delivered as an internet SIP trunk, ideally TLS.
  That removes the colo or interconnect, but you still need a thin bridge unless the operator does TLS/SRTP and E.164.
- **Or** point the 9200 at a number held by a KSA-licensed CPaaS that hands calls to SIP/TLS platforms directly.
  That gives fewer moving parts, but you depend on their platform, and their pricing becomes your cost floor.
- Keep the private circuit if you need the operator's QoS and SLA on the access leg, or if neither alternative exists for a UAN.

Decide this before the hosting is bought. The circuit is the long-lead item.

---

## What to send the operator's engineers

Send the list in their terms, as a table they fill in:

1. **Hand-off.** Physical interface and speed, VLAN ID, our IP/subnet, and gateway. Can it be delivered into a KSA cloud region or a colo cross-connect?
2. **Addresses.** Your SBC signalling IPs (primary/secondary). **Media IPs and RTP port range, if different from signalling.** Routes we must add.
3. **Signalling.** Transport (UDP/TCP) and port. Do you send OPTIONS to us? Do you answer ours?
4. **Auth.** IP-based only? Any registration or digest?
5. **Numbers.**
   - Called number format in the Request-URI and To header for the 9200.
   - Calling number format, P-Asserted-Identity, and privacy (CLIR) handling.
   - Diversion headers.
6. **Codec and DTMF.** PCMA only? ptime? RFC 2833/4733 payload type, or in-band?
7. **Timers.** Session timers (expected refresher and interval). Early media requirements (180 vs 183 + SDP).
8. **Capacity.** Licensed concurrent channels. What happens above the limit (486/503)?
9. **Redundancy.** Two hand-off IPs? How is a dead hand-off detected? A backup destination on the 9200 routing plan?
10. **MTU** on the circuit. Large UDP INVITEs fragment; do you support SIP over TCP if needed?
11. **Testing.** A test number, a maintenance window, and an engineer contact who can take a pcap on your SBC during turn-up.

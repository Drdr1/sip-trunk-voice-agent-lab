#!/usr/bin/env bash
# Render and start/stop the Asterisk instances inside their namespaces.
#   run.sh start <instance>   instance = sbc | agent-a | agent-b
#   run.sh stop  <instance>
#   run.sh cli   <instance> "<asterisk cli command>"
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNBASE="${RUNBASE:-$ROOT/lab/run}"

ip_of() { case "$1" in sbc) echo 203.0.113.1;; agent-a) echo 203.0.113.10;; agent-b) echo 203.0.113.11;; esac; }

render() {
  local name="$1" dir="$RUNBASE/$1" src
  if [ "$name" = sbc ]; then src="$ROOT/bridge"; else src="$ROOT/agent"; fi
  rm -rf "$dir"; mkdir -p "$dir"/{etc,run,log,lib,spool}
  for f in "$src"/*.conf; do
    sed -e "s#@RUN@#$dir#g" -e "s#@IP@#$(ip_of "$name")#g" -e "s#@NAME@#$name#g" "$f" > "$dir/etc/$(basename "$f")"
  done
  cat > "$dir/etc/asterisk.conf" <<EOF
[directories]
astetcdir => $dir/etc
astmoddir => /usr/lib/x86_64-linux-gnu/asterisk/modules
astvarlibdir => $dir/lib
astdbdir => $dir/lib
astkeydir => $dir/lib
astdatadir => /usr/share/asterisk
astagidir => /usr/share/asterisk/agi-bin
astspooldir => $dir/spool
astrundir => $dir/run
astlogdir => $dir/log
astcachedir => $dir/lib
[options]
verbose = 3
nofork = no
EOF
  cat > "$dir/etc/modules.conf" <<'EOF'
[modules]
autoload=no
load => res_pjproject.so
load => res_sorcery_config.so
load => res_sorcery_memory.so
load => res_sorcery_astdb.so
load => res_sorcery_realtime.so
load => res_pjsip.so
load => res_pjsip_session.so
load => chan_pjsip.so
load => res_pjsip_authenticator_digest.so
load => res_pjsip_endpoint_identifier_ip.so
load => res_pjsip_endpoint_identifier_user.so
load => res_pjsip_outbound_authenticator_digest.so
load => res_pjsip_outbound_registration.so
load => res_pjsip_registrar.so
load => res_pjsip_sdp_rtp.so
load => res_pjsip_caller_id.so
load => res_pjsip_header_funcs.so
load => res_pjsip_dtmf_info.so
load => res_pjsip_rfc3326.so
load => res_pjsip_nat.so
load => res_pjsip_pubsub.so
load => res_pjsip_logger.so
load => res_pjsip_diversion.so
load => res_pjsip_one_touch_record_info.so
load => res_pjsip_send_to_voicemail.so
load => res_pjsip_t38.so
load => res_pjsip_rfc3329.so
load => res_pjsip_path.so
load => res_pjsip_empty_info.so
load => res_rtp_asterisk.so
load => res_srtp.so
load => res_timing_timerfd.so
load => res_crypto.so
load => res_format_attr_g722.so
load => func_pjsip_aor.so
load => func_pjsip_contact.so
load => func_pjsip_endpoint.so
load => func_logic.so
load => func_strings.so
load => func_callerid.so
load => func_cdr.so
load => func_channel.so
load => app_dial.so
load => app_echo.so
load => app_playback.so
load => app_stack.so
load => pbx_config.so
load => bridge_simple.so
load => bridge_native_rtp.so
load => bridge_builtin_features.so
load => bridge_softmix.so
load => bridge_holding.so
load => codec_alaw.so
load => codec_ulaw.so
load => codec_g722.so
load => codec_gsm.so
load => format_gsm.so
load => format_wav.so
load => format_pcm.so
load => format_g722.so
load => cdr_csv.so
load => res_musiconhold.so
EOF
  cat > "$dir/etc/logger.conf" <<'EOF'
[general]
dateformat=%F %T.%3q
[logfiles]
full => notice,warning,error,verbose,dtmf
EOF
  printf '[general]\nrtpstart=10000\nrtpend=10999\nstrictrtp=yes\n' > "$dir/etc/rtp.conf"
  printf '[general]\nenable=yes\n[csv]\nusegmtime=yes\nloguniqueid=yes\nloguserfield=yes\n' > "$dir/etc/cdr.conf"
  : > "$dir/etc/musiconhold.conf"
}

cmd="$1"; name="$2"
case "$cmd" in
  start)
    render "$name"
    ip netns exec "$name" asterisk -C "$RUNBASE/$name/etc/asterisk.conf"
    for _ in $(seq 1 50); do
      ip netns exec "$name" asterisk -C "$RUNBASE/$name/etc/asterisk.conf" -rx "core waitfullybooted" >/dev/null 2>&1 && break
      sleep 0.2
    done
    # log every SIP message (decrypted, so TLS legs are readable) for the trace checks
    ip netns exec "$name" asterisk -C "$RUNBASE/$name/etc/asterisk.conf" -rx "pjsip set logger on" >/dev/null ;;
  stop)
    pidf="$RUNBASE/$name/run/asterisk.pid"
    pid="$(cat "$pidf" 2>/dev/null || true)"
    ip netns exec "$name" asterisk -C "$RUNBASE/$name/etc/asterisk.conf" -rx "core stop now" >/dev/null 2>&1 || true
    if [ -n "$pid" ]; then
      for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
      kill -9 "$pid" 2>/dev/null || true
    fi ;;
  cli)
    ip netns exec "$name" asterisk -C "$RUNBASE/$name/etc/asterisk.conf" -rx "$3" ;;
esac

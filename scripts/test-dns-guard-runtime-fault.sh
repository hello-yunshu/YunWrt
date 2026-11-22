#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GUARD="$ROOT/overlay/files/usr/sbin/openclash-dns-guard.sh"
H="$(mktemp -d /tmp/cfi-dns-guard.XXXXXX)"
cleanup(){ if [[ -n "${GUARD_PID:-}" ]]; then kill -TERM "$GUARD_PID" 2>/dev/null || true; wait "$GUARD_PID" 2>/dev/null || true; fi; rm -rf "$H"; }
trap cleanup EXIT
mkdir -p "$H/bin" "$H/logs" "$H/var/etc"
export HARNESS_ROOT="$H" UCI_STATE="$H/uci.state" DNS_PHASE="$H/dns-ok" ALERT_LOG="$H/alerts.log"
cat >"$H/bin/uci" <<'UCI'
#!/bin/sh
[ "${1:-}" = -q ] && shift
cmd=${1:-}; key=${2:-}; value=${key#*=}; key=${key%%=*}
case "$cmd" in
get) awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$UCI_STATE";;
show) cat "$UCI_STATE";;
set)
 awk -F= -v k="$key" -v v="$value" 'BEGIN{done=0} $1==k {if(!done){print k "=" v; done=1}; next} {print} END{if(!done) print k "=" v}' "$UCI_STATE" >"$UCI_STATE.next" && mv "$UCI_STATE.next" "$UCI_STATE";;
add_list) printf '%s=%s\n' "$key" "$value" >>"$UCI_STATE";;
del|delete) awk -F= -v k="$key" '$1!=k' "$UCI_STATE" >"$UCI_STATE.next" && mv "$UCI_STATE.next" "$UCI_STATE";;
commit|revert) :;;
*) exit 1;;
esac
UCI
cat >"$H/bin/nslookup" <<'DNS'
#!/bin/sh
[ -e "$DNS_PHASE" ]
DNS
cat >"$H/bin/curl" <<'CURL'
#!/bin/sh
printf '%s\n' "$*" >>"$ALERT_LOG"
printf '{"code":200}\n'
CURL
cat >"$H/bin/logger" <<'LOGGER'
#!/bin/sh
exit 0
LOGGER
cat >"$H/bin/dnsmasq-reload" <<'RELOAD'
#!/bin/sh
: >"$HARNESS_ROOT/var/etc/dnsmasq.conf.cfg001"
"$HARNESS_ROOT/bin/uci" -q get 'dhcp.@dnsmasq[0].server' | while IFS= read -r s; do printf 'server=%s\n' "$s"; done >"$HARNESS_ROOT/var/etc/dnsmasq.conf.cfg001"
RELOAD
chmod +x "$H/bin/"*
cat >"$UCI_STATE" <<'UCI'
openclash-dns-guard.main.bark_key=test-key
openclash-dns-guard.main.bark_group=harness
openclash-dns-guard.main.notify_on_fallback=1
openclash-dns-guard.main.notify_on_recover=1
openclash-dns-guard.main.notify_on_severe=1
openclash-dns-guard.main.probe_interval=5
openclash-dns-guard.main.primary_port=653
openclash-dns-guard.main.fallback_port=953
openclash-dns-guard.main.suspend_watchdog=0
openclash-dns-guard.main.alert_after=5
openclash-dns-guard.main.degrade_after=10
openclash-dns-guard.main.notify_cooldown=300
openclash-dns-guard.main.manage_ip_rule=0
dhcp.@dnsmasq[0].server=127.0.0.1#653
dhcp.@dnsmasq[0].noresolv=1
dhcp.@dnsmasq[0].resolvfile=/tmp/resolv.conf.auto
UCI
"$H/bin/dnsmasq-reload"
python3 - "$GUARD" "$H/guard.sh" "$H" <<'PY'
import pathlib, sys
src=pathlib.Path(sys.argv[1]).read_text()
h=sys.argv[3]
for a,b in {
 'STATE_FILE="/var/run/openclash-dns-guard.state"':f'STATE_FILE="{h}/state"',
 'QUEUE_FILE="/var/run/openclash-dns-guard.queue"':f'QUEUE_FILE="{h}/queue"',
 'LEASE_FILE="/var/run/openclash-dns-guard.maintenance"':f'LEASE_FILE="{h}/lease"',
 'LOG_DIR="/yunshu/openwrt-maintenance"':f'LOG_DIR="{h}/logs"',
 'LOG_FILE="/var/log/openclash-dns-guard.log"':f'LOG_FILE="{h}/logs/guard.log"',
 'for _wd in /var/log /tmp; do':f'for _wd in "{h}/logs"; do',
 '/var/etc/dnsmasq.conf.cfg*':f'{h}/var/etc/dnsmasq.conf.cfg*',
 '/etc/init.d/dnsmasq reload':f'{h}/bin/dnsmasq-reload',
}.items():
    src=src.replace(a,b)
pathlib.Path(sys.argv[2]).write_text(src)
PY
export PATH="$H/bin:$PATH"
start=$(date +%s)
/bin/sh "$H/guard.sh" >"$H/stdout" 2>&1 & GUARD_PID=$!
for i in $(seq 1 60); do
  if grep -q '^ROLE=wan$' "$H/state" 2>/dev/null; then break; fi
  sleep 0.25
done
grep -q '^ROLE=wan$' "$H/state" || { cat "$H/logs/openclash-dns-guard.log"; echo 'FAIL: no WAN failover'; exit 1; }
wan=$(date +%s)
wan_age=$((wan-start))
((wan_age <= 15)) || { echo "FAIL: WAN transition exceeded 15s bound (${wan_age}s)"; exit 1; }
printf 'WAN after %ss; role=%s; dnsmasq noresolv=%s\n' "$wan_age" "$(sed -n 's/^ROLE=//p' "$H/state")" "$("$H/bin/uci" -q get 'dhcp.@dnsmasq[0].noresolv')"
grep -q 'SWITCH ->wan-dns' "$H/logs/openclash-dns-guard.log"
[ "$(grep -c 'https://api.day.app' "$ALERT_LOG" || true)" -eq 1 ] || { echo 'FAIL: expected one failover notification'; cat "$ALERT_LOG"; exit 1; }
touch "$DNS_PHASE"
for i in $(seq 1 60); do
  if grep -q '^ROLE=primary$' "$H/state" 2>/dev/null && ! grep -q 'recovery_pending=1' "$UCI_STATE"; then break; fi
  sleep 0.25
done
grep -q '^ROLE=primary$' "$H/state" || { cat "$H/logs/openclash-dns-guard.log"; echo 'FAIL: recovery to primary'; exit 1; }
kill -TERM "$GUARD_PID"; wait "$GUARD_PID" 2>/dev/null || true; GUARD_PID=
[ "$("$H/bin/uci" -q get 'dhcp.@dnsmasq[0].server')" = '127.0.0.1#653' ] || { echo 'FAIL: original server not restored'; exit 1; }
[ "$("$H/bin/uci" -q get 'dhcp.@dnsmasq[0].noresolv')" = 1 ] || { echo 'FAIL: noresolv not restored'; exit 1; }
[ "$(grep -c 'https://api.day.app' "$ALERT_LOG" || true)" -eq 2 ] || { echo 'FAIL: expected exactly one failover and one recovery notification'; cat "$ALERT_LOG"; exit 1; }
printf 'PASS recovered after both endpoint probes; one failover alert and one recovery notification; total notifications=%s\n' "$(grep -c 'https://api.day.app' "$ALERT_LOG")"

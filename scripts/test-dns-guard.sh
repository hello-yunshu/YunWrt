#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="${ROOT_DIR}/overlay/files/usr/sbin/openclash-dns-guard.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

OPENCLASH_DNS_GUARD_SOURCE_ONLY=1
. "$GUARD"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (got '$1', want '$2')"; }

LEASE_FILE="${TMP_DIR}/lease"
STATE_FILE="${TMP_DIR}/state"
BOOT="boot-a"
UPTIME=1000
OWNER_ALIVE=1
uptime_seconds() { printf '%s\n' "$UPTIME"; }
boot_id() { printf '%s\n' "$BOOT"; }
proc_start_ticks() { [ -n "$1" ] || return 1; printf '12345\n'; }
lease_owner_alive() { [ "$OWNER_ALIVE" = 1 ]; }

maintenance_begin txn-42 120
maintenance_active || fail "valid lease must be active"
assert_eq "$LEASE_ID" txn-42 "lease transaction id"
assert_eq "$((LEASE_EXPIRES - LEASE_ISSUED))" 120 "lease bounded duration"
first_expiry=$LEASE_EXPIRES
UPTIME=1010
maintenance_begin txn-42 120
assert_eq "$LEASE_EXPIRES" "$first_expiry" "idempotent begin must not extend the hard expiry"
ok "valid transaction lease accepted"

UPTIME=1120
maintenance_active && fail "expired lease must fail closed"
[ ! -e "$LEASE_FILE" ] || fail "expired lease must be removed"
ok "lease expiry fails closed"

UPTIME=1200
maintenance_begin reboot-case 60
BOOT=boot-b
maintenance_active && fail "lease from prior boot must fail closed"
ok "reboot invalidates lease"

BOOT=boot-a
maintenance_begin owner-case 60
OWNER_ALIVE=0
maintenance_active && fail "dead transaction owner must invalidate lease"
[ ! -e "$LEASE_FILE" ] || fail "dead-owner lease must be removed"
OWNER_ALIVE=1
ok "owner exit invalidates lease"

maintenance_begin hard-limit 181 >/dev/null 2>&1 && fail "lease above hard maximum accepted"
ok "hard lease maximum enforced"

maintenance_begin txn-99 30
if maintenance_begin other-transaction 30 >/dev/null 2>&1; then fail "second transaction replaced active lease"; fi
if maintenance_end wrong-id >/dev/null 2>&1; then fail "wrong transaction id ended lease"; fi
maintenance_end txn-99
ok "lease ownership prevents replacement or foreign release"

cfg() {
	case "$1" in probe_interval) echo 99 ;; alert_after) echo 90 ;; degrade_after) echo 999 ;; notify_cooldown) echo 300 ;; *) echo "$2" ;; esac
}
uci() { return 0; }
load_cfg || fail "config normalization"
assert_eq "$INTERVAL" 15 "poll interval safety cap"
assert_eq "$DEGRADE_AFTER" 140 "configured downgrade hard cap"
ok "configured timing is bounded"

DEGRADE_AFTER=140
ALERT_AFTER=90
assert_eq "$(fault_action 2 0 120 1)" wait "lease suppresses a planned outage before hard max"
assert_eq "$(fault_action 2 0 90 0)" alert "unleased incident alerts at configured threshold"
assert_eq "$(fault_action 2 0 139 1)" wait "lease cannot extend beyond hard max"
assert_eq "$(fault_action 2 0 140 1)" fallback "lease cannot suppress fallback at hard max"
assert_eq "$(fault_action 2 2 15 1)" wan "loss of both resolvers bypasses lease"
ok "fault timing and severe-fault override"

NOW=2000
INCIDENT_ID=incident-a
NOTIFIED_KEYS=""
LAST_NOTIFY_KIND=""
LAST_NOTIFY_TS=0
NOTIFY_COOLDOWN=300
ALERTS=0
log() { :; }
bark() { ALERTS=$((ALERTS + 1)); }
notify_event alert title body
notify_event alert title body
assert_eq "$ALERTS" 1 "same-incident alert deduplication"
INCIDENT_ID=incident-b
NOW=2100
notify_event alert title body
assert_eq "$ALERTS" 1 "same-kind cooldown"
NOW=2301
notify_event alert title body
assert_eq "$ALERTS" 2 "cooldown expiry permits a new incident alert"
ok "incident deduplication and cooldown"

UCI_NORESOLV=1
UCI_RESOLVFILE=/tmp/resolv.conf.auto
uci() {
	[ "$1" = -q ] && shift
	[ "$1" = get ] || return 1
	case "$2" in
		dhcp.@dnsmasq\[0\].noresolv) printf '%s\n' "$UCI_NORESOLV" ;;
		dhcp.@dnsmasq\[0\].resolvfile) printf '%s\n' "$UCI_RESOLVFILE" ;;
		openclash-dns-guard.main.recovery_pending) printf '1\n' ;;
		openclash-dns-guard.main.recovery_server) printf '127.0.0.1#653\n' ;;
		openclash-dns-guard.main.recovery_noresolv_set) printf '1\n' ;;
		openclash-dns-guard.main.recovery_resolvfile_set) printf '1\n' ;;
		openclash-dns-guard.main.recovery_noresolv) printf '1\n' ;;
		openclash-dns-guard.main.recovery_resolvfile) printf '/tmp/resolv.conf.auto\n' ;;
		*) return 1 ;;
	esac
}
servers_match() { [ "${SERVER_MATCH:-1}" = 1 ]; }
sleep() { :; }
ORIG_SERVER='127.0.0.1#653'
ORIG_NORESOLV=1
ORIG_RESOLVFILE=/tmp/resolv.conf.auto
ORIG_NORESOLV_SET=1
ORIG_RESOLVFILE_SET=1
SERVER_MATCH=1
assert_eq "$ORIG_NORESOLV_SET" 1 "recorded noresolv presence flag"
assert_eq "$ORIG_RESOLVFILE_SET" 1 "recorded resolvfile presence flag"
uci_option_is_set noresolv || fail "mock UCI option presence"
verify_restore || fail "matching original DNS settings should verify"
UCI_NORESOLV=0
verify_restore && fail "noresolv mismatch should fail readback"
UCI_NORESOLV=1
UCI_RESOLVFILE=/tmp/other
verify_restore && fail "resolvfile mismatch should fail readback"
ok "restore readback covers server, noresolv, and resolvfile"

UCI_CALLS=""
RELOADS=0
SNAPSHOT_PENDING=1
RECOVERY_ROLE=fallback
UCI_SERVERS='127.0.0.1#953'
uci() {
	UCI_CALLS="$UCI_CALLS $*"
	[ "$1" = -q ] && shift
	case "$1" in
		get)
			case "$2" in
				dhcp.@dnsmasq\[0\].server) printf '%s\n' "$UCI_SERVERS" ;;
				dhcp.@dnsmasq\[0\].noresolv) printf '%s\n' "$UCI_NORESOLV" ;;
				dhcp.@dnsmasq\[0\].resolvfile) printf '%s\n' "$UCI_RESOLVFILE" ;;
				openclash-dns-guard.main.recovery_pending) [ "$SNAPSHOT_PENDING" = 1 ] || return 1; printf '1\n' ;;
				openclash-dns-guard.main.recovery_server) printf '127.0.0.1#653\n' ;;
				openclash-dns-guard.main.recovery_noresolv_set) printf '1\n' ;;
				openclash-dns-guard.main.recovery_resolvfile_set) printf '1\n' ;;
				openclash-dns-guard.main.recovery_noresolv) printf '1\n' ;;
				openclash-dns-guard.main.recovery_resolvfile) printf '/tmp/resolv.conf.auto\n' ;;
				openclash-dns-guard.main.recovery_role) printf '%s\n' "$RECOVERY_ROLE" ;;
				*) return 1 ;;
			esac
			;;
		del|delete)
			[ "$2" != openclash-dns-guard.main.recovery_pending ] || SNAPSHOT_PENDING=0
			return 0
			;;
		add_list|set|commit) return 0 ;;
		*) return 1 ;;
	esac
}
dnsmasq_reload() { RELOADS=$((RELOADS + 1)); }
ORIG_RECORDED=1
ORIG_SERVER='127.0.0.1#653 192.0.2.53'
ORIG_NORESOLV=1; ORIG_NORESOLV_SET=1
ORIG_RESOLVFILE=/tmp/resolv.conf.auto; ORIG_RESOLVFILE_SET=1
apply_primary || fail "restore UCI transaction should succeed"
case "$UCI_CALLS" in *' add_list dhcp.@dnsmasq[0].server=127.0.0.1#653'*) ;; *) fail "restore missed first server" ;; esac
case "$UCI_CALLS" in *' add_list dhcp.@dnsmasq[0].server=192.0.2.53'*) ;; *) fail "restore missed second server" ;; esac
case "$UCI_CALLS" in *' set dhcp.@dnsmasq[0].noresolv=1'*) ;; *) fail "restore missed noresolv" ;; esac
case "$UCI_CALLS" in *' set dhcp.@dnsmasq[0].resolvfile=/tmp/resolv.conf.auto'*) ;; *) fail "restore missed resolvfile" ;; esac
assert_eq "$RELOADS" 1 "restore triggers dnsmasq reload"
ok "restore writes original UCI values and reloads dnsmasq"

UCI_CALLS=""
save_orig_snapshot || fail "persistent DNS snapshot transaction should succeed"
case "$UCI_CALLS" in *' set openclash-dns-guard.main.recovery_pending=1'*) ;; *) fail "snapshot missed pending marker" ;; esac
case "$UCI_CALLS" in *' add_list openclash-dns-guard.main.recovery_server=127.0.0.1#653'*) ;; *) fail "snapshot missed original server" ;; esac
case "$UCI_CALLS" in *' set openclash-dns-guard.main.recovery_resolvfile=/tmp/resolv.conf.auto'*) ;; *) fail "snapshot missed original resolvfile" ;; esac
case "$UCI_CALLS" in *' commit openclash-dns-guard'*) ;; *) fail "snapshot was not committed before dnsmasq edit" ;; esac
ok "persistent snapshot commits before fallback changes"

load_state
assert_eq "$ROLE" fallback "reboot with snapshot must enter guarded recovery"
assert_eq "$ORIG_SERVER" '127.0.0.1#653 ' "persistent original server snapshot"
assert_eq "$ORIG_NORESOLV" 1 "persistent original noresolv snapshot"
ok "persistent snapshot recovers after volatile state loss"

UCI_SERVERS='127.0.0.1#653'
UCI_NORESOLV=1
UCI_RESOLVFILE=/tmp/resolv.conf.auto
load_state
assert_eq "$ROLE" primary "already restored UCI and runtime settings should clear stale snapshot"
assert_eq "$SNAPSHOT_PENDING" 0 "stale recovery marker cleared after verified original config"

SNAPSHOT_PENDING=1
RECOVERY_ROLE=wan
UCI_SERVERS=''
UCI_NORESOLV=0
UCI_RESOLVFILE=/tmp/resolv.conf.d/resolv.conf.auto
load_state
assert_eq "$ROLE" wan "crash while on WAN fallback must resume WAN mode"

SNAPSHOT_PENDING=0
UCI_SERVERS='127.0.0.1#953'
load_state
assert_eq "$ROLE" fallback "fallback DNS without a snapshot must not look healthy"
assert_eq "$ORIG_RECORDED" 0 "missing snapshot must not invent an original upstream"
ok "legacy fallback without snapshot fails closed"

# ---- 2026-11-23 现网回归：快照污染导致静默永久降级 / wan 兜底用了死 DNS ----

# wan 模式不能依赖运营商下发的 DNS（实测 218.4.4.4 / 218.2.2.2 全无响应）  # yunwrt-scan: allow-public-ip
UCI_CALLS=""
RELOADS=0
UCI_SERVERS=''
apply_wan || fail "wan apply should succeed"
case "$UCI_CALLS" in *' add_list dhcp.@dnsmasq[0].server=223.5.5.5'*) ;; *) fail "wan apply missed built-in resolver" ;; esac  # yunwrt-scan: allow-public-ip
case "$UCI_CALLS" in *' add_list dhcp.@dnsmasq[0].server=114.114.114.114'*) ;; *) fail "wan apply missed third built-in resolver" ;; esac  # yunwrt-scan: allow-public-ip
case "$UCI_CALLS" in *' set dhcp.@dnsmasq[0].noresolv=1'*) ;; *) fail "wan apply missed noresolv" ;; esac
case "$UCI_CALLS" in *' set dhcp.@dnsmasq[0].resolvfile='*) fail "wan apply must not depend on resolv.conf.auto" ;; esac
assert_eq "$RELOADS" 1 "wan apply triggers dnsmasq reload"
ok "wan apply uses built-in CN resolvers"

UCI_SERVERS='223.5.5.5 223.6.6.6 114.114.114.114'  # yunwrt-scan: allow-public-ip
wan_servers_ok || fail "intact wan upstream list must be accepted"
UCI_SERVERS='223.5.5.5 223.6.6.6'  # yunwrt-scan: allow-public-ip
wan_servers_ok && fail "wan upstream drift must be detected"
ok "wan mode detects upstream drift"

# clear_orig_snapshot 必须连内存快照一起复位：否则 save_state 把 ORIG_RECORDED=1
# 固化下去，record_orig 的短路会让"原值"永远不再刷新（现网 ORIG_SERVER 曾被固化成
# 127.0.0.1#953）。
ORIG_RECORDED=1
ORIG_SERVER='127.0.0.1#953'
ORIG_NORESOLV=1; ORIG_NORESOLV_SET=1
ORIG_RESOLVFILE=''; ORIG_RESOLVFILE_SET=0
clear_orig_snapshot >/dev/null 2>&1
assert_eq "$ORIG_RECORDED" 0 "clearing snapshot must reset ORIG_RECORDED"
assert_eq "$ORIG_SERVER" "" "clearing snapshot must drop the stale original server"
assert_eq "$ORIG_NORESOLV_SET" 0 "clearing snapshot must reset presence flags"
ok "clearing snapshot resets the in-memory original"

# 原值本身等于兜底端口时必须拒绝恢复，而不是把 dnsmasq 永久钉在 953 上并判"已恢复"
ORIG_RECORDED=1
ORIG_SERVER='127.0.0.1#953'
ORIG_NORESOLV=1; ORIG_NORESOLV_SET=1
FALLBACK_PORT=953
apply_primary && fail "snapshot pointing at the fallback port must be refused"
ok "fallback-port snapshot is refused instead of pinning dnsmasq"

printf 'PASS: dns-guard unit checks\n'

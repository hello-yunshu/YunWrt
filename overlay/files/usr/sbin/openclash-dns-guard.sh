#!/bin/sh
# openclash-dns-guard.sh
# 在 OpenClash 核心(端口 653)无响应时，把 dnsmasq 上游临时切到 mosdns(953)，
# 保证全网 DNS 不断；恢复后按降级前记录的原值切回。状态翻转时通过 Bark 推送。
#
# 只改 dhcp 的 UCI 配置，不修改 /etc/init.d/openclash 与 /usr/share/openclash/ 下任何文件。
# Maintenance API: this long-lived transaction process calls --maintenance-begin ID TTL,
# then --maintenance-end ID from the same PID. The lease never survives its owner or reboot.

STATE_FILE="/var/run/openclash-dns-guard.state"
QUEUE_FILE="/var/run/openclash-dns-guard.queue"
CFG="openclash-dns-guard.main"
LEASE_FILE="/var/run/openclash-dns-guard.maintenance"
LEASE_MAX_SECONDS=180
LOG_DIR="/yunshu/openwrt-maintenance"
LOG_MAX=262144
# 开机宽限期只延后告警；真实故障的降级时限不受它影响。
BOOT_GRACE=90
# 恢复失败告警的最小间隔，避免每轮都推送。
RESTORE_ALERT_GAP=300
DEGRADE_HARD_MAX=140
# wan 模式（653 与 953 同时不可用）使用的硬编码国内递归。见 apply_wan 的注释。
WAN_FALLBACK_SERVERS="223.5.5.5 223.6.6.6 114.114.114.114"

LOG_FILE="/var/log/openclash-dns-guard.log"
LOG_FALLBACK=""
EXITING=0
WD_STOPPED=""
SLEEP_PID=""

# ---------------- 配置 ----------------
cfg() {
	_cfgv=$(uci -q get "$CFG.$1" 2>/dev/null)
	[ -n "$_cfgv" ] || _cfgv="$2"
	printf '%s\n' "$_cfgv"
}

load_cfg() {
	BARK_KEY=$(uci -q get "$CFG.bark_key" 2>/dev/null)
	BARK_GROUP=$(cfg bark_group openwrt)
	NOTIFY_FB=$(cfg notify_on_fallback 1)
	NOTIFY_RC=$(cfg notify_on_recover 1)
	NOTIFY_SV=$(cfg notify_on_severe 1)
	INTERVAL=$(cfg probe_interval 15)
	PRIMARY_PORT=$(cfg primary_port 653)
	FALLBACK_PORT=$(cfg fallback_port 953)
	SUSPEND_WD=$(cfg suspend_watchdog 1)
	ALERT_AFTER=$(cfg alert_after 90)
	DEGRADE_AFTER=$(cfg degrade_after 180)
	NOTIFY_COOLDOWN=$(cfg notify_cooldown 300)
	MANAGE_RULE=$(cfg manage_ip_rule 1)
	MARK=$(cfg ip_rule_mark 0x162)
	TABLE=$(cfg ip_rule_table 0x162)
	PREF=$(cfg ip_rule_pref 1888)
	TABLE_DEC=$((TABLE))
	case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=15 ;; esac
	[ "$INTERVAL" -lt 5 ] && INTERVAL=5
	[ "$INTERVAL" -gt 15 ] && INTERVAL=15
	case "$ALERT_AFTER" in ''|*[!0-9]*) ALERT_AFTER=90 ;; esac
	case "$DEGRADE_AFTER" in ''|*[!0-9]*) DEGRADE_AFTER=180 ;; esac
	case "$NOTIFY_COOLDOWN" in ''|*[!0-9]*) NOTIFY_COOLDOWN=300 ;; esac
	[ "$DEGRADE_AFTER" -lt 1 ] && DEGRADE_AFTER=1
	[ "$DEGRADE_AFTER" -gt "$DEGRADE_HARD_MAX" ] && DEGRADE_AFTER="$DEGRADE_HARD_MAX"
	[ "$ALERT_AFTER" -gt "$DEGRADE_AFTER" ] && ALERT_AFTER="$DEGRADE_AFTER"
	return 0
}

uptime_seconds() {
	cut -d. -f1 /proc/uptime 2>/dev/null
}

boot_id() {
	cat /proc/sys/kernel/random/boot_id 2>/dev/null
}

proc_start_ticks() {
	[ -r "/proc/$1/stat" ] || return 1
	_proc_tail=$(sed 's/^[^)]*) //' "/proc/$1/stat") || return 1
	_proc_state=$(printf '%s\n' "$_proc_tail" | awk '{print $1}')
	case "$_proc_state" in Z|X) return 1 ;; esac
	printf '%s\n' "$_proc_tail" | awk '{print $20}'
}

lease_owner_alive() {
	[ -n "$1" ] && [ -n "$2" ] || return 1
	[ "$(proc_start_ticks "$1" 2>/dev/null)" = "$2" ]
}

lease_clear() {
	rm -f "$LEASE_FILE" "${LEASE_FILE}.tmp.$$" 2>/dev/null
}

maintenance_begin() {
	_id=$1; _ttl=$2; _owner=${PPID:-0}
	case "$_id" in ''|*[!A-Za-z0-9._:-]*) echo "invalid maintenance transaction id" >&2; return 2 ;; esac
	[ "${#_id}" -le 96 ] || { echo "maintenance transaction id too long" >&2; return 2; }
	case "$_ttl" in ''|*[!0-9]*) echo "invalid maintenance lease duration" >&2; return 2 ;; esac
	[ "$_ttl" -gt 0 ] && [ "$_ttl" -le "$LEASE_MAX_SECONDS" ] || {
		echo "maintenance lease must be 1..${LEASE_MAX_SECONDS}s" >&2; return 2;
	}
	_owner_start=$(proc_start_ticks "$_owner") || { echo "maintenance owner is not a live process" >&2; return 2; }
	_boot=$(boot_id); _now=$(uptime_seconds)
	[ -n "$_boot" ] || { echo "cannot read boot identity" >&2; return 2; }
	case "$_now" in ''|*[!0-9]*) echo "cannot read monotonic uptime" >&2; return 2 ;; esac
	if lease_read; then
		if [ "$LEASE_ID" = "$_id" ] && [ "$LEASE_OWNER" = "$_owner" ] && [ "$LEASE_OWNER_START" = "$_owner_start" ]; then return 0; fi
		echo "another maintenance transaction owns the lease" >&2; return 1
	fi
	mkdir -p "${LEASE_FILE%/*}" || return 1
	_tmp="${LEASE_FILE}.tmp.$$"
	( umask 077; printf 'id=%s\nowner=%s\nowner_start=%s\nboot=%s\nissued=%s\nexpires=%s\n' \
		"$_id" "$_owner" "$_owner_start" "$_boot" "$_now" "$((_now + _ttl))" > "$_tmp" ) || return 1
	mv -f "$_tmp" "$LEASE_FILE"
}

maintenance_end() {
	_id=$1; _owner=${PPID:-0}
	case "$_id" in ''|*[!A-Za-z0-9._:-]*) echo "invalid maintenance transaction id" >&2; return 2 ;; esac
	lease_read || { lease_clear; echo "maintenance lease is absent or expired" >&2; return 1; }
	[ "$LEASE_ID" = "$_id" ] && [ "$LEASE_OWNER" = "$_owner" ] &&
		[ "$LEASE_OWNER_START" = "$(proc_start_ticks "$_owner" 2>/dev/null)" ] || {
		echo "maintenance lease owner or transaction mismatch" >&2; return 1;
	}
	lease_clear
}

lease_read() {
	LEASE_ID=""; LEASE_OWNER=""; LEASE_OWNER_START=""; LEASE_BOOT=""; LEASE_ISSUED=""; LEASE_EXPIRES=""
	[ -f "$LEASE_FILE" ] || return 1
	while IFS='=' read -r _key _value; do
		case "$_key" in
		id) LEASE_ID=$_value ;; owner) LEASE_OWNER=$_value ;;
		owner_start) LEASE_OWNER_START=$_value ;; boot) LEASE_BOOT=$_value ;;
		issued) LEASE_ISSUED=$_value ;; expires) LEASE_EXPIRES=$_value ;;
		esac
	done < "$LEASE_FILE"
	case "$LEASE_OWNER:$LEASE_OWNER_START:$LEASE_ISSUED:$LEASE_EXPIRES" in *[!0-9:]*) return 1 ;; esac
	[ -n "$LEASE_ID" ] && [ -n "$LEASE_BOOT" ] || return 1
	[ "$LEASE_BOOT" = "$(boot_id)" ] || return 1
	LEASE_NOW=$(uptime_seconds)
	case "$LEASE_NOW" in ''|*[!0-9]*) return 1 ;; esac
	[ "$LEASE_EXPIRES" -gt "$LEASE_NOW" ] || return 1
	[ "$LEASE_EXPIRES" -gt "$LEASE_ISSUED" ] || return 1
	[ $((LEASE_EXPIRES - LEASE_ISSUED)) -le "$LEASE_MAX_SECONDS" ] || return 1
	lease_owner_alive "$LEASE_OWNER" "$LEASE_OWNER_START" || return 1
	return 0
}

maintenance_active() {
	if lease_read; then return 0; fi
	[ ! -e "$LEASE_FILE" ] || lease_clear
	return 1
}

fault_action() {
	_fa_primary_fails=$1; _fa_fallback_fails=$2; _fa_age=$3; _fa_lease=$4
	[ "$_fa_primary_fails" -ge 2 ] || { printf 'wait\n'; return; }
	if [ "$_fa_fallback_fails" -ge 2 ]; then
		printf 'wan\n'
	elif [ "$_fa_age" -ge "$DEGRADE_AFTER" ]; then
		printf 'fallback\n'
	elif [ "$_fa_age" -ge "$ALERT_AFTER" ] && [ "$_fa_lease" != "1" ]; then
		printf 'alert\n'
	else
		printf 'wait\n'
	fi
}

# ---------------- 日志 ----------------
writable_dir() {
	[ -d "$1" ] || return 1
	_wt="$1/.ocdg-write.$$"
	( umask 077; : > "$_wt" ) 2>/dev/null || return 1
	rm -f "$_wt" 2>/dev/null
	return 0
}

setup_log() {
	# 外接盘可能在也可能不在：先挑一个确定可写的回退目录，能写 /yunshu 时再切过去。
	for _wd in /var/log /tmp; do
		if writable_dir "$_wd"; then
			LOG_FALLBACK="$_wd/openclash-dns-guard.log"
			break
		fi
	done
	[ -n "$LOG_FALLBACK" ] || LOG_FALLBACK="/dev/null"
	LOG_FILE="$LOG_FALLBACK"
	if grep -q " /yunshu " /proc/mounts 2>/dev/null; then
		mkdir -p "$LOG_DIR" 2>/dev/null
		writable_dir "$LOG_DIR" && LOG_FILE="$LOG_DIR/openclash-dns-guard.log"
	fi
	if [ -f "$LOG_FILE" ]; then
		SZ=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
		[ "$SZ" -gt "$LOG_MAX" ] && mv -f "$LOG_FILE" "$LOG_FILE.1"
	fi
}

log() {
	TS=$(date "+%Y-%m-%d %H:%M:%S")
	logger -t openclash-dns-guard "$*" 2>/dev/null
	if ! printf '%s [%s] %s\n' "$TS" "$$" "$*" >> "$LOG_FILE" 2>/dev/null; then
		# 盘被拔掉等情况：退回启动时选好的可写路径，至少别再静默丢日志。
		if [ -n "$LOG_FALLBACK" ] && [ "$LOG_FILE" != "$LOG_FALLBACK" ]; then
			LOG_FILE="$LOG_FALLBACK"
			printf '%s [%s] %s\n' "$TS" "$$" "$*" >> "$LOG_FILE" 2>/dev/null
		fi
	fi
}

# ---------------- 状态 ----------------
load_state() {
	ROLE="primary"; OK_CNT=0; FAIL_CNT=0; P953_FAIL_CNT=0; LAST_SWITCH=0; FAIL_SINCE=0; FAIL_SINCE_UP=0
	FB_COUNT=0; FB_START=0; FB_START_STR=""
	ORIG_RECORDED=0; ORIG_SERVER=""; ORIG_NORESOLV=""; ORIG_RESOLVFILE=""
	ORIG_NORESOLV_SET=0; ORIG_RESOLVFILE_SET=0; INCIDENT_ID=""; ALERT_SENT=0
	LAST_NOTIFY_KIND=""; LAST_NOTIFY_TS=0; NOTIFIED_KEYS=""
	WD_STOPPED=""; RESTORE_FAIL_TS=0
	P653=0; P953=0; LAST_DRAIN=0
	# shellcheck disable=SC1090
	[ -f "$STATE_FILE" ] && . "$STATE_FILE"
	# 兼容旧 state：旧版本没有 ORIG_RECORDED 字段，但有 ORIG_SERVER 就说明记过原值。
	if [ "$ORIG_RECORDED" != "1" ] && [ -n "$ORIG_SERVER" ]; then
		ORIG_RECORDED=1
	fi
	if [ "$FAIL_SINCE" != "0" ] && [ "$FAIL_SINCE_UP" = "0" ]; then
		_LEGACY_AGE=$(($(date +%s) - FAIL_SINCE))
		[ "$_LEGACY_AGE" -lt 0 ] && _LEGACY_AGE=0
		[ "$_LEGACY_AGE" -gt "$DEGRADE_HARD_MAX" ] && _LEGACY_AGE="$DEGRADE_HARD_MAX"
		FAIL_SINCE_UP=$(($(uptime_seconds) - _LEGACY_AGE))
		[ "$FAIL_SINCE_UP" -lt 0 ] && FAIL_SINCE_UP=0
	fi
	if [ "$(uci -q get "$CFG.recovery_pending" 2>/dev/null)" = "1" ]; then
		if ! load_orig_snapshot; then
			ROLE="fallback"
			log "persistent original DNS snapshot is malformed; refusing to guess a restore target"
			return 0
		fi
		if original_settings_match; then
			clear_orig_snapshot
			ROLE="primary"
			log "persistent snapshot confirms original DNS settings are already restored"
		else
			_RECOVERY_ROLE=$(uci -q get "$CFG.recovery_role" 2>/dev/null)
			case "$_RECOVERY_ROLE" in fallback|wan) ROLE=$_RECOVERY_ROLE ;; *) has_srv "$FALLBACK_PORT" && ROLE=fallback || ROLE=wan ;; esac
			FAIL_CNT=0; OK_CNT=0; FAIL_SINCE=0; FAIL_SINCE_UP=0; ALERT_SENT=0
			log "persistent original DNS snapshot found; entering $ROLE recovery mode"
		fi
	elif [ ! -f "$STATE_FILE" ] && has_srv "$FALLBACK_PORT"; then
		ROLE="fallback"
		log "volatile state was lost while dnsmasq still points at fallback; original settings unavailable, refusing to guess"
	fi
}

save_state() {
	TMP="${STATE_FILE}.tmp"
	{
		echo "ROLE=$ROLE"
		echo "OK_CNT=$OK_CNT"
		echo "FAIL_CNT=$FAIL_CNT"
		echo "P953_FAIL_CNT=$P953_FAIL_CNT"
		echo "LAST_SWITCH=$LAST_SWITCH"
		echo "FAIL_SINCE=$FAIL_SINCE"
		echo "FAIL_SINCE_UP=$FAIL_SINCE_UP"
		echo "FB_COUNT=$FB_COUNT"
		echo "FB_START=$FB_START"
		echo "FB_START_STR=\"$FB_START_STR\""
		echo "ORIG_RECORDED=$ORIG_RECORDED"
		echo "ORIG_SERVER=\"$ORIG_SERVER\""
		echo "ORIG_NORESOLV=\"$ORIG_NORESOLV\""
		echo "ORIG_RESOLVFILE=\"$ORIG_RESOLVFILE\""
		echo "ORIG_NORESOLV_SET=$ORIG_NORESOLV_SET"
		echo "ORIG_RESOLVFILE_SET=$ORIG_RESOLVFILE_SET"
		echo "INCIDENT_ID=\"$INCIDENT_ID\""
		echo "ALERT_SENT=$ALERT_SENT"
		echo "LAST_NOTIFY_KIND=\"$LAST_NOTIFY_KIND\""
		echo "LAST_NOTIFY_TS=$LAST_NOTIFY_TS"
		echo "NOTIFIED_KEYS=\"$NOTIFIED_KEYS\""
		echo "WD_STOPPED=\"$WD_STOPPED\""
		echo "RESTORE_FAIL_TS=$RESTORE_FAIL_TS"
		echo "P653=$P653"
		echo "P953=$P953"
	} > "$TMP" 2>/dev/null && mv -f "$TMP" "$STATE_FILE"
}

# ---------------- 探测 ----------------
# 真实解析，不看进程。返回值 0=健康
probe() {
	nslookup -port="$1" -timeout=2 github.com 127.0.0.1 >/dev/null 2>&1
}

# ---------------- Bark ----------------
json_esc() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r'
}

bark_raw() {
	# $1=title $2=body $3=level
	# 返回 0=已送达 1=发送失败 2=未配置（不重试）
	if [ -z "$BARK_KEY" ]; then
		log "bark: bark_key empty in /etc/config/openclash-dns-guard, NOT sending: $1"
		return 2
	fi
	BT=$(json_esc "$1"); BB=$(json_esc "$2")
	PAYLOAD="{\"title\":\"$BT\",\"body\":\"$BB\",\"group\":\"$(json_esc "$BARK_GROUP")\",\"level\":\"${3:-timeSensitive}\"}"
	RESP=$(curl -sS --max-time 5 -X POST "https://api.day.app/$BARK_KEY" \
		-H "Content-Type: application/json; charset=utf-8" -d "$PAYLOAD" 2>&1)
	RC=$?
	if [ "$RC" = "0" ] && echo "$RESP" | grep -q '"code":200'; then
		log "bark ok: $1"
		return 0
	fi
	log "bark FAILED rc=$RC resp=$RESP"
	return 1
}

enqueue() {
	# $1=title $2=body $3=level
	printf '%s|%s|%s|%s\n' "$1" "$2" "${3:-timeSensitive}" "$(date "+%Y-%m-%d %H:%M:%S")" >> "$QUEUE_FILE" 2>/dev/null
	log "alert queued for later delivery: $1"
}

bark() {
	# 发送失败则入队，不阻塞主流程；配置缺失是明确错误，不入队（否则永远发不出去）
	bark_raw "$1" "$2" "$3"
	BRC=$?
	case "$BRC" in
	0) ;;
	2) ;;
	*) enqueue "$1" "$2" "$3" ;;
	esac
}

notify_event() {
	_ne_kind=$1; _ne_title=$2; _ne_body=$3; _ne_level=${4:-timeSensitive}
	[ -n "$INCIDENT_ID" ] || INCIDENT_ID="$(boot_id)-$NOW"
	_ne_key="${INCIDENT_ID}.${_ne_kind}"
	case " $NOTIFIED_KEYS " in *" $_ne_key "*) log "notification deduplicated incident=$_ne_key"; return 0 ;; esac
	if [ "$LAST_NOTIFY_KIND" = "$_ne_kind" ] &&
		[ $((NOW - LAST_NOTIFY_TS)) -lt "$NOTIFY_COOLDOWN" ]; then
		log "notification cooldown suppressed incident=$_ne_key"
		return 0
	fi
	NOTIFIED_KEYS="$NOTIFIED_KEYS $_ne_key"
	LAST_NOTIFY_KIND="$_ne_kind"; LAST_NOTIFY_TS=$NOW
	bark "$_ne_title" "$_ne_body" "$_ne_level"
}

# 只在 653 可用（走代理）时补发：clash 死时境外流量被 TUN 黑洞，发了也白发
drain_queue() {
	[ -s "$QUEUE_FILE" ] || return 0
	: > "${QUEUE_FILE}.tmp"
	while IFS='|' read -r QT QB QL QTS; do
		[ -z "$QT" ] && continue
		bark_raw "$QT" "$QB（原始告警时间 $QTS，因代理中断延迟送达）" "$QL"
		QRC=$?
		case "$QRC" in
		0) log "queued alert delivered: $QT" ;;
		2) log "queued alert dropped (bark_key missing): $QT" ;;
		*) printf '%s|%s|%s|%s\n' "$QT" "$QB" "$QL" "$QTS" >> "${QUEUE_FILE}.tmp" ;;
		esac
	done < "$QUEUE_FILE"
	mv -f "${QUEUE_FILE}.tmp" "$QUEUE_FILE" 2>/dev/null
}

# ---------------- dnsmasq 操作 ----------------
dnsmasq_servers() { uci -q get dhcp.@dnsmasq[0].server 2>/dev/null; }
has_srv() { dnsmasq_servers | grep -q "$1"; }

# wan 模式是否仍然是我们要的那组上游。只比对 uci，不去读 dnsmasq 的生成配置：
# reload 有延迟，读生成配置会在每轮巡检里误判成"被外部改回"从而反复重写。
wan_servers_ok() {
	_wv=$(dnsmasq_servers)
	for _ws in $WAN_FALLBACK_SERVERS; do
		case " ${_wv} " in *" ${_ws} "*) ;; *) return 1 ;; esac
	done
	return 0
}

# dnsmasq 实际加载的生成配置（reload 会重建它），用于回读校验
dnsmasq_effective_servers() {
	for _ef in /var/etc/dnsmasq.conf.cfg*; do
		[ -f "$_ef" ] || continue
		sed -n 's/^server=//p' "$_ef"
	done
}

dnsmasq_reload() {
	/etc/init.d/dnsmasq reload >/dev/null 2>&1
}

servers_match() {
	_want=$(for _ws in $1; do printf '%s\n' "$_ws"; done | sort -u)
	_have=$(dnsmasq_effective_servers | sort -u)
	[ "$_want" = "$_have" ]
}

original_settings_match() {
	_want=$(for _os in $ORIG_SERVER; do printf '%s\n' "$_os"; done | sort -u)
	_have=$(dnsmasq_servers | sort -u)
	[ "$_want" = "$_have" ] &&
		option_presence_matches "$ORIG_NORESOLV_SET" noresolv &&
		option_presence_matches "$ORIG_RESOLVFILE_SET" resolvfile &&
		[ "$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null)" = "$ORIG_NORESOLV" ] &&
		[ "$(uci -q get dhcp.@dnsmasq[0].resolvfile 2>/dev/null)" = "$ORIG_RESOLVFILE" ] &&
		servers_match "$ORIG_SERVER"
}

record_orig() {
	[ "$ORIG_RECORDED" = "1" ] && return
	ORIG_SERVER=$(dnsmasq_servers)
	ORIG_NORESOLV=$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null)
	uci_option_is_set noresolv && ORIG_NORESOLV_SET=1 || ORIG_NORESOLV_SET=0
	ORIG_RESOLVFILE=$(uci -q get dhcp.@dnsmasq[0].resolvfile 2>/dev/null)
	uci_option_is_set resolvfile && ORIG_RESOLVFILE_SET=1 || ORIG_RESOLVFILE_SET=0
	if ! save_orig_snapshot; then
		log "cannot persist original DNS snapshot; refusing to change dnsmasq"
		return 1
	fi
	ORIG_RECORDED=1
	log "recorded original: server=[$ORIG_SERVER] noresolv=[$ORIG_NORESOLV] resolvfile=[$ORIG_RESOLVFILE]"
}

uci_option_is_set() {
	uci -q get "dhcp.@dnsmasq[0].$1" >/dev/null 2>&1
}

option_presence_matches() {
	if [ "$1" = "1" ]; then uci_option_is_set "$2"; else ! uci_option_is_set "$2"; fi
}

save_orig_snapshot() {
	uci -q delete "$CFG.recovery_server"
	for _v in $ORIG_SERVER; do uci -q add_list "$CFG.recovery_server=$_v" || return 1; done
	uci -q set "$CFG.recovery_pending=1" || return 1
	uci -q set "$CFG.recovery_noresolv_set=$ORIG_NORESOLV_SET" || return 1
	uci -q set "$CFG.recovery_resolvfile_set=$ORIG_RESOLVFILE_SET" || return 1
	uci -q delete "$CFG.recovery_noresolv"
	uci -q delete "$CFG.recovery_resolvfile"
	[ "$ORIG_NORESOLV_SET" != "1" ] || uci -q set "$CFG.recovery_noresolv=$ORIG_NORESOLV" || return 1
	[ "$ORIG_RESOLVFILE_SET" != "1" ] || uci -q set "$CFG.recovery_resolvfile=$ORIG_RESOLVFILE" || return 1
	uci -q set "$CFG.recovery_role=prepared" || return 1
	uci -q commit openclash-dns-guard
}

load_orig_snapshot() {
	ORIG_SERVER=$(uci -q get "$CFG.recovery_server" 2>/dev/null | tr '\n' ' ')
	ORIG_NORESOLV_SET=$(uci -q get "$CFG.recovery_noresolv_set" 2>/dev/null)
	ORIG_RESOLVFILE_SET=$(uci -q get "$CFG.recovery_resolvfile_set" 2>/dev/null)
	ORIG_NORESOLV=$(uci -q get "$CFG.recovery_noresolv" 2>/dev/null)
	ORIG_RESOLVFILE=$(uci -q get "$CFG.recovery_resolvfile" 2>/dev/null)
	case "$ORIG_NORESOLV_SET:$ORIG_RESOLVFILE_SET" in 0:0|0:1|1:0|1:1) ;; *) return 1 ;; esac
	ORIG_RECORDED=1
}

clear_orig_snapshot() {
	uci -q delete "$CFG.recovery_pending"
	uci -q delete "$CFG.recovery_server"
	uci -q delete "$CFG.recovery_noresolv_set"
	uci -q delete "$CFG.recovery_resolvfile_set"
	uci -q delete "$CFG.recovery_noresolv"
	uci -q delete "$CFG.recovery_resolvfile"
	uci -q delete "$CFG.recovery_role"
	uci -q commit openclash-dns-guard
	# 必须同时把内存快照一起复位，否则 save_state 会把 ORIG_RECORDED=1 连同
	# ORIG_SERVER 持久化下去；而 record_orig 的第一行是「已记录就直接返回」，
	# 下次降级就再也不刷新原值了。现网出现过这个后果：ORIG_SERVER 被固化成
	# 127.0.0.1#953，恢复时把 dnsmasq 指向兜底端口，verify_restore 还判成功，
	# 于是永久停在 fallback 上游而 ROLE 显示 primary。
	reset_orig_snapshot
}

reset_orig_snapshot() {
	ORIG_RECORDED=0
	ORIG_SERVER=""
	ORIG_NORESOLV=""
	ORIG_RESOLVFILE=""
	ORIG_NORESOLV_SET=0
	ORIG_RESOLVFILE_SET=0
}

persist_recovery_role() {
	case "$1" in fallback|wan|prepared) ;; *) return 1 ;; esac
	uci -q set "$CFG.recovery_role=$1" && uci -q commit openclash-dns-guard
}

# 按 record_orig 记下的原值回填；原值缺失或非法时明确失败，不猜 653。
apply_primary() {
	if [ "$ORIG_RECORDED" != "1" ]; then
		log "restore FAILED: original dnsmasq settings were never recorded, refusing to guess"
		return 1
	fi
	# 原值等于我们自己的兜底上游，说明这份快照是在降级状态下拍的（历史 bug：
	# ORIG_RECORDED 未复位，沿用旧值）。照它"恢复"等于把 dnsmasq 永久钉在
	# fallback 上，而且 verify_restore 会因为期望值本身就是兜底值而判成功。
	for _ps in $ORIG_SERVER; do
		if [ "$_ps" = "127.0.0.1#${FALLBACK_PORT}" ]; then
			log "restore FAILED: recorded original upstream [$ORIG_SERVER] equals the fallback port, refusing to pin dnsmasq to ${FALLBACK_PORT}"
			return 1
		fi
	done
	case "$ORIG_NORESOLV" in
	''|0|1) ;;
	*)
		log "restore FAILED: recorded noresolv=[$ORIG_NORESOLV] is invalid"
		return 1
		;;
	esac

	uci -q del dhcp.@dnsmasq[0].server
	for _os in $ORIG_SERVER; do
		uci -q add_list dhcp.@dnsmasq[0].server="$_os"
	done
	if [ "$ORIG_NORESOLV_SET" = "1" ]; then
		uci -q set dhcp.@dnsmasq[0].noresolv="$ORIG_NORESOLV"
	else
		uci -q delete dhcp.@dnsmasq[0].noresolv
	fi
	if [ "$ORIG_RESOLVFILE_SET" = "1" ]; then
		uci -q set dhcp.@dnsmasq[0].resolvfile="$ORIG_RESOLVFILE"
	else
		uci -q delete dhcp.@dnsmasq[0].resolvfile
	fi
	if ! uci -q commit dhcp; then
		log "restore FAILED: uci commit dhcp"
		return 1
	fi
	dnsmasq_reload
	return 0
}

apply_fallback() {
	uci -q del dhcp.@dnsmasq[0].server
	uci -q add_list dhcp.@dnsmasq[0].server="127.0.0.1#$FALLBACK_PORT"
	uci -q set dhcp.@dnsmasq[0].noresolv='1'
	uci -q commit dhcp || return 1
	dnsmasq_reload
}

apply_wan() {
	# 不用 /tmp/resolv.conf.d/resolv.conf.auto：那里面是 PPPoE 下发的运营商 DNS，
	# 实测这台线路上 218.4.4.4 / 218.2.2.2 连续 6 次全部无响应。切过去等于把全网
	# DNS 从"还能解析"变成"彻底解析不了"，而 wan 是最后一级兜底，没有下一级了。
	# 因此硬编码一组实测可用的国内递归（223.5.5.5 27-31ms / 223.6.6.6 28ms /
	# 114.114.114.114 14ms）。
	uci -q del dhcp.@dnsmasq[0].server
	for _ws in $WAN_FALLBACK_SERVERS; do
		uci -q add_list dhcp.@dnsmasq[0].server="$_ws"
	done
	uci -q set dhcp.@dnsmasq[0].noresolv='1'
	uci -q delete dhcp.@dnsmasq[0].resolvfile
	uci -q commit dhcp || return 1
	dnsmasq_reload
}

# 写回 → reload → 回读生成配置 → 与原始值比对（顺序无关）
verify_restore() {
	_vi=0
	while [ "$_vi" -lt 3 ]; do
		if servers_match "$ORIG_SERVER" &&
			option_presence_matches "$ORIG_NORESOLV_SET" noresolv &&
			option_presence_matches "$ORIG_RESOLVFILE_SET" resolvfile &&
			[ "$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null)" = "$ORIG_NORESOLV" ] &&
			[ "$(uci -q get dhcp.@dnsmasq[0].resolvfile 2>/dev/null)" = "$ORIG_RESOLVFILE" ]; then
			return 0
		fi
		_vi=$((_vi+1))
		[ "$_vi" -lt 3 ] && sleep 1
	done
	return 1
}

# 降级期间挂起 OpenClash watchdog：它每 60s 会把上游改回 653，且 OpenClash 重启后会换 pid。
# 用 SIGSTOP 而不是 TERM：procd 仍认为实例存活、不会拉起新进程，进程状态也保留，
# 恢复时 SIGCONT 即可。每轮巡检会把“后来才出现的”新 pid 一并停住。
watchdog_pids() {
	pgrep -f "openclash_watchdog.sh" 2>/dev/null
}

watchdog_alive() {
	[ -n "$1" ] && [ -r "/proc/$1/cmdline" ] &&
		tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q "openclash_watchdog.sh"
}

suspend_watchdog() {
	[ "$SUSPEND_WD" = "1" ] || return 0
	for p in $(watchdog_pids); do
		[ "$p" = "$$" ] && continue
		case " $WD_STOPPED " in *" $p "*) continue ;; esac
		kill -STOP "$p" 2>/dev/null || continue
		_ST=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null)
		if [ "$_ST" = "T" ]; then
			WD_STOPPED="$WD_STOPPED $p"
			log "suspended openclash watchdog pid=$p (SIGSTOP)"
		else
			log "suspend watchdog pid=$p INEFFECTIVE (state=$_ST), will retry"
		fi
	done
}

resume_watchdog() {
	[ -n "$WD_STOPPED" ] || return 0
	for p in $WD_STOPPED; do
		watchdog_alive "$p" || continue
		kill -CONT "$p" 2>/dev/null && log "resumed openclash watchdog pid=$p (SIGCONT)"
	done
	WD_STOPPED=""
	# 立刻落盘：否则 procd 重拉后新进程会以为这些 pid 还停着而不再补停
	save_state
}

# ---------------- 策略路由（方案 2：只摘一条 ip rule） ----------------
# mark 与 nft 链保持不动，只移除 fwmark 0x162 -> table 354 的规则。
# 移除后打标流量落到 main 表，走 pppoe-wan 直连；不再进 utun（clash 假死时那里是黑洞）。
rule_present() {
	ip rule show 2>/dev/null | grep -q "fwmark $MARK lookup $TABLE_DEC"
}

table_ready() {
	ip route show table "$TABLE_DEC" 2>/dev/null | grep -q "^default"
}

rule_del() {
	[ "$MANAGE_RULE" = "1" ] || return 0
	if rule_present; then
		ip rule del fwmark "$MARK" table "$TABLE" pref "$PREF" 2>/dev/null \
			|| ip rule del fwmark "$MARK" table "$TABLE" 2>/dev/null
		if rule_present; then
			log "ip rule remove FAILED: fwmark $MARK lookup $TABLE_DEC still present"
		else
			log "ip rule removed: fwmark $MARK lookup $TABLE_DEC (marked traffic now follows main -> direct WAN)"
		fi
	else
		: # 已不存在：幂等，不重复记日志
	fi
}

rule_add() {
	[ "$MANAGE_RULE" = "1" ] || return 0
	if rule_present; then
		return 0   # 已存在：幂等，不重复记日志
	fi
	if ! table_ready; then
		return 0   # utun 还没建好，跳过（避免把流量导进不存在的表）
	fi
	ip rule add fwmark "$MARK" table "$TABLE" pref "$PREF" 2>/dev/null
	if rule_present; then
		log "ip rule restored: fwmark $MARK lookup $TABLE_DEC pref $PREF"
	else
		log "ip rule add FAILED: fwmark $MARK lookup $TABLE_DEC"
	fi
}

# ---------------- 切换 ----------------
# 恢复失败：保持降级，不切换角色，不发送“已恢复”。
restore_failed() {
	case " $(dnsmasq_servers) " in
	*" 127.0.0.1#$FALLBACK_PORT "*) ;;   # 已经是降级上游，不必反复重写
	*) apply_fallback || log "restore failure fallback write also failed" ;;
	esac
	ROLE="fallback"
	persist_recovery_role fallback || log "could not persist fallback recovery role"
	rule_del
	# 失败会每轮重试，日志与告警都限流，避免刷屏
	if [ $((NOW - RESTORE_FAIL_TS)) -ge "$RESTORE_ALERT_GAP" ]; then
		RESTORE_FAIL_TS=$NOW
		log "restore FAILED ($1): staying on fallback upstream"
		[ "$NOTIFY_SV" = "1" ] && bark "OpenClash DNS 恢复失败" \
			"653 已恢复响应，但无法还原原始 dnsmasq 上游（$1）。已继续使用 mosdns(953)，请检查 /etc/config/dhcp。" timeSensitive
	fi
	save_state
}

switch_to() {
	NEW="$1"; NOW=$(date +%s)
	case "$NEW" in
	fallback)
		persist_recovery_role fallback || { log "cannot persist fallback recovery role"; return 1; }
		# 先停住会改回 653 的 watchdog，再写降级配置，减少拉锯窗口
		suspend_watchdog
		if ! apply_fallback; then
			log "fallback apply failed; retaining current dnsmasq role and retrying"
			resume_watchdog
			return 1
		fi
		rule_del
		FB_COUNT=$((FB_COUNT+1)); FB_START=$NOW
		FB_START_STR=$(date "+%Y-%m-%d %H:%M:%S")
		# 持续失败时长以第一次失败的时间戳为基准，与开机宽限期无关
		FDUR=$(($(uptime_seconds) - FAIL_SINCE_UP)); [ "$FAIL_SINCE_UP" = "0" ] && FDUR=0
		log "SWITCH primary->fallback: dnsmasq upstream = 127.0.0.1#$FALLBACK_PORT (653 failed ${FAIL_CNT}x over ${FDUR}s, 953 ok)"
		[ "$NOTIFY_FB" = "1" ] && notify_event degraded "OpenClash DNS 已降级" \
			"653 连续不可用 ${FDUR}s，已切到 mosdns(953)。fake-ip 分流暂不可用。" timeSensitive
		;;
	primary)
		# 先把策略路由加回，再切回 653，避免 fake-ip 已生效但路由还在直连
		rule_add
		if ! apply_primary; then
			restore_failed "原始上游未记录或非法"
			return 0
		fi
		if ! verify_restore; then
			restore_failed "回读值与原始值不一致: 期望 [$ORIG_SERVER]，实际 [$(dnsmasq_effective_servers | tr '\n' ' ')]"
			return 0
		fi
		resume_watchdog
		clear_orig_snapshot
		DUR=$((NOW-FB_START))
		[ "$FB_START" = "0" ] && DUR=0
		log "SWITCH ->primary: dnsmasq upstream restored (653 ok 2x) duration=${DUR}s"
		# 代理恢复后再补发降级期间积压的告警（那时境外 api.day.app 被 TUN 黑洞）
		drain_queue
		[ "$NOTIFY_RC" = "1" ] && notify_event recovered "OpenClash DNS 已恢复" \
			"已按保存的原始配置恢复 dnsmasq 上游并回读验证。故障持续 ${DUR} 秒。" timeSensitive
		FB_START=0; FB_START_STR=""
		INCIDENT_ID=""; NOTIFIED_KEYS=""; ALERT_SENT=0; FAIL_SINCE=0; P953_FAIL_CNT=0
		;;
	wan)
		persist_recovery_role wan || { log "cannot persist WAN recovery role"; return 1; }
		suspend_watchdog
		if ! apply_wan; then
			log "WAN-DNS apply failed; retaining current role and retrying"
			resume_watchdog
			return 1
		fi
		rule_del
		log "SWITCH ->wan-dns: 653 and 953 both unreachable, dnsmasq reset to built-in CN resolvers [${WAN_FALLBACK_SERVERS}]"
		[ "$NOTIFY_SV" = "1" ] && notify_event degraded "DNS 上游不可用：已回落内置国内 DNS" \
			"653 与 953 连续探测失败，已切换到内置国内 DNS（${WAN_FALLBACK_SERVERS}）。" timeSensitive
		;;
	esac
	ROLE="$NEW"; LAST_SWITCH="$NOW"; OK_CNT=0; FAIL_CNT=0; P953_FAIL_CNT=0
	FAIL_SINCE=0; FAIL_SINCE_UP=0
	save_state
}

# 检测被外部（OpenClash watchdog 或 change_dnsmasq）改回的情况
repair_if_reverted() {
	case "$ROLE" in
	fallback)
		if ! has_srv "$FALLBACK_PORT"; then
			log "dnsmasq upstream reverted externally (now=[$(dnsmasq_servers)]), re-applying fallback"
			apply_fallback
		fi
		rule_present && rule_del
		suspend_watchdog
		;;
	wan)
		if ! wan_servers_ok || [ "$(uci -q get dhcp.@dnsmasq[0].noresolv)" != "1" ]; then
			log "dnsmasq upstream reverted externally (now=[$(dnsmasq_servers)]), re-applying built-in CN resolvers"
			apply_wan
		fi
		rule_present && rule_del
		suspend_watchdog
		;;
	primary)
		# OpenClash 启动/重启会自己加回这条规则；若缺失且路由表就绪则补上
		rule_add
		# 上次退出时若留下了被挂起的 watchdog，这里恢复
		[ -n "$WD_STOPPED" ] && resume_watchdog
		;;
	esac
}

on_exit() {
	# 幂等：EXIT 与 TERM/INT 可能先后都触发
	[ "$EXITING" = "1" ] && return 0
	EXITING=1
	# 打断主循环里的 wait，让 trap 立刻返回而不是等满一个轮询周期
	[ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
	# 别把 watchdog 永久留在 STOP 状态：退出/重启时先恢复，新进程会重新巡检。
	resume_watchdog
	log "guard exiting pid=$$ role=$ROLE (procd respawn will restart)"
}

on_term() {
	on_exit
	exit 0
}
# ---------------- 主循环 ----------------
main() {
	load_cfg
	setup_log
	load_state
	trap on_exit EXIT
	trap on_term INT TERM
	log "guard start pid=$$ interval=${INTERVAL}s alert_after=${ALERT_AFTER}s degrade_after=${DEGRADE_AFTER}s role=$ROLE primary=$PRIMARY_PORT fallback=$FALLBACK_PORT suspend_watchdog=$SUSPEND_WD log_file=$LOG_FILE"
	[ -z "$BARK_KEY" ] && log "ERROR: bark_key is empty in /etc/config/openclash-dns-guard, notifications will not be delivered"
	# 上次异常退出（SIGKILL/断电）可能留下被 STOP 的 watchdog：当前不是降级态就先放行
	if [ "$ROLE" = "primary" ] && [ -n "$WD_STOPPED" ]; then
		log "releasing leftover stopped watchdog from previous run: $WD_STOPPED"
		resume_watchdog
	fi

	while :; do
		load_cfg
		P653=0; P953=0
		probe "$PRIMARY_PORT" && P653=1
		probe "$FALLBACK_PORT" && P953=1
		NOW=$(date +%s)
		UP_NOW=$(uptime_seconds)
		case "$UP_NOW" in ''|*[!0-9]*) UP_NOW=999999 ;; esac
		MAINTENANCE=0
		maintenance_active && MAINTENANCE=1

		# 每轮都校正：fallback/wan 下确保 ip rule 不在，primary 下确保在
		repair_if_reverted

		if [ "$P653" = "1" ]; then
			OK_CNT=$((OK_CNT+1)); FAIL_CNT=0
			if [ "$ROLE" = "primary" ] && [ "$FAIL_SINCE" != "0" ]; then
				case " $NOTIFIED_KEYS " in *" ${INCIDENT_ID}.alert "*) _HAD_ALERT=1 ;; *) _HAD_ALERT=0 ;; esac
				if [ "$_HAD_ALERT" = "1" ] && [ "$NOTIFY_RC" = "1" ]; then
					NOW=$(date +%s)
					notify_event recovered "OpenClash DNS 短暂故障已恢复" "653 已恢复；未发生上游切换。" timeSensitive
				fi
				FAIL_SINCE=0; FAIL_SINCE_UP=0; INCIDENT_ID=""; ALERT_SENT=0; NOTIFIED_KEYS=""; P953_FAIL_CNT=0
			fi
		else
			OK_CNT=0
			if [ "$ROLE" = "primary" ] && [ "$FAIL_SINCE" = "0" ]; then
				FAIL_SINCE=$NOW; FAIL_SINCE_UP=$UP_NOW
				INCIDENT_ID="$(boot_id)-$UP_NOW"; ALERT_SENT=0; NOTIFIED_KEYS=""
			fi
			FAIL_CNT=$((FAIL_CNT+1))
		fi
		if [ "$P953" = "1" ]; then P953_FAIL_CNT=0; else P953_FAIL_CNT=$((P953_FAIL_CNT+1)); fi

		case "$ROLE" in
		primary)
			if [ "$P653" = "0" ]; then
				FAIL_AGE=$((UP_NOW - FAIL_SINCE_UP))
				ACTION=$(fault_action "$FAIL_CNT" "$P953_FAIL_CNT" "$FAIL_AGE" "$MAINTENANCE")
				if [ "$ACTION" = "wan" ]; then
					if record_orig; then
						save_state
						switch_to wan
					else
						[ "$NOTIFY_SV" = "1" ] && notify_event snapshot-failed "DNS 故障且原始设置快照失败" "未改写 dnsmasq；无法安全创建跨重启恢复点。" timeSensitive
					fi
				elif [ "$ACTION" = "fallback" ]; then
					if record_orig; then
						save_state
						switch_to fallback
					else
						[ "$NOTIFY_SV" = "1" ] && notify_event snapshot-failed "DNS 降级被安全检查阻止" "原始配置快照失败；未改写 dnsmasq。请人工检查。" timeSensitive
					fi
				elif [ "$ACTION" = "alert" ] && [ "$ALERT_SENT" != "1" ] && [ "$UP_NOW" -ge "$BOOT_GRACE" ]; then
					ALERT_SENT=1
					log "incident alert: primary DNS unavailable for ${FAIL_AGE}s; lease_active=$MAINTENANCE"
					[ "$NOTIFY_FB" = "1" ] && notify_event alert "OpenClash DNS 主上游异常" "653 连续解析失败 ${FAIL_AGE}s，暂未切换上游；最多 ${DEGRADE_AFTER}s 后降级。" timeSensitive
					save_state
				fi
			elif [ $((NOW-LAST_DRAIN)) -ge 300 ]; then
				# 代理健康时补发历史积压告警，5 分钟最多尝试一次
				LAST_DRAIN=$NOW
				drain_queue
			fi
			;;
		fallback)
			if [ "$P653" = "1" ] && [ "$OK_CNT" -ge 2 ]; then
				switch_to primary
			elif [ "$P653" = "0" ] && [ "$P953" = "0" ]; then
				log "fallback target 953 also unreachable"
				switch_to wan
			fi
			;;
		wan)
			if [ "$P653" = "1" ] && [ "$OK_CNT" -ge 2 ]; then
				switch_to primary
			elif [ "$P653" = "0" ] && [ "$P953" = "1" ]; then
				switch_to fallback
			fi
			;;
		esac

		save_state
		# sleep 放后台再 wait：前台 sleep 会吞掉 TERM 直到睡满，
		# procd 的 term_timeout(5s) 到了就会 SIGKILL，trap 来不及释放 watchdog。
		sleep "$INTERVAL" &
		SLEEP_PID=$!
		wait "$SLEEP_PID"
		SLEEP_PID=""
	done
}

if [ "${OPENCLASH_DNS_GUARD_SOURCE_ONLY:-0}" = "1" ]; then
	:
elif [ "${1:-}" = "--maintenance-begin" ]; then
	[ "$#" = "3" ] || { echo "usage: $0 --maintenance-begin TRANSACTION_ID TTL_SECONDS" >&2; exit 2; }
	maintenance_begin "$2" "$3"
elif [ "${1:-}" = "--maintenance-end" ]; then
	[ "$#" = "2" ] || { echo "usage: $0 --maintenance-end TRANSACTION_ID" >&2; exit 2; }
	maintenance_end "$2"
else
	main
fi

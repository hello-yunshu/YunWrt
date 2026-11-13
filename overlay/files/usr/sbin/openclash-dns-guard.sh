#!/bin/sh
# openclash-dns-guard.sh
# 在 OpenClash 核心(端口 653)无响应时，把 dnsmasq 上游临时切到 mosdns(953)，
# 保证全网 DNS 不断；恢复后按降级前记录的原值切回。状态翻转时通过 Bark 推送。
#
# 只改 dhcp 的 UCI 配置，不修改 /etc/init.d/openclash 与 /usr/share/openclash/ 下任何文件。

STATE_FILE="/var/run/openclash-dns-guard.state"
QUEUE_FILE="/var/run/openclash-dns-guard.queue"
CFG="openclash-dns-guard.main"
LOG_DIR="/yunshu/openwrt-maintenance"
LOG_MAX=262144
# 开机宽限期：系统 uptime 小于该值时不判定降级，避免开机期 OpenClash 尚未就绪就误降级。
BOOT_GRACE=90
# 恢复失败告警的最小间隔，避免每轮都推送。
RESTORE_ALERT_GAP=300

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
	MANAGE_RULE=$(cfg manage_ip_rule 1)
	MARK=$(cfg ip_rule_mark 0x162)
	TABLE=$(cfg ip_rule_table 0x162)
	PREF=$(cfg ip_rule_pref 1888)
	TABLE_DEC=$((TABLE))
	case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=15 ;; esac
	[ "$INTERVAL" -lt 5 ] && INTERVAL=5
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
	ROLE="primary"; OK_CNT=0; FAIL_CNT=0; LAST_SWITCH=0; FAIL_SINCE=0
	FB_COUNT=0; FB_START=0; FB_START_STR=""
	ORIG_RECORDED=0; ORIG_SERVER=""; ORIG_NORESOLV=""; ORIG_RESOLVFILE=""
	WD_STOPPED=""; RESTORE_FAIL_TS=0
	P653=0; P953=0; LAST_DRAIN=0
	# shellcheck disable=SC1090
	[ -f "$STATE_FILE" ] && . "$STATE_FILE"
	# 兼容旧 state：旧版本没有 ORIG_RECORDED 字段，但有 ORIG_SERVER 就说明记过原值。
	if [ "$ORIG_RECORDED" != "1" ] && [ -n "$ORIG_SERVER" ]; then
		ORIG_RECORDED=1
	fi
}

save_state() {
	TMP="${STATE_FILE}.tmp"
	{
		echo "ROLE=$ROLE"
		echo "OK_CNT=$OK_CNT"
		echo "FAIL_CNT=$FAIL_CNT"
		echo "LAST_SWITCH=$LAST_SWITCH"
		echo "FAIL_SINCE=$FAIL_SINCE"
		echo "FB_COUNT=$FB_COUNT"
		echo "FB_START=$FB_START"
		echo "FB_START_STR=\"$FB_START_STR\""
		echo "ORIG_RECORDED=$ORIG_RECORDED"
		echo "ORIG_SERVER=\"$ORIG_SERVER\""
		echo "ORIG_NORESOLV=\"$ORIG_NORESOLV\""
		echo "ORIG_RESOLVFILE=\"$ORIG_RESOLVFILE\""
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

# dnsmasq 实际加载的生成配置（reload 会重建它），用于回读校验
dnsmasq_effective_servers() {
	for _ef in /var/etc/dnsmasq.conf.cfg*; do
		[ -f "$_ef" ] || continue
		sed -n 's/^server=//p' "$_ef"
	done
}

servers_match() {
	_want=$(for _ws in $1; do printf '%s\n' "$_ws"; done | sort -u)
	_have=$(dnsmasq_effective_servers | sort -u)
	[ "$_want" = "$_have" ]
}

record_orig() {
	[ "$ORIG_RECORDED" = "1" ] && return
	ORIG_SERVER=$(dnsmasq_servers)
	ORIG_NORESOLV=$(uci -q get dhcp.@dnsmasq[0].noresolv)
	ORIG_RESOLVFILE=$(uci -q get dhcp.@dnsmasq[0].resolvfile)
	ORIG_RECORDED=1
	log "recorded original: server=[$ORIG_SERVER] noresolv=[$ORIG_NORESOLV] resolvfile=[$ORIG_RESOLVFILE]"
}

# 按 record_orig 记下的原值回填；原值缺失或非法时明确失败，不猜 653。
apply_primary() {
	if [ "$ORIG_RECORDED" != "1" ]; then
		log "restore FAILED: original dnsmasq settings were never recorded, refusing to guess"
		return 1
	fi
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
	if [ -n "$ORIG_NORESOLV" ]; then
		uci -q set dhcp.@dnsmasq[0].noresolv="$ORIG_NORESOLV"
	else
		uci -q delete dhcp.@dnsmasq[0].noresolv
	fi
	if [ -n "$ORIG_RESOLVFILE" ]; then
		uci -q set dhcp.@dnsmasq[0].resolvfile="$ORIG_RESOLVFILE"
	else
		uci -q delete dhcp.@dnsmasq[0].resolvfile
	fi
	if ! uci -q commit dhcp; then
		log "restore FAILED: uci commit dhcp"
		return 1
	fi
	/etc/init.d/dnsmasq reload >/dev/null 2>&1
	return 0
}

apply_fallback() {
	uci -q del dhcp.@dnsmasq[0].server
	uci -q add_list dhcp.@dnsmasq[0].server="127.0.0.1#$FALLBACK_PORT"
	uci -q set dhcp.@dnsmasq[0].noresolv='1'
	uci -q commit dhcp
	/etc/init.d/dnsmasq reload >/dev/null 2>&1
}

apply_wan() {
	uci -q del dhcp.@dnsmasq[0].server
	uci -q set dhcp.@dnsmasq[0].noresolv='0'
	uci -q set dhcp.@dnsmasq[0].resolvfile='/tmp/resolv.conf.d/resolv.conf.auto'
	uci -q commit dhcp
	/etc/init.d/dnsmasq reload >/dev/null 2>&1
}

# 写回 → reload → 回读生成配置 → 与原始值比对（顺序无关）
verify_restore() {
	_vi=0
	while [ "$_vi" -lt 3 ]; do
		servers_match "$ORIG_SERVER" && return 0
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
	*) apply_fallback ;;
	esac
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
		# 先停住会改回 653 的 watchdog，再写降级配置，减少拉锯窗口
		suspend_watchdog
		apply_fallback
		rule_del
		FB_COUNT=$((FB_COUNT+1)); FB_START=$NOW
		FB_START_STR=$(date "+%Y-%m-%d %H:%M:%S")
		# 持续失败时长以第一次失败的时间戳为基准，与开机宽限期无关
		FDUR=$((NOW-FAIL_SINCE)); [ "$FAIL_SINCE" = "0" ] && FDUR=0
		log "SWITCH primary->fallback: dnsmasq upstream = 127.0.0.1#$FALLBACK_PORT (653 failed ${FAIL_CNT}x over ${FDUR}s, 953 ok)"
		[ "$NOTIFY_FB" = "1" ] && bark "OpenClash DNS 已降级" \
			"clash 核心无响应（653 连续 2 次解析失败），已临时切到 mosdns(953)。国内网络可用，分流精度下降，fake-ip 暂失效。境外流量已改为直连。" timeSensitive
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
		DUR=$((NOW-FB_START))
		[ "$FB_START" = "0" ] && DUR=0
		log "SWITCH ->primary: dnsmasq upstream restored (653 ok 2x) duration=${DUR}s"
		# 代理恢复后再补发降级期间积压的告警（那时境外 api.day.app 被 TUN 黑洞）
		drain_queue
		[ "$NOTIFY_RC" = "1" ] && bark "OpenClash DNS 已恢复" \
			"已切回 clash(653)，fake-ip 与分流恢复正常。故障开始：${FB_START_STR:-未知}，持续 ${DUR} 秒。" timeSensitive
		FB_START=0; FB_START_STR=""
		;;
	wan)
		suspend_watchdog
		apply_wan
		rule_del
		log "SWITCH ->wan-dns: 653 and 953 both unreachable, dnsmasq reset to WAN resolv.conf.auto"
		[ "$NOTIFY_SV" = "1" ] && bark "DNS 完全不可用：已回落 WAN DNS" \
			"clash(653) 与 mosdns(953) 均无法解析，已把 dnsmasq 重置为 WAN DNS(resolv.conf.auto)。国内网络可能可用，分流与去广告全部失效。" timeSensitive
		;;
	esac
	ROLE="$NEW"; LAST_SWITCH="$NOW"; OK_CNT=0; FAIL_CNT=0; FAIL_SINCE=0
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
		if [ "$(uci -q get dhcp.@dnsmasq[0].noresolv)" != "0" ]; then
			log "dnsmasq upstream reverted externally (now=[$(dnsmasq_servers)]), re-applying WAN DNS"
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
trap on_exit EXIT
trap on_term INT TERM

# ---------------- 主循环 ----------------
main() {
	load_cfg
	setup_log
	load_state
	log "guard start pid=$$ interval=${INTERVAL}s role=$ROLE primary=$PRIMARY_PORT fallback=$FALLBACK_PORT suspend_watchdog=$SUSPEND_WD log_file=$LOG_FILE"
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
		UP_NOW=$(cut -d. -f1 /proc/uptime 2>/dev/null)
		case "$UP_NOW" in ''|*[!0-9]*) UP_NOW=999999 ;; esac

		# 每轮都校正：fallback/wan 下确保 ip rule 不在，primary 下确保在
		repair_if_reverted

		if [ "$P653" = "1" ]; then
			OK_CNT=$((OK_CNT+1)); FAIL_CNT=0; FAIL_SINCE=0
		else
			OK_CNT=0
			[ "$FAIL_SINCE" = "0" ] && FAIL_SINCE=$NOW
			FAIL_CNT=$((FAIL_CNT+1))
		fi

		case "$ROLE" in
		primary)
			# 两个独立概念：开机宽限期看 uptime；持续失败看连续失败次数（FAIL_SINCE 只用于计时/日志）
			if [ "$P653" = "0" ] && [ "$FAIL_CNT" -ge 2 ] && [ "$UP_NOW" -ge "$BOOT_GRACE" ]; then
				record_orig
				save_state
				if [ "$P953" = "1" ]; then
					switch_to fallback
				else
					switch_to wan
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

main

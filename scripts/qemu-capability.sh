#!/usr/bin/env bash
# P4 阻塞验收：QEMU 启动镜像，进 guest 取证据，逐项判定 16 项发布门槛。
# 任一项不满足即非 0 退出。--self-test 用合成证据证明判定确实会红（无需 QEMU）。
#   bash scripts/qemu-capability.sh [<image>] [--inject <key>] [--self-test]
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMG=""
INJECT=""
SELFTEST=0
while [ $# -gt 0 ]; do
	case "$1" in
	--inject)
		INJECT="${2:-}"
		shift 2
		;;
	--self-test)
		SELFTEST=1
		shift
		;;
	-h | --help)
		sed -n '2,4p' "$0"
		exit 0
		;;
	*)
		IMG="$1"
		shift
		;;
	esac
done

# 项目编号|键|判定方式(eq/re)|期望值
EXPECTED='
①|lan_ip|eq|192.168.2.1
①|lan_addr|eq|192.168.2.1/24
①|wan_addr|re|^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/
②|luci_ui|eq|ok
③|port_range|eq|10240 65535
④|mosdns953|re|^[1-9][0-9]*$
⑤|uci_defaults_left|eq|0
⑥|fw4_check|eq|OK
⑥|fw4_net_device|re|^[1-9][0-9]*$
⑦|upnp_relay|eq|present
⑧|flowcone_pkg|re|^[1-9][0-9]*$
⑧|btf|re|^(yes|detached)$
⑧|flowcone_proc|eq|yes
⑧|offload_rule|re|^[1-9][0-9]*$
⑧|dmesg_bad|eq|0
⑧|sfe_opt|eq|gone
'

evaluate() { # $1 = 证据文件（key<TAB>value）
	local results="$1" item key mode want got fails=0 total=0
	while IFS='|' read -r item key mode want; do
		[ -n "${key}" ] || continue
		total=$((total + 1))
		got="$(awk -F'\t' -v k="${key}" '$1 == k { v = $2 } END { print v }' "${results}")"
		if [ -z "${got}" ]; then
			printf 'FAIL [%s] %-18s 未取到证据\n' "${item}" "${key}"
			fails=$((fails + 1))
			continue
		fi
		case "${mode}" in
		eq)
			if [ "${got}" != "${want}" ]; then
				printf 'FAIL [%s] %-18s 期望 "%s" 实际 "%s"\n' "${item}" "${key}" "${want}" "${got}"
				fails=$((fails + 1))
				continue
			fi
			;;
		re)
			if ! printf '%s' "${got}" | grep -Eq -- "${want}"; then
				printf 'FAIL [%s] %-18s 期望匹配 %s 实际 "%s"\n' "${item}" "${key}" "${want}" "${got}"
				fails=$((fails + 1))
				continue
			fi
			;;
		esac
		printf 'ok   [%s] %-18s %s\n' "${item}" "${key}" "${got}"
	done <<EOF
$(printf '%s\n' "${EXPECTED}" | sed '/^$/d')
EOF
	if [ "${fails}" -ne 0 ]; then
		echo "==> 失败：${fails}/${total} 项不满足"
		return 1
	fi
	echo "==> 通过：${total}/${total} 项阻塞验收满足"
	return 0
}

self_test() {
	local tmp bad=0 key
	tmp="$(mktemp -d)"

	printf '%s\n' \
		$'lan_ip\t192.168.2.1' $'lan_addr\t192.168.2.1/24' $'wan_addr\t10.0.2.15/24' \
		$'luci_ui\tok' $'port_range\t10240 65535' $'mosdns953\t1' \
		$'uci_defaults_left\t0' $'fw4_check\tOK' $'fw4_net_device\t1' \
		$'upnp_relay\tpresent' \
		$'flowcone_pkg\t1' $'btf\tdetached' $'flowcone_proc\tyes' $'offload_rule\t2' \
		$'dmesg_bad\t0' $'sfe_opt\tgone' >"${tmp}/good"

	if ! evaluate "${tmp}/good" >/dev/null; then
		echo "FAIL self-test: 全好证据被判失败" >&2
		bad=1
	fi

	# 逐项注入坏值：任何一项坏掉都必须让门禁变红
	while IFS='|' read -r _ key _ _; do
		[ -n "${key}" ] || continue
		sed "s/^${key}	.*/${key}	BAD/" "${tmp}/good" >"${tmp}/bad"
		if evaluate "${tmp}/bad" >/dev/null 2>&1; then
			echo "FAIL self-test: 注入 ${key}=BAD 后判定仍然通过（门禁不会红）" >&2
			bad=1
		fi
	done <<EOF
$(printf '%s\n' "${EXPECTED}" | sed '/^$/d')
EOF

	# 逐项删证据：漏采集任何一项都必须变红，不能因为「没取到」被跳过
	while IFS='|' read -r _ key _ _; do
		[ -n "${key}" ] || continue
		grep -v "^${key}	" "${tmp}/good" >"${tmp}/missing"
		if evaluate "${tmp}/missing" >/dev/null 2>&1; then
			echo "FAIL self-test: 缺失 ${key} 证据仍然通过" >&2
			bad=1
		fi
	done <<EOF
$(printf '%s\n' "${EXPECTED}" | sed '/^$/d')
EOF

	rm -rf "${tmp}"
	[ "${bad}" -eq 0 ] || return 1
	echo "ok  self-test: 好证据通过；逐项注入坏值、逐项删证据，判定都会红"
}

if [ "${SELFTEST}" -eq 1 ]; then
	self_test
	exit $?
fi

# ---------------- VM 路径 ----------------
[ -n "${IMG}" ] || IMG="$(ls -1 "${ROOT_DIR}"/build/artifact/*combined-efi.img* 2>/dev/null | head -1 || true)"
if [ -z "${IMG}" ] || [ ! -f "${IMG}" ]; then
	echo "ERROR: 找不到镜像（传路径，或先跑 scripts/build.sh）" >&2
	exit 1
fi

QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
command -v "${QEMU_BIN}" >/dev/null 2>&1 || {
	echo "ERROR: 找不到 QEMU: ${QEMU_BIN}" >&2
	exit 1
}

OVMF_CODE="${OVMF_CODE:-}"
OVMF_VARS="${OVMF_VARS:-}"
if [ -z "${OVMF_CODE}" ]; then
	for pair in \
		"/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd" \
		"/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd" \
		"/usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd" \
		"/opt/homebrew/share/qemu/edk2-x86_64-code.fd:/opt/homebrew/share/qemu/edk2-i386-vars.fd"; do
		IFS=: read -r code vars <<<"${pair}"
		if [ -r "${code}" ] && [ -r "${vars}" ]; then
			OVMF_CODE="${code}"
			OVMF_VARS="${vars}"
			break
		fi
	done
fi
[ -n "${OVMF_CODE}" ] || {
	echo "ERROR: 找不到成对的 OVMF CODE/VARS（装 ovmf，或用 OVMF_CODE/OVMF_VARS 指定）" >&2
	exit 1
}

BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"

WORK="$(mktemp -d)"
RUN="${WORK}/boot.raw"
LOG="${WORK}/console.log"
VARS="${WORK}/OVMF_VARS.fd"
RESULTS="${WORK}/results.tsv"
QEMU_PID=""

cleanup() {
	if [ -n "${QEMU_PID}" ] && kill -0 "${QEMU_PID}" 2>/dev/null; then
		kill "${QEMU_PID}" 2>/dev/null || true
		wait "${QEMU_PID}" 2>/dev/null || true
	fi
	rm -rf "${WORK}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cp "${OVMF_VARS}" "${VARS}"
case "${IMG}" in
*.gz)
	# 不用 zcat：BSD/macOS 的 zcat 会给 .gz 再补一个 .Z 后缀，解出 0 字节
	gzip -dc "${IMG}" >"${RUN}" || {
		echo "ERROR: 解压失败: ${IMG}" >&2
		exit 1
	}
	;;
*) cp "${IMG}" "${RUN}" ;;  # 未压缩的 raw：直接复制（`cp src > dst` 是错的，会写成空文件）
esac
[ -s "${RUN}" ] || {
	echo "ERROR: 镜像解压后为空: ${IMG}" >&2
	exit 1
}

mkfifo "${WORK}/console.in"
"${QEMU_BIN}" \
	-machine q35,accel=tcg \
	-cpu max -m 1024 -smp 2 \
	-drive "if=pflash,format=raw,unit=0,readonly=on,file=${OVMF_CODE}" \
	-drive "if=pflash,format=raw,unit=1,file=${VARS}" \
	-drive "file=${RUN},format=raw,if=virtio" \
	-netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
	-netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
	-nographic -no-reboot \
	<"${WORK}/console.in" >"${LOG}" 2>&1 &
QEMU_PID=$!
# 用固定 fd 3 而不是 {VAR}>，后者要 bash 4.3，macOS 自带 bash 3.2
exec 3>"${WORK}/console.in" || {
	echo "ERROR: 打不开控制台 fifo" >&2
	exit 1
}

send() { printf '%s\n' "$1" >&3; }

# 注意：这里一律用 awk 单进程读日志，不用 `tr | grep -q`。
# 脚本开了 set -o pipefail，而 `grep -q` 命中即退出会让上游 tr 收到 SIGPIPE（141），
# 整条管道被判失败 —— 于是"明明已经出现"的哨兵被当成没出现，实测导致下发反复重试。
wait_for() { # $1=固定串 $2=超时秒 $3=起始行（只在第 3 行之后找，重试用）
	local from="${3:-1}" deadline=$((SECONDS + $2))
	while [ "${SECONDS}" -lt "${deadline}" ]; do
		awk -v want="$1" -v from="${from}" '
			NR >= from { sub(/\r$/, ""); if (index($0, want)) { f = 1; exit } }
			END { exit !f }' "${LOG}" 2>/dev/null && return 0
		kill -0 "${QEMU_PID}" 2>/dev/null || return 1
		sleep 1
	done
	return 1
}

take_value() { # $1=key $2=起始行：取最后一次出现的 R:<key>:<值>
	tail -n "+${2:-1}" "${LOG}" 2>/dev/null | tr -d '\r' |
		sed -n "s/^R:$1:\(.*\)$/\1/p" | tail -1
}

wait_exact() { # $1=整行固定串 $2=超时秒
	local deadline=$((SECONDS + $2))
	while [ "${SECONDS}" -lt "${deadline}" ]; do
		awk -v want="$1" '
			{ sub(/\r$/, "") }
			$0 == want { f = 1; exit }
			END { exit !f }' "${LOG}" 2>/dev/null && return 0
		kill -0 "${QEMU_PID}" 2>/dev/null || return 1
		sleep 1
	done
	return 1
}

wait_prefix() { # $1=行首固定串 $2=超时秒：值不固定的回执用行首匹配，避免命中回显的命令行
	local deadline=$((SECONDS + $2))
	while [ "${SECONDS}" -lt "${deadline}" ]; do
		awk -v want="$1" '
			{ sub(/\r$/, "") }
			index($0, want) == 1 { f = 1; exit }
			END { exit !f }' "${LOG}" 2>/dev/null && return 0
		kill -0 "${QEMU_PID}" 2>/dev/null || return 1
		sleep 1
	done
	return 1
}

fail() {
	cp "${LOG}" /tmp/yunwrt-cap-fail.log 2>/dev/null || true
	printf 'ERROR: %s\n' "$*" >&2
	printf '（控制台日志已保留：/tmp/yunwrt-cap-fail.log）\n' >&2
	exit 1
}

echo "[cap] image: ${IMG}"
echo "[cap] 等待系统启动 ..."
if ! wait_for 'Please press Enter to activate this console.' "${BOOT_TIMEOUT}"; then
	echo "ERROR: ${BOOT_TIMEOUT}s 内未进入控制台，日志尾部：" >&2
	tail -n 30 "${LOG}" >&2
	exit 1
fi

# 哨兵一律用引号拼接写（"CAP_""PROBE"）：串口 ECHO 关不掉时，回显出来的命令行里
# 不会出现连续的 "CAP_PROBE" 字面量，只有真正执行后的输出才会。否则 wait_* 
# 会命中自己的命令回显，直接误判成功。
send ''
sleep 2
send 'echo "CAP_""PROBE"'
if ! wait_exact 'CAP_PROBE' 10; then
	send 'root'
	sleep 2
	send 'echo "CAP_""PROBE"'
	if ! wait_exact 'CAP_PROBE' 15; then
		echo "ERROR: 无法进入 guest shell" >&2
		tail -n 30 "${LOG}" >&2
		exit 1
	fi
fi
echo "[cap] shell 就绪，关闭回显与输出换行处理，等 rcS 跑完再下发 ..."

# -echo：不把输入的命令再回显一遍，日志干净、也减少串口双向流量。
# -opost：关掉 tty 输出处理，否则超过 80 列的结果会被行规程插换行，把 R:key:value 拆成两行，
#         host 侧按行解析就会漏掉（实测 R:xfer 被拆成 "R:" + "xfer:..."）。
send 'stty -echo -opost 2>/dev/null; echo "CAP_TTY_""OK"'
# 用整行精确匹配：回显的命令行里有 "echo CAP_TTY_OK"，模糊匹配会误判成功。
if ! wait_exact 'CAP_TTY_OK' 20; then
	tail -n 20 "${LOG}" >&2
	fail "无法设置控制台 tty 模式"
fi

# 先等 rcS 结束。控制台横幅出现得比 rcS 启动还早，此刻 pgrep 找不到任何 rc.d 进程，
# 会以为"已经跑完"而在 rcS 期间灌入数据 —— tty 输入缓冲只有 4KB，溢出就丢字节。
# 所以先固定等一个基准时长，再确认 rc.d 进程确实清空。
send 'sleep 75; while pgrep -f "/etc/rc.d/" >/dev/null 2>&1; do sleep 1; done; echo "R:rc:""done"'
if ! wait_exact 'R:rc:done' 300; then
	tail -n 20 "${LOG}" >&2
	fail "300s 内 rcS 未结束"
fi
sleep 5

# 控制台横幅出现时 rcS 还在跑：uci-defaults 未应用、uwsgi 未拉起、S99 的服务还没起。
# 早期直接在此时采集会得到一片假失败（lan 还是 192.168.1.1、进程不在、HTTP 无响应）。
# 落定闸必须和探针在同一个脚本里执行，原因见下面的串口长度说明。
SNIPPET="$(cat <<'EOS'
# --- 启动落定：flowcone 起来、WAN 拿到地址、且 TCX 已经 attach ---
# 只等进程存在会在 attach 之前采集：实测 flowcone 08:42:38 启动、08:43:03 才 attach，
# 中间 25 秒采集会得到 dmesg_bad=1(attach=0) 的假失败。attach 不会发生也要等满，
# 这样报出来的是真实的「没 attach」而不是「采早了」。
m=0
while [ $m -lt 120 ]; do
	pgrep -f "/usr/bin/flowcone" >/dev/null 2>&1 &&
		ip -4 addr show $(uci -q get network.wan.device) 2>/dev/null | grep -q "inet " &&
		logread 2>/dev/null | grep -qi 'flowcone.*attached' && break
	m=$((m + 1))
	sleep 1
done
echo "R:ready:$m/120"
sleep 3

echo CAP_BEGIN
echo "R:lan_ip:$(uci -q get network.lan.ipaddr)"
echo "R:lan_addr:$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2; exit}')"
echo "R:wan_addr:$(ip -4 addr show $(uci -q get network.wan.device 2>/dev/null || echo eth0) 2>/dev/null | awk '/inet /{print $2; exit}')"
echo "R:luci_ui:$( s=$(curl -k -s --connect-timeout 5 --max-time 15 -o /tmp/.luci.html -w '%{http_code}' https://127.0.0.1/cgi-bin/luci/ 2>/dev/null); b=$(grep -ci luci /tmp/.luci.html 2>/dev/null); u=$(pgrep -x uhttpd >/dev/null 2>&1 && echo 1 || echo 0); ub=$(curl -k -s --connect-timeout 5 --max-time 15 -o /dev/null -w '%{http_code}' -X POST https://127.0.0.1/ubus -d '{"jsonrpc":"2.0","id":1,"method":"list","params":["00000000000000000000000000000000"]}' 2>/dev/null); if [ "$s" = 200 ] || [ "$s" = 403 ]; then if [ "${b:-0}" -ge 1 ] && [ "$u" = 0 ] && [ "$ub" = 200 ]; then echo ok; else echo "fail:body=${b:-0},uhttpd=$u,ubus=$ub"; fi; else echo "fail:code=$s"; fi )"
echo "R:port_range:$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null | tr -s '\t ' ' ' | sed 's/ *$//')"
echo "R:mosdns953:$( n=$(netstat -lnup 2>/dev/null | awk '$4 ~ /:953$/ {c++} END{print c+0}'); case "$n" in ''|0) n=$(grep -ic ':03B9' /proc/net/udp 2>/dev/null);; esac; echo "${n:-0}" )"
echo "R:uci_defaults_left:$( m=0; for f in /etc/init.d/swrt-vm-performance /etc/config/swrt-vm-performance /usr/bin/swrt-vm-perf /usr/libexec/yunwrt-mosdns-hotplug /usr/share/yunwrt/99-mosdns /etc/mosdns/yunwrt.yaml /etc/sysctl.d/90-yunwrt-x86-network.conf /etc/hotplug.d/iface/99-mosdns; do [ -e "$f" ] || m=1; done; n=$(ls /etc/uci-defaults 2>/dev/null | grep -cE '^(90-yunwrt-network-hooks|97-yunwrt-mosdns|98-swrt-vm-performance|99-x86-vm-network|99-yunwrt-upnpd)$'); if [ "$m" -eq 0 ]; then echo "$n"; else echo "overlay-missing"; fi )"
echo "R:fw4_check:$(fw4 check >/dev/null 2>&1 && echo OK || echo FAIL)"
echo "R:fw4_net_device:$(grep -c 'net.physdev || net.device' /usr/share/ucode/fw4.uc 2>/dev/null)"
echo "R:upnp_relay:$( if [ -x /etc/init.d/upnp_nat_relay ]; then pgrep -f 'upnp[-_]nat[-_]relay' >/dev/null 2>&1 && echo present || echo installed-not-running; else echo missing; fi )"
echo "R:flowcone_pkg:$(apk list -I 2>/dev/null | grep -c '^flowcone')"
echo "R:btf:$( if [ -e /sys/kernel/btf/vmlinux ]; then echo yes; elif [ -s /usr/lib/debug/boot/vmlinux ]; then echo detached; else echo no; fi )"
echo "R:flowcone_proc:$(pgrep -f /usr/bin/flowcone >/dev/null 2>&1 && echo yes || echo no)"
echo "R:offload_rule:$(nft list ruleset 2>/dev/null | grep -Eic 'flowtable|offload')"
echo "R:dmesg_bad:$( a=$(logread 2>/dev/null | grep -i flowcone | grep -ic 'attached'); e=$(dmesg 2>/dev/null | grep -iE 'flowcone|bpf' | grep -icE 'error|fail'); if [ "${a:-0}" -ge 1 ] && [ "${e:-1}" -eq 0 ]; then echo 0; else echo "1(attach=$a,err=$e)"; fi )"
echo "R:sfe_opt:$( command -v uci >/dev/null 2>&1 && command -v apk >/dev/null 2>&1 || { echo unknown; exit 0; }; uci -q show firewall >/dev/null 2>&1 || { echo unknown; exit 0; }; u=0; uci -q get firewall.@defaults[0].shortcut_fe >/dev/null 2>&1 && u=1; apk list -I 2>/dev/null | grep -qi 'shortcut-fe' && u=2; [ "$u" = 0 ] && echo gone || echo "present:$u" )"
echo CAP_END
EOS
)"

if [ -n "${INJECT}" ]; then
	SNIPPET="${SNIPPET/echo CAP_END/echo \"R:${INJECT}:INJECTED-BAD\"
echo CAP_END}"
fi

# 串口一次写长行会丢字节（实测：220 字节完整送达，500 字节起被截断成未闭合引号，
# shell 停在 ">" 续行提示，后续命令全部不执行）。guest 也没有 busybox 的 base64 applet，
# 只有 /usr/bin/openssl。所以把整个探针 base64 后按 64 字节分块写入，再用 openssl 解码，
# 并用 md5 校验解码结果；不符就重发（最多 3 次），绝不带着残缺探针往下判定。
md5_of() { if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | awk '{print $1}'; fi; }
B64="$(printf '%s' "${SNIPPET}" | base64 | tr -d '\n')"
WANT_SUM="$(printf '%s' "${SNIPPET}" | md5_of)"
# 注意用字节数：${#SNIPPET} 是字符数，探针里含中文注释，两者不相等
SBYTES="$(printf '%s' "${SNIPPET}" | wc -c | tr -d ' ')"
CHUNK=160
ATTEMPT=1
XFER_OK=0
while [ "${ATTEMPT}" -le 3 ]; do
	kill -0 "${QEMU_PID}" 2>/dev/null || fail "QEMU 已退出，无法下发探针"
	# macOS 的 wc -l 会输出前导空格，直接拼进 tail -n 会变成非法参数而静默失败
	MARK="$(wc -l <"${LOG}" | tr -d ' ')"
	send 'rm -f /tmp/cap.b64 /tmp/cap.sh'
	i=0
	while [ "${i}" -lt "${#B64}" ]; do
		send "printf '%s' '${B64:${i}:${CHUNK}}'>>/tmp/cap.b64"
		i=$((i + CHUNK))
		sleep 0.3
	done
	send "openssl base64 -d -A -in /tmp/cap.b64 -out /tmp/cap.sh; echo \"R:x\"\"fer:\$(md5sum /tmp/cap.sh 2>/dev/null | cut -d' ' -f1)|\$(wc -c </tmp/cap.sh)|\$(wc -c </tmp/cap.b64)\""
	if wait_for 'R:xfer:' 180 "${MARK}"; then
		GOT="$(take_value xfer "${MARK}")"
		GOT_SUM="${GOT%%|*}"
		GOT_DEC="${GOT#*|}"; GOT_DEC="${GOT_DEC%%|*}"
		GOT_B64="${GOT##*|}"
		if [ "${GOT_DEC}" = "${SBYTES}" ] && [ "${GOT_B64}" = "${#B64}" ] &&
			{ [ -z "${GOT_SUM}" ] || [ "${GOT_SUM}" = "${WANT_SUM}" ]; }; then
			XFER_OK=1
			break
		fi
		echo "[cap] 警告：第 ${ATTEMPT} 次下发校验不符（${GOT}；期望 md5=${WANT_SUM} 脚本=${SBYTES}B b64=${#B64}B），重发" >&2
	else
		echo "[cap] 警告：第 ${ATTEMPT} 次下发无回执，重发" >&2
	fi
	ATTEMPT=$((ATTEMPT + 1))
done
[ "${XFER_OK}" -eq 1 ] || fail "探针下发 3 次均未通过 md5 校验，串口不可靠（期望 ${WANT_SUM}）"
send 'sh /tmp/cap.sh'

PROBE_TIMEOUT="${PROBE_TIMEOUT:-420}"
if ! wait_exact 'CAP_END' "${PROBE_TIMEOUT}"; then
	tail -n 30 "${LOG}" >&2
	fail "${PROBE_TIMEOUT}s 内未采集完证据"
fi
sleep 1

echo "[cap] 启动落定：$(take_value ready)（rc.d/服务等待秒数）"

: >"${RESULTS}"
# 只认「行首就是 R:」的输出行；回显出来的命令行（echo "R:...$(...)"）不算证据
sed -n '/CAP_BEGIN/,/CAP_END/p' "${LOG}" | tr -d '\r' |
	sed -n 's/^R:\([a-z0-9_]*\):\(.*\)$/\1	\2/p' >"${RESULTS}"

echo "[cap] 证据："
sed 's/^/    /' "${RESULTS}"

# 判定失败时保留现场：否则 cleanup 会把 WORK 一起删掉，事后无从复核
if ! evaluate "${RESULTS}"; then
	cp "${LOG}" /tmp/yunwrt-cap-fail.log 2>/dev/null || true
	cp "${RESULTS}" /tmp/yunwrt-cap-results.tsv 2>/dev/null || true
	printf '（控制台日志：/tmp/yunwrt-cap-fail.log；证据表：/tmp/yunwrt-cap-results.tsv）\n' >&2
	exit 1
fi

#!/usr/bin/env bash
# P4 阻塞验收：QEMU 启动镜像，进 guest 取证据，逐项判定 8 项发布门槛。
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
②|luci_code|eq|200
③|port_range|eq|10240 65535
④|mosdns953|re|^[1-9][0-9]*$
⑤|uci_defaults_left|eq|0
⑥|fw4_check|eq|OK
⑥|fw4_net_device|re|^[1-9][0-9]*$
⑦|upnpd_enabled|eq|1
⑦|upnpd_ext_private|eq|1
⑦|upnp_relay|eq|present
⑧|flowcone_pkg|re|^[1-9][0-9]*$
⑧|btf|eq|yes
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
		$'luci_code\t200' $'port_range\t10240 65535' $'mosdns953\t1' \
		$'uci_defaults_left\t0' $'fw4_check\tOK' $'fw4_net_device\t1' \
		$'upnpd_enabled\t1' $'upnpd_ext_private\t1' $'upnp_relay\tpresent' \
		$'flowcone_pkg\t1' $'btf\tyes' $'flowcone_proc\tyes' $'offload_rule\t2' \
		$'dmesg_bad\t0' $'sfe_opt\tgone' >"${tmp}/good"

	if ! evaluate "${tmp}/good" >/dev/null; then
		echo "FAIL self-test: 全好证据被判失败" >&2
		bad=1
	fi

	for key in lan_ip lan_addr luci_code port_range mosdns953 uci_defaults_left \
		fw4_check fw4_net_device upnpd_enabled upnp_relay flowcone_pkg \
		flowcone_proc offload_rule dmesg_bad sfe_opt; do
		sed "s/^${key}	.*/${key}	BAD/" "${tmp}/good" >"${tmp}/bad"
		if evaluate "${tmp}/bad" >/dev/null 2>&1; then
			echo "FAIL self-test: 注入 ${key}=BAD 后判定仍然通过（门禁不会红）" >&2
			bad=1
		fi
	done

	grep -v '^luci_code' "${tmp}/good" >"${tmp}/missing"
	if evaluate "${tmp}/missing" >/dev/null 2>&1; then
		echo "FAIL self-test: 缺失 luci_code 证据仍然通过" >&2
		bad=1
	fi

	rm -rf "${tmp}"
	[ "${bad}" -eq 0 ] || return 1
	echo "ok  self-test: 好证据通过；逐项注入坏值、以及缺证据，判定都会红"
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
CAP_TIMEOUT="${CAP_TIMEOUT:-90}"

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
*) cp "${IMG}" >"${RUN}" ;;
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

wait_for() { # $1=固定串 $2=超时秒
	local deadline=$((SECONDS + $2))
	while [ "${SECONDS}" -lt "${deadline}" ]; do
		grep -Fq "$1" "${LOG}" 2>/dev/null && return 0
		kill -0 "${QEMU_PID}" 2>/dev/null || return 1
		sleep 1
	done
	return 1
}

echo "[cap] image: ${IMG}"
echo "[cap] 等待系统启动 ..."
if ! wait_for 'Please press Enter to activate this console.' "${BOOT_TIMEOUT}"; then
	echo "ERROR: ${BOOT_TIMEOUT}s 内未进入控制台，日志尾部：" >&2
	tail -n 30 "${LOG}" >&2
	exit 1
fi

send ''
sleep 2
send 'echo CAP_PROBE'
if ! wait_for 'CAP_PROBE' 10; then
	send 'root'
	sleep 2
	send 'echo CAP_PROBE'
	if ! wait_for 'CAP_PROBE' 15; then
		echo "ERROR: 无法进入 guest shell" >&2
		tail -n 30 "${LOG}" >&2
		exit 1
	fi
fi
echo "[cap] shell 就绪，采集证据 ..."

SNIPPET="$(cat <<'EOS'
echo CAP_BEGIN
echo "R:lan_ip:$(uci -q get network.lan.ipaddr)"
echo "R:lan_addr:$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2; exit}')"
echo "R:wan_addr:$(ip -4 addr show $(uci -q get network.wan.device 2>/dev/null || echo eth0) 2>/dev/null | awk '/inet /{print $2; exit}')"
echo "R:luci_code:$( (uclient-fetch -q -O /dev/null -S http://127.0.0.1/ 2>&1 || wget -q -O /dev/null -S http://127.0.0.1/ 2>&1) | awk '/HTTP\//{print $2; exit}')"
echo "R:port_range:$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null)"
echo "R:mosdns953:$( (ss -lnup 2>/dev/null || netstat -lnup 2>/dev/null) | grep -c ':953')"
echo "R:uci_defaults_left:$(ls /etc/uci-defaults 2>/dev/null | wc -l)"
echo "R:fw4_check:$(fw4 check >/dev/null 2>&1 && echo OK || echo FAIL)"
echo "R:fw4_net_device:$(grep -c 'net.physdev || net.device' /usr/share/ucode/fw4.uc 2>/dev/null)"
echo "R:upnpd_enabled:$(uci -q get upnpd.@upnpd[0].enabled)"
echo "R:upnpd_ext_private:$(uci -q get upnpd.@upnpd[0].ext_allow_private_ipv4)"
echo "R:upnp_relay:$(test -x /etc/init.d/upnp_nat_relay && echo present || echo missing)"
echo "R:flowcone_pkg:$(apk list -I 2>/dev/null | grep -c '^flowcone')"
echo "R:btf:$(test -e /sys/kernel/btf/vmlinux && echo yes || echo no)"
echo "R:flowcone_proc:$(pgrep -f flowcone >/dev/null 2>&1 && echo yes || echo no)"
echo "R:offload_rule:$(nft list ruleset 2>/dev/null | grep -Eic 'flowtable|offload')"
echo "R:dmesg_bad:$(dmesg 2>/dev/null | grep -iE 'flowcone|bpf' | grep -icE 'error|fail')"
echo "R:sfe_opt:$(uci -q get firewall.@defaults[0].shortcut_fe 2>/dev/null || echo gone)"
echo CAP_END
EOS
)"

if [ -n "${INJECT}" ]; then
	SNIPPET="${SNIPPET/echo CAP_END/echo \"R:${INJECT}:INJECTED-BAD\"
echo CAP_END}"
fi

printf '%s\n' "${SNIPPET}" | while IFS= read -r line; do
	send "${line}"
	# 串口是模拟的，发太快会丢字符（表现为命令被截断、$() 不展开）
	sleep 0.25
done

if ! wait_for 'CAP_END' "${CAP_TIMEOUT}"; then
	echo "ERROR: ${CAP_TIMEOUT}s 内未采集完证据，日志尾部：" >&2
	tail -n 40 "${LOG}" >&2
	exit 1
fi
sleep 1

: >"${RESULTS}"
# 只认「行首就是 R:」的输出行；回显出来的命令行（echo "R:...$(...)"）不算证据
sed -n '/CAP_BEGIN/,/CAP_END/p' "${LOG}" | tr -d '\r' |
	sed -n 's/^R:\([a-z0-9_]*\):\(.*\)$/\1	\2/p' >"${RESULTS}"

echo "[cap] 证据："
sed 's/^/    /' "${RESULTS}"

evaluate "${RESULTS}"

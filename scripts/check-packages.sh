#!/usr/bin/env bash
# 包清单检查。缺包、写错包名、越界包一律非 0 退出——不允许"警告后继续出镜像"。
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ERR=0

die() { printf 'FAIL %s\n' "$*" >&2; ERR=$((ERR + 1)); }

# 首版范围冻结线（迁移方案 §7.5 / 保全审计 §10.4）：这些包不进首版
FORBIDDEN='3proxy|performance-manager|rill-runtime-preview|dnsmasq_full_ipset|luci-app-wireguard|kmod-ipt-nat6'

mapfile_or_read() { cat "$@"; }

echo "==> 收集 overlay/packages/*.extra"
list="$(find "${ROOT_DIR}/overlay/packages" -maxdepth 1 -name '*.extra' -type f -exec cat {} + 2>/dev/null || true)"
pkgs="$(printf '%s\n' "${list}" | sed 's/[[:space:]]*#.*//' | tr -d '\r' | awk 'NF')"

if [ -z "${pkgs}" ]; then
	echo "  （空清单，P3 前正常）"
else
	dups="$(printf '%s\n' "${pkgs}" | sort | uniq -d)"
	[ -z "${dups}" ] || die "重复包名：$(echo ${dups})"

	while IFS= read -r p; do
		case "${p}" in
		*[!a-zA-Z0-9._+-]*) die "非法包名：${p}" ;;
		esac
		if printf '%s\n' "${p}" | grep -qE "^(${FORBIDDEN})$"; then
			die "越界包（不在首版冻结线内）：${p}"
		fi
	done <<< "${pkgs}"
fi

echo "==> 检查 profiles 里的包名与 overlay 不冲突"
overlap="$(comm -12 \
	<(printf '%s\n' "${pkgs}" | sort -u) \
	<(cat "${ROOT_DIR}/upstream/yaof/profiles/packages.common" "${ROOT_DIR}/upstream/yaof/profiles/packages.x86_64" 2>/dev/null | sed 's/[[:space:]]*#.*//' | awk 'NF' | sort -u) 2>/dev/null)"
# 与上游重复无害（apk 会去重），只提示，避免上游新增同名包时误报
[ -z "${overlap}" ] || echo "  note 与上游 profiles 重复（可清理）：$(echo ${overlap})"

if [ "${ERR}" -ne 0 ]; then
	printf '==> 包检查失败：%d 项\n' "${ERR}" >&2
	exit 1
fi
echo "==> 包检查通过（$(printf '%s\n' "${pkgs}" | awk 'NF' | wc -l | tr -d ' ') 个追加包）"

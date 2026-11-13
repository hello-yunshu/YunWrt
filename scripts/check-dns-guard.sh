#!/usr/bin/env bash
# 镜像内 openclash-dns-guard 门禁：overlay 文件必须真的落进 rootfs，且带开机自启。
#
# 与 check-openclash-watchdog.sh 互补，两者管的不是同一个东西：
#   - check-openclash-watchdog.sh：luci-app-openclash 自带 /usr/share/openclash/openclash_watchdog.sh
#     的版本（防止 feed 回退到有缺陷的 < 0.48.002）。
#   - 本脚本：随本仓库 overlay 发布的 /usr/sbin/openclash-dns-guard.sh 及其 init.d/config，
#     只读 build/ 里的 rootfs，断言它们确实被打进镜像。
# 注意：不要在 scripts/build.sh 的 manifest 核对里重复这件事——那一步只核对 apk 包，
# overlay 文件不在 manifest 里，这里必须单独查。
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ERR=0

die() { printf '  FAIL %s\n' "$*" >&2; ERR=$((ERR + 1)); }
ok() { printf '  ok  %s\n' "$*"; }

rootfs="$(find "${ROOT_DIR}/build" -type d -path '*/build_dir/*/root-x86' 2>/dev/null | head -1)"
if [ -z "${rootfs}" ]; then
	die "找不到 ImageBuilder rootfs（*/build_dir/*/root-x86），无法确认 overlay 是否进镜像"
else
	guard="${rootfs}/usr/sbin/openclash-dns-guard.sh"
	initd="${rootfs}/etc/init.d/openclash-dns-guard"
	cfg="${rootfs}/etc/config/openclash-dns-guard"
	ud="${rootfs}/etc/uci-defaults/97-yunwrt-openclash-dns-guard"
	rc_expected="/etc/rc.d/S96openclash-dns-guard"

	if [ ! -f "${guard}" ]; then
		die "rootfs 里没有 /usr/sbin/openclash-dns-guard.sh：overlay/files 未进镜像"
	elif [ ! -x "${guard}" ]; then
		die "/usr/sbin/openclash-dns-guard.sh 没有可执行位，procd 拉不起来"
	elif ! grep -q 'openclash-dns-guard.state' "${guard}"; then
		die "/usr/sbin/openclash-dns-guard.sh 内容异常（找不到状态文件名），可能是旧版或空文件"
	else
		ok "rootfs 有 /usr/sbin/openclash-dns-guard.sh（可执行）"
	fi

	if [ ! -x "${initd}" ]; then
		die "/etc/init.d/openclash-dns-guard 缺失或不可执行"
	elif ! grep -q '^START=96' "${initd}" || ! grep -q 'USE_PROCD=1' "${initd}"; then
		die "/etc/init.d/openclash-dns-guard 缺 START=96 或 USE_PROCD=1，与预期服务定义不符"
	else
		ok "rootfs 有 /etc/init.d/openclash-dns-guard（START=96，procd）"
	fi

	if [ ! -f "${cfg}" ]; then
		die "/etc/config/openclash-dns-guard 缺失：服务启动时读不到配置"
	elif ! grep -q "config guard 'main'" "${cfg}" || ! grep -q "option enabled '1'" "${cfg}"; then
		die "/etc/config/openclash-dns-guard 缺 config guard 'main' 或 enabled '1'（默认不自启）"
	elif grep -qE "^[[:space:]]*option bark_key '[^']+'" "${cfg}"; then
		die "/etc/config/openclash-dns-guard 里写进了非空 bark_key，密钥不能进镜像"
	else
		ok "rootfs 有 /etc/config/openclash-dns-guard（enabled=1，bark_key 为空）"
	fi

	if [ ! -x "${ud}" ]; then
		die "/etc/uci-defaults/97-yunwrt-openclash-dns-guard 缺失或不可执行：首次开机不会 enable"
	elif ! grep -q 'S96openclash-dns-guard' "${ud}"; then
		die "uci-defaults 里没有 ${rc_expected} 的断言，开机自启可能没生效"
	else
		ok "rootfs 有 uci-defaults 自启脚本（断言 ${rc_expected}）"
	fi
fi

if [ "${ERR}" -ne 0 ]; then
	printf '==> openclash-dns-guard 门禁失败：%d 项（overlay 文件可能没进镜像或丢了权限）\n' "${ERR}" >&2
	exit 1
fi
echo "==> openclash-dns-guard 门禁通过"

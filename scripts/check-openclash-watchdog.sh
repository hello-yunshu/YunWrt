#!/usr/bin/env bash
# 镜像内 OpenClash 看门狗门禁，构建末尾跑，只读 build/，不改任何包文件。
#
# 缺陷（luci-app-openclash < 0.48.002）：看门狗用
#   jsonfilter -e '@.openclash.instances.*.running' | grep -q true
# 判断主核心是否在跑。0.47.x 里 openclash-watchdog 自己是 openclash 服务的实例，
# 通配符会把它算进去，于是主核心崩溃后仍判为"在跑"，"enable=0 + stop" 分支永不
# 触发；procd respawn 耗尽后也不会调用 stop_service，revert_dnsmasq/revert_firewall
# 一次都不执行，dnsmasq 停在 127.0.0.1#dns_port 而该端口无人监听 → 全屋解析失效。
#
# 修复在 0.48.002 里由上游完成（精确探测 instances.openclash，且看门狗独立成
# openclash-watchdog 服务）。这里不改包文件：镜像层覆盖的文件会被 apk upgrade 覆盖，
# 所以只断言"落进镜像的脚本是修好的版本"，feed 回退到坏版本时构建直接失败。
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ERR=0

die() { printf '  FAIL %s\n' "$*" >&2; ERR=$((ERR + 1)); }
ok() { printf '  ok  %s\n' "$*"; }

# ImageBuilder 组装出的 rootfs 就是打进镜像的内容
watchdog="$(find "${ROOT_DIR}/build" -path '*/build_dir/*/root-x86/usr/share/openclash/openclash_watchdog.sh' -type f 2>/dev/null | head -1)"
manifest="$(find "${ROOT_DIR}/build" -path '*/bin/targets/x86/64/*.manifest' -type f 2>/dev/null | head -1)"

if [ -z "${watchdog}" ]; then
	die "镜像 rootfs 里没有 openclash_watchdog.sh：luci-app-openclash 没进镜像或构建没跑完"
else
	if grep -qE 'instances\.\*\.running' "${watchdog}"; then
		die "看门狗仍用通配符探测主核心（instances.*.running），会把自己算成在跑"
	else
		ok "看门狗没有通配符探测"
	fi

	if grep -qE 'instances\.openclash\.running|instances\.openclash\.respawn\.retry' "${watchdog}"; then
		ok "看门狗精确探测 openclash 主实例"
	else
		die "看门狗里没有 instances.openclash 精确探测，不能确认是修好的版本"
	fi
fi

if [ -n "${manifest}" ]; then
	version="$(sed -n 's/^luci-app-openclash - //p' "${manifest}" | head -1)"
	[ -n "${version}" ] || die "manifest 里没有 luci-app-openclash（包清单已漂移）"
	[ -z "${version}" ] || echo "    luci-app-openclash - ${version}"
else
	die "找不到镜像 manifest，无法确认包版本"
fi

if [ "${ERR}" -ne 0 ]; then
	printf '==> OpenClash 看门狗门禁失败：%d 项（feed 里的包可能已回退到 < 0.48.002）\n' "${ERR}" >&2
	exit 1
fi
echo "==> OpenClash 看门狗门禁通过"

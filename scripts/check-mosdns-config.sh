#!/usr/bin/env bash
# mosdns 自带配置门禁：保证"出厂就有一个 mosdns 能真加载的配置"。
#
# 这条门禁防的是一整类静默失效，不是某个已知 bug：
#   luci-app-mosdns 的 init 脚本会为 /var/etc/mosdns.json 生成配置，里面用到
#   log.size / stats_api / adblock_set —— 这三项只有打过 sbwml 补丁的 mosdns 才有。
#   预编译源里的 mosdns 5.3.4-r15 是上游原版，加载即 FATAL；而 FATAL 只写进
#   procd 日志，dnsmasq 上游由 OpenClash 占着，日常完全看不出异常，直到代理挂掉
#   需要 953 兜底时才暴露。所以必须在这里把"配置文件与二进制不配套"变成构建期失败。
#
# 检查分两层：
#   静态层：overlay 里的配置文件与 uci-defaults 本身是否自洽（无需构建即可跑）
#   镜像层：build/ 里的 rootfs 是否真的带上了这份配置（assemble + IB 之后才可跑）
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY="${ROOT_DIR}/overlay/files"
CONF_REL="etc/mosdns/config_custom.yaml"
CONF="${OVERLAY}/${CONF_REL}"
UCI_DEFAULTS="${OVERLAY}/etc/uci-defaults/97-yunwrt-mosdns"
EXPECT_CONF="/etc/mosdns/config_custom.yaml"
ERR=0

die() { printf '  FAIL %s\n' "$*" >&2; ERR=$((ERR + 1)); }
ok() { printf '  ok  %s\n' "$*"; }
note() { printf '  note %s\n' "$*"; }

echo "==> 静态层：随镜像发布的 mosdns 配置"

if [ ! -f "${CONF}" ]; then
	die "缺少 overlay/files/${CONF_REL}"
else
	ok "存在 overlay/files/${CONF_REL}"

	# 生成器专用、原版二进制不认的键。任何一个出现，mosdns 起的瞬间就退出。
	for bad in stats_api adblock_set query_log; do
		if grep -qE "^[[:space:]]*type:[[:space:]]*${bad}[[:space:]]*$" "${CONF}"; then
			die "配置用了 ${bad} 插件：未打补丁的 mosdns 5.3.4 没有它（plugin type ${bad} not defined）"
		fi
	done
	if sed -n '/^log:/,/^[^[:space:]]/p' "${CONF}" | grep -qE "^[[:space:]]+(size|backups):"; then
		die "log 段出现 size/backups：原版 mosdns 5.3.4 的 log schema 不认（'log' has invalid keys）"
	fi
	for bad in prefetch dump_file dump_interval; do
		if grep -qE "^[[:space:]]*${bad}:" "${CONF}"; then
			die "配置用了 ${bad}：属于生成器给补丁版准备的缓存参数"
		fi
	done
	ok "没有生成器专用的插件与键"

	# 953 是 openclash-dns-guard 的 fallback_port，也是 LuCI 里 listen_port 的默认值。
	# 两边对不上，守护降级时会把 dnsmasq 指向一个没人监听的端口。
	if ! grep -qE 'listen:[[:space:]]*"127\.0\.0\.1:953"' "${CONF}"; then
		die "配置里没有 listen: \"127.0.0.1:953\"，与 dns-guard 的 fallback_port 对不上"
	elif [ "$(grep -cE 'listen:[[:space:]]*"127\.0\.0\.1:953"' "${CONF}")" -lt 2 ]; then
		die "只有一处 953 监听：UDP 与 TCP 入口都必须有，否则纯 TCP 客户端解析不到"
	else
		ok "UDP/TCP 均监听 127.0.0.1:953"
	fi

	# 境外 DoT 直连不通（1.1.1.1 的 TLS 会被重置），且返回海外 CDN 节点。
	if grep -qE 'addr:[[:space:]]*"tls://(1\.1\.1\.1|8\.8\.8\.8)"' "${CONF}"; then
		die "上游用了境外 DoT：WAN 直连下不可用，且地理视图是海外（EdgeOne 会给新加坡节点）"
	fi
	ok "上游不含境外 DoT"
fi

if [ ! -f "${UCI_DEFAULTS}" ]; then
	die "缺少 overlay/files/etc/uci-defaults/97-yunwrt-mosdns"
else
	if ! grep -qF "set mosdns.config.configfile='${EXPECT_CONF}'" "${UCI_DEFAULTS}"; then
		die "uci-defaults 未把 configfile 设为 ${EXPECT_CONF}"
	elif ! grep -qF "= \"${EXPECT_CONF}\"" "${UCI_DEFAULTS}"; then
		die "uci-defaults 没有回读校验 configfile（commit 失败不会体现在 restart 返回码里）"
	else
		ok "uci-defaults 指向 ${EXPECT_CONF} 并回读校验"
	fi
	if ! grep -qE '^set mosdns\.config\.adblock=.0.$' "${UCI_DEFAULTS}"; then
		die "uci-defaults 未关闭 adblock：init 脚本会后台下载广告清单写进 /etc/mosdns/rule，而该插件在镜像里不存在"
	else
		ok "adblock 已关闭"
	fi
fi

# 同一个目录里不允许再躺第二份 mosdns 配置：上一版就是因为留了个
# /etc/mosdns/yunwrt.yaml 的死文件，看起来"带了配置"，实际从没被加载过。
stray="$(find "${OVERLAY}/etc/mosdns" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) 2>/dev/null |
	grep -vE "/(config_custom\.yaml|.*\.meta\.json)$" || true)"
[ -z "${stray}" ] || die "etc/mosdns 下有多余配置文件（不会被加载，只会误导排查）：${stray}"
[ -n "${stray}" ] || ok "etc/mosdns 下只有 config_custom.yaml"

echo "==> 镜像层：build/ 的 rootfs"

# build/ 下有两个 root-x86（target-x86_64_musl 与 target-x86_64-musl），只有一个
# 是 prepare_rootfs 真正处理过的。挑那个带 etc/ 的，否则会对着空目录报一堆假失败。
rootfs=""
while IFS= read -r d; do
	[ -d "${d}/etc" ] || continue
	rootfs="${d}"
	break
done < <(find "${ROOT_DIR}/build" -type d -path '*/build_dir/*/root-x86' 2>/dev/null | sort)

if [ -z "${rootfs}" ]; then
	note "没有 build/ 的 rootfs（尚未 assemble/构建），跳过镜像层检查"
else
	# 先看 uci-defaults 在不在：它只可能来自 overlay，缺了就说明 USER_FILES 这一步
	# 根本没跑（半成品 rootfs，或 ImageBuilder 不再叠加 files/）。此时再去比对配置
	# 内容只会得到"被包覆盖"的错误结论，所以分开报。
	if [ ! -f "${rootfs}/etc/uci-defaults/97-yunwrt-mosdns" ]; then
		die "rootfs 里没有 97-yunwrt-mosdns：overlay 未叠加进 rootfs（半成品构建，或上游不再支持 FILES）；mosdns 会保持 luci-app-mosdns 的默认装态 enabled=0"
	elif [ ! -f "${rootfs}${EXPECT_CONF}" ]; then
		die "rootfs 里没有 ${EXPECT_CONF}：overlay 未进镜像"
	elif ! cmp -s "${CONF}" "${rootfs}${EXPECT_CONF}"; then
		die "rootfs 里的 ${EXPECT_CONF} 与 overlay 不一致：被 luci-app-mosdns 的 conffile 盖回去了（USER_FILES 必须在包安装之后叠加）"
	else
		ok "rootfs 带上了 97-yunwrt-mosdns 与 ${EXPECT_CONF}（内容与 overlay 一致）"
	fi

	# configfile 的取值必须真的在 LuCI 下拉框里，否则用户点一次保存就被重置。
	basic="${rootfs}/www/luci-static/resources/view/mosdns/basic.js"
	if [ -f "${basic}" ]; then
		if grep -q "value('${EXPECT_CONF}'" "${basic}"; then
			ok "LuCI 下拉框接受 ${EXPECT_CONF}（保存不会回滚）"
		else
			die "LuCI 的 basic.js 不认识 ${EXPECT_CONF}：用户保存设置时会重置为默认，mosdns 再次崩溃"
		fi
	else
		note "rootfs 里没有 mosdns 的 basic.js，无法核对下拉框取值"
	fi

	# 二进制能力与配置的匹配关系，把"生成器能不能用"这件事量出来，供日后判断。
	bin="${rootfs}/usr/bin/mosdns"
	if [ -f "${bin}" ]; then
		if LC_ALL=C grep -aq "stats_api" "${bin}"; then
			note "镜像里的 mosdns 带 stats_api（补丁版）：日后可考虑改回默认生成器"
		else
			note "镜像里的 mosdns 不带 stats_api（上游原版）：默认生成器不可用，必须用自带配置"
		fi
	fi
fi

if [ "${ERR}" -ne 0 ]; then
	printf '==> mosdns 配置门禁失败：%d 项\n' "${ERR}" >&2
	exit 1
fi
echo "==> mosdns 配置门禁通过"

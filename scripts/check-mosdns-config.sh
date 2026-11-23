#!/usr/bin/env bash
# mosdns 门禁：镜像里的二进制必须是配套补丁版，配置必须走上游生成器。
#
# 背景：luci-app-mosdns 的界面只对 /var/etc/mosdns.json 生效——basic.js 里几乎
# 每个开关都 depends('configfile','/var/etc/mosdns.json')。那份 JSON 含 log.size
# 与 stats_api，只有打了 sbwml 那套补丁的 mosdns 才认。
#
# 而 mosdns-5.3.4-r15 这个名字对应两种互不兼容的构建，包名、版本号乃至文件大小
# 都很接近，靠元数据分不出来。装成无补丁版的表现是静默降级：生成器写出的配置
# 加载即 FATAL，FATAL 只进 procd 日志；dnsmasq 上游由 OpenClash 占着，日常完全
# 看不出异常，直到代理挂掉需要 953 兜底时才暴露。
#
# 所以这里把"二进制不配套"变成构建期失败。检查分两层：
#   静态层：overlay 与 uci-defaults 是否自洽（无需构建即可跑）
#   镜像层：rootfs 里的 mosdns 真的带补丁（assemble + ImageBuilder 之后才可跑）
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY="${ROOT_DIR}/overlay/files"
UCI_DEFAULTS="${OVERLAY}/etc/uci-defaults/97-yunwrt-mosdns"
EXPECT_CONF="/var/etc/mosdns.json"
ERR=0

die() { printf '  FAIL %s\n' "$*" >&2; ERR=$((ERR + 1)); }
ok() { printf '  ok  %s\n' "$*"; }
note() { printf '  note %s\n' "$*"; }

echo "==> 静态层：配置模式与 uci-defaults"

# overlay 里不能再躺一份 mosdns 配置。带 config_custom.yaml 就意味着 configfile
# 被钉在那个取值上，界面上的开关全部隐藏——正是这一版要根除的状态。
if [ -e "${OVERLAY}/etc/mosdns" ]; then
	die "overlay/files/etc/mosdns 仍存在：方案已改为上游生成器，这里的配置会覆盖包自带文件并让界面开关失效"
else
	ok "overlay 未覆盖 /etc/mosdns"
fi

if [ ! -f "${UCI_DEFAULTS}" ]; then
	die "缺少 overlay/files/etc/uci-defaults/97-yunwrt-mosdns"
else
	if grep -qF "set mosdns.config.configfile='${EXPECT_CONF}'" "${UCI_DEFAULTS}"; then
		ok "uci-defaults 把 configfile 设为 ${EXPECT_CONF}（走上游生成器）"
	else
		die "uci-defaults 未把 configfile 设为 ${EXPECT_CONF}"
	fi
	if grep -qF "= \"${EXPECT_CONF}\"" "${UCI_DEFAULTS}"; then
		ok "uci-defaults 回读校验 configfile"
	else
		die "uci-defaults 没有回读校验 configfile（commit 失败不会体现在 restart 返回码里）"
	fi

	# 953 是 openclash-dns-guard 的 fallback_port，也是 OpenClash 指向 mosdns 的
	# 地址。生成器默认是 5335，不对齐就会让整条 DNS 链断掉。
	if grep -qE "^set mosdns\.config\.listen_port='953'" "${UCI_DEFAULTS}"; then
		ok "listen_port 固定为 953（与 dns-guard 的 fallback_port 对齐）"
	else
		die "uci-defaults 未把 listen_port 设为 953：生成器默认 5335，会让 dns-guard 降级到没人监听的端口"
	fi
	if grep -qE "^set mosdns\.config\.listen_address='127\.0\.0\.1'" "${UCI_DEFAULTS}"; then
		ok "listen_address 固定为 127.0.0.1（不做 DNS 劫持）"
	else
		die "uci-defaults 未把 listen_address 设为 127.0.0.1"
	fi

	# 生成器默认 remote_dns 是 tls://8.8.8.8。这条线路上 853 会被中断（SYN 无响应
	# 或握手后单向 EOF），留着只会让"国外域名"分支卡到超时。
	if grep -qE "^(set|add_list) mosdns\.config\.(remote_dns|local_dns)=.*tls://(1\.1\.1\.1|8\.8\.8\.8)" "${UCI_DEFAULTS}"; then
		die "uci-defaults 把上游设成境外 DoT：WAN 直连下不可用"
	elif grep -qE "^set mosdns\.config\.remote_dns=" "${UCI_DEFAULTS}"; then
		ok "remote_dns 已改为国内可用上游"
	else
		die "uci-defaults 未覆盖 remote_dns：生成器默认 tls://8.8.8.8 在这条线路上不可用"
	fi
fi

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
	if [ ! -f "${rootfs}/etc/uci-defaults/97-yunwrt-mosdns" ]; then
		die "rootfs 里没有 97-yunwrt-mosdns：overlay 未叠加进 rootfs（半成品构建，或上游不再支持 FILES）；mosdns 会保持 luci-app-mosdns 的默认装态 enabled=0"
	else
		ok "rootfs 带上了 97-yunwrt-mosdns"
	fi

	# 这一条是本门禁的核心：镜像里的 mosdns 必须是补丁版。三个插件名只要缺一个，
	# 生成器写出的 /var/etc/mosdns.json 就会加载失败。
	bin="${rootfs}/usr/bin/mosdns"
	if [ ! -f "${bin}" ]; then
		die "rootfs 里没有 /usr/bin/mosdns：mosdns 未进镜像"
	else
		for plugin in stats_api adblock_set ip_set; do
			if LC_ALL=C grep -aq "${plugin}" "${bin}"; then
				ok "mosdns 带 ${plugin}"
			else
				die "mosdns 不带 ${plugin}：装成了无补丁构建，上游生成器的配置必然加载失败（详见 docs/decisions/D15）"
			fi
		done
	fi

	# 配置由生成器写到 /var/etc，rootfs 里不该出现我们自己的 /etc/mosdns/*.yaml。
	# 上一版就是因为留了个从没被加载的死文件，看起来"带了配置"，实际全靠手写。
	#
	# 但有一个例外必须放行：luci-app-mosdns 自己的 Makefile 就装了一份
	#   /etc/mosdns/config_custom.yaml   （sbwml 上游 root/etc/mosdns/ 下的模板）
	# 它是界面「自定义配置」的落点，configfile 钉在 /var/etc/mosdns.json 时不会被加载。
	# 静态层已经断言 overlay 里没有 /etc/mosdns，所以 rootfs 里出现的 YAML 只可能来自包，
	# 这一条要挡的是「我们自己又塞了一份覆盖包自带文件」——不是包自带那份。
	pkg_own="${rootfs}/etc/mosdns/config_custom.yaml"
	stray="$(find "${rootfs}/etc/mosdns" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null |
		grep -vxF "${pkg_own}" || true)"
	[ -z "${stray}" ] || die "rootfs 的 /etc/mosdns 下有多余 YAML（不会被加载，只会误导排查）：${stray}"
	if [ -f "${pkg_own}" ]; then
		ok "/etc/mosdns 下只有包自带的 config_custom.yaml（configfile 指向 /var/etc，不会被加载）"
	else
		ok "/etc/mosdns 下没有多余 YAML"
	fi
fi

if [ "${ERR}" -ne 0 ]; then
	printf '==> mosdns 门禁失败：%d 项\n' "${ERR}" >&2
	exit 1
fi
echo "==> mosdns 门禁通过"

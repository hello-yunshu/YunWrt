#!/usr/bin/env bash
# 凭据扫描门禁：默认扫工作树（tracked 文件），--history 扫全部提交，--self-test 证明门禁能真红。
# 任何命中都以非 0 退出，供 CI 直接当门禁用。
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="tree"
case "${1:-}" in
	--history) MODE="history" ;;
	--objects) MODE="objects" ;;
	--self-test) MODE="self-test" ;;
	"") ;;
	*)
		echo "用法: $0 [--history|--objects|--self-test]" >&2
		exit 2
		;;
esac

HITS="$(mktemp)"
trap 'rm -f "${HITS}"' EXIT

# 模板/占位/GitHub Actions 的 secrets 引用不算命中
ALLOW_RE='\$\{\{|GITHUB_TOKEN|your_|example\.(com|org)|CHANGEME|placeholder|REDACTED|<[A-Za-z_-]+>'

# name | ERE
PATTERNS=(
	'私钥|-----BEGIN [A-Z ]*PRIVATE KEY-----'
	'家目录|\/(Users|home)\/[A-Za-z0-9._-]+\/'
	'代理或订阅链接|(ss|ssr|vmess|vless|trojan|hysteria2?|tuic|socks5|clash)://'
	'MAC 地址|([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}'
	'凭据赋值|(password|passwd|passphrase|secret|api[_-]?key|token|uuid|psk|private[_-]?key|wpa[_-]?key)[[:space:]]*[:=][[:space:]]*[^[:space:]]{8,}'
	'云平台 token|(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35})'
	'UUID|([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
	'阴影口令|^[^:]+:\$[0-9a-z]\$[^:]*:'
)

hit() { printf '[%s] %s\n' "$1" "${2//$'\t'/: }" >>"${HITS}"; }

# 批量判定：$1 = 待判定文件（每行 "file:line:content"）
judge_file() {
	local lines="$1" pat name re
	[ -s "${lines}" ] || return 0

	for pat in "${PATTERNS[@]}"; do
		name="${pat%%|*}"
		re="${pat#*|}"
		grep -iE -- "${re}" "${lines}" | grep -vE -- "${ALLOW_RE}" |
			while IFS= read -r l; do hit "${name}" "${l}"; done
	done

	# 公网 IPv4：八位组必须 ≤255（排除 6.12.94.2023 这类版本号），且非私有/保留/文档段
	awk '
	function is_priv(ip) {
		return ip ~ /^(0\.0\.0\.0|127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|255\.255\.|22[4-9]\.|2[3-5][0-9]\.|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.)/
	}
	function octets_ok(ip,   a, i) {
		split(ip, a, ".")
		for (i = 1; i <= 4; i++) if (a[i] + 0 > 255) return 0
		return 1
	}
	{
		t = $0; sub(/^[^\t]*\t/, "", t)
		bad = 0; s = t
		while (match(s, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
			ip = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
			if (octets_ok(ip) && !is_priv(ip)) { bad = 1 }
		}
		if (bad) print
	}' "${lines}" | grep -vE -- "${ALLOW_RE}" |
		while IFS= read -r l; do hit '公网 IPv4' "${l}"; done

	# 公网 IPv6：只看 2000::/3（当前全球单播分配段），天然排除时间戳、fe80::、fc00::、ff02::
	# 2001:db8::/32 是文档段，不算真实地址
	awk '
	{
		t = $0; sub(/^[^\t]*\t/, "", t)
		bad = 0; s = t
		while (match(s, /([0-9a-fA-F]{1,4}:){2,}[0-9a-fA-F]{0,4}/)) {
			ip = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
			if (ip ~ /^[23][0-9a-fA-F]{3}:/ && ip !~ /^2001:db8:/) { bad = 1 }
		}
		if (bad) print
	}' "${lines}" | grep -vE -- "${ALLOW_RE}" |
		while IFS= read -r l; do hit '公网 IPv6' "${l}"; done
}

scan_tracked() {
	local f
	while IFS= read -r f; do
		grep -HniE -- '' "${ROOT_DIR}/${f}" 2>/dev/null |
			sed "s|^${ROOT_DIR}/||" | sed -E 's/^([^:]+):([0-9]+):/\1:\2\t/' || true
	done < <(git -C "${ROOT_DIR}" ls-files)
}

scan_history() {
	# shellcheck disable=SC2046
	git -C "${ROOT_DIR}" grep -nIiE -e '.' $(git -C "${ROOT_DIR}" rev-list --all) -- . 2>/dev/null |
		sed -E 's/^([0-9a-f]{7,40}):([^:]+):([0-9]+):/\1 \2:\3\t/' || true
}

scan_names() {
	local f
	while IFS= read -r f; do
		case "${f}" in
		*.rsa.pub | *.pub) continue ;;
		*id_rsa* | *id_ed25519* | *.pem | *.key | *.p12 | *.pfx | *.ovpn | *.env | *credential*)
			hit '可疑文件名' "${f}"
			;;
		esac
	done < <(git -C "${ROOT_DIR}" ls-files)
}

self_test() {
	local tmp
	tmp="$(mktemp -d)"

	# 样本在运行时拼出来，避免扫描器源码自身成为命中
	local gh_sample ip4 v6
	gh_sample="$(printf '%s%s' 'ghp_' '0123456789abcdefghij0123456789abcd')"
	ip4="8.$(printf '%s' '8.8.8')"
	v6="2408:$(printf '%s' '8207:1234::1')"
	printf 'leak.txt:1\tcfg = { api_key = "%s" }\n' "${gh_sample}" >"${tmp}/lines"
	: >"${HITS}"
	judge_file "${tmp}/lines"
	if [ ! -s "${HITS}" ]; then
		echo "FAIL self-test: 注入的假 token 未被检出（门禁不会红）" >&2
		rm -rf "${tmp}"
		return 1
	fi
	echo "ok  self-test: 注入的假 token 被检出 -> $(head -1 "${HITS}")"

	printf 'clean.txt:1\t# 没有任何凭据\nclean.txt:2\tPORT=8080\nclean.txt:3\tGITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}\nclean.txt:4\tnameserver 192.168.2.1\n' >"${tmp}/lines"
	: >"${HITS}"
	judge_file "${tmp}/lines"
	if [ -s "${HITS}" ]; then
		echo "FAIL self-test: 干净内容被误报" >&2
		cat "${HITS}" >&2
		rm -rf "${tmp}"
		return 1
	fi
	echo "ok  self-test: 干净内容放行"

	# 3) IP 判定：公网要红，版本号/时间戳/内网要绿
	printf 'a:1\tupstream %s\nb:1\tversion 6.12.94.2023.05.17\nc:1\ttime 13:28:21\nd:1\tv6 %s\ne:1\tv6 fe80::1\nf:1\tns 192.168.2.1\n' "${ip4}" "${v6}" >"${tmp}/lines"
	: >"${HITS}"
	judge_file "${tmp}/lines"
	if ! grep -qF "${ip4}" "${HITS}" || ! grep -qF '2408:' "${HITS}"; then
		echo "FAIL self-test: 公网 IP 未被检出" >&2
		cat "${HITS}" >&2
		rm -rf "${tmp}"
		return 1
	fi
	if grep -qE '(6\.12\.94\.2023|13:28:21|fe80:|192\.168\.)' "${HITS}"; then
		echo "FAIL self-test: 版本号/时间戳/内网地址被误报" >&2
		cat "${HITS}" >&2
		rm -rf "${tmp}"
		return 1
	fi
	echo "ok  self-test: 公网 IP 命中，版本号/时间戳/内网地址放行"
	rm -rf "${tmp}"
}

LINES="$(mktemp)"
trap 'rm -f "${HITS}" "${LINES}"' EXIT

case "${MODE}" in
self-test)
	self_test
	exit $?
	;;
objects)
	echo "==> 全量对象扫描（含不可达 blob，不只可达提交）"
	while IFS= read -r oid; do
		git -C "${ROOT_DIR}" cat-file blob "${oid}" 2>/dev/null |
			grep -nE '' | sed -E "s|^([0-9]+):|obj:${oid}:\1\t|"
	done < <(git -C "${ROOT_DIR}" cat-file --batch-all-objects --batch-check='%(objecttype) %(objectname)' |
		awk '$1 == "blob" { print $2 }') >"${LINES}"
	echo "    待扫行数：$(wc -l <"${LINES}" | tr -d ' ')"
	judge_file "${LINES}"
	;;
tree)
	echo "==> 工作树扫描（tracked 文件）"
	scan_tracked >"${LINES}"
	echo "    待扫行数：$(wc -l <"${LINES}" | tr -d ' ')"
	judge_file "${LINES}"
	echo "==> 文件名扫描"
	scan_names
	;;
history)
	echo "==> 全历史扫描"
	scan_history >"${LINES}"
	echo "    待扫行数：$(wc -l <"${LINES}" | tr -d ' ')"
	judge_file "${LINES}"
	;;
esac

if [ -s "${HITS}" ]; then
	printf '\n==> 命中 %s 条：\n' "$(wc -l <"${HITS}" | tr -d ' ')" >&2
	sort -u "${HITS}" >&2
	echo "==> 失败：存在疑似凭据，禁止发布" >&2
	exit 1
fi
echo "==> 通过：未发现疑似凭据"

#!/usr/bin/env bash
# 用本次构建实际解析出的 release，校验 patch 基线是否漂移。
# 失败必须非 0：构建成功但基线漂移，说明覆盖的文件已经不是我们以为的那个。
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
[ -n "${VERSION}" ] || {
	echo "用法: $0 <openwrt-version>" >&2
	exit 2
}

ERR=0
bad() {
	printf '  FAIL %s\n' "$*" >&2
	ERR=$((ERR + 1))
}
ok() { printf '  ok  %s\n' "$*"; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }

shopt -s nullglob
for d in "${ROOT_DIR}"/patches/*/; do
	[ -f "${d}meta.json" ] || continue
	name="$(basename "${d}")"
	repo="$(jq -r '.source_repo // empty' "${d}meta.json")"
	spath="$(jq -r '.source_path // empty' "${d}meta.json")"
	mpath="$(jq -r '.makefile_path // empty' "${d}meta.json")"
	expect="$(jq -r '.base_sha256 // empty' "${d}meta.json")"

	[ -n "${repo}" ] && [ -n "${spath}" ] && [ -n "${mpath}" ] && [ -n "${expect}" ] || {
		bad "${name}: meta.json 缺 source_repo/source_path/makefile_path/base_sha256"
		continue
	}

	mk="$(curl -fsSL --retry 3 "https://raw.githubusercontent.com/openwrt/openwrt/v${VERSION}/${mpath}" 2>/dev/null)" || {
		bad "${name}: 取不到 v${VERSION} 的 ${mpath}"
		continue
	}
	srcver="$(printf '%s\n' "${mk}" | sed -n 's/^PKG_SOURCE_VERSION:=//p' | head -1)"
	[ -n "${srcver}" ] || {
		bad "${name}: ${mpath} 里没有 PKG_SOURCE_VERSION"
		continue
	}

	actual="$(curl -fsSL --retry 3 "${repo}/raw/${srcver}/${spath}" 2>/dev/null | sha256 | awk '{print $1}')" || {
		bad "${name}: 取不到源码文件 ${spath}@${srcver}"
		continue
	}

	if [ "${actual}" = "${expect}" ]; then
		ok "${name}: 基线匹配 v${VERSION} / ${srcver}"
	else
		bad "${name}: 基线漂移（openwrt v${VERSION} 的 ${srcver}）期望=${expect} 实际=${actual}"
	fi
done

if [ "${ERR}" -ne 0 ]; then
	printf '==> patch 基线校验失败：%d 项\n' "${ERR}" >&2
	exit 1
fi
echo "==> patch 基线校验通过"

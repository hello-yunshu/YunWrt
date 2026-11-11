#!/usr/bin/env bash
# 由 upstream/yaof/ 重新生成 build/，再叠加 overlay 与 patch。build/ 不手工修改、不提交。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${ROOT_DIR}/build"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "${ROOT_DIR}/upstream/yaof/scripts" ] || die "upstream/yaof 不完整，先跑 scripts/sync-upstream.sh"

echo "==> 重建 build/"
rm -rf "${BUILD}"
mkdir -p "${BUILD}"
cp -a "${ROOT_DIR}/upstream/yaof/." "${BUILD}/"

has_files() { [ -n "$(find "$1" -type f ! -name '.gitkeep' -print -quit 2>/dev/null)" ]; }

echo "==> 叠加 rootfs 覆盖（.meta.json 是校验元数据，不进镜像）"
if has_files "${ROOT_DIR}/overlay/files"; then
	rsync -a --exclude='*.meta.json' --exclude='.gitkeep' \
		"${ROOT_DIR}/overlay/files/" "${BUILD}/files/"
fi

echo "==> 叠加 apk 公钥"
mkdir -p "${BUILD}/keys"
if has_files "${ROOT_DIR}/overlay/keys"; then
	rsync -a --exclude='.gitkeep' "${ROOT_DIR}/overlay/keys/" "${BUILD}/keys/"
fi

echo "==> 追加包清单"
for prof in common x86_64; do
	f="${ROOT_DIR}/overlay/packages/${prof}.extra"
	if [ -f "${f}" ]; then
		cat "${f}" >> "${BUILD}/profiles/packages.${prof}"
	fi
done

echo "==> 应用 patch 层"
shopt -s nullglob
for d in "${ROOT_DIR}"/patches/*/; do
	[ -f "${d}meta.json" ] || continue
	[ -f "${d}apply.sh" ] || die "$(basename "${d}"): 有 meta.json 却没有 apply.sh"
	echo "    -> $(basename "${d}")"
	bash "${d}apply.sh" "${BUILD}"
done

echo "==> 组装断言"
rej="$(find "${BUILD}" -name '*.rej' -print)"
[ -z "${rej}" ] || die "存在 .rej 文件：${rej}"
for p in scripts/build.sh profiles/packages.common profiles/packages.x86_64 files/etc/rc.local; do
	[ -e "${BUILD}/${p}" ] || die "组装后缺少 ${p}"
done

echo "==> build/ 就绪"

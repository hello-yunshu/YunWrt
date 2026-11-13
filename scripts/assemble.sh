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
	rsync -a --exclude='*.meta.json' --exclude='.gitkeep' --exclude='.DS_Store' \
		"${ROOT_DIR}/overlay/files/" "${BUILD}/files/"
fi

echo "==> 断言：overlay 提供的 init / uci-defaults / hotplug 脚本必须可执行"
# 只校验 overlay/files 里的文件：init.d 由 procd 直接 exec、uci-defaults 由 /etc/init.d/boot
# 逐个 source，hotplug.d 由 hotplug-call source，后两者虽不强制 +x，但我们自己的脚本一律 755，
# 一旦丢失就是打包失误。上游自带的（不在 overlay/files 里）权限不归我们管，扫全树会误伤。
bad=""
if [ -d "${ROOT_DIR}/overlay/files" ]; then
	while IFS= read -r f; do
		rel="${f#"${ROOT_DIR}/overlay/files/"}"
		[ -x "${BUILD}/files/${rel}" ] || bad="${bad} ${rel}"
	done < <(find "${ROOT_DIR}/overlay/files" -type f ! -name '*.meta.json' ! -name '.gitkeep' ! -name '.DS_Store' \
		\( -path '*/etc/uci-defaults/*' -o -path '*/etc/init.d/*' -o -path '*/etc/hotplug.d/*' \) 2>/dev/null)
fi
[ -z "${bad}" ] || die "以下脚本缺少可执行位：${bad}"

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
for p in scripts/build.sh profiles/packages.common profiles/packages.x86_64; do
	[ -e "${BUILD}/${p}" ] || die "组装后缺少 ${p}"
done
# 上游 25.12 已不带 files/etc/rc.local（定制迁入 system-addon 包），改验我们的 overlay
# 是否真的落进了 build/files，避免上游 build.sh 不再叠加 files/ 时静默丢文件。
if has_files "${ROOT_DIR}/overlay/files"; then
	[ -e "${BUILD}/files" ] || die "overlay/files 未叠加进 build/files"
fi

echo "==> build/ 就绪"

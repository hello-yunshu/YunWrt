#!/usr/bin/env bash
# 唯一构建入口。不向 build.sh 传版本：版本由上游 resolve_version() 决定（D3）。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
SHA="$(cat "${ROOT_DIR}/upstream/yaof.commit" 2>/dev/null || echo unknown)"
IB_LOG="$(mktemp -t yunwrt-ib-XXXXXX).log"
LOG_JSON="${ROOT_DIR}/build-log/${TS}-${SHA:0:7}.json"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

echo "==> 1/7 接口检查"
bash "${ROOT_DIR}/scripts/check-upstream.sh"

echo "==> 2/7 base 校验"
bash "${ROOT_DIR}/scripts/verify-bases.sh"

echo "==> 3/7 包检查"
bash "${ROOT_DIR}/scripts/check-packages.sh"

echo "==> 4/7 组装"
bash "${ROOT_DIR}/scripts/assemble.sh"

echo "==> 5/7 预置 ImageBuilder（注入自有 feed）"
# 上游 build.sh 只把自己维护的 feed 写进 IB 的 repositories；
# overlay/files 里的 yun-feed.list 只进镜像 rootfs，构建期 apk 看不到 → 自有包会被跳过。
# 因此先按上游即将使用的版本号把 IB 解包到位，注入 feed 地址与公钥；上游看到目录已存在即不再下载。
prepare_imagebuilder() {
	local series work ib_name ib_dir tarball feed
	series="$(sed -n 's/^[[:space:]]*local default_major="\([0-9][0-9.]*\)"$/\1/p' \
		"${ROOT_DIR}/build/scripts/build.sh" | head -1)"
	[ -n "${series}" ] || die "无法从上游 build.sh 解析版本线（default_major）——上游接口可能已变"

	VERSION_UP="$(curl -fsSL --retry 3 "https://downloads.openwrt.org/releases/" |
		grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+/"' | sed 's/href="//; s|/"||' |
		grep -E "^${series//./\\.}\.[0-9]+$" | sort -V | tail -1)"
	[ -n "${VERSION_UP}" ] || die "无法解析 ${series} 系列的最新 release"

	work="${ROOT_DIR}/build/build_x86_64_generic"
	ib_name="openwrt-imagebuilder-${VERSION_UP}-x86-64.Linux-x86_64"
	ib_dir="${work}/${ib_name}"
	if [ ! -d "${ib_dir}" ]; then
		mkdir -p "${work}"
		tarball="${work}/${ib_name}.tar.zst"
		curl -fsSL --retry 3 --retry-delay 2 -o "${tarball}" \
			"https://downloads.openwrt.org/releases/${VERSION_UP}/targets/x86/64/${ib_name}.tar.zst" ||
			die "ImageBuilder 下载失败：${VERSION_UP}"
		tar --zstd -xf "${tarball}" -C "${work}" || die "ImageBuilder 解包失败"
		rm -f "${tarball}"
	fi
	[ -f "${ib_dir}/repositories" ] || die "预置失败：${ib_dir}/repositories 不存在"

	# 分区几何必须与设备逐项一致（D11）：IB 默认 p1=16 MiB / p2=104 MiB，
	# 布局不同会让 platform_check_image 判定「layout changed」→ get_image_dd 整盘写，
	# 而新镜像 p1 只剩 16 MiB，platform_copy_config 写不进配置包且 do_stage2 不查返回值。
	# ImageBuilder 没有 KERNEL_PARTSIZE 的 make 变量映射，只能写进解包后的 .config。
	[ -f "${ib_dir}/.config" ] || die "预置失败：${ib_dir}/.config 不存在"
	set_ib_config() {
		local key="$1" val="$2" file="${ib_dir}/.config"
		if grep -q "^${key}=" "$file"; then
			sed -i.bak "s|^${key}=.*|${key}=${val}|" "$file" && rm -f "${file}.bak"
		else
			printf '%s=%s\n' "$key" "$val" >> "$file"
		fi
		grep -qx "${key}=${val}" "$file" || die "写入 ${key}=${val} 失败"
	}
	set_ib_config CONFIG_TARGET_KERNEL_PARTSIZE 64
	set_ib_config CONFIG_TARGET_ROOTFS_PARTSIZE 1024

	feed="$(grep -v '^[[:space:]]*#' "${ROOT_DIR}/overlay/files/etc/apk/repositories.d/yun-feed.list" |
		awk 'NF' | head -1)"
	[ -n "${feed}" ] || die "yun-feed.list 里没有 feed 地址"

	mkdir -p "${ib_dir}/keys"
	shopt -s nullglob
	keyfiles=("${ROOT_DIR}"/overlay/keys/*.rsa.pub)
	[ "${#keyfiles[@]}" -gt 0 ] || die "overlay/keys 下没有公钥"
	cp -f "${keyfiles[@]}" "${ib_dir}/keys/"

	if ! grep -qxF "${feed}" "${ib_dir}/repositories"; then
		{ printf '%s\n' "${feed}"; cat "${ib_dir}/repositories"; } > "${ib_dir}/repositories.new"
		mv -f "${ib_dir}/repositories.new" "${ib_dir}/repositories"
	fi
	grep -qxF "${feed}" "${ib_dir}/repositories" || die "自有 feed 未写入 ImageBuilder repositories"
	echo "    version: ${VERSION_UP}"
	echo "    feed: ${feed}"
}
prepare_imagebuilder

echo "==> 6/7 构建（上游 ImageBuilder）"
set +e
bash "${ROOT_DIR}/build/scripts/build.sh" x86 64 generic packages.x86_64 2>&1 | tee "${IB_LOG}"
rc=${PIPESTATUS[0]}
set -e
[ "${rc}" -eq 0 ] || die "上游 build.sh 退出码 ${rc}，日志：${IB_LOG}"

echo "==> 6/7 缺包检查（上游默认 WARNING 跳过，这里升级为硬失败）"
skipped="$(sed -n 's/.*skipping: //p' "${IB_LOG}" | tr '\n' ' ' | sed 's/  */ /g')"
[ -z "${skipped}" ] || die "以下包在 feed 中不可用，镜像不完整：${skipped}"

echo "==> 6/7 OpenClash 看门狗门禁（防 feed 回退到坏版本）"
bash "${ROOT_DIR}/scripts/check-openclash-watchdog.sh"

VERSION="$(sed -n 's/.*Using OpenWrt release: //p' "${IB_LOG}" | head -1)"
[ -n "${VERSION}" ] || die "无法从构建日志解析 OpenWrt 版本"
[ "${VERSION}" = "${VERSION_UP}" ] ||
	die "上游实际使用 ${VERSION}，与预置的 ${VERSION_UP} 不一致：自有 feed 可能未注入"

echo "==> 6/7 patch 基线（按实际解析出的 release）"
bash "${ROOT_DIR}/scripts/check-patch-bases.sh" "${VERSION}"

echo "==> 7/7 产物整理"
MANIFEST="$(find "${ROOT_DIR}/build" -path '*/bin/targets/x86/64/*.manifest' -type f | head -1)"
[ -n "${MANIFEST}" ] || die "找不到 manifest，构建产物不完整"

KERNEL="$(sed -n 's/^kernel - \([^ ]*\).*/\1/p' "${MANIFEST}" | head -1)"
[ -n "${KERNEL}" ] || KERNEL="unknown"

echo "==> 5b 清单核对（请求的包必须在 manifest 里，显式移除的除外）"
ALL="$(cat "${ROOT_DIR}/build/profiles/packages.common" "${ROOT_DIR}/build/profiles/packages.x86_64" |
	sed 's/[[:space:]]*#.*//' | tr -d '\r' | awk 'NF' | sort -u)"
REMOVED="$(printf '%s\n' "${ALL}" | sed -n 's/^-//p' | sort -u)"
EXPECTED="$(printf '%s\n' "${ALL}" | grep -v '^-')"
if [ -n "${REMOVED}" ]; then
	EXPECTED="$(printf '%s\n' "${EXPECTED}" | grep -vxF -f <(printf '%s\n' "${REMOVED}") || true)"
fi
missing=""
for p in ${EXPECTED}; do
	case "${p}" in
	libcurl) pattern='^(libcurl|libcurl4) - ' ;;
	*) pattern="^${p} - " ;;
	esac
	grep -qE "${pattern}" "${MANIFEST}" || missing="${missing} ${p}"
done
[ -z "${missing}" ] || die "manifest 中缺少：${missing}"

# 产物改名：上游产物固定带 YAOF 前缀
for f in "${ROOT_DIR}"/build/artifact/YAOF-*; do
	[ -e "${f}" ] || continue
	n="$(dirname "$f")/$(basename "$f" | sed 's/^YAOF-/YunWrt-/')"
	mv -f "$f" "$n"
	sha256 "$n" > "${n}.sha256"
	echo "    $(basename "$n")"
done

# Hyper-V 动态 VHDX：ImageBuilder 不带 qemu-img，VHDX_IMAGES 又默认关闭，
# 只能从 ext4 原始镜像自行转换。口径对齐 SWrt：只做 ext4，gzip 后发布。
vhdx_src="$(ls -1 "${ROOT_DIR}"/build/artifact/YunWrt-*-ext4-combined-efi.img.gz 2>/dev/null | head -1)"
[ -n "${vhdx_src}" ] || die "找不到 ext4 镜像，无法生成 VHDX"
command -v qemu-img >/dev/null 2>&1 || die "缺少 qemu-img，无法生成 VHDX（Debian/Ubuntu 装 qemu-utils）"
vhdx="${vhdx_src%.img.gz}.vhdx"
raw="${ROOT_DIR}/build/.vhdx-src.img"
gunzip -c "${vhdx_src}" > "${raw}"
qemu-img convert -f raw -O vhdx -o subformat=dynamic "${raw}" "${vhdx}"
rm -f "${raw}"
gzip -9 -n "${vhdx}"
sha256 "${vhdx}.gz" > "${vhdx}.gz.sha256"
echo "    $(basename "${vhdx}.gz")"

FEED_SHA="$(curl -fsSL --retry 3 "https://qiusimons.github.io/OpenWrt-Add/x86_64/packages.adb" 2>/dev/null | sha256 | awk '{print $1}' || true)"
ARTIFACT="$(basename "$(ls -1 "${ROOT_DIR}"/build/artifact/YunWrt-*.img.gz 2>/dev/null | head -1)")"

jq -n \
	--arg built_at "${TS}" \
	--arg yaof_commit "${SHA}" \
	--arg openwrt_version "${VERSION}" \
	--arg kernel_version "${KERNEL}" \
	--arg feed_index_sha256 "${FEED_SHA:-unavailable}" \
	--arg artifact "${ARTIFACT}" \
	--rawfile manifest "${MANIFEST}" \
	'{
    built_at: $built_at,
    yaof_commit: $yaof_commit,
    openwrt_version: $openwrt_version,
    kernel_version: $kernel_version,
    kmod_vermagic: "",
    feed_index_sha256: $feed_index_sha256,
    artifact: $artifact,
    packages: ($manifest | split("\n") | map(select(length > 0)) | map(split(" - ") | {name: .[0], version: (.[1] // "")})),
    capability_result: "not-run",
    failed_capabilities: []
  }' > "${LOG_JSON}"

echo "==> 完成 ${VERSION} / kernel ${KERNEL}"
echo "    build-log: ${LOG_JSON}"
rm -f "${IB_LOG}"

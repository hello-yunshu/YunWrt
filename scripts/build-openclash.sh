#!/usr/bin/env bash
# P3b：用官方 SDK 从源码打 OpenClash（vernesong/OpenClash）的 apk。
# 只负责构建与产物归档；签名/发布属于自有 feed 仓库（私钥不在本仓）。
#   bash scripts/build-openclash.sh [--tag <git-tag>]
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG=""
while [ $# -gt 0 ]; do
	case "$1" in
	--tag)
		TAG="${2:-}"
		shift 2
		;;
	*)
		echo "用法: $0 [--tag <git-tag>]" >&2
		exit 2
		;;
	esac
done

die() {
	echo "ERROR: $*" >&2
	exit 1
}

[ -f "${ROOT_DIR}/build/scripts/build.sh" ] || die "缺少 build/scripts/build.sh，先跑 scripts/sync-upstream.sh 与 scripts/assemble.sh"

# 与 build.sh 同一套版本解析：跟随上游 25.12 系列最新（不锁点版本）
series="$(sed -n 's/^[[:space:]]*local default_major="\([0-9][0-9.]*\)"$/\1/p' \
	"${ROOT_DIR}/build/scripts/build.sh" | head -1)"
[ -n "${series}" ] || die "无法从上游 build.sh 解析版本线"
VERSION="${VERSION:-$(curl -fsSL --retry 3 "https://downloads.openwrt.org/releases/" |
	grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+/"' | sed 's/href="//; s|/"||' |
	grep -E "^${series//./\\.}\.[0-9]+$" | sort -V | tail -1)}"
[ -n "${VERSION}" ] || die "无法解析 ${series} 最新版本"

[ -n "${TAG}" ] || TAG="$(curl -fsSL --retry 3 "https://api.github.com/repos/vernesong/OpenClash/releases/latest" |
	sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
[ -n "${TAG}" ] || die "无法解析 OpenClash 最新 release tag，请用 --tag 指定"

WORK="${ROOT_DIR}/build/openclash"
SDK_DIR="${WORK}/sdk"
mkdir -p "${WORK}" || die "无法创建 ${WORK}"

if [ ! -d "${SDK_DIR}" ]; then
	echo "==> 下载 OpenWrt SDK ${VERSION}"
	base="https://downloads.openwrt.org/releases/${VERSION}/targets/x86/64"
	sdk_name="$(curl -fsSL --retry 3 "${base}/" | grep -oE 'openwrt-sdk-[0-9.]+-x86-64_gcc-[0-9.]+_musl\.Linux-x86_64\.tar\.zst' | sort -u | tail -1)"
	[ -n "${sdk_name}" ] || die "在 ${base} 找不到 SDK 包"
	curl -fsSL --retry 3 --retry-delay 2 -o "${WORK}/sdk.tar.zst" "${base}/${sdk_name}" || die "SDK 下载失败"
	mkdir -p "${WORK}/x" && tar --zstd -xf "${WORK}/sdk.tar.zst" -C "${WORK}/x" || die "SDK 解包失败"
	mv "${WORK}/x"/openwrt-sdk-* "${SDK_DIR}" || die "SDK 目录重命名失败"
	rm -rf "${WORK}/x" "${WORK}/sdk.tar.zst"
fi

echo "==> 取 OpenClash ${TAG}"
rm -rf "${WORK}/src" "${SDK_DIR}/package/luci-app-openclash"
git clone -q --depth 1 --branch "${TAG}" https://github.com/vernesong/OpenClash.git "${WORK}/src" ||
	die "clone OpenClash ${TAG} 失败"
[ -f "${WORK}/src/luci-app-openclash/Makefile" ] || die "OpenClash ${TAG} 目录结构与预期不符"
cp -a "${WORK}/src/luci-app-openclash" "${SDK_DIR}/package/luci-app-openclash" || die "复制包目录失败"

grep -q 'PKGARCH:=all' "${SDK_DIR}/package/luci-app-openclash/Makefile" ||
	echo "WARN: OpenClash Makefile 里没看到 PKGARCH:=all，产物可能是架构相关的"

echo "==> 编译 luci-app-openclash"
(
	cd "${SDK_DIR}" || exit 1
	make defconfig >/dev/null 2>&1 || true
	make package/luci-app-openclash/compile V=s -j1
) >"${WORK}/build.log" 2>&1 || {
	tail -n 40 "${WORK}/build.log" >&2
	die "编译失败，完整日志：${WORK}/build.log"
}

OUT="${ROOT_DIR}/build/feed/openclash"
mkdir -p "${OUT}"
find "${SDK_DIR}/bin/packages" -name '*openclash*.apk' -exec cp -f {} "${OUT}/" \;
n="$(find "${OUT}" -name '*.apk' | wc -l | tr -d ' ')"
[ "${n}" -gt 0 ] || die "没有产出 apk，检查 ${WORK}/build.log"

echo "==> 产物："
ls -l "${OUT}"
echo "==> 未签名、未发布：签名私钥在自有 feed 仓库（yun-openwrt-packages）的 CI secrets 里，"
echo "    本脚本不持有私钥，产物需交由 feed 流水线签名并入索引后再被镜像消费。"

#!/usr/bin/env bash
# 把 fw4.uc 的 flow offload 设备来源从 net.physdev 扩到 net.device。
# 基线校验：内置 base 的 sha256 必须与 meta.json 一致，否则说明补丁被改过。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="${1:?需要 build/ 路径}"
BASE="${HERE}/base/usr/share/ucode/fw4.uc"
EXPECT="$(jq -r '.base_sha256' "${HERE}/meta.json")"

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

actual="$(sha256 "${BASE}" | awk '{print $1}')"
[ "${actual}" = "${EXPECT}" ] || {
	echo "ERROR: 内置基线被改动：期望 ${EXPECT} 实际 ${actual}" >&2
	exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

mkdir -p "${TMP}/usr/share/ucode"
cp "${BASE}" "${TMP}/usr/share/ucode/fw4.uc"
patch -p1 -d "${TMP}" --no-backup-if-mismatch < "${HERE}/fw4-flow-offload.patch"

grep -q 'net.physdev || net.device' "${TMP}/usr/share/ucode/fw4.uc" || {
	echo "ERROR: 补丁未生效" >&2
	exit 1
}

mkdir -p "${BUILD}/files/usr/share/ucode"
install -m 644 "${TMP}/usr/share/ucode/fw4.uc" "${BUILD}/files/usr/share/ucode/fw4.uc"
echo "    fw4.uc 已打补丁"

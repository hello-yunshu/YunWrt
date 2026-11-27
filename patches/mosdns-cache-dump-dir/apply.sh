#!/usr/bin/env bash
# 把 mosdns 缓存的 dump 文件从 overlay 闪存(/etc/mosdns/cache.dump)
# 改到 tmpfs 运行目录(/tmp/mosdns/cache.dump)，并在启动前确保目录存在。
# 基线校验：内置 base 的 sha256 必须与 meta.json 一致，否则说明补丁被改过。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="${1:?需要 build/ 路径}"
BASE="${HERE}/base/etc/init.d/mosdns"
EXPECT="$(jq -r '.base_sha256' "${HERE}/meta.json")"

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

actual="$(sha256 "${BASE}" | awk '{print $1}')"
[ "${actual}" = "${EXPECT}" ] || {
	echo "ERROR: 内置基线被改动：期望 ${EXPECT} 实际 ${actual}" >&2
	exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

mkdir -p "${TMP}/etc/init.d"
cp "${BASE}" "${TMP}/etc/init.d/mosdns"
patch -p1 -d "${TMP}" --no-backup-if-mismatch < "${HERE}/mosdns-cache-dump-dir.patch"

grep -qF 'DUMP_FILE=/tmp/mosdns/cache.dump' "${TMP}/etc/init.d/mosdns" || {
	echo "ERROR: 补丁未生效（DUMP_FILE 未指向 /tmp/mosdns）" >&2
	exit 1
}
grep -qF 'mkdir -p "${DUMP_FILE%/*}"' "${TMP}/etc/init.d/mosdns" || {
	echo "ERROR: 补丁未生效（缺少目录兜底 mkdir）" >&2
	exit 1
}

mkdir -p "${BUILD}/files/etc/init.d"
install -m 755 "${TMP}/etc/init.d/mosdns" "${BUILD}/files/etc/init.d/mosdns"
echo "    mosdns init 已打补丁（cache dump -> /tmp/mosdns）"

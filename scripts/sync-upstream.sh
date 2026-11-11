#!/usr/bin/env bash
# 把 YAOF 指定分支同步为纯净镜像：upstream/yaof/ 逐个文件等于上游，且不含 .git。
# 提交号写在上游目录之外（upstream/yaof.commit），保证镜像目录本身逐字节一致。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${ROOT_DIR}/upstream/yaof"
REPO="${YAOF_REPO:-https://github.com/QiuSimons/YAOF.git}"
BRANCH="${YAOF_BRANCH:-25.12}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "==> 拉取 ${REPO} (${BRANCH})"
git clone --quiet --depth 1 --branch "${BRANCH}" "${REPO}" "${TMP}/yaof" || die "clone 失败"

# 防呆：确认上游仍是 ImageBuilder 形态。形态一变就先停下来看 check-upstream.sh。
for p in scripts/build.sh profiles/packages.common profiles/packages.x86_64 files; do
	[ -e "${TMP}/yaof/${p}" ] || die "上游缺少 ${p}，形态已变"
done

SHA="$(git -C "${TMP}/yaof" rev-parse HEAD)"

mkdir -p "${DEST}"
rsync -a --delete --exclude='.git' "${TMP}/yaof/" "${DEST}/"
printf '%s\n' "${SHA}" > "${ROOT_DIR}/upstream/yaof.commit"

echo "==> 同步完成 ${SHA}"

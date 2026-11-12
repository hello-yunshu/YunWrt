#!/usr/bin/env bash
# 只检查"上游一变就会让我们静默失效"的接口。失败必须非 0 退出。
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
U="${ROOT_DIR}/upstream/yaof"
B="${U}/scripts/build.sh"
FAILS=0

ok() { printf '  ok  %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }

echo "==> 目录形态"
for p in scripts/build.sh profiles/packages.common profiles/packages.x86_64 \
	files/etc/rc.local files/etc/hotplug.d/net/01-maximize_nic_rx_tx_buffers \
	files/etc/sysctl.d/99-zram.conf; do
	[ -e "${U}/${p}" ] && ok "${p}" || bad "${p} 缺失"
done

if [ ! -f "${B}" ]; then
	echo "==> build.sh 不存在，跳过后续接口检查" >&2
	exit 1
fi

echo "==> 构建接口（我们按 4+1 位置参数调用，且不传版本）"
check_lit() { grep -qF -- "$2" "$1" && ok "$3" || bad "$3"; }
check_lit "${B}" 'Usage: $0 <TARGET> <SUBTARGET> <PROFILE> <PACKAGES_PROFILE> [VERSION]' 'Usage 行'
check_lit "${B}" 'TARGET="${1:-}"' '第 1 位置参数 = TARGET'
check_lit "${B}" 'SUBTARGET="${2:-}"' '第 2 位置参数 = SUBTARGET'
check_lit "${B}" 'PROFILE="${3:-}"' '第 3 位置参数 = PROFILE'
check_lit "${B}" 'PACKAGES_PROFILE="${4:-}"' '第 4 位置参数 = PACKAGES_PROFILE'
check_lit "${B}" 'VERSION="${5:-}"' '第 5 位置参数 = VERSION'
check_lit "${B}" 'resolve_version()' '版本解析函数 resolve_version'
check_lit "${B}" 'ARCH="x86_64"' 'x86 的 feed 架构名 x86_64'
check_lit "${B}" 'profiles/packages.common' '读取 profiles/packages.common'
check_lit "${B}" 'profiles/${PACKAGES_PROFILE}' '读取 profiles/${PACKAGES_PROFILE}'
check_lit "${B}" 'FILES="$OVERLAY_DIR"' '支持 FILES= 覆盖目录'
check_lit "${B}" 'ROOTFS_PARTSIZE=' '设置 ROOTFS_PARTSIZE'
check_lit "${B}" '*combined-efi.img.gz' 'x86 产物匹配 combined-efi.img.gz'

if [ -f "${ROOT_DIR}/upstream/yaof.commit" ]; then
	printf '  ok  upstream/yaof.commit = %s\n' "$(cat "${ROOT_DIR}/upstream/yaof.commit")"
else
	bad "upstream/yaof.commit 缺失（先跑 scripts/sync-upstream.sh）"
fi

if [ "${FAILS}" -ne 0 ]; then
	printf '==> 接口检查失败：%d 项\n' "${FAILS}" >&2
	exit 1
fi
echo "==> 接口检查通过"

#!/usr/bin/env bash
# 从最终镜像里回查两件只有产物能证明的事（D11/D12）：
#   1) p1 里的 grub.cfg 是否就是期望的那份 —— 这是唯一能证明 .config 被
#      ImageBuilder 采纳、文本级改写真的落到产物的检查（离线渲染只看模板）；
#   2) GPT 里 p1/p2 的实际尺寸 —— 证明 CONFIG_TARGET_*_PARTSIZE 生效。
# 用法：check-artifact.sh <raw.img>（未压缩的 combined-efi 原始镜像）
set -euo pipefail

IMG="${1:-}"
if [ -z "${IMG}" ] || [ ! -f "${IMG}" ]; then
	echo "用法: $0 <raw.img>" >&2
	exit 1
fi
die() { echo "产物回查失败: $*" >&2; exit 1; }

# --- 分区尺寸 ---------------------------------------------------------------
# 优先用 sfdisk（CI 的 util-linux 自带）；macOS 构建机没有，退回 python3 读 GPT，
# 两者都只读不写。sector 固定 512 B（x86/64 combined-efi）。
gpt_sizes() {
	if command -v sfdisk >/dev/null 2>&1; then
		sfdisk -d "$1" 2>/dev/null | awk '
			/: *start=/ && match($0, /size= *[0-9]+/) {
				s = substr($0, RSTART + 5, RLENGTH - 5)
				gsub(/ /, "", s)
				n++
				if (n == 1) a = s * 512
				else if (n == 2) b = s * 512
			}
			END { if (n >= 2) print a, b }'
		return
	fi
	python3 - "$1" <<'PY'
import struct, sys
with open(sys.argv[1], 'rb') as f:
    f.seek(512)
    hdr = f.read(92)
    if hdr[:8] != b'EFI PART':
        sys.exit(0)
    lba = struct.unpack_from('<Q', hdr, 72)[0]
    num = struct.unpack_from('<I', hdr, 80)[0]
    f.seek(lba * 512)
    ent = f.read(num * 128)
sizes = []
for i in range(2):
    first, last = struct.unpack_from('<QQ', ent, i * 128 + 32)
    sizes.append((last - first + 1) * 512)
print(sizes[0], sizes[1])
PY
}

read -r p1 p2 <<EOF
$(gpt_sizes "${IMG}")
EOF
[ -n "${p1:-}" ] && [ -n "${p2:-}" ] || die "解析不出 GPT 分区表（预期 x86/64 combined-efi）"
[ "${p1}" = 67108864 ] || die "p1 实际 $((p1 / 1048576)) MiB，期望 64 MiB"
[ "${p2}" = 1073741824 ] || die "p2 实际 $((p2 / 1048576)) MiB，期望 1024 MiB"

# --- grub.cfg ---------------------------------------------------------------
# grub.cfg 是 p1 FAT 里的明文文件；只截前 p1 字节，避免落到 p2 的 rootfs
# （rootfs 里的脚本/文档可能合法地出现 console=ttyS 字样，造成误报）。
tmp="$(mktemp "${TMPDIR:-/tmp}/grub-p1.XXXXXX")"
trap 'rm -f "${tmp}"' EXIT
head -c "${p1}" "${IMG}" > "${tmp}"

grep -aq 'set timeout="0"' "${tmp}" || die 'grub.cfg 缺 set timeout="0"'
grep -aq 'menuentry "yunshu"' "${tmp}" || die 'grub.cfg 缺 menuentry "yunshu"'
grep -aq 'noinitrd mitigations=off' "${tmp}" || die 'grub.cfg 缺 noinitrd mitigations=off'
if grep -aq 'console=ttyS' "${tmp}"; then
	die 'grub.cfg 出现 console=ttyS（GRUB_CONSOLE_CMDLINE 未清空）'
fi

echo "产物回查通过：grub.cfg 字段齐全，p1=64 MiB / p2=1024 MiB"

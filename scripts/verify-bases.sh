#!/usr/bin/env bash
# overlay/patch 失效检测（D9）。默认硬失败；--allow-base-drift 仅用于人工排障，产物不得发布。
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UP="${ROOT_DIR}/upstream/yaof"
ALLOW_DRIFT=0
[ "${1:-}" = "--allow-base-drift" ] && ALLOW_DRIFT=1
ERR=0
WARN=0

bad() { printf '  FAIL %s\n' "$*" >&2; ERR=$((ERR + 1)); }
ok() { printf '  ok  %s\n' "$*"; }
warn() { printf '  WARN %s\n' "$*" >&2; WARN=$((WARN + 1)); }

command -v jq >/dev/null 2>&1 || { echo "FAIL jq 不可用，无法校验 meta.json" >&2; exit 1; }

echo "==> 每个 overlay 文件必须有 .meta.json"
while IFS= read -r f; do
	rel="${f#"${ROOT_DIR}/overlay/files/"}"
	case "$rel" in .gitkeep | *.DS_Store | *.meta.json) continue ;; esac
	[ -f "${f}.meta.json" ] || bad "缺少元数据：overlay/files/${rel}.meta.json"
done < <(find "${ROOT_DIR}/overlay/files" -type f | sort)

echo "==> 逐项校验 overlay 元数据"
while IFS= read -r m; do
	rel="${m#"${ROOT_DIR}/overlay/files/"}"
	rel="${rel%.meta.json}"
	kind="$(jq -r '.kind // empty' "$m")"
	upath="$(jq -r '.upstream_path // empty' "$m")"
	base="$(jq -r '.base_sha256 // empty' "$m")"

	[ -f "${ROOT_DIR}/overlay/files/${rel}" ] || {
		bad "${rel}: meta.json 存在但文件不存在"
		continue
	}
	[ -n "${kind}" ] && [ -n "${upath}" ] || {
		bad "${rel}: meta.json 缺 kind/upstream_path"
		continue
	}

	exists=0
	[ -e "${UP}/${upath}" ] && exists=1

	case "${kind}" in
	add)
		if [ "${exists}" -eq 1 ]; then
			warn "${rel}: 新增文件与上游撞名（need-review，禁止发布）"
		else
			ok "${rel}: add"
		fi
		;;
	override)
		if [ "${exists}" -ne 1 ]; then
			bad "${rel}: 覆盖目标 upstream/${upath} 不存在"
			continue
		fi
		actual="$(shasum -a 256 "${UP}/${upath}" 2>/dev/null | awk '{print $1}')"
		if [ -z "${base}" ]; then
			bad "${rel}: override 缺 base_sha256"
		elif [ "${actual}" != "${base}" ]; then
			if [ "${ALLOW_DRIFT}" -eq 1 ]; then
				warn "${rel}: base 已漂移（允许漂移模式，产物不得发布）"
			else
				bad "${rel}: base 已漂移 upstream=${upath} 期望=${base} 实际=${actual}"
			fi
		else
			ok "${rel}: override base 一致"
		fi
		;;
	*)
		bad "${rel}: 未知 kind=${kind}"
		;;
	esac
done < <(find "${ROOT_DIR}/overlay/files" -name '*.meta.json' | sort)

echo "==> patch 层元数据"
shopt -s nullglob
for d in "${ROOT_DIR}"/patches/*/; do
	name="$(basename "${d}")"
	[ -f "${d}meta.json" ] || continue
	for k in kind base_sha256 upstream_path; do
		v="$(jq -r --arg k "$k" '.[$k] // empty' "${d}meta.json")"
		[ -n "${v}" ] || bad "patches/${name}: meta.json 缺 ${k}"
	done
	[ -f "${d}apply.sh" ] || bad "patches/${name}: 缺 apply.sh"
	ls "${d}"*.patch >/dev/null 2>&1 || bad "patches/${name}: 没有 .patch"
	ok "patches/${name}"
done

if [ "${ERR}" -ne 0 ]; then
	printf '==> base 校验失败：%d 项（%d 告警）\n' "${ERR}" "${WARN}" >&2
	exit 1
fi
if [ "${WARN}" -ne 0 ]; then
	printf '==> base 校验有 %d 项告警，产物不得发布\n' "${WARN}" >&2
	[ "${ALLOW_DRIFT}" -eq 1 ] || exit 1
fi
echo "==> base 校验通过"

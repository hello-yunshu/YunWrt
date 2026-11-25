#!/usr/bin/env bash
# Fixtures for check_feed_ready. A stale Pages copy still lists mosdns, so only
# the buildId comparison can tell it apart from the freshly deployed feed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/lock.json" <<'JSON'
{"packages":{"mosdns":{"packageVersion":"5.3.4"},"luci-app-mosdns":{"packageVersion":"1.7.15"}}}
JSON
# Same shape, but without the two packages the readiness check looks for.
cat >"$TMP/lock-old.json" <<'JSON'
{"packages":{"luci-app-cloudflare-ip":{"packageVersion":"2.7.0"}}}
JSON
printf '{"buildId":"111"}\n' >"$TMP/candidate-old.json"
printf '{"buildId":"222"}\n' >"$TMP/candidate-new.json"

run_case() {
	local name="$1" expected="$2" lock="$3" candidate="$4" want="$5" rc=0
	set +e
	FEED_READY_ATTEMPTS=1 FEED_READY_INTERVAL=0 \
	FEED_EXPECTED_BUILD_ID="${expected}" \
	FEED_READY_LOCK_URL="file://${lock}" \
	FEED_READY_CANDIDATE_URL="file://${candidate}" \
		bash "${ROOT}/scripts/build.sh" --check-feed >"${TMP}/out.log" 2>&1
	rc=$?
	set -e
	if [ "${want}" = ok ] && [ "${rc}" -ne 0 ]; then
		echo "FAIL ${name}: expected success, got rc=${rc}"
		sed -n '1,6p' "${TMP}/out.log"
		return 1
	fi
	if [ "${want}" = fail ] && [ "${rc}" -eq 0 ]; then
		echo "FAIL ${name}: expected failure, got rc=0"
		return 1
	fi
	echo "PASS ${name} (rc=${rc})"
}

run_case "matching buildId" 222 "${TMP}/lock.json" "${TMP}/candidate-new.json" ok
run_case "stale buildId is rejected" 222 "${TMP}/lock.json" "${TMP}/candidate-old.json" fail
run_case "no expected buildId keeps legacy behaviour" "" "${TMP}/lock.json" "${TMP}/candidate-old.json" ok
run_case "missing package keys still fail" "" "${TMP}/lock-old.json" "${TMP}/candidate-old.json" fail

echo "all feed-readiness fixtures passed"

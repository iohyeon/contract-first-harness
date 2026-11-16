#!/usr/bin/env bash
# 이 저장소 자체에 tests/lint/scan.sh 를 돌린다. tests/run.sh 가 자동으로 집어 간다.
# 검사기 자체 테스트는 같은 폴더의 scan_test.sh 다.
# 실행: bash tests/lint/run.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)
BASH_BIN="${TEST_BASH:-bash}"

OUT=$("$BASH_BIN" "$HERE/scan.sh" 2>&1)
RC=$?
if [ "$RC" -eq 0 ]; then
  printf 'ok   - 저장소 위생 검사: %s\n' "$(printf '%s\n' "$OUT" | tail -n 1)"
else
  printf 'FAIL - 저장소 위생 검사 (exit %s)\n' "$RC"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi
[ "$RC" -eq 0 ]

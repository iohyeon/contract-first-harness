#!/usr/bin/env bash
# tests/ 아래 테스트를 모두 실행한다. 외부 프레임워크 없음.
#   - tests/<폴더>/run.sh       (폴더 단위 실행기)
#   - tests/**/*_test.sh        (개별 테스트 파일)
# 각 테스트는 'ok   - ' 와 'FAIL - ' 로 시작하는 줄을 출력한다.
# 실행: bash tests/run.sh   (TEST_BASH 로 다른 bash 를 지정할 수 있다)

HERE=$(cd "$(dirname "$0")" && pwd -P)
BASH_BIN="${TEST_BASH:-bash}"

PASS=0
FAIL=0
SUITES=0
BROKEN=""

run_suite() {
  local f="$1" out rc p c
  SUITES=$((SUITES + 1))
  printf '== %s\n' "${f#"$HERE"/}"
  out=$("$BASH_BIN" "$f" 2>&1)
  rc=$?
  printf '%s\n' "$out" | grep -E '^FAIL - |^ {7}' || true
  p=$(printf '%s\n' "$out" | grep -c '^ok   - ')
  c=$(printf '%s\n' "$out" | grep -c '^FAIL - ')
  printf '   %s 통과, %s 실패\n' "$p" "$c"
  PASS=$((PASS + p))
  FAIL=$((FAIL + c))
  if [ "$rc" -ne 0 ] && [ "$c" -eq 0 ]; then
    BROKEN="$BROKEN ${f#"$HERE"/}"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/   | /'
  fi
}

for f in "$HERE"/*/run.sh; do
  [ -f "$f" ] || continue
  [ -n "$f" ] && run_suite "$f"
done
while IFS= read -r f; do
  [ -n "$f" ] && run_suite "$f"
done <<EOF
$(find "$HERE" -type f -name '*_test.sh' | LC_ALL=C sort)
EOF

printf '\n전체: 묶음 %s개, %s 통과, %s 실패' "$SUITES" "$PASS" "$FAIL"
[ -n "$BROKEN" ] && printf ', 비정상 종료:%s' "$BROKEN"
printf '\n'
[ "$FAIL" -eq 0 ] && [ -z "$BROKEN" ]

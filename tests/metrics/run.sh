#!/usr/bin/env bash
# harness-metrics 스크립트(cc-usage.sh) 테스트. 순수 bash, 의존성은 jq 와 awk.
# 실행: bash tests/metrics/run.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
SCRIPT="$REPO/skills/harness-metrics/scripts/cc-usage.sh"
FIX_CFG="$HERE/fixtures/claude"          # CLAUDE_CONFIG_DIR 로 쓸 디렉터리
FIX_ROOT="$FIX_CFG/projects"
SLUG="-tmp-proj-a"
BASH_BIN="${TEST_BASH:-bash}"

PASS=0; FAIL=0

# HM_PRICE_* 와 CLAUDE_CONFIG_DIR 가 바깥 환경에서 새어 들어오지 않게 비운다
unset HM_PRICE_INPUT HM_PRICE_OUTPUT HM_PRICE_CACHE_WRITE HM_PRICE_CACHE_READ CLAUDE_CONFIG_DIR

ok()   { PASS=$((PASS+1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL - $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; }

# 출력에서 행 이름(첫 칸)이 $2 인 줄의 $3 번째 칸
field() { printf '%s\n' "$1" | awk -v k="$2" -v n="$3" '$1==k {print $n; exit}'; }

expect_eq() {  # 이름 기대값 실제값 [출력]
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (기대 '$2', 실제 '$3')" "${4:-}"; fi
}

run() { "$BASH_BIN" "$SCRIPT" "$@" 2>&1; }

# --- 1. 합계 (서브에이전트 제외) -------------------------------------------
OUT=$(run --root "$FIX_ROOT" "$SLUG")
expect_eq "합계: 세션 aaaa1111 입력 토큰(스트리밍 중복 제거)" "120" "$(field "$OUT" aaaa1111 6)" "$OUT"
expect_eq "합계: 세션 aaaa1111 출력 토큰(같은 id 중 최대값)" "350" "$(field "$OUT" aaaa1111 7)" "$OUT"
expect_eq "합계: 세션 aaaa1111 API 호출 수" "3" "$(field "$OUT" aaaa1111 5)" "$OUT"
expect_eq "합계: 세션 aaaa1111 비용" "0.0171" "$(field "$OUT" aaaa1111 10)" "$OUT"
expect_eq "합계: TOTAL 입력" "620" "$(field "$OUT" TOTAL 5)" "$OUT"
expect_eq "합계: TOTAL 출력" "1250" "$(field "$OUT" TOTAL 6)" "$OUT"
expect_eq "합계: TOTAL 캐시 읽기" "15000" "$(field "$OUT" TOTAL 7)" "$OUT"
expect_eq "합계: TOTAL 비용(세션 합)" "0.0606" "$(field "$OUT" TOTAL 9)" "$OUT"
expect_eq "합계: cache_create" "cache_create=3000" "$(printf '%s\n' "$OUT" | grep -o 'cache_create=[0-9]*')" "$OUT"

# --- 2. 캐시 히트율 ---------------------------------------------------------
# aaaa1111: 3000 / (3000 + 1000 + 120) = 72.8
expect_eq "히트율: aaaa1111" "72.8" "$(field "$OUT" aaaa1111 9)" "$OUT"
# cccc3333: 4000 / (4000 + 0 + 100) = 97.6
expect_eq "히트율: cccc3333" "97.6" "$(field "$OUT" cccc3333 9)" "$OUT"
# TOTAL: 15000 / (15000 + 3000 + 620) = 80.6
expect_eq "히트율: TOTAL" "80.6" "$(field "$OUT" TOTAL 8)" "$OUT"

# --- 3. 서브에이전트 합산과 모델 혼합 표시 ----------------------------------
OUT=$(run --root "$FIX_ROOT" --subagents "$SLUG")
expect_eq "서브에이전트: bbbb2222 입력 합산" "250" "$(field "$OUT" bbbb2222 6)" "$OUT"
expect_eq "서브에이전트: bbbb2222 히트율 500/2750" "18.2" "$(field "$OUT" bbbb2222 9)" "$OUT"
expect_eq "서브에이전트: bbbb2222 비용(지배 모델 단가)" "0.0265" "$(field "$OUT" bbbb2222 10)" "$OUT"
LAST=$(printf '%s\n' "$OUT" | tail -1)
case "$LAST" in
  *"모델별 단가가 섞이면"*"모델 혼합 세션 있음"*) ok "혼합 모델 경고가 출력 마지막 줄에 있음" ;;
  *) fail "혼합 모델 경고가 출력 마지막 줄에 있음" "$LAST" ;;
esac

# --- 4. 품질 프록시 ----------------------------------------------------------
OUT=$(run --root "$FIX_ROOT" --quality "$SLUG")
QROW=$(printf '%s\n' "$OUT" | sed -n '/요구-결과 매칭/,$p' | awk '$1=="aaaa1111"')
expect_eq "품질: aaaa1111 정정/재편집/스텝턴" "2 1 1 1.5" "$(printf '%s\n' "$QROW" | awk '{print $2, $3, $7, $8}')" "$OUT"

# --- 5. 그룹 비교 ------------------------------------------------------------
OUT=$(run --root "$FIX_ROOT" --group-a aaaa1111,bbbb2222 --group-b cccc3333,dddd4444)
expect_eq "그룹: A 세션 수" "2" "$(field "$OUT" SESSIONS 2)" "$OUT"
expect_eq "그룹: A 입력 / B 입력" "320 300" "$(field "$OUT" IN 2) $(field "$OUT" IN 3)" "$OUT"
expect_eq "그룹: A 출력 / B 출력" "750 500" "$(field "$OUT" OUT 2) $(field "$OUT" OUT 3)" "$OUT"
expect_eq "그룹: 히트율 A / B" "47.5 97.6" "$(field "$OUT" HIT% 2) $(field "$OUT" HIT% 3)" "$OUT"
expect_eq "그룹: 비용 A / B / 비율" "0.0406 0.0200 0.49" \
  "$(field "$OUT" COST_USD 2) $(field "$OUT" COST_USD 3) $(field "$OUT" COST_USD 4)" "$OUT"
expect_eq "그룹: 정정률 A / B" "0.33 0.00" "$(field "$OUT" CORR_RATE 2) $(field "$OUT" CORR_RATE 3)" "$OUT"
expect_eq "그룹: 재편집 A / B" "1 0" "$(field "$OUT" REDO 2) $(field "$OUT" REDO 3)" "$OUT"
expect_eq "그룹: 스텝/턴 A / B" "1.33 1.00" "$(field "$OUT" STEPS/TURN 2) $(field "$OUT" STEPS/TURN 3)" "$OUT"
case "$OUT" in *"--subagents 없이"*) ok "그룹: 서브에이전트 미포함 경고" ;; *) fail "그룹: 서브에이전트 미포함 경고" "$OUT" ;; esac

OUT=$(run --root "$FIX_ROOT" --subagents --group-a aaaa,bbbb --group-b cccc,dddd)
expect_eq "그룹: ID 앞부분 + --subagents 로 A 입력" "370" "$(field "$OUT" IN 2)" "$OUT"
case "$(printf '%s\n' "$OUT" | tail -1)" in
  *"모델 혼합"*) ok "그룹: 혼합 모델 경고" ;; *) fail "그룹: 혼합 모델 경고" "$OUT" ;;
esac

OUT=$(run --root "$FIX_ROOT" --group-a aaaa1111 --group-b zzzz9999); RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q '세션을 찾지 못함: zzzz9999'; then
  ok "그룹: 없는 세션 ID 는 실패 종료"
else
  fail "그룹: 없는 세션 ID 는 실패 종료 (rc=$RC)" "$OUT"
fi

OUT=$(run --root "$FIX_ROOT" --group-a aaaa1111); RC=$?
if [ "$RC" -ne 0 ]; then ok "그룹: 한쪽만 주면 실패 종료"; else fail "그룹: 한쪽만 주면 실패 종료" "$OUT"; fi

# --- 6. CLAUDE_CONFIG_DIR 존중 ----------------------------------------------
OUT=$(CLAUDE_CONFIG_DIR="$FIX_CFG" HOME=/nonexistent "$BASH_BIN" "$SCRIPT" "$SLUG" 2>&1)
expect_eq "CLAUDE_CONFIG_DIR: 슬러그로 세션을 찾음" "620" "$(field "$OUT" TOTAL 5)" "$OUT"

OUT=$(CLAUDE_CONFIG_DIR="$FIX_CFG" HOME=/nonexistent "$BASH_BIN" "$SCRIPT" --group-a aaaa1111 --group-b cccc3333 2>&1)
expect_eq "CLAUDE_CONFIG_DIR: 그룹 모드도 같은 루트를 씀" "120 100" "$(field "$OUT" IN 2) $(field "$OUT" IN 3)" "$OUT"

OUT=$(CLAUDE_CONFIG_DIR=/nonexistent "$BASH_BIN" "$SCRIPT" --root "$FIX_ROOT" "$SLUG" 2>&1)
expect_eq "--root 가 CLAUDE_CONFIG_DIR 보다 우선" "620" "$(field "$OUT" TOTAL 5)" "$OUT"

# --- 7. 단가 env 덮어쓰기 ---------------------------------------------------
# 모든 단가를 1,000,000 으로 두면 비용 = 토큰 합계
OUT=$(HM_PRICE_INPUT=1000000 HM_PRICE_OUTPUT=1000000 HM_PRICE_CACHE_WRITE=1000000 HM_PRICE_CACHE_READ=1000000 \
      "$BASH_BIN" "$SCRIPT" --root "$FIX_ROOT" "$SLUG" 2>&1)
expect_eq "단가 env: aaaa1111 비용 = 토큰 합 4470" "4470.0000" "$(field "$OUT" aaaa1111 10)" "$OUT"
case "$(printf '%s\n' "$OUT" | tail -1)" in
  *"in=1000000 out=1000000 cw=1000000 cr=1000000"*) ok "단가 env: 하단 안내에 적용 단가 표시" ;;
  *) fail "단가 env: 하단 안내에 적용 단가 표시" "$OUT" ;;
esac

# 캐시 읽기 단가만 덮어쓰기: aaaa1111 = (120*5 + 350*25 + 1000*6.25 + 3000*0) / 1e6 = 0.0156
OUT=$(HM_PRICE_CACHE_READ=0 "$BASH_BIN" "$SCRIPT" --root "$FIX_ROOT" "$SLUG" 2>&1)
expect_eq "단가 env: 한 항목만 덮어쓰기" "0.0156" "$(field "$OUT" aaaa1111 10)" "$OUT"

# --- 8. JSON 출력 -----------------------------------------------------------
OUT=$("$BASH_BIN" "$SCRIPT" --root "$FIX_ROOT" --json "$SLUG" 2>&1)
expect_eq "JSON: 세션 4줄이 모두 유효한 JSON" "4" "$(printf '%s\n' "$OUT" | jq -c . 2>/dev/null | wc -l | tr -d ' ')" "$OUT"

echo
echo "결과: ${PASS} 통과, ${FAIL} 실패 (bash: $("$BASH_BIN" -c 'echo $BASH_VERSION'))"
[ "$FAIL" -eq 0 ]

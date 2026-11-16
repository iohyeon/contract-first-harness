#!/usr/bin/env bash
# tests/lint/scan.sh 자체 테스트. 임시 저장소에 위반 파일을 하나씩 만들어 잡히는지 본다.
# 위반 문자열은 이 파일 자체가 검사에 걸리지 않도록 조각을 이어 붙여 만든다.
# 실행: bash tests/lint/scan_test.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)
SCAN="$HERE/scan.sh"
BASH_BIN="${TEST_BASH:-bash}"

PASS=0
FAIL=0
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t scan-test)
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_NOSYSTEM=1
export HOME="$WORK/home"
mkdir -p "$HOME"
unset CFH_DENYLIST GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL - %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'
}

# 새 저장소에 정상 SKILL.md 하나를 둔다. $(...) 안에서 불리므로 이름은 mktemp 로 정한다.
new_repo() {
  local d
  d=$(mktemp -d "$WORK/repo.XXXXXX")
  mkdir -p "$d/skills/demo"
  git -C "$d" init -q
  printf -- '---\nname: demo\ndescription: 예시 스킬이다.\n---\n\n본문\n' >"$d/skills/demo/SKILL.md"
  printf '%s\n' "$d"
}

OUT=""
RC=0
scan() { OUT=$("$BASH_BIN" "$SCAN" "$1" 2>&1); RC=$?; }

# 사용: expect_hit <이름> <파일 경로(저장소 기준)> <내용> <기대 문구>
expect_hit() {
  local name="$1" rel="$2" body="$3" want="$4" r
  r=$(new_repo)
  mkdir -p "$(dirname "$r/$rel")"
  printf '%s\n' "$body" >"$r/$rel"
  scan "$r"
  if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qF "$rel:1: $want"; then
    ok "$name"
  else
    fail "$name (rc=$RC)" "$OUT"
  fi
}

expect_clean() {
  local name="$1" rel="$2" body="$3" r
  r=$(new_repo)
  mkdir -p "$(dirname "$r/$rel")"
  printf '%s\n' "$body" >"$r/$rel"
  scan "$r"
  if [ "$RC" -eq 0 ]; then ok "$name"; else fail "$name (rc=$RC)" "$OUT"; fi
}

# --- 기준선 ------------------------------------------------------------------
R=$(new_repo)
scan "$R"
if [ "$RC" -eq 0 ]; then ok "깨끗한 저장소는 통과"; else fail "깨끗한 저장소는 통과 (rc=$RC)" "$OUT"; fi

# --- 1. 개인 홈 경로 ---------------------------------------------------------
U="/Us""ers"
H="/ho""me"
expect_hit "홈 경로: macOS" "a.txt" "cd $U/alice/work" "개인 홈 절대 경로"
expect_hit "홈 경로: Linux" "b.sh" "X=$H/bob.k/x" "개인 홈 절대 경로"
expect_clean "홈 경로: 자리 표시(<이름>)는 통과" "c.md" "경로는 $U/<이름>/ 형식이다."
expect_clean "홈 경로: 슬러그 모양 가짜 경로는 통과" "d.txt" "-tmp-proj-a and /tmp/proj-a"

# --- 2. 사설 IPv4 ------------------------------------------------------------
expect_hit "IPv4: 10.x" "e.txt" "host=1""0.12.3.4" "사설 IPv4 주소"
expect_hit "IPv4: 172.16~31" "f.txt" "host 17""2.20.0.1:8080" "사설 IPv4 주소"
expect_hit "IPv4: 192.168" "g.txt" "(19""2.168.1.10)" "사설 IPv4 주소"
expect_clean "IPv4: 172.32 는 공인 대역이라 통과" "h.txt" "17""2.32.0.1"
expect_clean "IPv4: 버전 문자열은 통과" "i.txt" "v1.1""0.0.1.5 and 2.1""0.3.4"

# --- 3. 시크릿 모양 ----------------------------------------------------------
expect_hit "시크릿: AWS" "j.txt" "key=AK""IAABCDEFGHIJKLMNOP" "시크릿 모양(AWS 액세스 키)"
expect_hit "시크릿: ghp" "k.txt" "token gh""p_abcdefghijklmnopqrstuvwxyz0123" "시크릿 모양(GitHub 토큰)"
expect_hit "시크릿: github_pat" "l.txt" "github""_pat_11ABCDEFG0123456789_abcdef" "시크릿 모양(GitHub 토큰)"
expect_hit "시크릿: sk-ant" "m.txt" "sk-""ant-api03-abcdefghijklmnop" "시크릿 모양(Anthropic 키)"
expect_hit "시크릿: Slack" "n.txt" "xo""xb-1234567890-abcdef" "시크릿 모양(Slack 토큰)"
expect_hit "시크릿: 개인키" "o.pem" "-----BEG""IN RSA PRIVATE KEY-----" "시크릿 모양(개인키)"
expect_clean "시크릿: 접두사 설명 문장은 통과" "p.md" "GitHub 토큰은 gh""p_ 로 시작한다."

# --- 4. 마크다운 문체 --------------------------------------------------------
DASH=$(printf '\342\200\224')
DOT=$(printf '\302\267')
expect_hit "문체: md 의 긴 대시" "q.md" "앞${DASH}뒤" "긴 대시(U+2014)"
expect_hit "문체: md 의 가운뎃점" "r.md" "가${DOT}나" "가운뎃점(U+00B7)"
expect_clean "문체: md 가 아니면 통과" "s.txt" "앞${DASH}뒤${DOT}"

# --- 5. SKILL.md 형식 --------------------------------------------------------
R=$(new_repo)
mkdir -p "$R/skills/other"
printf -- '---\nname: wrong\ndescription: 설명\n---\n' >"$R/skills/other/SKILL.md"
scan "$R"
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'skills/other/SKILL.md:1: SKILL.md name(wrong)이 폴더명(other)과 다름'; then
  ok "SKILL.md: name 이 폴더명과 다르면 위반"
else
  fail "SKILL.md: name 이 폴더명과 다르면 위반 (rc=$RC)" "$OUT"
fi

R=$(new_repo)
printf -- '---\nname: demo\ndescription: ""\n---\n' >"$R/skills/demo/SKILL.md"
scan "$R"
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'description 이 비어 있음'; then
  ok "SKILL.md: 빈 description 은 위반"
else
  fail "SKILL.md: 빈 description 은 위반 (rc=$RC)" "$OUT"
fi

R=$(new_repo)
LONG=$(awk 'BEGIN { for (i = 0; i < 1025; i++) printf "가" }')
printf -- '---\nname: demo\ndescription: "%s"\n---\n' "$LONG" >"$R/skills/demo/SKILL.md"
scan "$R"
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'description 이 1025자(1024자 초과)'; then
  ok "SKILL.md: description 1025자는 위반(글자 수 기준)"
else
  fail "SKILL.md: description 1025자는 위반 (rc=$RC)" "$OUT"
fi

R=$(new_repo)
LONG=$(awk 'BEGIN { for (i = 0; i < 1024; i++) printf "가" }')
printf -- '---\nname: demo\ndescription: %s\n---\n' "$LONG" >"$R/skills/demo/SKILL.md"
scan "$R"
if [ "$RC" -eq 0 ]; then ok "SKILL.md: 한글 1024자(3072바이트)는 통과"; else fail "SKILL.md: 한글 1024자는 통과 (rc=$RC)" "$OUT"; fi

R=$(new_repo)
printf -- '---\nname: demo\ndescription: >\n  여러 줄\n  설명이다.\n---\n' >"$R/skills/demo/SKILL.md"
scan "$R"
if [ "$RC" -eq 0 ]; then ok "SKILL.md: 여러 줄 description 을 읽음"; else fail "SKILL.md: 여러 줄 description 을 읽음 (rc=$RC)" "$OUT"; fi

# --- 대상 범위 ---------------------------------------------------------------
R=$(new_repo)
printf 'ignored.txt\n' >"$R/.gitignore"
printf 'key=AK''IAABCDEFGHIJKLMNOP\n' >"$R/ignored.txt"
scan "$R"
if [ "$RC" -eq 0 ]; then ok "범위: .gitignore 로 무시된 파일은 건너뜀"; else fail "범위: 무시된 파일은 건너뜀 (rc=$RC)" "$OUT"; fi

R=$(new_repo)
printf 'key=AK''IAABCDEFGHIJKLMNOP\n' >"$R/new.txt"
scan "$R"
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qF 'new.txt:1:'; then
  ok "범위: 아직 add 하지 않은 새 파일도 검사"
else
  fail "범위: 아직 add 하지 않은 새 파일도 검사 (rc=$RC)" "$OUT"
fi
if printf '%s\n' "$OUT" | grep -q 'ABCDEFGHIJKLMNOP'; then
  fail "출력: 일치한 시크릿 내용을 찍지 않음" "$OUT"
else
  ok "출력: 일치한 시크릿 내용을 찍지 않음"
fi

# --- 6. CFH_DENYLIST ---------------------------------------------------------
R=$(new_repo)
printf 'We met Foocorp yesterday.\nnothing here\n' >"$R/notes.txt"
DENY="$WORK/deny.txt"
printf '# 주석 줄\n\n  foocorp  \n' >"$DENY"
OUT=$(CFH_DENYLIST="$DENY" "$BASH_BIN" "$SCAN" "$R" 2>&1); RC=$?
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qF 'notes.txt:1: 금지어 목록(CFH_DENYLIST) 단어'; then
  ok "금지어: 대소문자 무시 고정 문자열로 잡음"
else
  fail "금지어: 대소문자 무시 고정 문자열로 잡음 (rc=$RC)" "$OUT"
fi
if printf '%s\n' "$OUT" | grep -qi 'foocorp'; then
  fail "금지어: 출력에 금지어를 찍지 않음" "$OUT"
else
  ok "금지어: 출력에 금지어를 찍지 않음"
fi

printf '# 주석만\n# foocorp\n' >"$DENY"
OUT=$(CFH_DENYLIST="$DENY" "$BASH_BIN" "$SCAN" "$R" 2>&1); RC=$?
if [ "$RC" -eq 0 ]; then ok "금지어: 주석 줄은 단어로 쓰지 않음"; else fail "금지어: 주석 줄은 단어로 쓰지 않음 (rc=$RC)" "$OUT"; fi

OUT=$(CFH_DENYLIST="$WORK/없는파일" "$BASH_BIN" "$SCAN" "$R" 2>&1); RC=$?
if [ "$RC" -eq 0 ]; then ok "금지어: 파일이 없으면 건너뜀"; else fail "금지어: 파일이 없으면 건너뜀 (rc=$RC)" "$OUT"; fi

# --- 실행 오류 ---------------------------------------------------------------
mkdir -p "$WORK/notrepo"
OUT=$("$BASH_BIN" "$SCAN" "$WORK/notrepo" 2>&1); RC=$?
if [ "$RC" -eq 2 ]; then ok "git 저장소가 아니면 exit 2"; else fail "git 저장소가 아니면 exit 2 (rc=$RC)" "$OUT"; fi

printf '\n결과: %s 통과, %s 실패 (bash: %s)\n' "$PASS" "$FAIL" "$("$BASH_BIN" -c 'echo $BASH_VERSION')"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# 공개 저장소 위생 검사기. 저장소에 올라갈 텍스트 파일에서 일반 패턴만 찾는다.
#
#   1. 개인 홈 절대 경로    /Users/<이름>/, /home/<이름>/
#   2. 사설 IPv4            10.x.x.x, 172.16~31.x.x, 192.168.x.x
#   3. 시크릿 모양          AWS 액세스 키, GitHub 토큰, Anthropic 키, Slack 토큰, 개인키 머리줄
#   4. 마크다운 문체        *.md 의 긴 대시(U+2014)와 가운뎃점(U+00B7)
#   5. SKILL.md 형식        skills/*/SKILL.md 의 name 이 폴더명과 같고,
#                           description 이 비어 있지 않고 1024자 이하
#   6. 선택: CFH_DENYLIST   환경 변수가 가리키는 파일이 있으면 그 단어도 찾는다.
#                           한 줄에 하나, '#' 로 시작하는 줄은 주석, 대소문자 무시 고정 문자열.
#
# 대상: git 이 추적하는 파일과 무시되지 않은 미추적 파일(.git 제외). 바이너리는 건너뛴다.
# 출력: 위반마다 '파일:줄: 이유'. 일치한 내용은 출력하지 않는다(시크릿이 로그에 남지 않게).
# 종료: 위반 없으면 0, 있으면 1, 실행 오류는 2.
# 사용: bash tests/lint/scan.sh [저장소 루트]   (기본: 이 파일 기준 두 단계 위)
# 의존: bash 3.2 이상, git, grep, sed, awk, tr, wc

set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT="${1:-$HERE/../..}"
ROOT=$(cd "$ROOT" 2>/dev/null && pwd -P) || {
  printf 'scan: 저장소 루트를 찾지 못했습니다: %s\n' "${1:-}" >&2
  exit 2
}
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
  printf 'scan: git 저장소가 아닙니다: %s\n' "$ROOT" >&2
  exit 2
}

# 바이트 단위로 비교해 로캘에 따라 결과가 달라지지 않게 한다.
export LC_ALL=C

VIOLATIONS=0
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t cfh-scan) || exit 2
trap 'rm -rf "$TMP"' EXIT

FILES=()
MD_FILES=()
while IFS= read -r -d '' f; do
  case "$f" in .git/*|*/.git/*) continue ;; esac
  [ -f "$ROOT/$f" ] || continue
  [ -L "$ROOT/$f" ] && continue
  FILES[${#FILES[@]}]="$f"
  case "$f" in *.md|*.MD|*.markdown) MD_FILES[${#MD_FILES[@]}]="$f" ;; esac
done < <(git -C "$ROOT" ls-files -z --cached --others --exclude-standard)

# 사용: check <이유> <grep 옵션> <패턴> <파일...>
# grep -n 출력 '파일:줄:내용' 에서 내용을 버리고 '파일:줄: 이유' 로 찍는다.
check() {
  local reason="$1" opt="$2" pat="$3" out
  shift 3
  [ $# -gt 0 ] || return 0
  out=$(cd "$ROOT" && grep -HnI "$opt" -e "$pat" -- "$@" 2>/dev/null |
    awk -F: -v r="$reason" '{ print $1 ":" $2 ": " r }')
  if [ -n "$out" ]; then
    printf '%s\n' "$out" >>"$TMP/out"
  fi
}

if [ ${#FILES[@]} -gt 0 ]; then
  # 1. 개인 홈 경로. 이름 자리에 영문, 숫자, . _ - 가 오는 실제 경로만 잡는다.
  #    <이름>, $USER 같은 자리 표시는 문자 집합에 맞지 않아 걸리지 않는다.
  check "개인 홈 절대 경로" -E '/(Users|home)/[A-Za-z0-9._-]+/' "${FILES[@]}"

  # 2. 사설 IPv4. 앞뒤가 숫자나 점이면 버전 문자열의 일부로 보고 건너뛴다.
  O='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
  B='(^|[^0-9.])'
  E='([^0-9]|$)'
  check "사설 IPv4 주소" -E "${B}10\\.${O}\\.${O}\\.${O}${E}" "${FILES[@]}"
  check "사설 IPv4 주소" -E "${B}172\\.(1[6-9]|2[0-9]|3[01])\\.${O}\\.${O}${E}" "${FILES[@]}"
  check "사설 IPv4 주소" -E "${B}192\\.168\\.${O}\\.${O}${E}" "${FILES[@]}"

  # 3. 시크릿 모양. 접두사 뒤에 토큰 본문이 붙은 것만 잡아, 접두사를 설명하는 문장은 통과시킨다.
  check "시크릿 모양(AWS 액세스 키)" -E 'AKIA[0-9A-Z]{16}' "${FILES[@]}"
  check "시크릿 모양(GitHub 토큰)" -E 'ghp_[A-Za-z0-9]{20,}' "${FILES[@]}"
  check "시크릿 모양(GitHub 토큰)" -E 'github_pat_[A-Za-z0-9_]{20,}' "${FILES[@]}"
  check "시크릿 모양(Anthropic 키)" -E 'sk-ant-[A-Za-z0-9_-]{16,}' "${FILES[@]}"
  check "시크릿 모양(Slack 토큰)" -E 'xox[abp]-[A-Za-z0-9-]{10,}' "${FILES[@]}"
  check "시크릿 모양(개인키)" -E '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----' "${FILES[@]}"
fi

if [ ${#MD_FILES[@]} -gt 0 ]; then
  # 4. 마크다운 문체. UTF-8 바이트로 찾는다.
  check "긴 대시(U+2014)" -F "$(printf '\342\200\224')" "${MD_FILES[@]}"
  check "가운뎃점(U+00B7)" -F "$(printf '\302\267')" "${MD_FILES[@]}"
fi

# 6. 선택: 사용자 금지어 목록
if [ -n "${CFH_DENYLIST:-}" ] && [ -f "$CFH_DENYLIST" ] && [ ${#FILES[@]} -gt 0 ]; then
  # 주석 줄과 빈 줄을 버리고 앞뒤 공백과 CR 을 지운다.
  sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$CFH_DENYLIST" |
    grep -v -e '^#' -e '^$' >"$TMP/deny"
  if [ -s "$TMP/deny" ]; then
    out=$(cd "$ROOT" && grep -HnIiF -f "$TMP/deny" -- "${FILES[@]}" 2>/dev/null |
      awk -F: '{ print $1 ":" $2 ": 금지어 목록(CFH_DENYLIST) 단어" }')
    [ -n "$out" ] && printf '%s\n' "$out" >>"$TMP/out"
  fi
fi

# 5. SKILL.md 형식
# frontmatter 에서 name 과 description 값을 꺼낸다. 따옴표로 감싼 한 줄 값과
# 들여쓴 여러 줄 값(>, | 블록)을 모두 읽는다. 출력: 'name<TAB>값' 과 'desc<TAB>값'
frontmatter() {
  awk '
    NR == 1 { if ($0 != "---") exit; infm = 1; next }
    infm && $0 == "---" { flush(); exit }
    function unq(s) {
      sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
      if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) s = substr(s, 2, length(s) - 2)
      return s
    }
    function flush() { if (key != "") print key "\t" val; key = "" }
    /^[A-Za-z_-]+:/ {
      flush()
      k = $0; sub(/:.*/, "", k)
      v = $0; sub(/^[^:]*:/, "", v); v = unq(v)
      if (k == "name" || k == "description") {
        key = (k == "name") ? "name" : "desc"
        val = (v ~ /^[>|][-+]?$/) ? "" : v
      }
      next
    }
    /^[ \t]/ && key != "" {
      line = $0; sub(/^[ \t]+/, "", line)
      val = (val == "") ? line : val " " line
      next
    }
  ' "$1"
}

for sk in "$ROOT"/skills/*/SKILL.md; do
  [ -f "$sk" ] || continue
  rel="${sk#"$ROOT"/}"
  dir="${rel#skills/}"
  dir="${dir%/SKILL.md}"
  fm=$(frontmatter "$sk")
  name=$(printf '%s\n' "$fm" | awk -F'\t' '$1 == "name" { sub(/^name\t/, ""); print; exit }')
  desc=$(printf '%s\n' "$fm" | awk -F'\t' '$1 == "desc" { sub(/^desc\t/, ""); print; exit }')
  if [ "$name" != "$dir" ]; then
    printf '%s:1: SKILL.md name(%s)이 폴더명(%s)과 다름\n' "$rel" "${name:-없음}" "$dir" >>"$TMP/out"
  fi
  if [ -z "$(printf '%s' "$desc" | tr -d '[:space:]')" ]; then
    printf '%s:1: SKILL.md description 이 비어 있음\n' "$rel" >>"$TMP/out"
  else
    # UTF-8 이어지는 바이트(0x80~0xBF)를 빼면 바이트 수가 글자 수가 된다.
    n=$(printf '%s' "$desc" | tr -d '\200-\277' | wc -c | tr -d ' ')
    if [ "$n" -gt 1024 ]; then
      printf '%s:1: SKILL.md description 이 %s자(1024자 초과)\n' "$rel" "$n" >>"$TMP/out"
    fi
  fi
done

if [ -s "$TMP/out" ]; then
  sort -t: -k1,1 -k2,2n -u "$TMP/out"
  VIOLATIONS=$(sort -u "$TMP/out" | wc -l | tr -d ' ')
  printf '\nscan: 위반 %s건 (파일 %s개 검사)\n' "$VIOLATIONS" "${#FILES[@]}" >&2
  exit 1
fi
printf 'scan: 위반 없음 (파일 %s개 검사)\n' "${#FILES[@]}"
exit 0

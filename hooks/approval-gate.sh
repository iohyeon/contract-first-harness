#!/usr/bin/env bash
# approval-gate: PreToolUse 훅.
# 플랜 파일의 승인 마커는 사람만 바꾼다. 승인되지 않은 플랜이 실행 중이면
# 하네스 밖 파일 편집과 codex exec 를 막는다.
#
# 입력: stdin 으로 훅 JSON (tool_name, tool_input, cwd)
# 출력: 통과는 exit 0, 거부는 exit 2 와 stderr 메시지
# 의존: bash 3.2 이상, jq, git, grep, head

APPROVED_RE='^\*\*승인\*\*:[[:space:]]*승인[[:space:]]*\(?[0-9]{4}-[0-9]{2}-[0-9]{2}'
PLAN_HEAD_LINES=20

deny() {
  {
    printf '[approval-gate] 거부: %s\n' "$1"
    [ -n "${2:-}" ] && printf '사람이 할 일: %s\n' "$2"
  } >&2
  exit 2
}

if ! command -v jq >/dev/null 2>&1; then
  printf '[approval-gate] jq 가 없어 검사를 건너뜁니다. jq 를 설치하세요.\n' >&2
  exit 0
fi

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD="${CLAUDE_PROJECT_DIR:-$PWD}"

case "$TOOL" in
  Bash|Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

TMPDIR_AG=$(mktemp -d 2>/dev/null || mktemp -d -t approval-gate)
trap 'rm -rf "$TMPDIR_AG"' EXIT

# 경로를 절대 경로로 바꾸고 . 과 .. 을 정리한 뒤, 존재하는 가장 가까운
# 상위 디렉터리의 심볼릭 링크를 풀어 실제 경로로 만든다.
canon_path() {
  local p="$1" base="$2" part dir rest="" n
  case "$p" in /*) ;; *) p="$base/$p" ;; esac
  local -a parts stack
  stack=()
  IFS=/ read -r -a parts <<EOF
$p
EOF
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.) ;;
      ..)
        n=${#stack[@]}
        if [ "$n" -gt 0 ]; then
          unset "stack[$((n - 1))]"
          if [ "$n" -gt 1 ]; then stack=("${stack[@]}"); else stack=(); fi
        fi
        ;;
      *) stack[${#stack[@]}]="$part" ;;
    esac
  done
  dir=""
  for part in "${stack[@]}"; do dir="$dir/$part"; done
  [ -z "$dir" ] && dir=/
  while [ ! -d "$dir" ]; do
    rest="/${dir##*/}$rest"
    dir="${dir%/*}"
    [ -z "$dir" ] && dir=/
  done
  dir=$(cd "$dir" 2>/dev/null && pwd -P)
  [ "$dir" = / ] && dir=""
  printf '%s%s' "$dir" "$rest"
}

# 파일 앞부분에 승인 줄이 있으면 0
file_is_approved() {
  [ -f "$1" ] || return 1
  head -n "$PLAN_HEAD_LINES" "$1" | LC_ALL=C grep -Eq "$APPROVED_RE"
}

REPO_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT=$(canon_path "$CWD" /)
fi
HARNESS_DIR="$REPO_ROOT/.claude/harness"

# 실행 중인 플랜이 승인되지 않았으면 그 플랜 경로를 출력하고 0
active_plan_unapproved() {
  local pointer="$HARNESS_DIR/active-plan" rel plan
  [ -f "$pointer" ] || return 1
  rel=$(head -n 1 "$pointer" | tr -d '\r')
  rel="${rel#"${rel%%[![:space:]]*}"}"
  rel="${rel%"${rel##*[![:space:]]}"}"
  if [ -z "$rel" ]; then
    printf '%s' "(active-plan 이 비어 있음)"
    return 0
  fi
  case "$rel" in
    /*) plan="$rel" ;;
    *) plan="$REPO_ROOT/$rel" ;;
  esac
  if file_is_approved "$plan"; then
    return 1
  fi
  printf '%s' "$rel"
  return 0
}

if [ "$TOOL" = Bash ]; then
  CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')

  # 규칙 2: 셸로 승인 마커를 조작하지 못하게 한다.
  case "$CMD" in
    *".claude/harness/plan/"*)
      case "$CMD" in
        *"승인"*)
          deny "셸 명령이 플랜 파일과 승인 마커를 함께 다룹니다. 승인 줄은 사람만 바꿉니다." \
            "승인하려면 플랜 파일을 직접 열어 '**승인**: 승인 YYYY-MM-DD' 로 고치세요."
          ;;
      esac
      ;;
  esac

  # 규칙 3: 미승인 플랜 실행 중에는 codex exec 를 막는다.
  if printf '%s' "$CMD" | grep -Eq '(^|[^[:alnum:]_-])codex[[:space:]]+exec([[:space:]]|$)'; then
    if plan=$(active_plan_unapproved); then
      deny "실행 중인 플랜($plan)이 승인되지 않아 codex exec 를 실행할 수 없습니다." \
        "플랜을 검토한 뒤 승인 줄을 '**승인**: 승인 YYYY-MM-DD' 로 직접 고치세요."
    fi
  fi
  exit 0
fi

# Edit, Write, MultiEdit
RAW_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$RAW_PATH" ] && exit 0
TARGET=$(canon_path "$RAW_PATH" "$CWD")

# 규칙 1: 미승인 플랜을 승인 상태로 바꾸는 편집을 막는다.
case "$TARGET" in
  */.claude/harness/plan/*.md)
    OLD_FILE=/dev/null
    [ -f "$TARGET" ] && OLD_FILE="$TARGET"
    NEW_FILE="$TMPDIR_AG/new.md"
    if ! printf '%s' "$INPUT" | jq -r --rawfile old "$OLD_FILE" '
        def replace_first($s; $o; $n):
          ($s | split($o)) as $p
          | if ($p | length) < 2 then $s else $p[0] + $n + ($p[1:] | join($o)) end;
        def apply_edit($s; $e):
          ($e.old_string // "") as $o
          | ($e.new_string // "") as $n
          | if $o == "" then (if $s == "" then $n else $s end)
            elif ($e.replace_all // false) then ($s | split($o) | join($n))
            else replace_first($s; $o; $n) end;
        .tool_input as $t
        | if .tool_name == "Write" then ($t.content // "")
          elif .tool_name == "Edit" then apply_edit($old; $t)
          else reduce ($t.edits // [])[] as $e ($old; apply_edit(.; $e))
          end
      ' >"$NEW_FILE" 2>/dev/null; then
      deny "플랜 파일 편집 결과를 계산하지 못했습니다(입력 JSON 해석 실패)." \
        "편집 내용을 확인하세요."
    fi
    if file_is_approved "$NEW_FILE" && ! file_is_approved "$OLD_FILE"; then
      deny "이 편집은 미승인 플랜($RAW_PATH)을 승인 상태로 바꿉니다. 승인 줄은 사람만 바꿉니다." \
        "플랜을 검토한 뒤 직접 '**승인**: 승인 YYYY-MM-DD' 로 고치세요. AI 에게는 승인 줄을 빼고 편집하게 하세요."
    fi
    ;;
esac

# 규칙 3: 미승인 플랜 실행 중에는 하네스 밖 파일 편집을 막는다.
case "$TARGET" in
  "$HARNESS_DIR"/*) exit 0 ;;
esac
if plan=$(active_plan_unapproved); then
  deny "실행 중인 플랜($plan)이 승인되지 않아 .claude/harness/ 밖 파일($RAW_PATH)을 고칠 수 없습니다." \
    "플랜을 검토해 승인 줄을 '**승인**: 승인 YYYY-MM-DD' 로 직접 고치거나, 실행을 멈추려면 .claude/harness/active-plan 을 지우세요."
fi
exit 0

#!/usr/bin/env bash
# review-gate: PreToolUse 훅. 저장소별 opt-in(git config review-gate.enabled true).
#
# 막는 것
#   1. Bash 의 git commit, git push, gh pr create, glab mr create 중
#      해당 트리에 사용자 확인 기록이 없는 것
#      (commit 은 작업 트리 전체의 트리, 나머지는 HEAD^{tree} 기준)
#   2. 모델이 기록을 쓰는 것: Bash 의 review-gate record,
#      git-dir 아래 review-gate/ 를 대상으로 하는 Edit, Write, MultiEdit
# 입력: stdin 으로 훅 JSON. 통과는 exit 0, 거부는 exit 2 와 stderr 메시지.

HOOK_DIR=$(cd "$(dirname "$0")" && pwd -P)
PLUGIN_ROOT=$(cd "$HOOK_DIR/.." && pwd -P)
CLI="$PLUGIN_ROOT/bin/review-gate"

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  # jq 없이는 입력을 읽을 수 없다. 켜진 저장소에서는 막고(fail-closed), 아니면 통과.
  if [ "$(git config --bool review-gate.enabled 2>/dev/null)" = true ]; then
    printf '[review-gate] 거부: jq 가 없어 판정할 수 없습니다. jq 를 설치하세요.\n' >&2
    exit 2
  fi
  exit 0
fi

# shellcheck source=lib/review-gate-core.sh
if ! . "$HOOK_DIR/lib/review-gate-core.sh" 2>/dev/null; then
  if [ "$(git config --bool review-gate.enabled 2>/dev/null)" = true ]; then
    printf '[review-gate] 거부: lib/review-gate-core.sh 를 읽지 못했습니다.\n' >&2
    exit 2
  fi
  exit 0
fi

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD="${CLAUDE_PROJECT_DIR:-$PWD}"

deny() {
  printf '[review-gate] 거부: %s\n' "$1" >&2
  shift
  while [ $# -gt 0 ]; do
    printf '%s\n' "$1" >&2
    shift
  done
  exit 2
}

record_hint() {
  printf '%s\n' \
    "할 일: review-gate 스킬 절차대로 바뀐 쿼리의 실행 SQL과 읽을 코드 목록을 사용자에게 제시하고, 사용자가 직접 기록하게 요청하세요. 모델은 기록하지 않습니다." \
    "  사용자 명령: ! review-gate record code \"<코드 피드백>\"" \
    "              ! review-gate record query \"<실행한 SQL과 결과 요약>\"" \
    "              ! review-gate record loose \"<느슨하게 가는 이유>\" (세 번 문답 뒤)" \
    "  review-gate 가 PATH 에 없으면: ! \"$CLI\" record ..." \
    "  상태 보기: ! review-gate status"
}

strip_quotes() {
  local s="$1"
  case "$s" in
    \"*\") s="${s#\"}"; s="${s%\"}" ;;
    \'*\') s="${s#\'}"; s="${s%\'}" ;;
  esac
  printf '%s' "$s"
}

case "$TOOL" in
  Bash)
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
    [ -z "$CMD" ] && exit 0

    # 대상 저장소: git -C <경로>, 명령 앞 cd <경로>, 아니면 cwd
    DIR="$CWD"
    QARG='("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|]+)'
    CD_ARG=$(printf '%s\n' "$CMD" | head -n 1 | sed -nE "s/^[[:space:]]*cd[[:space:]]+$QARG.*/\\1/p")
    if [ -n "$CD_ARG" ]; then
      DIR=$(rg_canon_path "$(strip_quotes "$CD_ARG")" "$CWD")
    fi
    C_ARG=$(printf '%s\n' "$CMD" | sed -nE "s/.*(^|[[:space:];&|(])git[[:space:]]+-C[[:space:]]+$QARG.*/\\2/p" | head -n 1)
    if [ -n "$C_ARG" ]; then
      DIR=$(rg_canon_path "$(strip_quotes "$C_ARG")" "$DIR")
    fi

    rg_is_repo "$DIR" || exit 0
    rg_enabled "$DIR" || exit 0

    if printf '%s' "$CMD" | grep -Eq 'review-gate["'"'"']?[[:space:]]+record'; then
      deny "확인 기록은 사용자만 남깁니다. 모델은 review-gate record 를 실행할 수 없습니다." \
        "사용자에게 '! review-gate record ...' 를 직접 실행해 달라고 요청하세요."
    fi

    SEP='(^|[;&|({`[:space:]])'
    GITPRE="${SEP}git([[:space:]]+(-C|-c|--git-dir|--work-tree)[[:space:]]+[^[:space:]]+|[[:space:]]+-[-[:alnum:]]+(=[^[:space:]]*)?)*[[:space:]]+"
    END='([[:space:];&|)]|$)'
    IS_COMMIT=0
    IS_PUBLISH=0
    printf '%s' "$CMD" | grep -Eq "${GITPRE}commit${END}" && IS_COMMIT=1
    printf '%s' "$CMD" | grep -Eq "${GITPRE}push${END}" && IS_PUBLISH=1
    printf '%s' "$CMD" | grep -Eq "${SEP}(gh[[:space:]]+pr[[:space:]]+create|glab[[:space:]]+mr[[:space:]]+create)${END}" && IS_PUBLISH=1

    if [ "$IS_COMMIT" -eq 0 ] && [ "$IS_PUBLISH" -eq 0 ]; then
      exit 0
    fi

    if [ "$IS_COMMIT" -eq 1 ]; then
      # 커밋이 섞이면 작업 트리 전체 기준으로 본다(커밋 뒤 push 하는 한 줄 명령 포함).
      MODE=commit
      BASIS="작업 트리 전체"
      TREE=$(rg_worktree_tree "$DIR")
      if [ -z "$TREE" ]; then
        deny "작업 트리의 트리 해시를 계산하지 못했습니다." "저장소 상태를 확인하세요(git status)."
      fi
    else
      MODE=push
      BASIS="HEAD^{tree}"
      TREE=$(rg_head_tree "$DIR")
      [ -z "$TREE" ] && exit 0
    fi

    if rg_check "$DIR" "$TREE" "$MODE"; then
      exit 0
    fi

    NEED="code 기록"
    [ -n "$RG_QUERY_FILES" ] && NEED="code 기록과 query 기록"
    QLIST=""
    if [ -n "$RG_QUERY_FILES" ]; then
      QLIST="바뀐 쿼리 파일: $(printf '%s' "$RG_QUERY_FILES" | tr '\n' ' ')"
    fi
    # shellcheck disable=SC2046
    deny "이 코드 트리에 사용자 확인 기록이 없습니다." \
      "기준: $BASIS, tree $TREE" \
      "필요한 기록: $NEED (빠진 것: $RG_MISSING). loose 기록이 있으면 대신 통과합니다." \
      ${QLIST:+"$QLIST"} \
      "기록 뒤 파일이 하나라도 바뀌면 tree 가 달라져 다시 기록해야 합니다." \
      "$(record_hint)"
    ;;

  Edit|Write|MultiEdit)
    RAW_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
    [ -z "$RAW_PATH" ] && exit 0
    TARGET=$(rg_canon_path "$RAW_PATH" "$CWD")
    for d in "$(rg_existing_dir "$TARGET")" "$CWD"; do
      rg_is_repo "$d" || continue
      rg_enabled "$d" || continue
      GD=$(rg_git_dir "$d") || continue
      case "$TARGET" in
        "$GD/review-gate"|"$GD/review-gate/"*)
          deny "확인 기록은 사용자만 남깁니다. git-dir 아래 review-gate/ 는 모델이 쓸 수 없습니다." \
            "사용자에게 '! review-gate record ...' 를 직접 실행해 달라고 요청하세요."
          ;;
      esac
    done
    exit 0
    ;;
esac

exit 0

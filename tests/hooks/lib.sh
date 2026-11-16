#!/usr/bin/env bash
# 훅 테스트 공용 도구. 각 *_test.sh 가 source 한다. 외부 프레임워크 없음.

TESTS_HOOKS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
PLUGIN_DIR=$(cd "$TESTS_HOOKS_DIR/../.." && pwd -P)
# 아래 경로 변수는 이 파일을 source 하는 테스트가 쓴다.
# shellcheck disable=SC2034
APPROVAL_HOOK="$PLUGIN_DIR/hooks/approval-gate.sh"
# shellcheck disable=SC2034
REVIEW_HOOK="$PLUGIN_DIR/hooks/review-gate.sh"
# shellcheck disable=SC2034
REVIEW_CLI="$PLUGIN_DIR/bin/review-gate"
BASH_BIN="${TEST_BASH:-bash}"

PASS=0
FAIL=0

# 바깥 git 설정과 환경이 새어 들어오지 않게 한다.
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t hooks-test)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=tester GIT_AUTHOR_EMAIL=tester@example.com
export GIT_COMMITTER_NAME=tester GIT_COMMITTER_EMAIL=tester@example.com
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE CLAUDE_PROJECT_DIR

ok() {
  PASS=$((PASS + 1))
  printf 'ok   - %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL - %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'
}

# 새 git 저장소를 만들고 경로를 출력한다.
new_repo() {
  local d
  d=$(mktemp -d "$WORK/repo.XXXXXX")
  git -C "$d" init -q
  git -C "$d" config user.name tester
  git -C "$d" config user.email tester@example.com
  git -C "$d" config commit.gpgsign false
  printf '%s\n' "$d"
}

# 훅 JSON 만들기
json_bash() { # cwd command
  jq -n --arg cwd "$1" --arg c "$2" '{tool_name:"Bash", cwd:$cwd, tool_input:{command:$c}}'
}
json_edit() { # cwd file old new [replace_all]
  jq -n --arg cwd "$1" --arg f "$2" --arg o "$3" --arg n "$4" --argjson r "${5:-false}" \
    '{tool_name:"Edit", cwd:$cwd, tool_input:{file_path:$f, old_string:$o, new_string:$n, replace_all:$r}}'
}
json_write() { # cwd file content
  jq -n --arg cwd "$1" --arg f "$2" --arg c "$3" \
    '{tool_name:"Write", cwd:$cwd, tool_input:{file_path:$f, content:$c}}'
}
json_multiedit() { # cwd file edits-json
  jq -n --arg cwd "$1" --arg f "$2" --argjson e "$3" \
    '{tool_name:"MultiEdit", cwd:$cwd, tool_input:{file_path:$f, edits:$e}}'
}

# 사용: expect_exit <이름> <기대 코드> <훅> <json>
LAST_ERR=""
expect_exit() {
  local name="$1" want="$2" hook="$3" json="$4" got
  LAST_ERR=$(printf '%s' "$json" | "$BASH_BIN" "$hook" 2>&1 >/dev/null)
  got=$?
  if [ "$got" = "$want" ]; then
    ok "$name"
  else
    fail "$name (기대 exit $want, 실제 $got)" "$LAST_ERR"
  fi
}

finish() {
  printf '\n결과: %s 통과, %s 실패 (bash: %s)\n' "$PASS" "$FAIL" "$("$BASH_BIN" -c 'echo $BASH_VERSION')"
  [ "$FAIL" -eq 0 ]
}

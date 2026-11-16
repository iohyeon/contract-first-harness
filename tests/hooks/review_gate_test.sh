#!/usr/bin/env bash
# review-gate 훅과 CLI 테스트. 실행: bash tests/hooks/review_gate_test.sh
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

H="$REVIEW_HOOK"
cli() { # 저장소 인자...
  local d="$1"
  shift
  (cd "$d" && "$BASH_BIN" "$REVIEW_CLI" "$@") >/dev/null 2>&1
}

R=$(new_repo)
printf 'class App {}\n' >"$R/App.java"
printf 'build/\n' >"$R/.gitignore"
git -C "$R" add -A && git -C "$R" commit -qm init

# --- opt-in --------------------------------------------------------------------
printf 'class App { int a; }\n' >"$R/App.java"
expect_exit "비활성 저장소: commit 통과" 0 "$H" "$(json_bash "$R" 'git commit -am x')"
expect_exit "저장소가 아니면 통과" 0 "$H" "$(json_bash "$WORK" 'git commit -am x')"

cli "$R" enable
if [ "$(git -C "$R" config --bool review-gate.enabled)" = true ]; then
  ok "CLI enable: git config 에 켜짐"
else
  fail "CLI enable: git config 에 켜짐"
fi
if [ -z "$(git -C "$R" status --porcelain)" ] || [ "$(git -C "$R" status --porcelain)" = " M App.java" ]; then
  ok "enable 은 추적 파일을 바꾸지 않음"
else
  fail "enable 은 추적 파일을 바꾸지 않음" "$(git -C "$R" status --porcelain)"
fi

# --- commit 판정 -----------------------------------------------------------------
expect_exit "기록 없음: commit 거부" 2 "$H" "$(json_bash "$R" 'git commit -am x')"
case "$LAST_ERR" in
  *"review-gate record code"*) ok "거부 메시지에 사용자 기록 명령 안내" ;;
  *) fail "거부 메시지에 사용자 기록 명령 안내" "$LAST_ERR" ;;
esac
expect_exit "기록 없음: git -C 경로 commit 거부(cwd 는 저장소 밖)" 2 "$H" \
  "$(json_bash "$WORK" "git -C '$R' commit -m x")"
expect_exit "기록 없음: cd 경로 && git commit 거부" 2 "$H" \
  "$(json_bash "$WORK" "cd \"$R\" && git add -A && git commit -m x")"
expect_exit "기록 없음: git -c 옵션 뒤 commit 거부" 2 "$H" \
  "$(json_bash "$R" 'git -c core.editor=true commit -m x')"
expect_exit "기록 없음: gh pr create 거부(HEAD 기준)" 2 "$H" "$(json_bash "$R" 'gh pr create --fill')"
expect_exit "기록 없음: glab mr create 거부" 2 "$H" "$(json_bash "$R" 'glab mr create --fill')"
expect_exit "커밋, push 가 아닌 명령은 통과" 0 "$H" "$(json_bash "$R" 'git status && git log --oneline')"

cli "$R" record code "App 필드 추가 확인함"
expect_exit "code 기록 뒤 commit 통과" 0 "$H" "$(json_bash "$R" 'git commit -am x')"
expect_exit "code 기록 뒤 부분 스테이징 commit 도 통과(작업 트리 기준)" 0 "$H" \
  "$(json_bash "$R" 'git add App.java && git commit -m x')"

printf 'class App { int a; int b; }\n' >"$R/App.java"
expect_exit "파일을 바꾸면 tree 가 달라져 다시 거부" 2 "$H" "$(json_bash "$R" 'git commit -am x')"
cli "$R" record code "b 필드도 확인"
expect_exit "다시 기록하면 통과" 0 "$H" "$(json_bash "$R" 'git commit -am x')"

printf 'tmp\n' >"$R/notes.txt"
expect_exit "무시되지 않은 미추적 파일이 생겨도 tree 가 달라져 거부" 2 "$H" "$(json_bash "$R" 'git commit -am x')"
rm -f "$R/notes.txt"
mkdir -p "$R/build" && printf 'out\n' >"$R/build/out.bin"
expect_exit "무시된 파일은 tree 에 들어가지 않아 통과" 0 "$H" "$(json_bash "$R" 'git commit -am x')"

# --- query 판정 ------------------------------------------------------------------
mkdir -p "$R/db"
printf 'SELECT id FROM app;\n' >"$R/db/find.sql"
cli "$R" record code "find.sql 추가 코드 확인"
expect_exit "쿼리 파일 변경: code 기록만으로는 거부" 2 "$H" "$(json_bash "$R" 'git commit -am x')"
case "$LAST_ERR" in
  *db/find.sql*) ok "거부 메시지에 바뀐 쿼리 파일 표시" ;;
  *) fail "거부 메시지에 바뀐 쿼리 파일 표시" "$LAST_ERR" ;;
esac
cli "$R" record query "SELECT id FROM app; 실행, 3건, 인덱스 사용 확인"
expect_exit "query 기록까지 있으면 통과" 0 "$H" "$(json_bash "$R" 'git commit -am x')"

rm -f "$R/db/find.sql"
mkdir -p "$R/src/mapper"
printf '<mapper/>\n' >"$R/src/mapper/UserMapper.xml"
cli "$R" record code "Mapper 확인"
expect_exit "*Mapper.xml 도 기본 쿼리 패턴: code 만으로는 거부" 2 "$H" "$(json_bash "$R" 'git commit -am x')"
rm -f "$R/src/mapper/UserMapper.xml"

git -C "$R" config --add review-gate.query-pattern '*.graphql'
printf 'query { a }\n' >"$R/q.graphql"
cli "$R" record code "graphql 확인"
expect_exit "사용자 쿼리 패턴: code 만으로는 거부" 2 "$H" "$(json_bash "$R" 'git commit -am x')"
rm -f "$R/q.graphql"
printf '<mapper/>\n' >"$R/OtherMapper.xml"
cli "$R" record code "xml 확인"
expect_exit "사용자 패턴을 정하면 기본 패턴은 쓰지 않음(설정 우선)" 0 "$H" "$(json_bash "$R" 'git commit -am x')"
rm -f "$R/q.graphql" "$R/OtherMapper.xml"
git -C "$R" config --unset-all review-gate.query-pattern

# --- loose ------------------------------------------------------------------------
printf 'SELECT 1;\n' >"$R/db/loose.sql"
expect_exit "loose 기록 전: 거부" 2 "$H" "$(json_bash "$R" 'git commit -am x')"
cli "$R" record loose "Q: 왜 빨리? A: 장애 대응. Q: 범위? A: 한 줄. Q: 확인 계획? A: 내일 다시 본다."
expect_exit "loose 기록으로 통과(code, query 없어도)" 0 "$H" "$(json_bash "$R" 'git commit -am x')"
rm -f "$R/db/loose.sql"

# --- push 는 HEAD tree 기준 --------------------------------------------------------
printf 'class App { int c; }\n' >"$R/App.java"
cli "$R" record code "c 필드 확인"
expect_exit "커밋 전 commit 판정 통과" 0 "$H" "$(json_bash "$R" 'git commit -am c')"
git -C "$R" add -A && git -C "$R" commit -qm c
printf 'class App { int c; int dirty; }\n' >"$R/App.java"
expect_exit "push: 작업 트리가 더러워도 HEAD tree 에 기록이 있으면 통과" 0 "$H" "$(json_bash "$R" 'git push origin HEAD')"
expect_exit "commit: 같은 상태에서 작업 트리 기준이라 거부" 2 "$H" "$(json_bash "$R" 'git commit -am d')"
git -C "$R" commit -qam "기록 없는 커밋"
expect_exit "push: HEAD tree 에 기록이 없으면 거부" 2 "$H" "$(json_bash "$R" 'git push')"
cli "$R" record --head code "HEAD 기준 확인"
expect_exit "record --head 뒤 push 통과" 0 "$H" "$(json_bash "$R" 'git push -u origin main')"

# --- 모델의 기록 쓰기 금지 --------------------------------------------------------------
expect_exit "Bash: 모델의 review-gate record 거부" 2 "$H" "$(json_bash "$R" 'review-gate record code "좋음"')"
expect_exit "Bash: 경로로 부른 review-gate record 도 거부" 2 "$H" \
  "$(json_bash "$R" "\"$REVIEW_CLI\" record loose 'Q: A:'")"
expect_exit "Bash: review-gate status 는 허용" 0 "$H" "$(json_bash "$R" 'review-gate status')"
GD=$(git -C "$R" rev-parse --absolute-git-dir)
expect_exit "Write: git-dir 아래 review-gate 기록 파일 거부" 2 "$H" \
  "$(json_write "$R" "$GD/review-gate/code-0000.md" '확인함')"
expect_exit "Write: 상대 경로 .git/review-gate 도 거부" 2 "$H" \
  "$(json_write "$R" ".git/review-gate/loose-0000.md" 'Q: A:')"
expect_exit "Edit: 기존 기록 파일 편집 거부" 2 "$H" \
  "$(json_edit "$R" "$(ls "$GD"/review-gate/code-*.md | head -n 1)" '확인' '좋음')"
expect_exit "Write: 일반 파일은 통과" 0 "$H" "$(json_write "$R" "$R/App.java" 'class App {}')"

# --- 실제 인덱스가 변하지 않음 -------------------------------------------------------------
printf 'class App { int staged; }\n' >"$R/App.java"
git -C "$R" add App.java
printf 'class App { int staged; int unstaged; }\n' >"$R/App.java"
printf 'new\n' >"$R/untracked.txt"
IDX="$GD/index"
BEFORE_SUM=$(cksum <"$IDX")
BEFORE_CACHED=$(git -C "$R" diff --cached --name-status)
BEFORE_STATUS=$(git -C "$R" status --porcelain)
BEFORE_SUM=$(cksum <"$IDX")
expect_exit "인덱스 검사용 commit 판정(거부)" 2 "$H" "$(json_bash "$R" 'git commit -m x')"
cli "$R" status
cli "$R" record code "인덱스 테스트"
AFTER_SUM=$(cksum <"$IDX")
if [ "$BEFORE_SUM" = "$AFTER_SUM" ]; then
  ok "훅과 CLI 실행 뒤 실제 인덱스 파일이 그대로"
else
  fail "훅과 CLI 실행 뒤 실제 인덱스 파일이 그대로"
fi
if [ "$BEFORE_CACHED" = "$(git -C "$R" diff --cached --name-status)" ] &&
  [ "$BEFORE_STATUS" = "$(git -C "$R" status --porcelain)" ]; then
  ok "스테이징 상태와 미추적 파일이 그대로"
else
  fail "스테이징 상태와 미추적 파일이 그대로" "$(git -C "$R" status --porcelain)"
fi
expect_exit "미추적 파일 포함 tree 로 기록하면 부분 스테이징 commit 통과" 0 "$H" "$(json_bash "$R" 'git commit -m x')"

# --- CLI ------------------------------------------------------------------------------
REC=$(ls "$GD"/review-gate/code-*.md | head -n 1)
if grep -q '시각:' "$REC" && grep -q 'tree:' "$REC" && grep -q '브랜치:' "$REC"; then
  ok "기록 파일에 시각, tree, 브랜치가 있음"
else
  fail "기록 파일에 시각, tree, 브랜치가 있음" "$(cat "$REC")"
fi
if (cd "$R" && "$BASH_BIN" "$REVIEW_CLI" record code "") >/dev/null 2>&1; then
  fail "CLI: 빈 내용은 기록하지 않음"
else
  ok "CLI: 빈 내용은 기록하지 않음"
fi
if (cd "$R" && "$BASH_BIN" "$REVIEW_CLI" record review "x") >/dev/null 2>&1; then
  fail "CLI: 모르는 kind 는 실패"
else
  ok "CLI: 모르는 kind 는 실패"
fi
STATUS=$(cd "$R" && "$BASH_BIN" "$REVIEW_CLI" status 2>&1)
case "$STATUS" in
  *"필요한 기록"*"있는 기록"*) ok "CLI status: 필요한 기록과 있는 기록 표시" ;;
  *) fail "CLI status: 필요한 기록과 있는 기록 표시" "$STATUS" ;;
esac
printf 'Q: 1\nA: 1\n' | (cd "$R" && "$BASH_BIN" "$REVIEW_CLI" record loose -) >/dev/null 2>&1 &&
  ok "CLI: - 로 표준 입력에서 기록" || fail "CLI: - 로 표준 입력에서 기록"

cli "$R" disable
expect_exit "CLI disable 뒤 commit 통과" 0 "$H" "$(json_bash "$R" 'git commit -am x')"

finish

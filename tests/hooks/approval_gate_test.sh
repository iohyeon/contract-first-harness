#!/usr/bin/env bash
# approval-gate 훅 테스트. 실행: bash tests/hooks/approval_gate_test.sh
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

H="$APPROVAL_HOOK"
R=$(new_repo)
mkdir -p "$R/.claude/harness/plan" "$R/.claude/harness/report" "$R/src"
PLAN="$R/.claude/harness/plan/feature.md"
APPROVED_PLAN="$R/.claude/harness/plan/approved.md"
LEGACY_PLAN="$R/.claude/harness/plan/legacy.md"
POINTER="$R/.claude/harness/active-plan"
printf 'int main(void) { return 0; }\n' >"$R/src/main.c"

write_plan() { # 경로 승인줄
  printf '# 플랜\n\n%s\n\n## 태스크\n\n- [ ] T1 첫 작업\n' "$2" >"$1"
}
write_plan "$PLAN" '**승인**: 미승인'
write_plan "$APPROVED_PLAN" '**승인**: 승인 2026-11-16 검토 끝'
write_plan "$LEGACY_PLAN" '**승인**: 승인 (2026-11-16, 예전 형식)'

# --- 규칙 1: 플랜 승인 줄 ----------------------------------------------------
expect_exit "Edit: 미승인을 승인으로 바꾸면 거부" 2 "$H" \
  "$(json_edit "$R" "$PLAN" '**승인**: 미승인' '**승인**: 승인 2026-11-16')"
case "$LAST_ERR" in
  *사람*) ok "Edit 거부 메시지에 사람이 할 일이 있음" ;;
  *) fail "Edit 거부 메시지에 사람이 할 일이 있음" "$LAST_ERR" ;;
esac
expect_exit "Edit: 괄호 형식으로 승인해도 거부" 2 "$H" \
  "$(json_edit "$R" "$PLAN" '**승인**: 미승인' '**승인**: 승인 (2026-11-16, 메모)')"
expect_exit "Edit: 미승인 플랜의 다른 줄 편집은 허용" 0 "$H" \
  "$(json_edit "$R" "$PLAN" '- [ ] T1 첫 작업' '- [x] T1 첫 작업')"
expect_exit "Edit: 승인 상태 파일의 다른 줄 편집은 허용" 0 "$H" \
  "$(json_edit "$R" "$APPROVED_PLAN" '- [ ] T1 첫 작업' '- [x] T1 첫 작업')"
expect_exit "Edit: 상대 경로와 .. 으로 가도 거부" 2 "$H" \
  "$(json_edit "$R/src" "../.claude/harness/plan/./feature.md" '미승인' '승인 2026-11-16')"
expect_exit "Edit: replace_all 로 승인하면 거부" 2 "$H" \
  "$(json_edit "$R" "$PLAN" '미승인' '승인 2026-11-16' true)"
expect_exit "Write: 새 플랜을 승인 상태로 만들면 거부" 2 "$H" \
  "$(json_write "$R" "$R/.claude/harness/plan/new.md" "$(printf '# 새 플랜\n\n**승인**: 승인 2026-11-16\n')")"
expect_exit "Write: 새 플랜을 미승인 상태로 만들면 허용" 0 "$H" \
  "$(json_write "$R" "$R/.claude/harness/plan/new.md" "$(printf '# 새 플랜\n\n**승인**: 미승인\n')")"
expect_exit "Write: 기존 미승인 플랜을 승인 내용으로 덮어쓰면 거부" 2 "$H" \
  "$(json_write "$R" "$PLAN" "$(printf '# 플랜\n\n**승인**: 승인 2026-11-16\n')")"
EDITS=$(jq -n '[{old_string:"- [ ] T1 첫 작업", new_string:"- [x] T1 첫 작업"},
                {old_string:"**승인**: 미승인", new_string:"**승인**: 승인 2026-11-16"}]')
expect_exit "MultiEdit: 편집 중 하나가 승인으로 바꾸면 거부" 2 "$H" "$(json_multiedit "$R" "$PLAN" "$EDITS")"
EDITS=$(jq -n '[{old_string:"**승인**: 미승인", new_string:"**승인**: 보류"},
                {old_string:"**승인**: 보류", new_string:"**승인**: 승인 2026-11-16"}]')
expect_exit "MultiEdit: 순서대로 적용해 최종 결과가 승인이면 거부" 2 "$H" "$(json_multiedit "$R" "$PLAN" "$EDITS")"
EDITS=$(jq -n '[{old_string:"- [ ] T1 첫 작업", new_string:"- [x] T1 첫 작업"}]')
expect_exit "MultiEdit: 승인 줄을 건드리지 않으면 허용" 0 "$H" "$(json_multiedit "$R" "$PLAN" "$EDITS")"

# --- 규칙 2: Bash 로 승인 마커 조작 ------------------------------------------
expect_exit "Bash: sed 로 승인 마커를 바꾸면 거부" 2 "$H" \
  "$(json_bash "$R" "sed -i '' 's/미승인/승인 2026-11-16/' .claude/harness/plan/feature.md")"
expect_exit "Bash: 플랜 경로만 다루는 명령은 허용" 0 "$H" \
  "$(json_bash "$R" "cat .claude/harness/plan/feature.md")"

# --- 규칙 3: active-plan ------------------------------------------------------
expect_exit "active-plan 없음: src 편집 허용" 0 "$H" \
  "$(json_edit "$R" "$R/src/main.c" 'return 0' 'return 1')"
expect_exit "active-plan 없음: codex exec 허용" 0 "$H" "$(json_bash "$R" 'codex exec "T1 구현"')"

printf '.claude/harness/plan/feature.md\n' >"$POINTER"
expect_exit "active-plan 미승인: src Edit 거부" 2 "$H" \
  "$(json_edit "$R" "$R/src/main.c" 'return 0' 'return 1')"
expect_exit "active-plan 미승인: src Write 거부" 2 "$H" \
  "$(json_write "$R" "$R/src/new.c" 'int x;')"
expect_exit "active-plan 미승인: 저장소 밖 파일 Write 거부" 2 "$H" \
  "$(json_write "$R" "$WORK/outside.txt" 'x')"
expect_exit "active-plan 미승인: .claude/harness 아래 리포트 Write 허용" 0 "$H" \
  "$(json_write "$R" "$R/.claude/harness/report/drift-feature-T1.md" '# 리포트')"
expect_exit "active-plan 미승인: 플랜 체크박스 Edit 허용" 0 "$H" \
  "$(json_edit "$R" "$PLAN" '- [ ] T1 첫 작업' '- [x] T1 첫 작업')"
expect_exit "active-plan 미승인: codex exec 거부" 2 "$H" \
  "$(json_bash "$R" 'cd . && codex exec --full-auto "T1 구현"')"
expect_exit "active-plan 미승인: 일반 Bash 허용" 0 "$H" "$(json_bash "$R" 'ls src')"
expect_exit "active-plan 미승인: 하위 디렉터리 cwd 에서도 src 편집 거부" 2 "$H" \
  "$(json_edit "$R/src" "main.c" 'return 0' 'return 1')"

printf '\n' >"$POINTER"
expect_exit "active-plan 이 비어 있으면 src 편집 거부" 2 "$H" \
  "$(json_edit "$R" "$R/src/main.c" 'return 0' 'return 1')"

printf '.claude/harness/plan/missing.md\n' >"$POINTER"
expect_exit "active-plan 이 없는 플랜을 가리키면 src 편집 거부" 2 "$H" \
  "$(json_edit "$R" "$R/src/main.c" 'return 0' 'return 1')"

printf '.claude/harness/plan/approved.md\n' >"$POINTER"
expect_exit "active-plan 승인: src 편집 허용" 0 "$H" \
  "$(json_edit "$R" "$R/src/main.c" 'return 0' 'return 1')"
expect_exit "active-plan 승인: codex exec 허용" 0 "$H" "$(json_bash "$R" 'codex exec "T1 구현"')"

printf '.claude/harness/plan/legacy.md\r\n' >"$POINTER"
expect_exit "괄호 하위 호환 형식 승인 인정: src 편집 허용" 0 "$H" \
  "$(json_edit "$R" "$R/src/main.c" 'return 0' 'return 1')"
expect_exit "괄호 하위 호환 형식 승인 인정: codex exec 허용" 0 "$H" "$(json_bash "$R" 'codex exec "T1"')"

# 승인 줄이 앞 20줄 밖이면 승인으로 보지 않는다.
{
  i=0
  while [ $i -lt 25 ]; do printf '줄 %s\n' "$i"; i=$((i + 1)); done
  printf '**승인**: 승인 2026-11-16\n'
} >"$R/.claude/harness/plan/late.md"
printf '.claude/harness/plan/late.md\n' >"$POINTER"
expect_exit "승인 줄이 20줄 밖이면 미승인: src 편집 거부" 2 "$H" \
  "$(json_edit "$R" "$R/src/main.c" 'return 0' 'return 1')"
rm -f "$POINTER"

# 다른 도구는 통과
expect_exit "다른 도구(Read)는 통과" 0 "$H" \
  "$(jq -n --arg cwd "$R" --arg f "$PLAN" '{tool_name:"Read", cwd:$cwd, tool_input:{file_path:$f}}')"

finish

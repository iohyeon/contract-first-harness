#!/usr/bin/env bash
# review-gate 공용 함수. 훅(hooks/review-gate.sh)과 CLI(bin/review-gate)가 source 한다.
#
# 기록 위치: $(git rev-parse --git-dir)/review-gate/<kind>-<tree>.md
#   kind: code, query, loose
#   tree: 작업 트리 전체(추적 + 무시되지 않은 미추적)의 트리 해시.
#         임시 인덱스로 계산하므로 실제 인덱스는 바뀌지 않는다.
# 의존: bash 3.2 이상, git, grep, sed, mktemp

RG_DEFAULT_QUERY_PATTERNS='*.sql
*Mapper.xml'

# 경로를 절대 경로로 바꾸고 . 과 .. 을 정리한 뒤, 존재하는 가장 가까운
# 상위 디렉터리의 심볼릭 링크를 풀어 실제 경로로 출력한다.
# 사용: rg_canon_path <경로> <기준 디렉터리>
rg_canon_path() {
  local p="$1" base="$2" part dir rest="" n
  # 따옴표 안 ~ 는 의도한 글자 그대로의 비교다.
  # shellcheck disable=SC2088
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
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
  printf '%s%s\n' "$dir" "$rest"
}

# 경로가 가리키는(또는 가장 가까운 존재하는 상위) 디렉터리
rg_existing_dir() {
  local d="$1"
  [ -d "$d" ] || d="${d%/*}"
  while [ -n "$d" ] && [ ! -d "$d" ]; do d="${d%/*}"; done
  [ -z "$d" ] && d=/
  printf '%s\n' "$d"
}

rg_is_repo() {
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1
}

rg_toplevel() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null
}

rg_git_dir() {
  local d
  d=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  (cd "$d" 2>/dev/null && pwd -P)
}

rg_enabled() {
  [ "$(git -C "$1" config --bool review-gate.enabled 2>/dev/null)" = true ]
}

rg_record_dir() {
  local g
  g=$(rg_git_dir "$1") || return 1
  printf '%s/review-gate\n' "$g"
}

rg_record_path() {
  # 사용: rg_record_path <dir> <kind> <tree>
  local rd
  rd=$(rg_record_dir "$1") || return 1
  printf '%s/%s-%s.md\n' "$rd" "$2" "$3"
}

rg_has_record() {
  local f
  f=$(rg_record_path "$1" "$2" "$3") || return 1
  [ -s "$f" ]
}

rg_empty_tree() {
  git -C "$1" hash-object -t tree /dev/null 2>/dev/null
}

rg_head_tree() {
  git -C "$1" rev-parse -q --verify 'HEAD^{tree}' 2>/dev/null
}

# 작업 트리 전체의 트리 해시. 실제 인덱스를 복사한 임시 인덱스에
# git add -A 를 한 뒤 write-tree 한다. 실제 인덱스는 읽기만 한다.
rg_worktree_tree() {
  local top idx tmpd tree rc
  top=$(rg_toplevel "$1") || return 1
  [ -n "$top" ] || return 1
  idx=$(cd "$top" && git rev-parse --git-path index 2>/dev/null) || return 1
  case "$idx" in /*) ;; *) idx="$top/$idx" ;; esac
  tmpd=$(mktemp -d 2>/dev/null || mktemp -d -t review-gate) || return 1
  [ -f "$idx" ] && cp "$idx" "$tmpd/index"
  tree=$(
    cd "$top" &&
      GIT_INDEX_FILE="$tmpd/index" git add -A -- . >/dev/null 2>&1 &&
      GIT_INDEX_FILE="$tmpd/index" git write-tree 2>/dev/null
  )
  rc=$?
  rm -rf "$tmpd"
  [ "$rc" -eq 0 ] && [ -n "$tree" ] || return 1
  printf '%s\n' "$tree"
}

# 쿼리 판정의 기준 커밋. review-gate.base 설정, upstream, origin/HEAD 순으로
# 찾은 참조와 HEAD 의 merge-base. 없으면 빈 출력.
rg_base_commit() {
  local dir="$1" ref c
  for ref in "$(git -C "$dir" config --get review-gate.base 2>/dev/null)" '@{upstream}' 'refs/remotes/origin/HEAD'; do
    [ -n "$ref" ] || continue
    c=$(git -C "$dir" rev-parse -q --verify "$ref^{commit}" 2>/dev/null) || continue
    [ -n "$c" ] || continue
    c=$(git -C "$dir" merge-base HEAD "$c" 2>/dev/null) || continue
    if [ -n "$c" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

# 비교 기준 트리. 사용: rg_base_tree <dir> <mode>
#   mode commit: 기준 커밋이 없으면 HEAD (HEAD 도 없으면 빈 트리)
#   mode push:   기준 커밋이 없으면 HEAD 의 부모 (없으면 빈 트리)
rg_base_tree() {
  local dir="$1" mode="$2" c t
  if c=$(rg_base_commit "$dir"); then
    git -C "$dir" rev-parse "$c^{tree}" 2>/dev/null
    return
  fi
  if [ "$mode" = push ]; then
    t=$(git -C "$dir" rev-parse -q --verify 'HEAD~1^{tree}' 2>/dev/null)
  else
    t=$(rg_head_tree "$dir")
  fi
  [ -n "$t" ] || t=$(rg_empty_tree "$dir")
  printf '%s\n' "$t"
}

rg_query_patterns() {
  local p
  p=$(git -C "$1" config --get-all review-gate.query-pattern 2>/dev/null)
  if [ -n "$p" ]; then
    printf '%s\n' "$p"
  else
    printf '%s\n' "$RG_DEFAULT_QUERY_PATTERNS"
  fi
}

# 경로가 쿼리 패턴에 맞으면 0. 전체 경로, 파일명, 임의 하위 경로를 본다.
# 사용: rg_path_matches <경로> <패턴 목록(줄바꿈 구분)>
rg_path_matches() {
  local path="$1" pats="$2" pat base="${1##*/}"
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254
    case "$path" in $pat|*/$pat) return 0 ;; esac
    # shellcheck disable=SC2254
    case "$base" in $pat) return 0 ;; esac
  done <<EOF
$pats
EOF
  return 1
}

# 두 트리 사이에 바뀐 파일 중 쿼리 패턴에 맞는 것을 줄 단위로 출력
# 사용: rg_query_files <dir> <기준 트리> <대상 트리>
rg_query_files() {
  local dir="$1" from="$2" to="$3" pats f
  pats=$(rg_query_patterns "$dir")
  git -C "$dir" diff-tree -r -z --name-only --no-renames "$from" "$to" 2>/dev/null |
    while IFS= read -r -d '' f; do
      if rg_path_matches "$f" "$pats"; then printf '%s\n' "$f"; fi
    done
}

# 판정. 사용: rg_check <dir> <tree> <mode>
# 통과면 0. 거부면 1 이고 RG_MISSING(빠진 kind 목록), RG_QUERY_FILES 를 채운다.
rg_check() {
  local dir="$1" tree="$2" mode="$3" base
  RG_MISSING=""
  RG_QUERY_FILES=""
  if rg_has_record "$dir" loose "$tree"; then
    return 0
  fi
  base=$(rg_base_tree "$dir" "$mode")
  RG_QUERY_FILES=$(rg_query_files "$dir" "$base" "$tree")
  rg_has_record "$dir" code "$tree" || RG_MISSING="code"
  if [ -n "$RG_QUERY_FILES" ] && ! rg_has_record "$dir" query "$tree"; then
    RG_MISSING="${RG_MISSING:+$RG_MISSING }query"
  fi
  [ -z "$RG_MISSING" ]
}

# 기록 남기기. 사용: rg_write_record <dir> <kind> <tree> <내용>
rg_write_record() {
  local dir="$1" kind="$2" tree="$3" body="$4" rd f branch head
  rd=$(rg_record_dir "$dir") || return 1
  mkdir -p "$rd" || return 1
  f="$rd/$kind-$tree.md"
  branch=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null) || branch="(분리된 HEAD)"
  [ -n "$branch" ] || branch="(분리된 HEAD)"
  head=$(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null) || head="(커밋 없음)"
  [ -n "$head" ] || head="(커밋 없음)"
  {
    printf '## %s 기록\n\n' "$kind"
    printf -- '- 시각: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf -- '- tree: %s\n' "$tree"
    printf -- '- 브랜치: %s\n' "$branch"
    printf -- '- HEAD: %s\n\n' "$head"
    printf '%s\n\n' "$body"
  } >>"$f" || return 1
  printf '%s\n' "$f"
}

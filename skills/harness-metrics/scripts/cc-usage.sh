#!/usr/bin/env bash
# cc-usage.sh - Claude Code 세션 토큰/캐시/비용 집계
#
# 사용법:
#   cc-usage.sh                          # 현재 디렉터리 프로젝트의 모든 세션
#   cc-usage.sh /path/to/project         # 특정 프로젝트 경로
#   cc-usage.sh <슬러그>                  # <로그 루트>/<슬러그>
#   cc-usage.sh session.jsonl            # 특정 세션 파일
#   cc-usage.sh --subagents /path        # 서브에이전트 토큰까지 합산
#   cc-usage.sh --quality /path          # 요구-결과 매칭 프록시 지표 추가 출력
#   cc-usage.sh --json /path             # JSON 라인 출력
#   cc-usage.sh --all /path              # API 호출 0건 세션도 표시
#   cc-usage.sh --root <dir> ...         # 로그 루트 지정
#   cc-usage.sh --group-a id1,id2 --group-b id3,id4
#                                        # 세션 두 그룹을 나란히 비교 (A/B 판정용)
#
# 로그 루트: --root > ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects
# 세션 ID: 루트 아래 <슬러그>/<ID>.jsonl 를 찾는다. 앞부분만 줘도 하나로 정해지면 된다.
#          .jsonl 파일 경로를 그대로 줘도 된다.
# 단가 덮어쓰기 (USD / 1M tokens, 모든 모델에 적용):
#   HM_PRICE_INPUT, HM_PRICE_OUTPUT, HM_PRICE_CACHE_WRITE, HM_PRICE_CACHE_READ
#
# 의존성: bash(3.2 이상), jq, awk
set -uo pipefail

# ============================================================================
# 모델 단가 (USD / 1M tokens): input | output | cache_write_5m | cache_read
#
# 기본값은 공개 가격표의 입력/출력 단가에 캐시 배수(쓰기 1.25배, 읽기 0.1배)를
# 적용한 추정값이다. 가격은 바뀔 수 있으니 HM_PRICE_* 로 덮어쓴다.
# 표에 없는 모델은 PRICE_DEFAULT 로 계산한다.
# cache_write 는 5분 TTL 기준이다. 1시간 TTL 캐시를 많이 쓰면 과소 추정된다.
# ============================================================================
PRICE_DEFAULT="5 25 6.25 0.50"        # opus 4.5 ~ 5 계열
PRICE_SONNET4="3 15 3.75 0.30"        # sonnet 4.x
PRICE_SONNET5="2 10 2.50 0.20"        # sonnet 5
PRICE_HAIKU="1 5 1.25 0.10"           # haiku 4.5
# 모델명 -> 단가 매핑 (부분 문자열 매치, 위에서부터). env 가 있으면 항목별로 덮어쓴다.
price_for() {
  local p
  case "$1" in
    *haiku*)    p="$PRICE_HAIKU" ;;
    *sonnet-5*) p="$PRICE_SONNET5" ;;
    *sonnet*)   p="$PRICE_SONNET4" ;;
    *)          p="$PRICE_DEFAULT" ;;
  esac
  local a b c d
  IFS=" " read -r a b c d <<<"$p"
  echo "${HM_PRICE_INPUT:-$a} ${HM_PRICE_OUTPUT:-$b} ${HM_PRICE_CACHE_WRITE:-$c} ${HM_PRICE_CACHE_READ:-$d}"
}

WITH_SUB=0; QUALITY=0; AS_JSON=0; SHOW_ALL=0
GROUP_A=""; GROUP_B=""; ROOT_OPT=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --subagents) WITH_SUB=1 ;;
    --quality)   QUALITY=1 ;;
    --json)      AS_JSON=1 ;;
    --all)       SHOW_ALL=1 ;;   # API 호출 0건(빈/orphaned) 세션도 표시
    --root)      shift; ROOT_OPT="${1:-}" ;;
    --group-a)   shift; GROUP_A="${1:-}" ;;
    --group-b)   shift; GROUP_B="${1:-}" ;;
    -h|--help)   sed -n '2,/^# 의존성/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           ARGS+=("$1") ;;
  esac
  shift
done

if [ -n "$ROOT_OPT" ]; then
  PROJ_ROOT="$ROOT_OPT"
else
  PROJ_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
fi

# 경로 -> 슬러그: 영숫자 아닌 문자를 전부 '-' 로 치환 (Claude Code 규칙)
slugify() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }

# ---------------------------------------------------------------------------
# 한 jsonl 파일의 usage 를 집계해서 "in out cc cr calls models" 한 줄로 반환
#
# 한 번의 API 응답이 content block 개수만큼 여러 줄로 기록된다.
#   같은 message.id 가 반복되고, 스트리밍 도중 스냅샷이라 output_tokens 가
#   점점 커진다. 따라서 message.id 로 묶고 output_tokens 최대인 레코드만 취해야
#   중복 계상과 과소 계상을 동시에 피할 수 있다.
# models 는 호출 수가 많은 모델이 맨 앞에 온다(지배 모델).
# ---------------------------------------------------------------------------
agg_usage() {
  jq -rc 'select(.type=="assistant" and .message.usage!=null and .message.model!="<synthetic>")
          | [.message.id, .message.model,
             (.message.usage.input_tokens//0), (.message.usage.output_tokens//0),
             (.message.usage.cache_creation_input_tokens//0),
             (.message.usage.cache_read_input_tokens//0)] | @tsv' "$1" \
  | awk -F'\t' '
      { if (!($1 in seen) || $4 > o[$1]) { seen[$1]=1; m[$1]=$2; i[$1]=$3; o[$1]=$4; cc[$1]=$5; cr[$1]=$6 } }
      END {
        for (k in seen) { I+=i[k]; O+=o[k]; C+=cc[k]; R+=cr[k]; n++; mc[m[k]]++ }
        top=""; best=-1
        for (x in mc) if (mc[x] > best || (mc[x] == best && x < top)) { best=mc[x]; top=x }
        ms=top; for (x in mc) if (x != top) ms = ms","x
        printf "%d\t%d\t%d\t%d\t%d\t%s\n", I+0, O+0, C+0, R+0, n+0, (ms==""?"-":ms)
      }'
}

# 모델 + 토큰으로 비용 추정.
# 세션에 여러 모델이 섞여도 지배 모델 단가를 일괄 적용한다. 정확한 분리는 --json 후 후처리.
est_cost() {
  local model="$1" i="$2" o="$3" cc="$4" cr="$5"
  local pi po pw pr
  IFS=" " read -r pi po pw pr <<<"$(price_for "$model")"
  awk -v i="$i" -v o="$o" -v cc="$cc" -v cr="$cr" \
      -v pi="$pi" -v po="$po" -v pw="$pw" -v pr="$pr" \
      'BEGIN { printf "%.4f", (i*pi + o*po + cc*pw + cr*pr)/1000000 }'
}

hit_pct() { awk -v r="$1" -v c="$2" -v i="$3" 'BEGIN{d=r+c+i; printf "%.1f", (d>0? r*100/d : 0)}'; }

# 세션 메타: 시작시각 / 유저턴 / 도구호출
sess_meta() {
  local f="$1"
  local start turns tools
  start=$(jq -r 'select(.timestamp)|.timestamp' "$f" | head -1)
  # 실제 유저 프롬프트 = tool_result 가 아니고 isMeta 도 아닌 user 레코드
  turns=$(jq -rc 'select(.type=="user" and .toolUseResult==null and .isMeta!=true)|1' "$f" | wc -l | tr -d ' ')
  # tool_use 블록은 스트리밍 중복 기록되므로 tool_use.id 로 유니크 처리
  tools=$(jq -r 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")|.id' "$f" \
          | sort -u | wc -l | tr -d ' ')
  printf '%s\t%s\t%s\n' "${start:--}" "$turns" "$tools"
}

# 서브에이전트 집계: <세션>/subagents/agent-*.jsonl
sub_dir_for() { local f="$1"; echo "${f%.jsonl}/subagents"; }

sub_usage() {
  local d="$1"
  [ -d "$d" ] || { printf '0\t0\t0\t0\t0\t-\t0\n'; return; }
  local n=0 sf
  local tmp; tmp=$(mktemp)
  for sf in "$d"/agent-*.jsonl; do
    [ -e "$sf" ] || continue
    agg_usage "$sf" >> "$tmp"; n=$((n+1))
  done
  awk -F'\t' -v n="$n" '{I+=$1;O+=$2;C+=$3;R+=$4;K+=$5; if($6!="-"){k=split($6,a,","); for(j=1;j<=k;j++) mm[a[j]]=1}}
    END { ms=""; for(x in mm) ms=(ms==""?x:ms","x); printf "%d\t%d\t%d\t%d\t%d\t%s\t%d\n", I+0,O+0,C+0,R+0,K+0,(ms==""?"-":ms), n }' "$tmp"
  rm -f "$tmp"
}

# 모델 목록 두 개("a,b" 와 "c")를 합쳐 서로 다른 모델 수를 센다. "-" 는 무시.
model_count() { printf '%s,%s\n' "$1" "$2" | tr ',' '\n' | grep -v '^-\{0,1\}$' | sort -u | wc -l | tr -d ' '; }

# ---------------------------------------------------------------------------
# 세션 1건의 지표를 탭 한 줄로:
#   START TURNS TOOLS CALLS I O CC CR MAIN_MODEL MODELS SMODELS SN SI SO SCC SCR COST NMODELS
# ---------------------------------------------------------------------------
sess_stats() {
  local f="$1" I O CC CR CALLS MODELS START TURNS TOOLS
  local SI=0 SO=0 SCC=0 SCR=0 SCALLS=0 SMODELS="-" SN=0
  IFS=$'\t' read -r I O CC CR CALLS MODELS <<<"$(agg_usage "$f")"
  IFS=$'\t' read -r START TURNS TOOLS <<<"$(sess_meta "$f")"
  if [ "$WITH_SUB" -eq 1 ]; then
    IFS=$'\t' read -r SI SO SCC SCR SCALLS SMODELS SN <<<"$(sub_usage "$(sub_dir_for "$f")")"
    I=$((I+SI)); O=$((O+SO)); CC=$((CC+SCC)); CR=$((CR+SCR)); CALLS=$((CALLS+SCALLS))
  fi
  local MAIN_MODEL="${MODELS%%,*}"
  [ "$MAIN_MODEL" = "-" ] && MAIN_MODEL="${SMODELS%%,*}"
  local COST; COST=$(est_cost "$MAIN_MODEL" "$I" "$O" "$CC" "$CR")
  local NM; NM=$(model_count "$MODELS" "$SMODELS")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$START" "$TURNS" "$TOOLS" "$CALLS" "$I" "$O" "$CC" "$CR" "$MAIN_MODEL" "$MODELS" "$SMODELS" \
    "$SN" "$SI" "$SO" "$SCC" "$SCR" "$COST" "$NM"
}

# ---------------------------------------------------------------------------
# 품질 프록시 1건: TURNS CORR DENY INTR ERRS REDO CALLS (메인 세션 파일 기준)
#   토큰 로그는 의미를 모른다. 아래는 전부 대리 신호이며 인과가 아니다.
# ---------------------------------------------------------------------------
quality_stats() {
  local f="$1" turns corr deny intr errs redo calls
  turns=$(jq -rc 'select(.type=="user" and .toolUseResult==null and .isMeta!=true)|1' "$f" | wc -l | tr -d ' ')
  # 정정: 유저 프롬프트에 정정/부정 신호어가 들어간 수
  # 메시지 1건 = 1줄이 되도록 개행을 공백으로 치환한 뒤 매칭 (여러 줄 중복 카운트 방지)
  corr=$(jq -rc 'select(.type=="user" and .toolUseResult==null and .isMeta!=true)
                 | (if (.message.content|type)=="string" then .message.content
                    else ([.message.content[]?|select(.type=="text")|.text]|join(" ")) end)
                 | gsub("\\s+";" ")' "$f" \
         | grep -icE '아니|아냐|잘못|틀렸|다시|되돌려|롤백|취소|원복|no,|not what|actually|revert|undo|wrong|instead' || true)
  # 거부: 사용자가 도구 실행을 거절
  deny=$(grep -c '"toolDenialKind"' "$f" || true)
  # 중단: 사용자가 실행 중인 도구를 끊음
  intr=$(jq -rc 'select(.toolUseResult!=null and (.toolUseResult|type)=="object" and .toolUseResult.interrupted==true)|1' "$f" | wc -l | tr -d ' ')
  # 에러툴: is_error tool_result 개수
  errs=$(jq -rc 'select(.type=="user")|.message.content[]?|select(.type=="tool_result" and .is_error==true)|1' "$f" | wc -l | tr -d ' ')
  # 재편집: 같은 파일을 2회 이상 Edit/Write 한 파일 수 (첫 시도에 못 맞춘 신호)
  redo=$(jq -rc 'select(.toolUseResult!=null and (.toolUseResult|type)=="object" and .toolUseResult.filePath!=null)|.toolUseResult.filePath' "$f" \
         | sort | uniq -c | awk '$1>1' | wc -l | tr -d ' ')
  calls=$(jq -rc 'select(.type=="assistant" and .message.usage!=null)|.message.id' "$f" | sort -u | wc -l | tr -d ' ')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$turns" "${corr:-0}" "${deny:-0}" "$intr" "$errs" "$redo" "$calls"
}

price_note() {
  local p a b c d; p=$(price_for "default")
  IFS=" " read -r a b c d <<<"$p"
  echo "참고: 비용은 추정 단가(기본 in=$a out=$b cw=$c cr=$d USD/1M, HM_PRICE_* 로 덮어쓰기) 기준이며, 모델별 단가가 섞이면 지배 모델 단가로 일괄 계산해 정확하지 않다${MIXED_TAG:-}"
}

# 세션 ID(또는 앞부분, 또는 파일 경로) -> 세션 파일 경로
resolve_id() {
  local id="$1" hits n
  if [ -f "$id" ]; then echo "$id"; return 0; fi
  hits=$(find "$PROJ_ROOT" -mindepth 2 -maxdepth 2 -type f -name "${id}*.jsonl" 2>/dev/null | sort)
  n=$(printf '%s' "$hits" | grep -c . || true)
  if [ "$n" -eq 0 ]; then echo "세션을 찾지 못함: $id (root=$PROJ_ROOT)" >&2; return 1; fi
  if [ "$n" -gt 1 ]; then echo "세션 ID가 여러 개와 맞음: $id (더 길게 줄 것)" >&2; return 1; fi
  echo "$hits"
}

# ===========================================================================
# 그룹 비교 모드
# ===========================================================================
if [ -n "$GROUP_A" ] || [ -n "$GROUP_B" ]; then
  if [ -z "$GROUP_A" ] || [ -z "$GROUP_B" ]; then
    echo "--group-a 와 --group-b 를 함께 줘야 한다" >&2; exit 1
  fi
  MIXED_TAG=""
  # 그룹 합계: N TURNS CALLS I O CC CR COST CORR REDO
  group_totals() {
    local ids="$1" id f s
    local N=0 TT=0 TC=0 TI=0 TO=0 TCC=0 TCR=0 TCOST=0 TCORR=0 TREDO=0
    local START TURNS TOOLS CALLS I O CC CR MODELS SMODELS SN SI SO SCC SCR COST NM
    local qcorr qredo
    for id in $(printf '%s' "$ids" | tr ',' ' '); do
      f=$(resolve_id "$id") || return 1
      IFS=$'\t' read -r START TURNS TOOLS CALLS I O CC CR _ MODELS SMODELS SN SI SO SCC SCR COST NM <<<"$(sess_stats "$f")"
      IFS=$'\t' read -r _ qcorr _ _ _ qredo _ <<<"$(quality_stats "$f")"
      N=$((N+1)); TT=$((TT+TURNS)); TC=$((TC+CALLS)); TI=$((TI+I)); TO=$((TO+O))
      TCC=$((TCC+CC)); TCR=$((TCR+CR)); TCORR=$((TCORR+qcorr)); TREDO=$((TREDO+qredo))
      TCOST=$(awk -v a="$TCOST" -v b="$COST" 'BEGIN{printf "%.4f", a+b}')
      [ "${NM:-1}" -gt 1 ] && echo "MIXED" >&2
    done
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$N" "$TT" "$TC" "$TI" "$TO" "$TCC" "$TCR" "$TCOST" "$TCORR" "$TREDO"
  }
  ERRF=$(mktemp)
  RA=$(group_totals "$GROUP_A" 2>>"$ERRF") || { grep -v '^MIXED$' "$ERRF" >&2; rm -f "$ERRF"; exit 1; }
  RB=$(group_totals "$GROUP_B" 2>>"$ERRF") || { grep -v '^MIXED$' "$ERRF" >&2; rm -f "$ERRF"; exit 1; }
  grep -q '^MIXED$' "$ERRF" && MIXED_TAG=" (이번 비교에 모델 혼합 세션 있음)"
  rm -f "$ERRF"
  printf '%s\n%s\n' "$RA" "$RB" | awk -F'\t' '
    NR==1 { for (k=1;k<=NF;k++) a[k]=$k }
    NR==2 { for (k=1;k<=NF;k++) b[k]=$k }
    function ratio(x, y) { return (x+0 > 0) ? sprintf("%.2f", y/x) : "-" }
    function hit(r, c, i) { d=r+c+i; return sprintf("%.1f", (d>0 ? r*100/d : 0)) }
    function div(x, y) { return sprintf("%.2f", (y+0>0 ? x/y : 0)) }
    function row(name, x, y) { printf "%-12s %14s %14s %8s\n", name, x, y, ratio(x, y) }
    END {
      printf "%-12s %14s %14s %8s\n", "METRIC", "A", "B", "B/A"
      print "------------------------------------------------------"
      row("SESSIONS", a[1], b[1])
      row("TURNS",    a[2], b[2])
      row("CALLS",    a[3], b[3])
      row("IN",       a[4], b[4])
      row("OUT",      a[5], b[5])
      row("CACHE_W",  a[6], b[6])
      row("CACHE_R",  a[7], b[7])
      row("HIT%",     hit(a[7],a[6],a[4]), hit(b[7],b[6],b[4]))
      row("COST_USD", a[8], b[8])
      row("CORR_RATE",div(a[9],a[2]), div(b[9],b[2]))
      row("REDO",     a[10], b[10])
      row("STEPS/TURN",div(a[3],a[2]), div(b[3],b[2]))
    }'
  echo "  CORR_RATE=정정 신호어 포함 프롬프트 / TURNS, REDO=2회 이상 수정된 파일 수, STEPS/TURN=CALLS / TURNS"
  echo
  [ "$WITH_SUB" -eq 0 ] && echo "주의: --subagents 없이 집계했다. 서브에이전트 토큰이 빠져 있다."
  price_note
  exit 0
fi

# ===========================================================================
# 일반 모드: 인자를 세션 .jsonl 목록으로 전개
# ===========================================================================
[ ${#ARGS[@]} -eq 0 ] && ARGS=("$PWD")
SESSIONS=()
for a in "${ARGS[@]}"; do
  if [ -f "$a" ]; then
    SESSIONS+=("$a")
  elif [ -d "$PROJ_ROOT/$a" ]; then
    while IFS= read -r f; do SESSIONS+=("$f"); done < <(find "$PROJ_ROOT/$a" -maxdepth 1 -name '*.jsonl' | sort)
  elif [ -d "$a" ]; then
    s=$(slugify "$(cd "$a" && pwd)")
    if [ -d "$PROJ_ROOT/$s" ]; then
      while IFS= read -r f; do SESSIONS+=("$f"); done < <(find "$PROJ_ROOT/$s" -maxdepth 1 -name '*.jsonl' | sort)
    else
      echo "no transcripts for: $a (slug=$s, root=$PROJ_ROOT)" >&2
    fi
  else
    echo "not found: $a" >&2
  fi
done
[ ${#SESSIONS[@]} -eq 0 ] && { echo "집계할 세션 없음" >&2; exit 1; }

if [ "$AS_JSON" -eq 0 ]; then
  printf '%-14s %-16s %5s %5s %6s %9s %10s %12s %7s %9s %s\n' \
    SESSION START TURNS TOOLS CALLS IN OUT CACHE_R HIT% "COST_USD" MODEL
  printf '%s\n' "--------------------------------------------------------------------------------------------------------------------"
fi

T_I=0; T_O=0; T_CC=0; T_CR=0; T_CALLS=0; T_TURNS=0; T_TOOLS=0; T_SUBI=0; T_SUBO=0; T_SUBCC=0; T_SUBCR=0; T_SUBN=0
T_COST="0"; ALL_MODELS="-"; MIXED_TAG=""

for f in "${SESSIONS[@]}"; do
  IFS=$'\t' read -r START TURNS TOOLS CALLS I O CC CR MAIN_MODEL MODELS SMODELS SN SI SO SCC SCR COST NM <<<"$(sess_stats "$f")"
  HIT=$(hit_pct "$CR" "$CC" "$I")
  SID=$(basename "$f" .jsonl); SID_SHORT="${SID:0:8}"
  # 같은 세션의 orphaned 스냅샷은 파일이 따로 있어 앞 8자가 겹친다. 표시에서 구분한다.
  case "$SID" in *orphaned*) SID_SHORT="${SID:0:8}~orph" ;; esac
  if [ "$CALLS" -eq 0 ] && [ "$SHOW_ALL" -eq 0 ]; then continue; fi
  STARTS="${START:0:16}"

  if [ "$AS_JSON" -eq 1 ]; then
    jq -nc --arg s "$SID" --arg st "$START" --arg m "$MODELS" --arg sm "$SMODELS" \
      --argjson t "$TURNS" --argjson tl "$TOOLS" --argjson c "$CALLS" \
      --argjson i "$I" --argjson o "$O" --argjson cc "$CC" --argjson cr "$CR" \
      --argjson hit "$HIT" --argjson cost "$COST" --argjson sn "${SN:-0}" \
      --argjson si "${SI:-0}" --argjson so "${SO:-0}" --argjson scc "${SCC:-0}" --argjson scr "${SCR:-0}" \
      '{session:$s,start:$st,models:$m,turns:$t,tool_calls:$tl,api_calls:$c,
        input:$i,output:$o,cache_create:$cc,cache_read:$cr,cache_hit_pct:$hit,est_cost_usd:$cost,
        subagents:{count:$sn,models:$sm,input:$si,output:$so,cache_create:$scc,cache_read:$scr}}'
  else
    printf '%-14s %-16s %5s %5s %6s %9s %10s %12s %7s %9s %s\n' \
      "$SID_SHORT" "$STARTS" "$TURNS" "$TOOLS" "$CALLS" "$I" "$O" "$CR" "$HIT" "$COST" "$MAIN_MODEL"
  fi

  T_I=$((T_I+I)); T_O=$((T_O+O)); T_CC=$((T_CC+CC)); T_CR=$((T_CR+CR))
  T_CALLS=$((T_CALLS+CALLS)); T_TURNS=$((T_TURNS+TURNS)); T_TOOLS=$((T_TOOLS+TOOLS))
  T_SUBI=$((T_SUBI+SI)); T_SUBO=$((T_SUBO+SO)); T_SUBCC=$((T_SUBCC+SCC)); T_SUBCR=$((T_SUBCR+SCR)); T_SUBN=$((T_SUBN+SN))
  T_COST=$(awk -v a="$T_COST" -v b="$COST" 'BEGIN{printf "%.4f", a+b}')
  [ "${NM:-1}" -gt 1 ] && MIXED_TAG=" (모델 혼합 세션 있음)"
  ALL_MODELS="$ALL_MODELS,$MODELS,$SMODELS"
done

[ "$(model_count "$ALL_MODELS" "-")" -gt 1 ] && [ -z "$MIXED_TAG" ] && MIXED_TAG=" (세션마다 모델이 다름)"

if [ "$AS_JSON" -eq 0 ]; then
  T_HIT=$(hit_pct "$T_CR" "$T_CC" "$T_I")
  printf '%s\n' "--------------------------------------------------------------------------------------------------------------------"
  printf '%-14s %-16s %5s %5s %6s %9s %10s %12s %7s %9s %s\n' \
    TOTAL "" "$T_TURNS" "$T_TOOLS" "$T_CALLS" "$T_I" "$T_O" "$T_CR" "$T_HIT" "$T_COST" "(세션 합)"
  echo
  echo "cache_create=$T_CC  |  billable_total=$((T_I+T_O+T_CC+T_CR))  |  턴당 출력토큰=$(awk -v o=$T_O -v t=$T_TURNS 'BEGIN{printf "%.0f", (t>0?o/t:0)}')"
  [ "$WITH_SUB" -eq 1 ] && echo "서브에이전트: ${T_SUBN}개  in=$T_SUBI out=$T_SUBO cc=$T_SUBCC cr=$T_SUBCR  (위 합계에 포함됨)"
fi

# ---------------------------------------------------------------------------
# --quality: "입출력이 요구와 얼마나 매칭되는가"의 프록시 지표
# ---------------------------------------------------------------------------
if [ "$QUALITY" -eq 1 ] && [ "$AS_JSON" -eq 0 ]; then
  echo
  echo "== 요구-결과 매칭 프록시 지표 =="
  printf '%-14s %6s %6s %6s %6s %7s %7s %8s\n' SESSION TURNS 정정 거부 중단 에러툴 재편집 스텝/턴
  for f in "${SESSIONS[@]}"; do
    SID=$(basename "$f" .jsonl)
    IFS=$'\t' read -r turns corr deny intr errs redo calls <<<"$(quality_stats "$f")"
    spt=$(awk -v c="$calls" -v t="$turns" 'BEGIN{printf "%.1f", (t>0?c/t:0)}')
    printf '%-14s %6s %6s %6s %6s %7s %7s %8s\n' "${SID:0:8}" "$turns" "$corr" "$deny" "$intr" "$errs" "$redo" "$spt"
  done
  echo "  정정=유저 프롬프트 중 정정/부정 신호어 포함 수, 거부=권한 거절, 중단=도구 인터럽트,"
  echo "  에러툴=is_error tool_result, 재편집=2회 이상 수정된 파일 수, 스텝/턴=유저 1턴당 API 호출 수"
fi

[ "$AS_JSON" -eq 0 ] && { echo; price_note; }
exit 0

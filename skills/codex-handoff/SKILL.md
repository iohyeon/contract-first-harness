---
name: codex-handoff
description: 승인된 플랜 파일을 Codex(codex exec)에 넘겨 구현시키고 결과를 Claude로 회수한다. plan-verify 통과와 사람 승인 직후, plan-execute 대신 Codex에 구현을 맡길 때 사용한다. 착수 시 .claude/harness/active-plan 포인터를 쓰고 완료 시 지운다. 자동화 배관을 만들지 않고 Bash로 codex exec 한 줄을 실행한 뒤 파일과 git diff로만 회수한다. 회수 후 검증은 drift-watch와 final-verify가 담당하며 이 스킬은 넘기고 받는 일만 한다.
user-invocable: true
---

# codex-handoff

Claude는 말하고 판단하고, Codex는 코드를 친다.
**자동화 배관을 만들지 않는다.** Claude가 `codex exec` 한 줄을 Bash로 실행하고, 결과는 파일과 `git diff`로 회수한다.

## 언제 쓰는가

- `plan-verify`가 `✅ 승인 요청`을 냈고 사람이 승인 줄을 바꾼 직후
- 그 구현을 `plan-execute`(Claude가 직접 침) 대신 Codex에 넘길 때

쓰지 않는 경우: 플랜이 없다, 승인이 없다, 사람 승인 게이트를 구현 도중에 또 걸어야 한다.
**`codex exec`는 `approval: never` 고정이다.** 승인 게이트를 Codex 쪽에 둘 수 없으므로, 도중 승인이 필요한 작업은 넘기지 않는다.

## 사전 조건 체크

다섯 다 통과해야 실행한다. 하나라도 실패하면 멈추고 사용자에게 보고한다.

| # | 확인 | 실패 시 |
|---|---|---|
| 1 | 대상 레포 cwd에 `AGENTS.md`가 있는가 | `resources/AGENTS.md.template`을 복사해 레포별 명령을 채우자고 제안하고 멈춘다. 이 스킬이 임의로 만들지 않는다 |
| 2 | 플랜 앞 20줄 안의 승인 줄이 `^\*\*승인\*\*:[[:space:]]*승인[[:space:]]*\(?[0-9]{4}-[0-9]{2}-[0-9]{2}` (ERE) 에 매칭되는가. **Read 도구로** 확인한다. `미승인`이거나 마커가 없으면 실패다. AI가 이 줄을 바꾸지 않는다 | 승인을 요청하고 멈춘다 |
| 3 | `git status --short -- . ':!.claude/harness'` 가 비어 있는가 | 지저분하면 회수 시 `git diff`로 Codex의 변경을 분리할 수 없다. 정리를 요청하고 멈춘다. `.claude/harness/` 아래 플랜과 리포트는 제외하고 본다 |
| 4 | 남은 `- [ ]` 태스크가 있는가 | 없으면 넘길 일이 없다. `final-verify`로 보낸다 |
| 5 | 오늘 날짜의 `.claude/harness/report/preflight-<slug>-<YYYYMMDD>.md`가 있고 `❌ 착수 불가`가 아닌가 | `env-preflight`를 먼저 호출한다. Codex는 환경 문제를 만나도 묻지 않고 우회하려 든다 |

승인 줄을 Bash로 `grep`하지 않는 이유: Bash 명령에 `.claude/harness/plan/` 경로와 `승인`이 함께 들어가면 approval-gate 훅이 마커 조작 시도로 보고 거부한다. 같은 이유로 아래 `codex exec` 프롬프트에도 `승인`이라는 단어를 넣지 않는다.

Codex는 `AGENTS.md`만 읽는다. `.claude/` 디렉터리와 `.claude/skills/`는 전혀 보지 않는다.
`CLAUDE.md`도 기본으로는 읽지 않는다(`project_doc_fallback_filenames=["CLAUDE.md"]` 설정 시 폴백 가능하나, `AGENTS.md`가 있으면 그쪽이 이긴다).
그래서 조건 1이 필수다. 플랜 본문은 아래 프롬프트에서 경로로 읽히므로 `AGENTS.md`에 중복해 넣지 않는다.

## 실행 포인터

사전 조건이 통과하면 `codex exec` 전에 `.claude/harness/active-plan` 에 저장소 루트 기준 플랜 경로 한 줄을 Write 도구로 쓴다(예: `.claude/harness/plan/order-cancel.md`). 이미 다른 플랜을 가리키고 있으면 덮어쓰지 않고 묻는다.

**approval-gate 훅이 이 포인터를 강제한다.** `active-plan`이 가리키는 플랜이 승인 상태가 아니면 훅은 Bash의 `codex exec`와 `.claude/harness/` 밖 파일 편집을 거부한다. 거부되면 포인터를 지워 우회하지 않고 재승인을 요청한다.

Codex 프로세스 안의 편집은 Claude Code 훅을 거치지 않는다. 그래서 `AGENTS.md`에 "승인 줄과 플랜 본문을 고치지 않는다"를 반드시 넣고(템플릿에 들어 있다), 회수 단계에서 승인 줄이 그대로인지 Read로 확인한다.

## 실행

먼저 `.claude/harness/report/` 디렉터리가 없으면 만든다. 경로는 전부 절대경로로 쓴다. 출력 파일 이름은 `codex-<slug>-<태스크ID>.md`다. 여러 태스크를 한 번에 넘기면 첫 태스크와 마지막 태스크 ID를 하이픈으로 잇는다(예: `codex-order-cancel-I1-I3.md`).

```bash
codex exec \
  -C /절대/경로/레포 \
  -s workspace-write \
  -o /절대/경로/레포/.claude/harness/report/codex-<slug>-<태스크ID>.md \
  "$(cat <<'PROMPT'
/절대/경로/레포/.claude/harness/plan/<slug>.md 를 읽어라. 이 파일이 실행 명세다.
AGENTS.md의 규약과 정지 조건을 따른다.

대상 태스크: T1, T2, T3
이 태스크들을 위에 적힌 순서대로 하나씩 순차로 실행한다. 동시에 진행하지 않는다.
각 태스크의 건드리는 파일만 고치고, 수정 금지 칸의 경로는 건드리지 않는다.
태스크 하나가 끝날 때마다 플랜의 검증 명령을 실행하고, 체크박스를 - [x] 로 바꾸고,
플랜 하단 ## 실행 로그 에 한 줄을 추가한 뒤 다음 태스크로 간다.

정지 조건에 걸리면 그 자리에서 멈춘다. 우회로를 찾지 않는다.
멈춘 태스크는 - [!] 로 표시하고 실행 로그에 사유와 근거를 남긴다.
마지막 메시지에 완료한 태스크, 멈춘 태스크와 사유, 변경한 파일 목록을 적는다.
PROMPT
)" < /dev/null
```

**`< /dev/null`은 빼면 안 된다.** stdin이 tty가 아니면 `codex exec`가 그대로 멈춘다.
`-s workspace-write`도 필수다. `codex exec`의 기본값은 read-only라 파일을 못 고친다.

Claude Code 설정에 `Bash(codex exec:*)` 허용이 없으면 매번 권한 프롬프트가 뜬다.
필요하면 사용자가 직접 추가한다. 이 스킬은 설정 파일을 고치지 않는다.

## 회수

**Claude는 Codex의 대화 기록을 읽지 않는다. 아래 파일 3개만 본다.**

1. **플랜 파일**: 체크박스가 `[x]`로 바뀐 태스크, `[!]`로 남은 태스크, `## 실행 로그`의 각 줄. 승인 줄과 본문이 그대로인지도 본다
2. **`git status --short`와 `git diff`**: 실제로 무엇이 바뀌었는가. 실행 로그가 주장하는 변경 파일과 대조하고, 각 태스크의 `수정 금지` 경로가 diff에 있는지 대조한다
3. **`-o`로 받은 최종 메시지**: `.claude/harness/report/codex-<slug>-<태스크ID>.md`

셋이 어긋나면 그 사실 자체가 보고 대상이다. 실행 로그에 없는 파일이 diff에 있거나,
`[x]`인데 diff가 비어 있거나, 수정 금지 경로가 diff에 있거나, 승인 줄이나 플랜 본문이 바뀌었으면 회수 단계에서 멈추고 사용자에게 묻는다.

회수 요약은 Claude가 직접 작성한다. Codex 최종 메시지를 그대로 옮기지 않는다.

## 회수 후

이번에 넘긴 태스크가 하나였고 플랜에 남은 태스크가 있으면 `drift-watch`로 넘긴다.
여러 태스크를 한 번에 넘겼거나 플랜의 태스크가 전부 끝났으면 `drift-watch`의 스킵 조건(변경 파일 3개 초과, 구현이 전부 끝난 뒤)에 걸리므로 바로 `final-verify`로 넘긴다.

플랜의 태스크가 전부 `[x]`면 `.claude/harness/active-plan`을 지운다(`rm .claude/harness/active-plan`). 남은 태스크가 있거나 `[!]`로 멈췄으면 지우지 않는다. 재개 지점이다.

**Codex가 자기 작업을 자기가 검증하지 않는다는 것이 이 구조의 실제 이득이다.**
같은 모델이 구현과 검증을 다 하면 자기가 세운 전제를 그대로 통과시킨다. 여기서는 구현자와 검증자가 다른 프로세스다.

## 중단 시 재개

세션이 끊겼거나 태스크가 남았으면 새로 넘기지 말고 이어간다.

```bash
codex exec resume --last "남은 태스크 T4부터 이어서 하라. 앞서와 같은 규칙을 지킨다." < /dev/null
```

`resume`이 실패하거나 세션이 사라졌으면, 플랜 파일의 `[x]` 상태를 진실로 보고 남은 태스크만 새 `codex exec`로 넘긴다.
대화 기록을 복원하려 하지 않는다. 재개 전에 승인 줄을 다시 Read로 확인한다.

## 병렬

**플랜의 병렬 표시를 프롬프트에 그대로 넘기지 마라.** Codex 서브에이전트 동작은 검증되지 않았다.
프롬프트에는 항상 순차 실행을 명시한다.

병렬이 필요하면 Claude가 플랜을 쪼개서 `codex exec`를 여러 번 부른다. 조건은 하나다.
**호출 간 파일 경계가 전혀 겹치지 않을 때만.** 플랜의 태스크 표에서 건드리는 파일과 수정 금지를 대조해 확인한다.
겹치면 순차로 내린다. 겹침을 발견한 사실은 보고에 남긴다.

여러 호출이 같은 플랜 파일의 체크박스를 동시에 쓰면 Single Writer가 깨진다. 병렬 호출에서는 프롬프트에서 체크박스와 실행 로그 갱신을 빼고, 회수 후 Claude가 한 번에 갱신한다.

각 호출의 `-o` 파일 이름은 다르게 준다. 같은 파일로 주면 서로 덮어쓴다.

## 하지 않는 것

- 커밋과 푸시. 프롬프트에도 금지를 넣고 `AGENTS.md`에도 넣는다
- 플랜 본문과 승인 줄 수정. 체크박스와 실행 로그만 갱신 대상이다
- Codex 결과를 검증 없이 통과 처리하는 것

## Completion Criteria

- 사전 조건 5개를 전부 확인한 기록이 있다
- 착수 시 `active-plan`을 썼고, 플랜이 전부 끝났으면 지웠다
- 프롬프트에 순차 실행, 수정 금지, 정지 조건이 명시돼 있다
- 회수 시 파일 3개를 전부 확인했고 서로 어긋나지 않는다
- 다음 단계로 `drift-watch` 또는 `final-verify` 중 하나를 지목하고 멈췄다

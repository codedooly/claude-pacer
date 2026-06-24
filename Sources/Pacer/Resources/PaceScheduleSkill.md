---
name: "pace-schedule"
description: "Pacer 의 5시간 윈도우 워밍 클라우드 routine 관리 — RemoteTrigger 로 register/disable/enable/status. ARGUMENTS 로 동작과 핑 시각을 받는다. 매일 지정 시각(KST)에 클라우드 Claude 가 keep-alive 핑 1건을 날려 5h usage window 를 워밍한다. \"페이스 스케줄\", \"루틴 등록/해제\" 요청에 사용."
---

Pacer 의 워밍 routine(`pace-window-warm`)을 `RemoteTrigger`(claude.ai code triggers API)로 관리한다.
**Pacer 앱이 `claude -p "/pace-schedule <action> [times]"` 로 호출**하므로, 사람 보고 외에 **기계 파싱용 결과 줄을 반드시 마지막에 출력**한다.

> 클라우드 routine 이라 로컬 맥이 꺼져 있어도 Anthropic 클라우드에서 발화한다. (로컬 `CronCreate` 와 다름.)

## ARGUMENTS 파싱

`ARGUMENTS` 의 첫 토큰 = **action**, 둘째 토큰(있으면) = **핑 시각 CSV**.

| action | 의미 |
|--------|------|
| `register <HH:MM,HH:MM,...>` | routine 생성/갱신 (기본). times 없으면 `08:00,13:00,18:00` |
| `disable` | routine 비활성 (`enabled=false`) |
| `enable` | routine 재활성 (`enabled=true`) |
| `status` | 현황 조회 |

action 이 비어 있으면 `register`(times `08:00,13:00,18:00`) 로 간주.

## 0. 도구 로드

```
ToolSearch select:RemoteTrigger
```
auth 는 in-process — curl 쓰지 말 것.

## 1. 기존 routine 찾기

`RemoteTrigger {action: "list"}` → `name == "pace-window-warm"` 항목의 `id` 를 확보(= `<tid>`). 없으면 미등록 상태.

## 2. cron 변환 (KST → UTC)

핑 시각은 KST. cron 은 **UTC**. 각 시각의 시 `h` → UTC 시 = `(h + 15) % 24`. 분은 `0`.

| 의도(KST) | UTC 시 |
|-----------|--------|
| 08:00 | 23 |
| 13:00 | 4 |
| 18:00 | 9 |

→ `cron_expression: "0 <UTC시들 콤마구분> * * *"` (예: `"0 23,4,9 * * *"`)
> routine 최소 간격 1시간 — 정상. 분은 워밍 목적상 무의미하므로 `0`.

## 3. action 처리

### register
- cron 을 위 규칙으로 만든다.
- `<tid>` 있으면 → `{action:"update", trigger_id:"<tid>", body:{cron_expression:"<cron>", enabled:true, job_config:<아래 ccr>}}`
- 없으면 → `{action:"create", body:<아래 create 템플릿>}`
> **중요**: register 는 **항상 `enabled: true` 로 update** 한다. cron 이 이미 같더라도 routine 이 비활성(disabled) 상태였을 수 있으므로 반드시 다시 활성화한다. "이미 일치하니 변경 없음" 으로 건너뛰지 말 것.

### disable
- `<tid>` 있으면 → `{action:"update", trigger_id:"<tid>", body:{enabled:false}}`
- 없으면 → 미등록 보고만.

### enable
- `<tid>` 있으면 → `{action:"update", trigger_id:"<tid>", body:{enabled:true}}`

### status
- `<tid>` 있으면 → `{action:"get", trigger_id:"<tid>"}` 로 현황.
- 없으면 → 미등록 보고.

## create 템플릿

`uuidgen | tr '[:upper:]' '[:lower:]'` 로 lowercase v4 UUID 1개 생성 후:

```json
{
  "name": "pace-window-warm",
  "cron_expression": "<cron>",
  "enabled": true,
  "job_config": {
    "ccr": {
      "environment_id": "<env>",
      "session_context": { "model": "claude-haiku-4-5", "allowed_tools": [] },
      "events": [
        { "data": {
            "uuid": "<생성한 uuid>",
            "session_id": "",
            "type": "user",
            "parent_tool_use_id": null,
            "message": { "role": "user", "content": "예약된 keep-alive 핑입니다. 5시간 사용량 창을 새로 여는 것이 유일한 목적입니다. 어떤 작업도, 도구 호출도, 파일 읽기도 하지 마세요. 정확히 한 단어로만 답하세요: ok\n\nScheduled keep-alive ping. Its sole purpose is to initialize a fresh 5-hour usage window. Do not perform any task, call any tool, or read any files. Reply with exactly one word and nothing else: ok" }
        } }
      ]
    }
  }
}
```

> `environment_id` 가 계정에서 다르면 list/get 응답의 값을 재사용한다. `allowed_tools: []` 로 보내도 서버가 기본셋을 채우지만 프롬프트가 "도구 쓰지 말라"라 무해.

## 4. 결과 출력 — Pacer 파싱용 (필수)

사람용 보고 1줄 뒤, **마지막 줄에 정확히 이 형식**으로 출력한다 (Pacer 가 grep `PACE_RESULT`):

```
PACE_RESULT {"action":"<action>","ok":true,"id":"<trigger_id 또는 빈칸>","enabled":<true|false>,"next_run_at":"<UTC ISO 또는 빈칸>","cron":"<cron 또는 빈칸>"}
```

- 실패하거나 미등록이면 `"ok":false` 로.
- `disable`/`enable`/`register`/`status` 모두 이 줄을 낸다.

## 참고 — 스케줄러 종류

| 도구 | 정체 | 맥 꺼져도 발화? |
|------|------|----------------|
| `RemoteTrigger` (이 스킬) | 클라우드 routine | ✅ |
| `CronCreate` | 로컬 세션 cron | ❌ (REPL idle 시 · 세션 종료 시 소멸) |

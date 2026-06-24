---
name: "pace-schedule"
description: "Pacer 의 5시간 윈도우 워밍 클라우드 routine 관리 — RemoteTrigger 로 register/disable/enable/status. ARGUMENTS 로 동작과 핑 시각을 받는다. 매일 지정 시각(KST)에 클라우드 Claude 가 keep-alive 핑 1건을 날려 5h usage window 를 워밍한다. \"페이스 스케줄\", \"루틴 등록/해제\" 요청에 사용."
---

Pacer 의 워밍 routine(`pace-window-warm`)을 `RemoteTrigger`(claude.ai code triggers API)로 관리한다.
**Pacer 앱이 `claude -p "/pace-schedule <action> [times]"` 로 호출**하므로, 사람 보고 외에 **기계 파싱용 결과 줄을 반드시 마지막에 출력**한다.

> 클라우드 routine 이라 로컬 맥이 꺼져 있어도 Anthropic 클라우드에서 발화한다. (로컬 `CronCreate` 와 다름.)

## ARGUMENTS 파싱

`ARGUMENTS` 의 첫 토큰 = **action**, 둘째 토큰(있으면) = **핑 시각 CSV**, 셋째 토큰(있으면) = **env_id**(선택).

| 토큰 | 의미 |
|------|------|
| 1번 = action | `register` / `disable` / `enable` / `status` |
| 2번 = 핑 시각 CSV | `register` 시 `08:00,13:00,18:00` 형식. 없으면 기본값 |
| 3번 = env_id | (선택) 사용자가 `/schedule` 에서 복사한 환경ID. 있으면 환경 자동탐지보다 **최우선** 사용 |

| action | 의미 |
|--------|------|
| `register <HH:MM,HH:MM,...> [env_id]` | routine 생성/갱신 (기본). times 없으면 `08:00,13:00,18:00`. env_id 있으면 그 환경에 등록 |
| `disable` | routine 비활성 (`enabled=false`) |
| `enable` | routine 재활성 (`enabled=true`) |
| `status` | 현황 조회 |

action 이 비어 있으면 `register`(times `08:00,13:00,18:00`) 로 간주.

## 0. 도구 로드

```
ToolSearch select:RemoteTrigger
```
auth 는 in-process — curl 쓰지 말 것.

## 1. 기존 routine 찾기 + 환경ID 확보 (중요)

먼저 **3번째 인자 env_id 가 넘어왔는지** 확인한 뒤, `RemoteTrigger {action: "list"}` 를 호출한다. `<env>` 결정 우선순위:

1. **3번째 인자 env_id 가 있으면 → 그 값을 `<env>` 로 최우선 사용** (자동탐지 건너뜀). 단, list 응답에 `name == "pace-window-warm"` 항목이 있으면 그 `id` 는 여전히 `<tid>` 로 잡아 update 에 쓴다.
2. 없으면 list 응답에서 추출:
   - `name == "pace-window-warm"` 항목이 있으면 → 그 `id` = `<tid>`, 그 `job_config.ccr.environment_id` = `<env>`.
   - 없지만 **다른 trigger 가 하나라도 있으면** → 첫 항목의 `job_config.ccr.environment_id` 를 `<env>` 로 쓴다 (= 이 계정의 클라우드 환경).
3. 그래도 못 찾으면(3번째 인자도 없고 **trigger 가 하나도 없음**) → `<env>` 를 알 수 없다. register 를 **중단**하고 4번 형식으로 `"ok":false, "reason":"no_env"` 출력. 환경ID 를 추측·하드코딩하지 말 것.

> `<env>` 는 **반드시 이 list 응답에서 얻은 본인 계정 값**이어야 한다. 예시·타인 ID 를 쓰면 등록이 실패하거나 엉뚱한 환경을 가리킨다.

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
      "session_context": { "model": "claude-haiku-4-5-20251001", "allowed_tools": [] },
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

> `environment_id` 는 **1번에서 list 로 확보한 `<env>`** 를 그대로 넣는다 (계정마다 다름 — 하드코딩 금지). `allowed_tools: []` 로 보내도 서버가 기본셋을 채우지만 프롬프트가 "도구 쓰지 말라"라 무해.

## 4. 결과 출력 — Pacer 파싱용 (필수)

사람용 보고 1줄 뒤, **마지막 줄에 정확히 이 형식**으로 출력한다 (Pacer 가 grep `PACE_RESULT`):

```
PACE_RESULT {"action":"<action>","ok":true,"id":"<trigger_id 또는 빈칸>","enabled":<true|false>,"next_run_at":"<UTC ISO 또는 빈칸>","cron":"<cron 또는 빈칸>","reason":"<빈칸 또는 no_env 등>"}
```

- 실패·미등록이면 `"ok":false`. 환경ID 를 못 찾은 경우(trigger 0개) `"reason":"no_env"` 포함 — 앱이 "클라우드 환경을 먼저 설정하세요" 안내에 사용한다.
- `disable`/`enable`/`register`/`status` 모두 이 줄을 낸다.

## 참고 — 스케줄러 종류

| 도구 | 정체 | 맥 꺼져도 발화? |
|------|------|----------------|
| `RemoteTrigger` (이 스킬) | 클라우드 routine | ✅ |
| `CronCreate` | 로컬 세션 cron | ❌ (REPL idle 시 · 세션 종료 시 소멸) |

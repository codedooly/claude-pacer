# Cloud 모드 — 설정 & 문제해결

> Cloud(Routine) 모드는 **Anthropic 클라우드**에서 핑을 발사하므로 맥이 꺼져 있어도 됩니다. 이 문서는 설정 방법과 "왜 등록이 안 되지?" 케이스를 다룹니다. **대부분은 에러를 안 봐요** — Pacer 가 다 자동 감지하거든요. 안 될 때를 위한 문서입니다.
>
> 한 줄 요약: **막히면 99%는 "클라우드 환경(environment) 부재"** 이고, Pacer 가 `/schedule` 로 자동 조회하지만 그래도 없으면 **claude.ai/code 에서 환경을 한 번 만들면** 됩니다.
>
> 🇺🇸 English → [cloud-setup.en.md](cloud-setup.en.md)

---

## 동작 방식

**Cloud** 를 고르고 **적용**을 누르면, Pacer 가 클라우드 트리거 API 로 Claude 루틴(`pace-window-warm`)을 등록합니다. 번들 내장 지침을 `claude -p` 로 실행하는 방식이라(글로벌 스킬 설치 없음), 등록된 루틴은 매일 핑 시각에 한 단어 `ok` keep-alive 를 발사해 **맥이 잠들어 있어도** 새 5시간 창을 엽니다.

등록하려면 클라우드가 **어느 환경**에서 루틴을 돌릴지(`environment_id`)를 알아야 합니다. Pacer 가 자동으로 구합니다:

1. **기존 루틴 있음** → 그 `environment_id` 재사용 (즉시).
2. **루틴 없음** → Pacer 가 `/schedule` 로 계정의 *Available environments* 를 읽어 첫 환경 사용.
3. **환경 자체가 없음** → [claude.ai/code](https://claude.ai/code) 에서 한 번 생성한 뒤 다시 시도.

`environment_id` 는 **계정마다 다르고 추측·하드코딩 불가**합니다 — 그래서 완전 신규 계정은 웹 1회가 필요해요.

---

## 문제해결

| 증상 | 원인 | 해결 |
|------|------|------|
| 적용 후에도 **"클라우드 환경이 없습니다" / no_env** 반복 | 계정에 **클라우드 환경 미프로비저닝** (자동탐지가 아무것도 못 찾음) | **claude.ai/code 열기** → 로그인·셋업 → 환경 생성됨 → Pacer 로 돌아와 **다시 적용** |
| **"웹 열기" 시 인증·셋업 프롬프트** (어떤 팀원은 바로 열림) | 그 계정이 웹 셋업을 안 해 환경이 아직 없음 | 위와 동일 — 웹 셋업 1회 완료 = 환경 생성 단계 |
| 에러 팝업에 **404 `not_found_error` · `model: claude-...`** | **Claude Code CLI 가 구버전** — 모델 alias 가 은퇴 스냅샷으로 풀림 | Claude Code 업데이트 (`claude` 자체 갱신 또는 재설치). Pacer 가 현재 모델을 고정하지만 아주 오래된 CLI 는 여전히 걸릴 수 있음 |
| 첫 실행에 **사용량 0% / "갱신 실패"** | Keychain 토큰 stale (이 맥에서 Claude Code 를 최근 실행 안 함) | 터미널에서 **`claude`** 한 번 실행(토큰 갱신) → Pacer **새로고침** |
| 그 외 **등록 실패** 에러 | 에러 팝업이 실제 메시지를 보여줌 | 읽어보고 — 인증/로그인 관련이면 `claude` 실행, 네트워크면 VPN·`api.anthropic.com` 확인 |

---

## 수동 환경ID (고급)

자동탐지가 환경을 못 찾는데 존재하는 건 안다면, 직접 붙여넣을 수 있습니다:

1. 터미널 → `claude` → `/schedule` 입력.
2. **Available environments** 목록에서 `env_...` id 복사.
3. Pacer(Cloud, no_env 화면)에서 **`env_...`** 칸에 붙여넣고 → **적용**.

Pacer 가 저장하므로 한 번만 하면 됩니다.

---

## 참고

- **루틴 삭제는 웹에서만** — Pacer 는 삭제 못 함. [claude.ai/code/routines](https://claude.ai/code/routines).
- 루틴은 **claude.ai/code 셋업 여부와 무관하게 발화**합니다 — 웹 셋업은 브라우저에서 루틴을 보기/관리하는 용도일 뿐, 실행 여부와 별개.
- Cloud Pace log 는 **근사치**(usage `resets_at` 역산)입니다. Local 모드는 핑을 정확히 기록.
- Cloud 루틴은 **주말·공휴일 스킵 불가**(cron 한계) — 그게 중요하면 Local 모드.

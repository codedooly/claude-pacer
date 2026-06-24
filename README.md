<div align="center">

**🇰🇷 한국어** · [🇺🇸 English](README.en.md)

<img src="assets/hero.png" width="300" alt="Pacer" />

# Pacer

### Claude 사용량의 페이스를 잡아주는 macOS 메뉴바 앱

*한도 안에서 리듬을 유지하세요* — Claude Pro / Max 용

![platform](https://img.shields.io/badge/platform-macOS%2014+-1c1c1e?style=flat-square)
&nbsp;![license](https://img.shields.io/badge/license-MIT-7C3AED?style=flat-square)
&nbsp;![swift](https://img.shields.io/badge/Swift-SwiftUI-orange?style=flat-square)

</div>

---

## ⚡ 빠른 설치

**터미널 한 줄로 설치하세요.** 미서명 앱이라 브라우저로 받은 `.dmg` 는 macOS 보안(Gatekeeper)에 막힙니다 — curl 로 받으면 격리가 안 붙어 다운로드부터 `/Applications` 설치까지 한 번에 됩니다:

```sh
curl -fsSL https://github.com/codedooly/claude-pacer/releases/latest/download/Pacer.dmg -o /tmp/Pacer.dmg \
  && hdiutil attach -nobrowse -quiet /tmp/Pacer.dmg \
  && cp -R "/Volumes/Pacer/Pacer.app" /Applications/ \
  && hdiutil detach -quiet "/Volumes/Pacer" \
  && echo "✓ /Applications/Pacer.app — Launchpad 에서 실행"
```

> 실행하려면 [Claude Code](https://claude.com/claude-code) 설치·로그인이 먼저입니다 → 아래 [요구사항](#요구사항) · 소스에서 빌드하려면 → [설치](#설치)

---

## 요구사항

Pacer 는 **Claude Code CLI** 위에서 동작합니다 — 설치해 쓰는 사용자에게 **Xcode 는 필요 없습니다.**

| 구분 | 필요한 것 |
|------|----------|
| **실행** (dmg 설치) | macOS 14+ · [Claude Code](https://claude.com/claude-code) 설치·로그인 · Claude Pro / Max 구독 |
| **빌드** (소스에서) | 위 + 정식 Xcode · `xcodegen` · `create-dmg` (Homebrew) |

> Claude Code 가 사용량 토큰(Keychain)·핑 발사·Cloud routine 등록을 담당하므로 **필수**입니다. 토큰이 없으면 앱이 온보딩 화면을 띄웁니다. (Claude Code 자체는 Node.js 기반)

---

## Claude 의 5시간 한도, **언제부터** 카운트되는지 아세요?

> 저도 몇 달을 썼지만, 이번에 처음 알았습니다.

많은 분들이 **"5시간마다 자동으로 도는 크레딧"** 으로 압니다. **아닙니다.**

- 5시간 창은 **당신이 첫 메시지를 보낸 순간** 시작됩니다.
- 그 5시간이 지난 뒤 Claude 를 안 쓰면 → 창은 **대기 상태로 잠듭니다.**
- 다음 첫 메시지(또는 핑)를 보내기 전까지, **카운트다운은 시작조차 안 합니다.**

즉, **언제 시작하느냐**에 따라 하루에 쓸 수 있는 *신선한 5시간 창*의 수가 달라집니다.

### 그래서 핑이 필요합니다

9시에 출근해 바로 시작하면 — 창은 `09:00–14:00`. 오후에 몰아 쓰면 14시 직후 한도에 걸리기 쉽죠.
하지만 **08·13·18시에 핑을 맞춰두면**, 각 시각마다 자동으로 새 창이 열려 **점심 후·저녁마다 신선한 5시간**으로 출발합니다.

<div align="center">
  <img src="assets/why-ping.svg" width="820" alt="핑 없이 = 하루 1창, 지친 페이서 / 핑 정렬 = 코어 시간마다 신선한 3창" />
</div>

> **주간 총량은 그대로입니다.** Pacer 가 늘려주는 게 아니에요 — **5시간 흐름을 당신의 코어 작업 시간에 정렬**해, *같은 양을 더 잘 쓰게* 할 뿐입니다.

---

## 한눈에

|  |  |
|---|---|
| **사용량 게이지** | 5시간 · 7일 한도를 도넛 게이지로 — 리셋 카운트다운(시계 아이콘) + `Plan: Max (5x)` 배지 |
| **핑 캘린더** | 이번 달 핑 이력을 상태별 색으로 — `Sent` 채운 점, `Auto` 테두리 점, `Failed` ✕, `Missed`/`Pending` |
| **사용량 히트맵** | 일별 5h 창 슬롯별 피크 히트맵 — 농도로 사용량 확인 |
| **자동 정렬** | Local(launchd) 또는 Cloud(Routine) 중 선택해 정해진 시각에 자동 핑 |

| Pace 탭 | Usage 탭 |
|---|---|
| ![Pace 탭](assets/screenshot-pace.png) | ![Usage 탭](assets/screenshot-usage.png) |

| Settings — Cloud | Settings — Local |
|---|---|
| ![Settings Cloud](assets/screenshot-settings-cloud.png) | ![Settings Local](assets/screenshot-settings-local.png) |

---

## 왜 "핑(ping)" 이라 부르나요?

**소나(sonar)** — 잠수함이 주변을 감지하려고 내보내는 짧은 펄스죠. Pacer 의 핑은 *새 5시간 창을 여는* 신호입니다. 마라톤의 **페이서**가 옆에서 리듬을 잡아주듯, Pacer 가 당신의 사용 페이스를 잡아줍니다.

---

## 핑 방식: Local vs Cloud

맥이 꺼져 있어도 핑이 나가야 한다면 **Cloud**, Pace log 정확도와 주말·공휴일 스킵이 중요하다면 **Local** 을 선택하세요.

| 기능 | Local (launchd) | Cloud (Routine) |
|------|:--------------:|:---------------:|
| 맥이 꺼져 있어도 발화 | ✗ (맥이 켜져 있어야) | ✓ (Anthropic 클라우드에서 발화) |
| Pace log 정확도 | ✓ 정확 (PingRunner 가 직접 기록) | △ 근사 (usage 의 `resets_at` 역산) |
| 주말·공휴일 스킵 | ✓ (한국 공휴일은 로컬 음력 계산) | ✗ (매일 발화 — cron 으로는 특정일 제외 불가) |
| 핑 자동화 방식 | launchd LaunchAgent | Claude Routine — Pacer 가 `claude -p "/pace-schedule"` 로 RemoteTrigger 자동 등록 |
| 모드 전환 적용 시점 | 즉시 (launchd 재설치) | **Done** 탭 시 확정 — routine 등록/비활성 동기화 (수 초) |
| Claude Code (claude CLI) 필요 | ✓ (핑 발사) | ✓ (routine 등록·발화) |

---

## 동작 방식

### 사용량 조회

macOS **Keychain** 의 Claude Code 로그인 토큰으로 usage API 를 호출합니다. 토큰은 머신을 떠나지 않으며(읽기만 함 — 갱신은 Claude Code 담당), **사용량 데이터는 15분마다 자동 폴링**됩니다.

### 창 정렬 — Local 모드

launchd LaunchAgent 가 설정한 시각에 `claude -p "ok"` 를 실행해 새 5시간 창을 엽니다. 주말과 한국 공휴일은 건너뜁니다 — 공휴일은 **음력 달력으로 로컬 계산**(외부 데이터·API 없음). 잠든 맥에서는 핑이 발화되지 않으므로, 설정에서 `sudo pmset -c disablesleep 1` 명령 복사 안내를 제공합니다.

### 창 정렬 — Cloud 모드

Pacer 가 `claude -p "/pace-schedule"` 로 **Claude Routine(RemoteTrigger 클라우드 cron)을 자동 등록**합니다. 등록 중 Settings 에 카운트다운이 표시되며 보통 ~15초(최대 60초) 걸립니다. 등록 후에는 맥이 꺼져 있어도 Anthropic 클라우드가 정해진 시각에 핑을 발화합니다. 단, cron 특성상 주말·공휴일 스킵은 불가합니다. Pace log 는 usage API 의 `resets_at` 점프를 역산해 근사 기록합니다.

Cloud Routine 의 상태(등록됨 / 끊김 / 갱신 필요)는 앱 시작 시·Settings 열 때 자동 감지합니다. 웹에서 Routine 을 직접 삭제하거나 만료된 경우 모드 칩이 **회색("확인 필요")** 으로 전환됩니다.

### pace-schedule 스킬

`pace-schedule` 스킬은 앱 번들에 내장되어 있으며, 앱 설치 시 사용자의 `~/.claude/skills` 에 자동 설치됩니다.

---

## 메뉴 카드 구성

- **상단**: 워드마크 + Pace / Usage 탭 전환
- **모드 칩**: Local=초록 / Cloud 정상=파랑 / Cloud 끊김=회색(`확인 필요`)
- **플랜 배지**: `Plan: Max (5x)` (클로드 주황)
- **도넛 게이지**: 5-Hour · 7-Day — 리셋 카운트다운(시계 아이콘)
- **하단 버튼 / 우클릭 메뉴**: 새로고침 · 설정 · 종료 (메뉴바 아이콘 **우클릭**으로도 열림, 로그인 전엔 비활성)

**Pace 탭**
이번 달 핑 이력 캘린더. 날짜별 상태:

| 상태 | 표시 |
|------|------|
| `Sent` | 채운 점 — PingRunner 직접 기록 |
| `Auto` | 테두리 점 — usage `resets_at` 역산 추정 (Cloud 모드) |
| `Failed` | ✕ |
| `Missed` / `Pending` | 빈 상태 |

주말은 빨강/파랑, 공휴일은 흐림 처리됩니다.

**Usage 탭**
일별 5h 창 슬롯별 피크 히트맵(농도). 어떤 시간대에 사용이 집중되는지 한눈에 확인할 수 있습니다.

---

## 설치

> 그냥 쓰실 분은 위 **⚡ 빠른 설치**(다운로드)면 충분합니다. 이 섹션은 **직접 빌드·기여자용** — 네이티브 앱이라 파이썬·SwiftBar 없음. Swift / SwiftUI (`MenuBarExtra`).

**소스에서 빌드·실행**

```sh
git clone https://github.com/codedooly/claude-pacer.git
cd claude-pacer
brew install xcodegen
xcodegen generate
xcodebuild -project Pacer.xcodeproj -scheme Pacer -configuration Release -derivedDataPath ./build build
open build/Build/Products/Release/Pacer.app
```

**dmg 직접 만들기** — Releases 에 올릴 아티팩트 생성 (xcodegen + xcodebuild + create-dmg)

```sh
./scripts/build-dmg.sh      # → build/Pacer.dmg
```

첫 실행 시 macOS 가 **Keychain 접근**을 물으면 → **항상 허용**. `pace-schedule` 스킬은 첫 실행 때 자동 설치됩니다. (미서명이라 *다운로드*한 dmg 설치본은 첫 실행만 **우클릭 → 열기**)

### 온보딩

Claude Code 토큰이 Keychain 에 없으면 앱이 **"Connect Claude Code"** 안내 화면을 표시합니다. Claude Code 를 먼저 설치·로그인한 뒤 앱을 재시작하세요.

<div align="center"><img src="assets/screenshot-onboarding.png" width="360" alt="온보딩 화면" /></div>

---

## 설정 (Settings)

Settings 는 **Done** 으로 확정, **X(닫기)** 는 무효(취소)입니다.

| 항목 | 설명 |
|------|------|
| **언어** | English / 한국어 토글 (온보딩 화면 워드마크 옆에도 표시) |
| **핑 방식** | `Local` / `Cloud` 세그먼트 — 하나만 활성(중복 방지) |
| **핑 시각** | 최대 5개 — 각 핑은 **앞 핑 +5시간 이후**만 선택 가능 |
| **로그인 시 자동 실행** | LaunchAgent 등록 토글 |
| **기본값 초기화** | 모든 설정을 기본값으로 되돌림 |

**Local 전용 옵션**

| 항목 | 설명 |
|------|------|
| 주말 스킵 | 토요일·일요일 핑 건너뜀 |
| 공휴일 스킵(KR) | 한국 공휴일 로컬 음력 계산으로 건너뜀 |
| 맥북 잠들지 않게 | `sudo pmset -c disablesleep 1` 명령 복사 버튼 |

**Cloud 전용 옵션**

| 항목 | 설명 |
|------|------|
| Routine 상태 | 등록됨 / 끊김 / 갱신 필요 — 앱 시작 시·Settings 열 때 자동 감지 |
| 재등록 | routine 을 삭제 후 재등록 |
| 갱신 | 핑 시각 변경 시 routine 업데이트 |
| 웹 열기 | Claude Routine 관리 페이지 열기 |

---

## 면책

Pacer 는 **Anthropic 과 무관한 독립 프로젝트**입니다. **비공식** usage 엔드포인트를 본인 계정 토큰으로 사용하므로 API 변경 시 깨질 수 있으나, **우아하게 실패**(마지막 값 유지)합니다. 다른 사용량 도구의 코드는 일절 쓰지 않은 클린룸 구현입니다.

---

## 라이선스

[MIT](LICENSE) © 2026 codedooly

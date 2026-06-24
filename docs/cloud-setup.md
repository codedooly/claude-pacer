# Cloud mode — setup & troubleshooting

> Cloud (Routine) mode fires pings from **Anthropic's cloud**, so your Mac can be off. This guide covers setup and the common "why won't it register?" cases. **Most people never see an error** — Pacer auto-detects everything. This is here for when it doesn't.
>
> 한 줄 요약: **막히면 99%는 "클라우드 환경(environment) 부재"** 이고, Pacer 가 `/schedule` 로 자동 조회하지만 그래도 없으면 **claude.ai/code 에서 환경을 한 번 만들면** 됩니다.

---

## How it works

When you pick **Cloud** and press **Apply**, Pacer registers a Claude Routine (`pace-window-warm`) via the cloud triggers API. It runs the bundled instructions through `claude -p` (no global skill install). The routine then fires a one-word `ok` keep-alive at your ping times every day — opening a fresh 5-hour window, even when your Mac is asleep.

To register, the cloud needs to know **which environment** the routine runs in (`environment_id`). Pacer gets it automatically:

1. **Existing routine** → reuse its `environment_id` (instant).
2. **No routine yet** → Pacer runs `/schedule` to read your account's *Available environments* and uses the first one.
3. **No environment at all** → you create one once at [claude.ai/code](https://claude.ai/code) (web), then retry.

`environment_id` differs per account and **can't be guessed or hardcoded** — that's why a one-time web step is needed for brand-new accounts.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| **"클라우드 환경이 없습니다" / no_env** keeps showing after Apply | Account has **no cloud environment provisioned** (auto-detect returned nothing) | Tap **claude.ai/code 열기** → sign in / set up → this provisions your environment → back in Pacer, **Apply** again |
| **"웹 열기" opens an auth / setup prompt** (works fine for some teammates) | That account hasn't done the web setup, so it has no environment yet | Same as above — complete the web setup once; it's the environment-creation step |
| **404 `not_found_error` · `model: claude-...`** in the error popup | Your **Claude Code CLI is outdated** — its model alias resolves to a retired snapshot | Update Claude Code (`claude` self-updates, or reinstall). Pacer pins a current model, but a very old CLI can still trip |
| Usage shows **0% / "Couldn't update"** on first launch | Keychain token is stale (Claude Code not run recently on this machine) | Run **`claude`** in a terminal once (refreshes the token) → **Refresh** in Pacer |
| Pacer says **registration failed** with some other error | The error popup shows the real message | Read it; if it mentions auth/login, run `claude`; if network, check VPN to `api.anthropic.com` |

---

## Manual environment ID (advanced)

If auto-detect can't find your environment but you know it exists, you can paste the ID yourself:

1. Terminal → `claude` → type `/schedule`.
2. Find the **Available environments** list → copy the `env_...` id.
3. In Pacer (Cloud, on the no_env screen) → paste it into the **`env_...`** field → **Apply**.

Pacer stores it, so you only do this once.

---

## Notes

- **Deleting a routine** is web-only — Pacer can't delete it. Go to [claude.ai/code/routines](https://claude.ai/code/routines).
- The routine **fires regardless of whether claude.ai/code is set up** — the web setup only affects viewing/managing routines in the browser, not whether they run.
- Cloud Pace log is **approximate** (inferred from usage `resets_at`), unlike Local mode which records pings exactly.
- Cloud routines **can't skip weekends/holidays** (cron limitation) — use Local mode if that matters.

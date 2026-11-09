#!/usr/bin/env python3
"""Print one provider's plan usage as JSON for the Plasma widgets: `ai-usage <provider>`.

Reads the CLIs' local logins and asks the same read-only usage endpoints the CLIs use. These are
undocumented and can change without notice. Never refreshes tokens: that would rotate the CLIs'
refresh tokens. An expired token shows as an error until the CLI is used again.

Output: {"provider", "at", "plan", "session": Window|null, "week": Window|null} or {..., "error", "retry_after"?}
  Window = {"pct": 0-100 used, "reset": unix time it resets, "len": window length in seconds}
"""
import json, os, sys, time, urllib.request
from datetime import datetime

H = os.path.expanduser


def get(url, headers):
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=10) as r:
        return json.load(r)


def claude():
    c = json.load(open(H("~/.claude/.credentials.json")))["claudeAiOauth"]
    d = get("https://api.anthropic.com/api/oauth/usage",
            {"Authorization": f"Bearer {c['accessToken']}", "anthropic-beta": "oauth-2025-04-20"})
    # A window is null when it isn't running (e.g. no 5h session open yet): the widget shows an empty bar.
    w = lambda x, ln: {"pct": x["utilization"], "reset": int(datetime.fromisoformat(x["resets_at"]).timestamp()), "len": ln} \
        if x and x.get("resets_at") else None
    tier = c.get("rateLimitTier", "").rsplit("_", 1)[-1]
    plan = f"{c.get('subscriptionType', '').capitalize()} {tier if tier.endswith('x') else ''}".strip()
    return {"plan": plan, "session": w(d.get("five_hour"), 5 * 3600), "week": w(d.get("seven_day"), 7 * 86400)}


def codex():
    t = json.load(open(H("~/.codex/auth.json")))["tokens"]
    d = get("https://chatgpt.com/backend-api/wham/usage",
            {"Authorization": f"Bearer {t['access_token']}", "ChatGPT-Account-Id": t["account_id"]})
    w = lambda x: {"pct": x["used_percent"], "reset": x["reset_at"], "len": x["limit_window_seconds"]} if x else None
    r = d["rate_limit"]
    return {"plan": d.get("plan_type", "").capitalize(), "session": w(r.get("primary_window")), "week": w(r.get("secondary_window"))}


# ── Adding a provider ─────────────────────────────────────────────────────────────────────────────
# 1. Write a function like the ones above: read the provider CLI's local login, call its usage
#    endpoint read-only (find it by watching what the CLI requests), return
#    {"plan": str, "session": Window|None, "week": Window|None}. Raise on failure; the loop below
#    turns exceptions into {"error"}, and HTTP 401/429 into a retry delay.
#    Don't refresh tokens yourself. Windows that don't fit session/week: add your own keys and
#    show them in that provider's widget.
#
#      def gemini():
#          tok = json.load(open(H("~/.gemini/<login file>")))[...]
#          d = get("https://<usage endpoint>", {"Authorization": f"Bearer {tok}"})
#          return {"plan": ..., "session": {"pct": ..., "reset": ..., "len": ...}, "week": None}
#
# 2. Register it in PROVIDERS.
# 3. Copy widgets/_template to widgets/<key>/ and fix its TODOs. Then run ./install.sh.
PROVIDERS = {"claude": claude, "codex": codex}  # add the next provider here

if __name__ == "__main__":
    provider = sys.argv[1] if len(sys.argv) > 1 else "claude"
    if provider not in PROVIDERS:
        sys.exit(f"usage: ai-usage {'|'.join(PROVIDERS)}")
    now = int(time.time())
    out = {"provider": provider, "at": now}
    # Retry once: transient failures (5xx, timeouts, credentials file mid-rewrite by the CLI) are common.
    # 401/429 aren't retried: the usage endpoint's limit is shared with the CLIs on the same token, so pass
    # retry-after on for the widget to wait out.
    for attempt in (1, 2):
        try:
            out.update(PROVIDERS[provider]())
            out.pop("error", None)
            break
        except FileNotFoundError:  # no login file: CLI not installed or never logged in. Retrying won't help.
            out["error"] = f"not logged in: run {provider} and log in"
            out["retry_after"] = 600
            break
        except Exception as e:
            body = e.read(200).decode(errors="replace") if hasattr(e, "read") else ""
            out["error"] = str(e)[:80]
            if getattr(e, "code", None) == 429:
                ra = e.headers.get("retry-after", "")  # seconds, or (rarely) an HTTP date: then use the default
                out["retry_after"] = int(ra) if ra.isdigit() else 300
            elif getattr(e, "code", None) == 401:  # expired token: only the CLI refreshes it
                out["error"] = f"login expired: run {provider} once"
                out["retry_after"] = 120
            log = H("~/.local/state/ai-usage/errors.log")
            os.makedirs(os.path.dirname(log), exist_ok=True)
            # Start over past 100 KB so the log can't grow forever
            mode = "w" if os.path.exists(log) and os.path.getsize(log) > 100_000 else "a"
            with open(log, mode) as f:
                f.write(f"{datetime.now():%F %T} {provider} try{attempt} {type(e).__name__}: {e} {body}\n")
            if "retry_after" in out:
                break
            if attempt == 1:
                time.sleep(3)
    print(json.dumps(out))

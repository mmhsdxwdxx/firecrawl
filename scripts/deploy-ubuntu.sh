#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/opt/stacks/firecrawl"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

cd "$STACK_DIR" || fail "Must run under $STACK_DIR (cannot cd)."
[[ "$(pwd -P)" == "$STACK_DIR" ]] || fail "Must run under $STACK_DIR (pwd is $(pwd -P))."

command -v git >/dev/null 2>&1 || fail "git not found"
command -v docker >/dev/null 2>&1 || fail "docker not found"
docker compose version >/dev/null 2>&1 || fail "docker compose not available (try installing Docker Compose v2)"

[[ -d .git ]] || fail "$STACK_DIR is not a git repo"

echo "==> Updating repo (git pull)"
git pull --ff-only

echo "==> Building/updating containers (docker compose up -d --build)"
docker compose up -d --build

echo "==> Current commit"
git rev-parse --short HEAD

read_dotenv_value() {
  local key="$1"
  local file="$2"
  [[ -f "$file" ]] || return 1
  local line
  line="$(grep -E "^[[:space:]]*${key}=" "$file" | tail -n 1 || true)"
  [[ -n "$line" ]] || return 1
  line="${line#*=}"
  line="${line%$'\r'}"
  line="${line%\"}"; line="${line#\"}"
  line="${line%\'}"; line="${line#\'}"
  printf '%s' "$line"
}

PORT="${PORT:-}"
TEST_API_KEY="${TEST_API_KEY:-}"

if [[ -z "$PORT" ]]; then
  PORT="$(read_dotenv_value "PORT" ".env" || true)"
fi
if [[ -z "$PORT" ]]; then
  PORT="3002"
fi

if [[ -z "$TEST_API_KEY" ]]; then
  TEST_API_KEY="$(read_dotenv_value "TEST_API_KEY" ".env" || true)"
fi

API_URL="http://127.0.0.1:${PORT}/v2/crawl"
BODY='{"url":"https://docs.firecrawl.dev"}'

echo "==> Self-check: POST /v2/crawl"
resp="$(curl -sS -m 60 -X POST "$API_URL" -H 'Content-Type: application/json' -d "$BODY" || true)"

# If unauthorized and we have a key, retry with Authorization header
if echo "$resp" | grep -q '"status"[[:space:]]*:[[:space:]]*401\|"Unauthorized"\|"unauthorized"'; then
  if [[ -n "$TEST_API_KEY" ]]; then
    resp="$(curl -sS -m 60 -X POST "$API_URL" -H 'Content-Type: application/json' -H "Authorization: Bearer ${TEST_API_KEY}" -d "$BODY")"
  else
    fail "Self-check unauthorized and no TEST_API_KEY provided (set env TEST_API_KEY or add it to .env)."
  fi
fi

python3 - <<'PY' "$resp"
import json, sys
raw = sys.argv[1]
try:
  data = json.loads(raw)
except Exception:
  sys.stderr.write("ERROR: Self-check did not return valid JSON.\n")
  sys.stderr.write(raw + "\n")
  sys.exit(1)

success = data.get("success")
crawl_id = data.get("id") or data.get("data", {}).get("id")
if success is not True or not crawl_id:
  sys.stderr.write("ERROR: Self-check failed.\n")
  sys.stderr.write(json.dumps(data, ensure_ascii=False) + "\n")
  sys.exit(1)

print(f"success={str(success).lower()} id={crawl_id}")
PY
echo "==> Self-check (proxy): POST /v2/crawl via reverse proxy (optional)"

# 你当前的统一入口（后续如果换域名/端口，只改这里或用环境变量覆盖）
EXPECTED_BASE="${EXPECTED_BASE:-https://firecrawl.pangkaihome.vip:30443}"
PROXY_API_URL="${PROXY_API_URL:-${EXPECTED_BASE}/v2/crawl}"

proxy_resp="$(curl -sk -m 60 -X POST "$PROXY_API_URL" \
  -H 'Content-Type: application/json' \
  -d "$BODY" || true)"

# 如果反代也返回了 unauthorized，且你提供了 TEST_API_KEY，则带 Bearer 再试一次（兼容未来你加鉴权）
if echo "$proxy_resp" | grep -q '"status"[[:space:]]*:[[:space:]]*401\|"Unauthorized"\|"unauthorized"'; then
  if [[ -n "${TEST_API_KEY:-}" ]]; then
    proxy_resp="$(curl -sk -m 60 -X POST "$PROXY_API_URL" \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer ${TEST_API_KEY}" \
      -d "$BODY")"
  else
    echo "[healthcheck][WARN] Proxy self-check unauthorized and no TEST_API_KEY provided; skipping proxy URL check."
    proxy_resp=""
  fi
fi

if [[ -n "$proxy_resp" ]]; then
  python3 - <<'PY' "$proxy_resp" "$EXPECTED_BASE"
import json, sys
raw = sys.argv[1]
expected = sys.argv[2].rstrip("/")

try:
  data = json.loads(raw)
except Exception:
  print("[healthcheck][WARN] Proxy self-check did not return valid JSON (skipping).")
  sys.exit(0)

url = data.get("url") or ""
if not url:
  print("[healthcheck][WARN] Proxy self-check JSON has no 'url' field (skipping).")
  sys.exit(0)

if url.startswith(expected + "/"):
  print(f"[healthcheck][OK] proxy url base correct: {url}")
else:
  print("[healthcheck][WARN] proxy url base mismatch")
  print(f"  expected prefix: {expected}/")
  print(f"  got: {url}")
PY
fi

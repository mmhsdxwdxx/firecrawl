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

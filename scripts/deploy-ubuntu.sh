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
docker compose version >/dev/null 2>&1 || fail "docker compose not available (need Docker Compose v2)"

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
[[ -n "$PORT" ]] || PORT="3002"

if [[ -z "$TEST_API_KEY" ]]; then
  TEST_API_KEY="$(read_dotenv_value "TEST_API_KEY" ".env" || true)"
fi

API_ROOT="http://127.0.0.1:${PORT}"
ENDPOINT="/v2/crawl"
BODY='{"url":"https://docs.firecrawl.dev"}'

echo "==> Self-check: POST ${ENDPOINT} (wait until API is ready)"

resp=""
for i in $(seq 1 30); do
  echo "  - waiting api... try=$i"

  # 先不带鉴权试一次（大多数情况下够用）
  resp="$(curl -sS -m 10 -X POST "${API_ROOT}${ENDPOINT}" \
    -H 'Content-Type: application/json' \
    -d "$BODY" 2>/dev/null || true)"

  # 如果返回的不是 JSON，就继续等（常见于刚启动时 connection reset / empty）
  if ! echo "$resp" | grep -q '^{'; then
    resp=""
    sleep 2
    continue
  fi

  # 如果 401 且你有 key，就带 Bearer 再试一次
  if echo "$resp" | grep -q '"status"[[:space:]]*:[[:space:]]*401\|"Unauthorized"\|"unauthorized"'; then
    if [[ -n "$TEST_API_KEY" ]]; then
      resp="$(curl -sS -m 10 -X POST "${API_ROOT}${ENDPOINT}" \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer ${TEST_API_KEY}" \
        -d "$BODY" 2>/dev/null || true)"
    fi
  fi

  # 有 JSON 就交给 python 校验；校验通过就退出循环
  if python3 - <<'PY' "$resp" >/dev/null 2>&1; then
import json, sys
data = json.loads(sys.argv[1])
ok = bool(data.get("success")) and bool(data.get("id") or (data.get("data") or {}).get("id"))
sys.exit(0 if ok else 1)
PY
    break
  fi

  resp=""
  sleep 2
done

[[ -n "$resp" ]] || fail "API not ready after waiting (no valid JSON success response)."

python3 - <<'PY' "$resp"
import json, sys
raw = sys.argv[1]
data = json.loads(raw)

success = data.get("success")
crawl_id = data.get("id") or (data.get("data") or {}).get("id")

if success is not True or not crawl_id:
  sys.stderr.write("ERROR: Self-check failed.\n")
  sys.stderr.write(json.dumps(data, ensure_ascii=False) + "\n")
  sys.exit(1)

print(f"success={str(success).lower()} id={crawl_id}")
PY
fi
#!/bin/sh
set -e

BASE_URL="http://127.0.0.1:${PORT:-3100}"

ONBOARD_COMPANY_NAME="${PAPERCLIP_ONBOARD_COMPANY_NAME:-}"
ONBOARD_COMPANY_GOAL="${PAPERCLIP_ONBOARD_COMPANY_GOAL:-}"
ONBOARD_AGENT_NAME="${PAPERCLIP_ONBOARD_AGENT_NAME:-CEO}"
ONBOARD_ADAPTER_TYPE="${PAPERCLIP_ONBOARD_ADAPTER_TYPE:-claude_local}"
ONBOARD_MODEL="${PAPERCLIP_ONBOARD_MODEL:-}"
ONBOARD_TASK_TITLE="${PAPERCLIP_ONBOARD_TASK_TITLE:-Hire your first engineer and create a hiring plan}"
ONBOARD_TASK_DESCRIPTION="${PAPERCLIP_ONBOARD_TASK_DESCRIPTION:-You are the CEO. You set the direction for the company.\n\n- hire a founding engineer\n- write a hiring plan\n- break the roadmap into concrete tasks and start delegating work}"
ONBOARD_ADMIN_NAME="${PAPERCLIP_ONBOARD_ADMIN_NAME:-}"
ONBOARD_ADMIN_EMAIL="${PAPERCLIP_ONBOARD_ADMIN_EMAIL:-}"
ONBOARD_ADMIN_PASSWORD="${PAPERCLIP_ONBOARD_ADMIN_PASSWORD:-}"
ONBOARD_SKIP="${PAPERCLIP_ONBOARD_SKIP:-false}"

DEPLOYMENT_MODE="${PAPERCLIP_DEPLOYMENT_MODE:-local_trusted}"

log() {
  echo "[env-onboard] $*"
}

wait_for_http() {
  url="$1"
  attempts="${2:-120}"
  sleep_sec="${3:-1}"
  i=1
  while [ "$i" -le "$attempts" ]; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_sec"
    i=$((i + 1))
  done
  return 1
}

bool_is_true() {
  case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes) return 0 ;;
    *) return 1 ;;
  esac
}

should_onboard() {
  if bool_is_true "$ONBOARD_SKIP"; then
    log "PAPERCLIP_ONBOARD_SKIP=true, skipping onboarding"
    return 1
  fi
  if [ -z "$ONBOARD_COMPANY_NAME" ]; then
    return 1
  fi
  return 0
}

startup_cmd() {
  exec /usr/local/bin/docker-entrypoint.sh "$@"
}

do_authenticated_bootstrap() {
  if [ -z "$ONBOARD_ADMIN_EMAIL" ] || [ -z "$ONBOARD_ADMIN_PASSWORD" ]; then
    log "ERROR: PAPERCLIP_ONBOARD_ADMIN_EMAIL and PAPERCLIP_ONBOARD_ADMIN_PASSWORD are required in authenticated mode"
    return 1
  fi

  ADMIN_NAME="${ONBOARD_ADMIN_NAME:-Admin}"

  SIGNUP_BODY=$(printf '{"name":"%s","email":"%s","password":"%s"}' \
    "$ADMIN_NAME" "$ONBOARD_ADMIN_EMAIL" "$ONBOARD_ADMIN_PASSWORD")

  SIGNUP_STATUS=$(curl -sS -o /dev/null -w "%{http_code}" \
    -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    -H "Content-Type: application/json" \
    -H "Origin: $BASE_URL" \
    -X POST "$BASE_URL/api/auth/sign-up/email" \
    --data "$SIGNUP_BODY" 2>/dev/null || true)

  if echo "$SIGNUP_STATUS" | grep -qE '^2'; then
    log "Admin user created: $ONBOARD_ADMIN_EMAIL"
  else
    SIGNIN_STATUS=$(curl -sS -o /dev/null -w "%{http_code}" \
      -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
      -H "Content-Type: application/json" \
      -H "Origin: $BASE_URL" \
      -X POST "$BASE_URL/api/auth/sign-in/email" \
      --data "{\"email\":\"$ONBOARD_ADMIN_EMAIL\",\"password\":\"$ONBOARD_ADMIN_PASSWORD\"}" 2>/dev/null || true)
    if echo "$SIGNIN_STATUS" | grep -qE '^2'; then
      log "Signed in existing admin: $ONBOARD_ADMIN_EMAIL"
    else
      log "ERROR: Could not sign up or sign in admin user"
      return 1
    fi
  fi

  HEALTH_JSON=$(curl -sS "$BASE_URL/api/health" 2>/dev/null || echo '{}')
  if echo "$HEALTH_JSON" | grep -q '"bootstrapStatus":"ready"'; then
    log "Instance already bootstrapped"
    return 0
  fi

  BOOTSTRAP_OUTPUT=$(timeout 30s npx --yes "paperclipai@latest" auth bootstrap-ceo \
    --data-dir "${PAPERCLIP_HOME:-/paperclip}" \
    --base-url "$BASE_URL" 2>&1 || true)

  INVITE_URL=$(printf '%s\n' "$BOOTSTRAP_OUTPUT" \
    | grep -o 'https\?://[^[:space:]]*/invite/pcp_bootstrap_[[:alnum:]]*' \
    | tail -n 1)

  if [ -z "$INVITE_URL" ]; then
    log "ERROR: bootstrap-ceo did not produce an invite URL"
    log "Output: $BOOTSTRAP_OUTPUT"
    return 1
  fi

  INVITE_TOKEN="${INVITE_URL##*/}"
  ACCEPT_STATUS=$(curl -sS -o /dev/null -w "%{http_code}" \
    -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    -H "Content-Type: application/json" \
    -H "Origin: $BASE_URL" \
    -X POST "$BASE_URL/api/invites/$INVITE_TOKEN/accept" \
    --data '{"requestType":"human"}' 2>/dev/null || true)

  if ! echo "$ACCEPT_STATUS" | grep -qE '^2'; then
    log "ERROR: Bootstrap invite acceptance returned HTTP $ACCEPT_STATUS"
    return 1
  fi
  log "Bootstrap invite accepted"
  return 0
}

api_get() {
  curl -sS \
    -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    -H "Accept: application/json" \
    "$BASE_URL$1" 2>/dev/null
}

api_post() {
  path="$1"
  body="$2"
  expect_status="${3:-201}"
  curl -sS \
    -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    -H "Content-Type: application/json" \
    -H "Origin: $BASE_URL" \
    -o "$TMPResponseBody" \
    -w "%{http_code}" \
    -X POST "$BASE_URL$path" \
    --data "$body" 2>/dev/null
}

do_onboard() {
  if ! wait_for_http "$BASE_URL/api/health" 120 1; then
    log "ERROR: Server did not become ready at $BASE_URL/api/health"
    return 1
  fi
  log "Server is ready"

  if [ "$DEPLOYMENT_MODE" = "authenticated" ]; then
    if ! do_authenticated_bootstrap; then
      log "ERROR: Authenticated bootstrap failed"
      return 1
    fi
  fi

  COMPANIES=$(api_get "/api/companies")
  if [ "${COMPANIES:0:1}" = "[" ] && [ "$COMPANIES" != "[]" ]; then
    log "Onboarding already done (companies exist), skipping"
    return 0
  fi

  log "Creating company: $ONBOARD_COMPANY_NAME"
  COMPANY_BODY=$(printf '{"name":"%s"}' "$(echo "$ONBOARD_COMPANY_NAME" | sed 's/"/\\"/g')")
  STATUS=$(api_post "/api/companies" "$COMPANY_BODY")
  if ! echo "$STATUS" | grep -qE '^2'; then
    log "ERROR: Failed to create company (HTTP $STATUS)"
    cat "$TMPResponseBody" 2>/dev/null
    return 1
  fi
  COMPANY_JSON=$(cat "$TMPResponseBody")
  COMPANY_ID=$(printf '%s' "$COMPANY_JSON" | jq -r '.id')
  log "Company created: $COMPANY_ID"

  GOAL_ID=""
  if [ -n "$ONBOARD_COMPANY_GOAL" ]; then
    FIRST_LINE=$(printf '%s' "$ONBOARD_COMPANY_GOAL" | head -n1 | sed 's/"/\\"/g')
    REST_LINES=$(printf '%s' "$ONBOARD_COMPANY_GOAL" | tail -n +2 | sed 's/"/\\"/g')
    GOAL_BODY=$(printf '{"title":"%s","description":"%s","level":"company","status":"active"}' "$FIRST_LINE" "$REST_LINES")
    STATUS=$(api_post "/api/companies/$COMPANY_ID/goals" "$GOAL_BODY")
    if echo "$STATUS" | grep -qE '^2'; then
      GOAL_ID=$(cat "$TMPResponseBody" | jq -r '.id')
      log "Company goal created: $GOAL_ID"
    else
      log "WARNING: Failed to create company goal (HTTP $STATUS), continuing"
    fi
  fi

  log "Hiring agent: $ONBOARD_AGENT_NAME ($ONBOARD_ADAPTER_TYPE)"
  ADAPTER_CONFIG="{}"
  if [ -n "$ONBOARD_MODEL" ]; then
    ADAPTER_CONFIG=$(printf '{"model":"%s"}' "$(echo "$ONBOARD_MODEL" | sed 's/"/\\"/g')")
  fi
  AGENT_BODY=$(cat <<AGENTEOF
{"name":"$(echo "$ONBOARD_AGENT_NAME" | sed 's/"/\\"/g')","role":"ceo","adapterType":"$ONBOARD_ADAPTER_TYPE","adapterConfig":$ADAPTER_CONFIG}
AGENTEOF
)
  STATUS=$(api_post "/api/companies/$COMPANY_ID/agent-hires" "$AGENT_BODY")
  if ! echo "$STATUS" | grep -qE '^2'; then
    log "ERROR: Failed to hire agent (HTTP $STATUS)"
    cat "$TMPResponseBody" 2>/dev/null
    return 1
  fi
  AGENT_ID=$(cat "$TMPResponseBody" | jq -r '.id')
  log "Agent hired: $AGENT_ID"

  PROJECT_BODY=$(printf '{"name":"Onboarding","status":"in_progress"%s}' "$([ -n "$GOAL_ID" ] && printf ',"goalIds":["%s"]' "$GOAL_ID" || printf '')")
  STATUS=$(api_post "/api/companies/$COMPANY_ID/projects" "$PROJECT_BODY")
  if ! echo "$STATUS" | grep -qE '^2'; then
    log "WARNING: Failed to create onboarding project (HTTP $STATUS), continuing"
    PROJECT_ID=""
  else
    PROJECT_ID=$(cat "$TMPResponseBody" | jq -r '.id')
    log "Project created: $PROJECT_ID"
  fi

  ESCAPED_TITLE=$(printf '%s' "$ONBOARD_TASK_TITLE" | sed 's/"/\\"/g')
  ESCAPED_DESC=$(printf '%s' "$ONBOARD_TASK_DESCRIPTION" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
  ISSUE_BODY=$(cat <<ISSUEEOF
{"title":"$ESCAPED_TITLE","description":"$ESCAPED_DESC","status":"todo","assigneeAgentId":"$AGENT_ID"$([ -n "$PROJECT_ID" ] && printf ',"projectId":"%s"' "$PROJECT_ID" || printf '')$([ -n "$GOAL_ID" ] && printf ',"goalId":"%s"' "$GOAL_ID" || printf '')}
ISSUEEOF
)
  STATUS=$(api_post "/api/companies/$COMPANY_ID/issues" "$ISSUE_BODY" 201)
  if ! echo "$STATUS" | grep -qE '^2'; then
    log "WARNING: Failed to create starter issue (HTTP $STATUS)"
  else
    ISSUE_ID=$(cat "$TMPResponseBody" | jq -r '.id')
    log "Starter issue created: $ISSUE_ID"
  fi

  log "Onboarding complete"
  return 0
}

if ! should_onboard; then
  startup_cmd "$@"
fi

TMPDIR_ONBOARD=$(mktemp -d "${TMPDIR:-/tmp}/paperclip-onboard.XXXXXX")
COOKIE_JAR="$TMPDIR_ONBOARD/cookies.txt"
TMPResponseBody="$TMPDIR_ONBOARD/response.json"

cleanup_onboard() {
  rm -rf "$TMPDIR_ONBOARD" 2>/dev/null || true
}
trap cleanup_onboard EXIT INT TERM

log "Starting server in background for onboarding..."
"$@" &
SERVER_PID=$!

log "Waiting for server..."
if ! do_onboard; then
  log "Onboarding failed, stopping server"
  kill "$SERVER_PID" 2>/dev/null || true
  exit 1
fi

log "Onboarding done, keeping server alive (PID $SERVER_PID)"
wait "$SERVER_PID"

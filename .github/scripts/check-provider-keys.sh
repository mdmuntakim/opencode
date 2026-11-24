#!/usr/bin/env bash
# ============================================================================
# check-provider-keys.sh -- prove that the provider keys can actually infer
# ----------------------------------------------------------------------------
# The agent falls back to keyed models only when the provider key is valid.
# A secret that holds the wrong value (for example a GitHub token pasted into
# the Groq field) looks "configured" to OpenCode and then fails with a 401 on
# the first keyed model, which is hard to spot in a long log.
#
# This script sends one tiny chat completion per configured provider and prints
# the model, the reply and the number of seconds it took, or the exact error the
# provider returned.  A value that looks like a GitHub token is reported and
# never sent to a third party.
#
#   check-provider-keys.sh            report, exit 0
#   check-provider-keys.sh --strict   exit 1 when a configured provider fails
#
# Environment:
#   GROQ_API_KEY          key from console.groq.com
#   OPENROUTER_API_KEY    key from openrouter.ai/keys
#   GROQ_TEST_MODEL       default openai/gpt-oss-120b
#   OPENROUTER_TEST_MODEL default inclusionai/ling-3.2-flash:free
#   PROVIDER_TEST_TIMEOUT curl timeout in seconds (default 30)
# ============================================================================
set -uo pipefail

strict=0
for arg in "$@"; do
  case "$arg" in
    --strict) strict=1 ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

timeout_s="${PROVIDER_TEST_TIMEOUT:-30}"
[[ "$timeout_s" =~ ^[1-9][0-9]*$ ]] || timeout_s=30

failures=0
checked=0

# A GitHub token in a provider secret is both useless and a leak: it must never
# be posted to api.groq.com or openrouter.ai.
looks_like_github_token() {
  case "$1" in
    ghp_*|gho_*|ghu_*|ghs_*|ghr_*|github_pat_*) return 0 ;;
    *) return 1 ;;
  esac
}

# The reply text of an OpenAI compatible chat completion, without a JSON parser
# dependency beyond what the runner already has.
reply_text() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.choices[0].message.content // empty' 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)["choices"][0]["message"]["content"] or "")
except Exception:
    pass' 2>/dev/null
  fi
}

error_text() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.error.message // .error // .message // empty' 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)["error"]
    print(d.get("message",d) if isinstance(d,dict) else d)
except Exception:
    pass' 2>/dev/null
  fi
}

# probe <provider> <key> <url> <model>
probe() {
  local provider="$1" key="$2" url="$3" model="$4"
  local body status elapsed tmp

  printf '\n%s: key present (%s***, %s characters)\n' \
    "$provider" "${key:0:4}" "${#key}"

  if looks_like_github_token "$key"; then
    printf '  FAIL  the secret holds a GitHub token, not a %s API key\n' "$provider"
    printf '        it was not sent to %s; set %s_API_KEY to the real key\n' \
      "$url" "$(printf '%s' "$provider" | tr '[:lower:]' '[:upper:]')"
    failures=$((failures + 1))
    return
  fi

  checked=$((checked + 1))
  tmp="$(mktemp)"
  body="$(printf '{"model":"%s","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":16}' "$model")"

  elapsed="$(curl -sS -m "$timeout_s" -o "$tmp" -w '%{time_total}' \
    -X POST "$url" \
    -H "Authorization: Bearer $key" \
    -H 'Content-Type: application/json' \
    -d "$body" 2>"$tmp.err")"
  status=$?

  if [ "$status" -ne 0 ]; then
    printf '  FAIL  %s/%s: curl exit %s after %ss: %s\n' \
      "$provider" "$model" "$status" "$elapsed" "$(tr '\n' ' ' <"$tmp.err")"
    failures=$((failures + 1))
  elif reply="$(reply_text <"$tmp")" && [ -n "$reply" ]; then
    printf '  OK    %s/%s in %ss: %s\n' \
      "$provider" "$model" "$elapsed" "$(printf '%s' "$reply" | tr '\n' ' ')"
  else
    err="$(error_text <"$tmp")"
    [ -n "$err" ] || err="$(head -c 300 "$tmp" | tr '\n' ' ')"
    printf '  FAIL  %s/%s in %ss: %s\n' "$provider" "$model" "$elapsed" "$err"
    failures=$((failures + 1))
  fi

  rm -f "$tmp" "$tmp.err"
}

groq="$(printf '%s' "${GROQ_API_KEY:-}" | tr -d '\r\n')"
openrouter="$(printf '%s' "${OPENROUTER_API_KEY:-}" | tr -d '\r\n')"

if [ -z "$groq" ] && [ -z "$openrouter" ]; then
  echo "no provider key is configured (GROQ_API_KEY, OPENROUTER_API_KEY are empty); nothing to check"
  exit 0
fi

[ -n "$groq" ] && probe groq "$groq" \
  "https://api.groq.com/openai/v1/chat/completions" \
  "${GROQ_TEST_MODEL:-openai/gpt-oss-120b}"

[ -n "$openrouter" ] && probe openrouter "$openrouter" \
  "https://openrouter.ai/api/v1/chat/completions" \
  "${OPENROUTER_TEST_MODEL:-inclusionai/ling-3.2-flash:free}"

printf '\n%s\n' "------------------------------------------------------------"
if [ "$failures" -eq 0 ]; then
  printf 'all configured provider keys work (%s probed)\n' "$checked"
  exit 0
fi

printf '%s provider key(s) failed\n' "$failures"
[ "$strict" -eq 1 ] && exit 1
exit 0

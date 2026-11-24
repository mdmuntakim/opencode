#!/usr/bin/env bash
# Tests for .github/scripts/check-provider-keys.sh.
#
# `curl` is replaced by a stub, so the suite never touches a provider and needs
# no API key.  It asserts the success path, the 401 path, the strict exit code
# and that a GitHub token is never sent anywhere.
#
#   .github/scripts/tests/check-provider-keys.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/.github/scripts/check-provider-keys.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

contains() { printf '%s' "$1" | grep -qF -- "$2"; }
not_contains() { ! contains "$1" "$2"; }

# A curl stub that copies $CURL_BODY to the -o target, prints the elapsed time
# that -w asked for, and records every invocation.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) shift 2 ;;
    -d|-H|-X|-m) shift 2 ;;
    *) shift ;;
  esac
done
printf 'call\n' >> "$CURL_LOG"
[ -n "$out" ] && cp "$CURL_BODY" "$out"
printf '0.42'
exit "${CURL_EXIT:-0}"
STUB
chmod +x "$WORK/bin/curl"
: > "$WORK/curl.log"

# run [VAR=value ...] -- [script arguments]
run() {
  local envs=("CURL_LOG=$WORK/curl.log") args=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  args=("$@")
  env -u GROQ_API_KEY -u OPENROUTER_API_KEY -u GROQ_TEST_MODEL -u OPENROUTER_TEST_MODEL \
      -u CURL_BODY -u CURL_EXIT \
      PATH="$WORK/bin:$PATH" "${envs[@]}" "$SCRIPT" "${args[@]}" 2>&1
}

# --- 1. no keys, nothing to check -----------------------------------------
out="$(run --)"
status=$?
check "no key configured exits 0" [ "$status" -eq 0 ]
check "no key configured says so" contains "$out" "no provider key is configured"
check "no key configured does not call the network" [ ! -s "$WORK/curl.log" ]

# --- 2. a working key reports model, reply and time ------------------------
cat > "$WORK/ok.json" <<'JSON'
{"choices":[{"message":{"role":"assistant","content":"OK"}}]}
JSON
out="$(run CURL_BODY="$WORK/ok.json" GROQ_API_KEY=gsk_test_1234567890 --)"
status=$?
check "working key exits 0" [ "$status" -eq 0 ]
check "working key names the model" contains "$out" "groq/openai/gpt-oss-120b"
check "working key reports reply and time" contains "$out" "in 0.42s: OK"
check "working key does not print the full secret" not_contains "$out" "gsk_test_1234567890"
check "summary says the key works" contains "$out" "all configured provider keys work"

# --- 3. a rejected key reports the exact provider error --------------------
cat > "$WORK/unauthorised.json" <<'JSON'
{"error":{"message":"Invalid API Key","type":"invalid_request_error","code":"invalid_api_key"}}
JSON
out="$(run CURL_BODY="$WORK/unauthorised.json" GROQ_API_KEY=gsk_wrong_key_000000 --)"
status=$?
check "rejected key exits 0 without --strict" [ "$status" -eq 0 ]
check "rejected key prints the provider message" contains "$out" "Invalid API Key"
check "rejected key prints the model" contains "$out" "groq/openai/gpt-oss-120b"
check "rejected key is counted" contains "$out" "1 provider key(s) failed"

run CURL_BODY="$WORK/unauthorised.json" GROQ_API_KEY=gsk_wrong_key_000000 -- --strict >/dev/null
check "--strict exits 1 on a rejected key" [ "$?" -eq 1 ]

# --- 4. a GitHub token in a provider secret is never sent ------------------
: > "$WORK/curl.log"
out="$(run GROQ_API_KEY=ghp_0123456789abcdefghijklmnopqrstuvwxyz --)"
status=$?
check "github token is detected" contains "$out" "holds a GitHub token"
check "github token is not sent to the provider" [ ! -s "$WORK/curl.log" ]
check "github token names the secret to fix" contains "$out" "set GROQ_API_KEY to the real key"
check "github token is counted as a failure" contains "$out" "1 provider key(s) failed"

# --- 5. both providers are probed when both keys are set -------------------
out="$(run CURL_BODY="$WORK/ok.json" GROQ_API_KEY=gsk_test_1234567890 OPENROUTER_API_KEY=sk-or-v1-test --)"
status=$?
check "two configured keys exit 0" [ "$status" -eq 0 ]
check "groq is probed" contains "$out" "groq/openai/gpt-oss-120b"
check "openrouter is probed" contains "$out" "openrouter/inclusionai/ling-3.2-flash:free"
check "two keys reported as working" contains "$out" "(2 probed)"

# --- 6. a transport failure is reported, not swallowed ---------------------
out="$(run CURL_EXIT=7 CURL_BODY="$WORK/ok.json" GROQ_API_KEY=gsk_test_1234567890 --)"
status=$?
check "curl failure is reported" contains "$out" "curl exit 7"
check "curl failure is counted" contains "$out" "1 provider key(s) failed"
run CURL_EXIT=7 CURL_BODY="$WORK/ok.json" GROQ_API_KEY=gsk_test_1234567890 -- --strict >/dev/null
check "curl failure with --strict exits 1" [ "$?" -eq 1 ]

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

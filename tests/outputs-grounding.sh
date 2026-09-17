#!/usr/bin/env bash
# Grounding (#782) on report outputs: salmona-api#1128.
#
# Hermetic: curl is replaced by a stub on PATH, the config file is a throwaway,
# and ARK_API_URL points at a domain that does not resolve. No request ever
# leaves this suite.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

REAL_JQ=$(command -v jq)
CALL_FILE="${TEST_TMP}/call.json"
CONFIG_FILE="${TEST_TMP}/config"
printf 'api-key=test-token\n' > "$CONFIG_FILE"

FAILURES=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s\nexpected: %s\nactual:   %s\n' "$label" "$expected" "$actual" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# ─── curl stub ─────────────────────────────────────────────────────────────────
# Records the JSON body (--data) and every multipart field (-F) as JSON so the
# assertions can tell a JSON object from a JSON-encoded string field.
cat > "${TEST_TMP}/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

method="GET"; body=""; body_file=""; header_file=""; url=""
form_names=(); form_values=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data) body="$2"; shift 2 ;;
    --output) body_file="$2"; shift 2 ;;
    --dump-header) header_file="$2"; shift 2 ;;
    --write-out) shift 2 ;;
    -H) shift 2 ;;
    -F) form_names+=("${2%%=*}"); form_values+=("${2#*=}"); shift 2 ;;
    --silent) shift ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done

form_json='{}'
i=0
while [[ $i -lt ${#form_names[@]} ]]; do
  form_json=$(printf '%s' "$form_json" | jq --arg k "${form_names[$i]}" --arg v "${form_values[$i]}" '. + {($k): $v}')
  i=$((i + 1))
done

jq -n --arg m "$method" --arg u "$url" --arg b "$body" --argjson f "$form_json" \
  '{method:$m, url:$u, body:(if $b == "" then null else ($b | fromjson) end), form:$f}' \
  > "$ARK_TEST_CALL_FILE"

printf 'HTTP/1.1 201 Created\r\nX-Request-Id: request-123\r\n\r\n' > "$header_file"
printf '%s' '{"ok":true,"data":{"id":"output-1","version":1}}' > "$body_file"
printf '201'
STUB
chmod +x "${TEST_TMP}/curl"

run_cli() {
  ARK_CONFIG_FILE="$CONFIG_FILE" \
  ARK_API_URL="https://api.example.test" \
  ARK_IDEMPOTENCY_KEY="grounding-key" \
  ARK_TEST_CALL_FILE="$CALL_FILE" \
  PATH="${TEST_TMP}:$PATH" \
  "$ROOT_DIR/ark" "$@"
}

GROUNDING='{"documents":[{"input_id":"11111111-1111-1111-1111-111111111111","ocr_sha256":"deadbeef","pages_read":"1-93","pages_cited":[12,40]}]}'
GROUNDING_COMPACT=$(printf '%s' "$GROUNDING" | "$REAL_JQ" -c '.')
printf '%s\n' "$GROUNDING" > "${TEST_TMP}/grounding.json"

REPORT_FILE="${TEST_TMP}/report.json"
printf '%s' '{"hallazgos":[]}' > "$REPORT_FILE"

# ─── submit: inline --grounding ────────────────────────────────────────────────
rm -f "$CALL_FILE"
run_cli tasks outputs submit task-1 --type json --label report \
  --data '{"hallazgos":[]}' --grounding "$GROUNDING" >/dev/null
assert_eq "POST" "$("$REAL_JQ" -r '.method' "$CALL_FILE")" "submit inline: method"
assert_eq "https://api.example.test/api/tasks/task-1/outputs" "$("$REAL_JQ" -r '.url' "$CALL_FILE")" "submit inline: URL"
assert_eq "object" "$("$REAL_JQ" -r '.body.grounding | type' "$CALL_FILE")" "submit inline: grounding is a JSON object"
assert_eq "$GROUNDING_COMPACT" "$("$REAL_JQ" -c '.body.grounding' "$CALL_FILE")" "submit inline: grounding payload"
assert_eq "null" "$("$REAL_JQ" -r '.body.grounding_contract_version // "null"' "$CALL_FILE")" "submit inline: no contract version unless asked"
assert_eq "1" "$("$REAL_JQ" -r '.body.data.hallazgos | length + 1' "$CALL_FILE")" "submit inline: data still sent"

# ─── submit: --grounding @file ─────────────────────────────────────────────────
rm -f "$CALL_FILE"
run_cli tasks outputs submit task-1 --type json --label report \
  --grounding "@${TEST_TMP}/grounding.json" >/dev/null
assert_eq "$GROUNDING_COMPACT" "$("$REAL_JQ" -c '.body.grounding' "$CALL_FILE")" "submit @file: grounding payload"

# ─── submit: --grounding - (stdin) ─────────────────────────────────────────────
rm -f "$CALL_FILE"
printf '%s' "$GROUNDING" | run_cli tasks outputs submit task-1 --type json --label report \
  --grounding - >/dev/null
assert_eq "$GROUNDING_COMPACT" "$("$REAL_JQ" -c '.body.grounding' "$CALL_FILE")" "submit stdin: grounding payload"

# ─── submit: --grounding-contract-version 1 is an integer ──────────────────────
rm -f "$CALL_FILE"
run_cli tasks outputs submit task-1 --type json --label report \
  --grounding "$GROUNDING" --grounding-contract-version 1 >/dev/null
assert_eq "number" "$("$REAL_JQ" -r '.body.grounding_contract_version | type' "$CALL_FILE")" "submit: contract version is an integer"
assert_eq "1" "$("$REAL_JQ" -r '.body.grounding_contract_version' "$CALL_FILE")" "submit: contract version value"

# ─── submit: --grounding=<json> equals form ────────────────────────────────────
rm -f "$CALL_FILE"
run_cli tasks outputs submit task-1 --type json --label report \
  "--grounding=${GROUNDING}" "--grounding-contract-version=1" >/dev/null
assert_eq "$GROUNDING_COMPACT" "$("$REAL_JQ" -c '.body.grounding' "$CALL_FILE")" "submit --flag=value: grounding payload"
assert_eq "1" "$("$REAL_JQ" -r '.body.grounding_contract_version' "$CALL_FILE")" "submit --flag=value: contract version"

# ─── submit: flag absent leaves the body unchanged ─────────────────────────────
rm -f "$CALL_FILE"
run_cli tasks outputs submit task-1 --type json --label report --data '{"hallazgos":[]}' >/dev/null
assert_eq '{"output_type":"json","label":"report","data":{"hallazgos":[]}}' \
  "$("$REAL_JQ" -c '.body' "$CALL_FILE")" "submit without --grounding: body unchanged"

# ─── upload: grounding is a JSON-encoded STRING form field ─────────────────────
rm -f "$CALL_FILE"
run_cli tasks outputs upload task-1 "$REPORT_FILE" --type file --label report \
  --grounding "$GROUNDING" --grounding-contract-version 1 >/dev/null
assert_eq "https://api.example.test/api/tasks/task-1/outputs/upload" "$("$REAL_JQ" -r '.url' "$CALL_FILE")" "upload: URL"
assert_eq "string" "$("$REAL_JQ" -r '.form.grounding | type' "$CALL_FILE")" "upload: grounding form field is a string"
assert_eq "$GROUNDING_COMPACT" "$("$REAL_JQ" -r '.form.grounding' "$CALL_FILE")" "upload: grounding form field is the JSON-encoded block"
assert_eq "$GROUNDING_COMPACT" "$("$REAL_JQ" -r '.form.grounding | fromjson | tojson' "$CALL_FILE")" "upload: grounding form field decodes back to the block"
assert_eq "1" "$("$REAL_JQ" -r '.form.grounding_contract_version' "$CALL_FILE")" "upload: contract version form field"
assert_eq "report" "$("$REAL_JQ" -r '.form.label' "$CALL_FILE")" "upload: label still sent"

# ─── upload: flag absent leaves the form unchanged ─────────────────────────────
rm -f "$CALL_FILE"
run_cli tasks outputs upload task-1 "$REPORT_FILE" --type file --label report >/dev/null
assert_eq "false" "$("$REAL_JQ" -r 'has("grounding") | tostring' <<<"$("$REAL_JQ" -c '.form' "$CALL_FILE")")" "upload without --grounding: no grounding field"
assert_eq "file,label,local_path,output_type" \
  "$("$REAL_JQ" -r '.form | keys | join(",")' "$CALL_FILE")" "upload without --grounding: form unchanged"

# ─── dry-run shows what would be sent ──────────────────────────────────────────
rm -f "$CALL_FILE"
dry=$(run_cli --dry-run tasks outputs submit task-1 --type json --label report \
  --grounding "$GROUNDING" --grounding-contract-version 1)
assert_eq "$GROUNDING_COMPACT" "$(printf '%s' "$dry" | "$REAL_JQ" -c '.data.would_send.body.grounding')" "dry-run submit: grounding object"
assert_eq "1" "$(printf '%s' "$dry" | "$REAL_JQ" -r '.data.would_send.body.grounding_contract_version')" "dry-run submit: contract version"

dry=$(run_cli --dry-run tasks outputs upload task-1 "$REPORT_FILE" --type file --label report \
  --grounding "$GROUNDING" --grounding-contract-version 1)
assert_eq "string" "$(printf '%s' "$dry" | "$REAL_JQ" -r '.data.would_send.body.multipart.grounding | type')" "dry-run upload: grounding shown as string"
assert_eq "$GROUNDING_COMPACT" "$(printf '%s' "$dry" | "$REAL_JQ" -r '.data.would_send.body.multipart.grounding')" "dry-run upload: grounding value"
assert_eq "1" "$(printf '%s' "$dry" | "$REAL_JQ" -r '.data.would_send.body.multipart.grounding_contract_version')" "dry-run upload: contract version"
assert_eq "false" "$([[ -f "$CALL_FILE" ]] && echo true || echo false)" "dry-run sends no request"

# ─── invalid JSON: exit 2, bad_argument, no request ────────────────────────────
assert_no_request_bad_argument() {
  local label="$1"; shift
  rm -f "$CALL_FILE"
  local status=0 err
  set +e
  err=$(run_cli "$@" 2>&1 >/dev/null)
  status=$?
  set -e
  assert_eq "2" "$status" "${label}: exit code"
  assert_eq "bad_argument" "$(printf '%s' "$err" | "$REAL_JQ" -r '.error.code')" "${label}: error code"
  assert_eq "false" "$([[ -f "$CALL_FILE" ]] && echo true || echo false)" "${label}: sends no request"
}

assert_no_request_bad_argument "submit invalid grounding JSON" \
  tasks outputs submit task-1 --type json --label report --grounding 'not json'
assert_no_request_bad_argument "submit truncated grounding JSON" \
  tasks outputs submit task-1 --type json --label report --grounding '{"documents":['
assert_no_request_bad_argument "submit empty grounding" \
  tasks outputs submit task-1 --type json --label report --grounding ''
assert_no_request_bad_argument "submit missing grounding file" \
  tasks outputs submit task-1 --type json --label report --grounding "@${TEST_TMP}/does-not-exist.json"
assert_no_request_bad_argument "submit non-integer contract version" \
  tasks outputs submit task-1 --type json --label report --grounding "$GROUNDING" --grounding-contract-version one
assert_no_request_bad_argument "upload invalid grounding JSON" \
  tasks outputs upload task-1 "$REPORT_FILE" --type file --label report --grounding 'not json'
assert_no_request_bad_argument "upload missing grounding file" \
  tasks outputs upload task-1 "$REPORT_FILE" --type file --label report --grounding "@${TEST_TMP}/does-not-exist.json"
assert_no_request_bad_argument "upload non-integer contract version" \
  tasks outputs upload task-1 "$REPORT_FILE" --type file --label report --grounding-contract-version 1.5

# ─── invalid JSON from stdin is rejected the same way ──────────────────────────
rm -f "$CALL_FILE"
set +e
err=$(printf 'not json' | run_cli tasks outputs submit task-1 --type json --label report --grounding - 2>&1 >/dev/null)
status=$?
set -e
assert_eq "2" "$status" "submit invalid stdin grounding: exit code"
assert_eq "bad_argument" "$(printf '%s' "$err" | "$REAL_JQ" -r '.error.code')" "submit invalid stdin grounding: error code"
assert_eq "false" "$([[ -f "$CALL_FILE" ]] && echo true || echo false)" "submit invalid stdin grounding: sends no request"

# ─── documented everywhere the agent looks ─────────────────────────────────────
"$ROOT_DIR/ark" --help 2>&1 | grep -q -- '--grounding' || fail "ark --help documents --grounding"
"$ROOT_DIR/ark" skills | "$REAL_JQ" -e '.data.workflows.upload_soat_report | length > 0' >/dev/null \
  || fail "ark skills exposes the upload_soat_report workflow"
"$ROOT_DIR/ark" skills | "$REAL_JQ" -e '.data.resource_fields.outputs.grounding' >/dev/null \
  || fail "ark skills documents the grounding output field"

if [[ "$FAILURES" -ne 0 ]]; then
  printf 'FAILED: %s grounding assertion(s)\n' "$FAILURES" >&2
  exit 1
fi

printf 'PASS: outputs grounding tests\n'

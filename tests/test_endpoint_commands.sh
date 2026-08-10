#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

REAL_JQ=$(command -v jq)
CALL_FILE="${TEST_TMP}/call.tsv"
CONFIG_FILE="${TEST_TMP}/config"
printf 'api-key=test-token\n' > "$CONFIG_FILE"

cat > "${TEST_TMP}/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

method="GET"
body=""
body_file=""
header_file=""
url=""
idempotency_key=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data) body="$2"; shift 2 ;;
    --output) body_file="$2"; shift 2 ;;
    --dump-header) header_file="$2"; shift 2 ;;
    --write-out) shift 2 ;;
    -H)
      [[ "$2" == Idempotency-Key:* ]] && idempotency_key="${2#Idempotency-Key: }"
      shift 2
      ;;
    --silent) shift ;;
    *) url="$1"; shift ;;
  esac
done

body_compact="$body"
[[ -z "$body" ]] || body_compact=$(printf '%s' "$body" | jq -c '.')
printf '%s|%s|%s|%s\n' "$method" "$url" "$body_compact" "$idempotency_key" > "$ARK_TEST_CALL_FILE"
printf 'HTTP/1.1 200 OK\r\nX-Request-Id: request-123\r\n\r\n' > "$header_file"

case "$url" in
  */api/tasks/claim-next*)
    response='{"ok":true,"data":{"id":"task-1","status":"in_progress","task_type":"general"},"_links":{"complete":"/tasks/task-1/status"}}'
    ;;
  */api/tasks/task-1/ask-review)
    response='{"ok":true,"data":{"id":"task-1","status":"in_progress"},"_links":{}}'
    ;;
  */api/batches/*/status*)
    response='{"ok":true,"data":{"batch_id":"batch uno","status":"processing"},"meta":{"missing":2}}'
    ;;
  */api/tasks/task-1/inputs/input-1/ocr)
    response='{"ok":true,"data":{"text":"OCR text"}}'
    ;;
  */api/reps/prestadores*)
    response='{"ok":true,"data":[{"nit":"900123"}],"meta":{"count":1,"total":1,"limit":20,"offset":0}}'
    ;;
  */api/reps/servicios*)
    response='{"ok":true,"data":[{"serv_codigo":"123"}],"meta":{"count":1,"total":1,"limit":20,"offset":0}}'
    ;;
  */api/reps/habilitacion/*)
    response='{"ok":true,"data":{"resumen":{"habilitado":true}}}'
    ;;
  *)
    response='{"ok":false,"error":{"code":"unexpected_request","message":"Unexpected test URL"}}'
    ;;
esac

printf '%s' "$response" > "$body_file"
printf '200'
STUB
chmod +x "${TEST_TMP}/curl"

run_cli() {
  ARK_CONFIG_FILE="$CONFIG_FILE" \
  ARK_API_URL="https://api.example.test" \
  ARK_IDEMPOTENCY_KEY="${ARK_IDEMPOTENCY_KEY:-}" \
  ARK_TEST_CALL_FILE="$CALL_FILE" \
  PATH="${TEST_TMP}:$PATH" \
  "$ROOT_DIR/ark" "$@"
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s\nexpected: %s\nactual:   %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

output=$(ARK_IDEMPOTENCY_KEY="claim-key" run_cli tasks claim-next --task-type "audit soat")
assert_eq "task-1" "$(printf '%s' "$output" | "$REAL_JQ" -r '.data.id')" "claim-next response"
IFS='|' read -r method url body idem < "$CALL_FILE"
assert_eq "POST" "$method" "claim-next method"
assert_eq "https://api.example.test/api/tasks/claim-next?task_type=audit%20soat" "$url" "claim-next URL"
assert_eq "claim-key" "$idem" "claim-next idempotency key"

output=$(ARK_IDEMPOTENCY_KEY="review-key" run_cli tasks ask-review task-1 --reason "Check coverage")
IFS='|' read -r method url body idem < "$CALL_FILE"
assert_eq "POST" "$method" "ask-review method"
assert_eq "https://api.example.test/api/tasks/task-1/ask-review" "$url" "ask-review URL"
assert_eq "Check coverage" "$(printf '%s' "$body" | "$REAL_JQ" -r '.body')" "ask-review body"
assert_eq "review-key" "$idem" "ask-review idempotency key"
assert_eq "task-1" "$(printf '%s' "$output" | "$REAL_JQ" -r '.data.id')" "ask-review response"

output=$(run_cli batches status "batch uno" --missing-limit 25)
IFS='|' read -r method url body idem < "$CALL_FILE"
assert_eq "GET" "$method" "batch status method"
assert_eq "https://api.example.test/api/batches/batch%20uno/status?missing_limit=25" "$url" "batch status URL"
assert_eq "2" "$(printf '%s' "$output" | "$REAL_JQ" -r '.meta.missing')" "batch status meta"

output=$(run_cli tasks inputs ocr task-1 input-1)
IFS='|' read -r method url body idem < "$CALL_FILE"
assert_eq "GET" "$method" "OCR method"
assert_eq "https://api.example.test/api/tasks/task-1/inputs/input-1/ocr" "$url" "OCR URL"
assert_eq "OCR text" "$(printf '%s' "$output" | "$REAL_JQ" -r '.data.text')" "OCR response"

output=$(run_cli reps prestadores --razon-social "Clínica Central" --habilitado SI --limit 10 --offset 20)
IFS='|' read -r method url body idem < "$CALL_FILE"
assert_eq "GET" "$method" "prestadores method"
assert_eq "https://api.example.test/api/reps/prestadores?razon_social=Cl%C3%ADnica%20Central&habilitado=SI&limit=10&offset=20" "$url" "prestadores filters"
assert_eq "1" "$(printf '%s' "$output" | "$REAL_JQ" -r '.meta.total')" "prestadores meta"

run_cli reps servicios --codigo-habilitacion 0500100003 --serv-codigo 123 --modalidad telemedicina >/dev/null
IFS='|' read -r method url body idem < "$CALL_FILE"
assert_eq "https://api.example.test/api/reps/servicios?codigo_habilitacion=0500100003&serv_codigo=123&modalidad=telemedicina" "$url" "servicios filters"

output=$(run_cli reps habilitacion "05001/00003")
IFS='|' read -r method url body idem < "$CALL_FILE"
assert_eq "https://api.example.test/api/reps/habilitacion/05001%2F00003" "$url" "habilitacion URL encoding"
assert_eq "true" "$(printf '%s' "$output" | "$REAL_JQ" -r '.data.resumen.habilitado')" "habilitacion response"

set +e
run_cli reps prestadores --limit 0 >/dev/null 2>"${TEST_TMP}/error.json"
status=$?
set -e
assert_eq "2" "$status" "invalid REPS limit exit code"
assert_eq "bad_argument" "$("$REAL_JQ" -r '.error.code' "${TEST_TMP}/error.json")" "invalid REPS limit error"

printf 'PASS: endpoint command tests\n'

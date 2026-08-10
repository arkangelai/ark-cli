#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

fake_bin="$test_tmp/bin"
test_home="$test_tmp/home"
capture_url="$test_tmp/request-url"
mkdir -p "$fake_bin" "$test_home"

cat > "$fake_bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail

output_file=""
header_file=""
request_url=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|--dump-header|--write-out|-X|-H)
      case "$1" in
        --output) output_file="$2" ;;
        --dump-header) header_file="$2" ;;
      esac
      shift 2
      ;;
    --silent)
      shift
      ;;
    *)
      request_url="$1"
      shift
      ;;
  esac
done

printf '%s' "$ARK_TEST_RESPONSE" > "$output_file"
printf 'HTTP/1.1 200 OK\r\n' > "$header_file"
printf '%s\n' "$request_url" > "$ARK_TEST_CAPTURE_URL"
printf '200'
CURL
chmod +x "$fake_bin/curl"

HOME="$test_home" "$repo_root/ark" config set api-key test-key >/dev/null

run_ark() {
  PATH="$fake_bin:$PATH" \
    HOME="$test_home" \
    ARK_API_URL='https://api.example.test' \
    ARK_TEST_CAPTURE_URL="$capture_url" \
    ARK_TEST_RESPONSE="$ARK_TEST_RESPONSE" \
    "$repo_root/ark" "$@"
}

ARK_TEST_RESPONSE='{"data":[],"meta":{"count":0}}'
export ARK_TEST_RESPONSE
run_ark tasks list \
  --status 'needs review' \
  --priority 'high+urgent' \
  --factura-key 'FE 57100' \
  --client-ref 'case+42' \
  --batch-id 'batch/2026' \
  --parent-task-id 'parent?one' \
  --limit 3 \
  --cursor '2026-08-10T12:00:00+00:00' >/dev/null

actual_url=$(<"$capture_url")
expected_url='https://api.example.test/api/tasks?limit=3&status=needs%20review&priority=high%2Burgent&factura_key=FE%2057100&client_ref=case%2B42&batch_id=batch%2F2026&parent_task_id=parent%3Fone&cursor=2026-08-10T12%3A00%3A00%2B00%3A00'
[[ "$actual_url" == "$expected_url" ]] || {
  printf 'List URL mismatch\nExpected: %s\nActual:   %s\n' "$expected_url" "$actual_url" >&2
  exit 1
}

ARK_TEST_RESPONSE='{"data":[{"id":"task-1","status":"review","title":"Factura FE 57100","context":{"private":"omit"}},{"id":"task-2","status":"done","title":"Caso alterno","description":"omit"}],"meta":{"count":2,"next_cursor":"next+page"}}'
export ARK_TEST_RESPONSE
json_output=$(run_ark tasks find 'FE 57100 + siniestro/42' --limit 2 --cursor 'next+page')

actual_url=$(<"$capture_url")
expected_url='https://api.example.test/api/tasks/search?q=FE%2057100%20%2B%20siniestro%2F42&limit=2&cursor=next%2Bpage'
[[ "$actual_url" == "$expected_url" ]] || {
  printf 'Find URL mismatch\nExpected: %s\nActual:   %s\n' "$expected_url" "$actual_url" >&2
  exit 1
}

printf '%s' "$json_output" | jq -e '
  .ok == true and
  .data == [
    {"id":"task-1","status":"review","title":"Factura FE 57100"},
    {"id":"task-2","status":"done","title":"Caso alterno"}
  ] and
  .meta == {"count":2,"next_cursor":"next+page"}
' >/dev/null

human_output=$(run_ark --human tasks find 'FE 57100' --limit 2)
[[ "$human_output" == *'[review] task-1 — Factura FE 57100'* ]]
[[ "$human_output" == *'[done] task-2 — Caso alterno'* ]]
[[ "$human_output" == *'count: 2'* ]]

set +e
missing_output=$(run_ark tasks find 2>&1)
missing_status=$?
unknown_output=$(run_ark tasks find invoice --unknown 2>&1)
unknown_status=$?
set -e

[[ "$missing_status" -eq 2 ]]
printf '%s' "$missing_output" | jq -e '.error.code == "bad_argument" and (.suggestion | contains("ark tasks find"))' >/dev/null
[[ "$unknown_status" -eq 2 ]]
printf '%s' "$unknown_output" | jq -e '.error.code == "bad_argument" and .error.message == "Unknown: --unknown"' >/dev/null

printf 'tasks business filters and find: ok\n'

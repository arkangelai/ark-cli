#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"

# `ark` guards main with BASH_SOURCE, so sourcing exercises the real command
# functions without performing authentication or network requests.
source "${REPO_DIR}/ark"

tests_run=0

fail() {
  echo "not ok - $1" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  tests_run=$((tests_run + 1))
  [[ "$actual" == "$expected" ]] || fail "${message}: expected '${expected}', got '${actual}'"
}

assert_json_eq() {
  local expected="$1" expression="$2" json="$3" message="$4"
  local actual
  actual=$(printf '%s' "$json" | jq -c "$expression")
  assert_eq "$expected" "$actual" "$message"
}

CAPTURED_METHOD=""
CAPTURED_PATH=""

http_request() {
  CAPTURED_METHOD="$1"
  CAPTURED_PATH="$2"
  HTTP_STATUS="200"
  HTTP_BODY='{"data":[{"id":"task-1","status":"blocked","title":"Oldest blocker","created_at":"2026-08-01T10:00:00Z"}],"meta":{"count":1,"next_cursor":"opaque+cursor/value"}}'
  HTTP_REQUEST_ID="request-1"
  HTTP_IDEMPOTENT_REPLAY="false"
}

tmp_output=$(mktemp)
trap 'rm -f "$tmp_output"' EXIT

cmd_tasks_list \
  --status blocked \
  --priority=high \
  --limit 100 \
  --cursor 'opaque+cursor/value' \
  --since '2026-08-01T00:00:00-05:00' \
  --until=2026-08-10 \
  --sort created_at \
  --order=asc \
  --fields id,status,title,created_at >"$tmp_output"

output=$(<"$tmp_output")
assert_eq "GET" "$CAPTURED_METHOD" "list uses GET"
assert_eq "/api/tasks?limit=100&status=blocked&priority=high&cursor=opaque%2Bcursor%2Fvalue&created_after=2026-08-01T00%3A00%3A00-05%3A00&created_before=2026-08-10&sort=created_at&order=asc&fields=id%2Cstatus%2Ctitle%2Ccreated_at" "$CAPTURED_PATH" "all query controls are forwarded and encoded"
assert_json_eq 'true' '.ok' "$output" "success envelope is preserved"
assert_json_eq '1' '.meta.count' "$output" "list metadata is preserved"
assert_json_eq '"Oldest blocker"' '.data[0].title' "$output" "task data is preserved"

cmd_tasks_list --brief >"$tmp_output"
assert_eq "/api/tasks?limit=20&fields=id%2Cstatus%2Ctitle%2Ccreated_at" "$CAPTURED_PATH" "brief uses the minimal projection"

cmd_tasks_list --status queued --limit 1 >"$tmp_output"
assert_eq "/api/tasks?limit=1&status=queued" "$CAPTURED_PATH" "legacy query behavior is preserved"

set +e
invalid_order=$( (cmd_tasks_list --order sideways) 2>&1 )
invalid_order_status=$?
set -e
assert_eq "2" "$invalid_order_status" "invalid order exits with bad-argument status"
assert_json_eq '"bad_argument"' '.error.code' "$invalid_order" "invalid order returns an error envelope"

set +e
invalid_field=$( (cmd_tasks_list --fields id,created-at) 2>&1 )
invalid_field_status=$?
set -e
assert_eq "2" "$invalid_field_status" "invalid field exits with bad-argument status"
assert_json_eq '"Invalid task field: created-at"' '.error.message' "$invalid_field" "invalid field is identified"

cmd_tasks_list --fields id,batch_id,available_at >"$tmp_output"
assert_eq "/api/tasks?limit=20&fields=id%2Cbatch_id%2Cavailable_at" "$CAPTURED_PATH" "new API fields remain forward-compatible"

set +e
conflict=$( (cmd_tasks_list --brief --fields id,title) 2>&1 )
conflict_status=$?
set -e
assert_eq "2" "$conflict_status" "brief and fields conflict exits with bad-argument status"
assert_json_eq '"--brief and --fields cannot be used together"' '.error.message' "$conflict" "projection conflict is explained"

set +e
missing_value=$( (cmd_tasks_list --since) 2>&1 )
missing_value_status=$?
set -e
assert_eq "2" "$missing_value_status" "missing option value exits with bad-argument status"
assert_json_eq '"--since requires a value"' '.error.message' "$missing_value" "missing option value is explained"

set +e
empty_fields=$( (cmd_tasks_list --fields=) 2>&1 )
empty_fields_status=$?
set -e
assert_eq "2" "$empty_fields_status" "empty projection exits with bad-argument status"
assert_json_eq '"--fields requires a value"' '.error.message' "$empty_fields" "empty projection is explained"

echo "ok - ${tests_run} task list assertions passed"

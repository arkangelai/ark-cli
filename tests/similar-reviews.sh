#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../ark
source "$ROOT_DIR/ark"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
tests_run=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_jq() {
  printf '%s' "$1" | jq -e "$2" >/dev/null || fail "jq assertion: $2"
}

test_discovery_contract_and_encoding() (
  local request_log="$TEST_DIR/discovery-request"
  http_request() {
    printf '%s\n' "$2" >"$request_log"
    HTTP_STATUS=200
    HTTP_REQUEST_ID=request-list
    HTTP_IDEMPOTENT_REPLAY=false
    HTTP_BODY='{"ok":true,"data":[{"request":{"method":"POST","href":"/review","body":{}}}],"meta":{"scanned":100,"matched":1,"has_more":false,"next_after_id":null,"snapshot_at":"2026-08-31T13:00:00.000Z"}}'
  }

  local output
  output=$(main tasks similar-reviews list 'scan id' --page-size 100 \
    --after-id 'next+id' --snapshot-at '2026-08-31T13:00:00.000Z' --json)
  assert_jq "$output" '.meta.scanned == 100 and .meta.matched == 1 and .data[0].request.method == "POST"'
  [[ "$(<"$request_log")" == '/api/tasks/scan%20id/similar-reviews?page_size=100&after_id=next%2Bid&snapshot_at=2026-08-31T13%3A00%3A00.000Z' ]] \
    || fail "discovery URL was not encoded exactly"
)

test_discovery_rejects_invalid_contract() (
  http_request() {
    HTTP_STATUS=200
    HTTP_BODY='{"ok":true,"data":[],"meta":{"has_more":true,"next_after_id":null}}'
  }
  local output code
  set +e
  output=$(cmd_tasks_similar_reviews_list scan 2>&1)
  code=$?
  set -e
  [[ "$code" -eq 1 ]] || fail "invalid discovery contract exit code"
  assert_jq "$output" '.error.code == "invalid_response"'
)

test_direct_review_retry_and_body() (
  local attempts_file="$TEST_DIR/review-attempts" body_file="$TEST_DIR/review-body" sleep_file="$TEST_DIR/review-sleep"
  : >"$attempts_file"
  http_request_once() {
    printf 'x\n' >>"$attempts_file"
    printf '%s' "$3" >"$body_file"
    HTTP_REQUEST_ID=request-review
    HTTP_IDEMPOTENT_REPLAY=false
    if [[ "$(wc -l <"$attempts_file" | tr -d ' ')" -eq 1 ]]; then
      HTTP_STATUS=429
      HTTP_RETRY_AFTER=2
      HTTP_BODY='{"ok":false,"error":{"code":"rate_limited","message":"slow down","detail":{}}}'
    else
      HTTP_STATUS=200
      HTTP_RETRY_AFTER=''
      HTTP_BODY='{"ok":true,"data":{"decision":"proposal","proposal":{"field":"value"},"explanation":"applies","changed_paths":["/field"],"target":{"case_id":"case"},"model":{"model":"test"}}}'
    fi
  }
  sleep() { printf '%s\n' "$1" >>"$sleep_file"; }
  ARK_SIMILAR_REVIEW_JITTER_PERCENT=0

  local output
  output=$(main soat corrections similar-review 'case/id' --scan-task-id scan --item-key 'item:1' --baseline-output-id baseline --json 2>"$TEST_DIR/review-stderr")
  assert_jq "$output" '.data.decision == "proposal" and .data.proposal.field == "value"'
  assert_jq "$(<"$body_file")" '. == {scan_task_id:"scan",item_key:"item:1",baseline_output_id:"baseline"}'
  [[ "$(wc -l <"$attempts_file" | tr -d ' ')" -eq 2 ]] || fail "429 retry count"
  [[ "$(<"$sleep_file")" == 2 ]] || fail "Retry-After was not respected"
)

test_direct_review_5xx_retry_and_abstain() (
  local attempts_file="$TEST_DIR/5xx-attempts" sleep_file="$TEST_DIR/5xx-sleep"
  : >"$attempts_file"
  http_request_once() {
    printf 'x\n' >>"$attempts_file"
    HTTP_REQUEST_ID=request-review HTTP_IDEMPOTENT_REPLAY=false
    if [[ "$(wc -l <"$attempts_file" | tr -d ' ')" -eq 1 ]]; then
      HTTP_STATUS=503 HTTP_RETRY_AFTER=3
      HTTP_BODY='{"ok":false,"error":{"code":"unavailable","message":"retry","detail":{}}}'
    else
      HTTP_STATUS=200 HTTP_RETRY_AFTER=''
      HTTP_BODY='{"ok":true,"data":{"decision":"abstain","proposal":null,"explanation":"no match","changed_paths":[],"target":{},"model":{}}}'
    fi
  }
  sleep() { printf '%s\n' "$1" >"$sleep_file"; }
  local output
  output=$(cmd_soat_corrections_similar_review case --scan-task-id scan --item-key item --baseline-output-id baseline 2>/dev/null)
  assert_jq "$output" '.data.decision == "abstain" and .data.proposal == null'
  [[ "$(wc -l <"$attempts_file" | tr -d ' ')" -eq 2 && "$(<"$sleep_file")" == 3 ]] || fail "5xx Retry-After handling"
)

test_direct_review_network_exhaustion_and_no_4xx_retry() (
  local attempts_file="$TEST_DIR/network-attempts"
  : >"$attempts_file"
  http_request_once() {
    printf 'x\n' >>"$attempts_file"
    HTTP_STATUS=000 HTTP_BODY='' HTTP_REQUEST_ID=''
    return 7
  }
  sleep() { :; }
  ARK_SIMILAR_REVIEW_MAX_RETRIES=1
  local output code
  set +e
  output=$(cmd_soat_corrections_similar_review case --scan-task-id scan --item-key item --baseline-output-id baseline 2>&1)
  code=$?
  set -e
  [[ "$code" -eq 1 ]] || fail "network exhaustion exit code"
  assert_jq "$(printf '%s\n' "$output" | sed -n '/^{/,$p')" '.error.status == 503 and .error.code == "network_error" and .error.detail.attempts == 2'

  : >"$attempts_file"
  http_request_once() {
    printf 'x\n' >>"$attempts_file"
    HTTP_STATUS=409
    HTTP_BODY='{"ok":false,"error":{"code":"stale_execution","message":"stale","detail":{}}}'
  }
  set +e
  output=$(cmd_soat_corrections_similar_review case --scan-task-id scan --item-key item --baseline-output-id baseline 2>&1)
  code=$?
  set -e
  [[ "$code" -eq 5 ]] || fail "409 exit code"
  [[ "$(wc -l <"$attempts_file" | tr -d ' ')" -eq 1 ]] || fail "409 was retried"
  assert_jq "$output" '.error.status == 409 and .error.code == "stale_execution"'
)

test_sensitive_debug_redaction() (
  curl() {
    local output_file='' header_file=''
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output) shift; output_file="$1" ;;
        --dump-header) shift; header_file="$1" ;;
      esac
      shift || true
    done
    printf '%s' '{"ok":true,"data":{"proposal":{"secret":"sensitive"}}}' >"$output_file"
    printf 'HTTP/1.1 200 OK\r\nX-Request-Id: request-redacted\r\n\r\n' >"$header_file"
    printf 200
  }
  resolve_api_key() { printf secret-api-key; }
  resolve_api_url() { printf http://example.test; }
  ARK_DEBUG=2
  http_request_once POST /review '{"proposal":"sensitive"}' '' '' true 2>"$TEST_DIR/redacted-stderr"
  grep -q 'body=\[REDACTED\]' "$TEST_DIR/redacted-stderr" || fail "sensitive body not redacted"
  ! grep -q 'sensitive\|secret-api-key' "$TEST_DIR/redacted-stderr" || fail "secret leaked to stderr"
)

test_literal_aliases_and_run_fencing() (
  local request_body="$TEST_DIR/alias-body" worker_file="$TEST_DIR/worker"
  http_request() {
    printf '%s' "$3" >"$request_body"
    printf '%s' "${5:-}" >"$worker_file"
    HTTP_STATUS=201 HTTP_REQUEST_ID=request-alias HTTP_IDEMPOTENT_REPLAY=false
    case "$2" in
      */claim-next*) HTTP_BODY='{"ok":true,"data":{"task":{"id":"task-1"},"assignment":{}}}' ;;
      */outputs) HTTP_BODY='{"ok":true,"data":{"label":"report"}}' ;;
      */status) HTTP_STATUS=200; HTTP_BODY='{"ok":true,"data":{"id":"task-1","status":"done"}}' ;;
    esac
  }

  local output report="$TEST_DIR/report.json"
  output=$(main tasks claim-next --worker-id worker-literal --json)
  assert_jq "$output" '.data.task.id == "task-1"'
  [[ "$(<"$worker_file")" == worker-literal ]] || fail "worker-id was not propagated"

  printf '{"schema_version":1,"results":[]}' >"$report"
  output=$(main tasks outputs create task-1 --output-type json --label report --run-id run-1 --data-file "$report" --json)
  assert_jq "$output" '.meta.http_status == 201 and .data.label == "report"'
  assert_jq "$(<"$request_body")" '.output_type == "json" and .run_id == "run-1" and .data.schema_version == 1'

  output=$(main tasks status task-1 --status done --confidence-score 1 --run-id run-1 --json)
  assert_jq "$output" '.data.status == "done"'
  assert_jq "$(<"$request_body")" '.status == "done" and .confidence_score == 1 and .run_id == "run-1"'
)

test_data_file_validation_and_limit() (
  http_request() { fail "HTTP called for invalid local file"; }
  local invalid="$TEST_DIR/invalid.json" exact="$TEST_DIR/exact.json" output code
  printf '{invalid' >"$invalid"
  set +e
  output=$(cmd_tasks_outputs_submit task --output-type json --label report --data-file "$invalid" 2>&1)
  code=$?
  set -e
  [[ "$code" -eq 2 && -f "$invalid" ]] || fail "invalid JSON handling"
  assert_jq "$output" '.error.code == "bad_argument"'

  printf '"' >"$exact"
  dd if=/dev/zero bs=511998 count=1 2>/dev/null | tr '\0' a >>"$exact"
  printf '"' >>"$exact"
  set +e
  output=$(cmd_tasks_outputs_submit task --output-type json --label report --data-file "$exact" 2>&1)
  code=$?
  set -e
  [[ "$code" -eq 2 && -f "$exact" ]] || fail "500 KiB handling"
  assert_jq "$output" '.error.code == "payload_too_large" and .error.detail.max_bytes_exclusive == 512000'
)

run_test() {
  local name="$1"
  "$name"
  tests_run=$((tests_run + 1))
  printf 'ok - %s\n' "$name"
}

run_test test_discovery_contract_and_encoding
run_test test_discovery_rejects_invalid_contract
run_test test_direct_review_retry_and_body
run_test test_direct_review_5xx_retry_and_abstain
run_test test_direct_review_network_exhaustion_and_no_4xx_retry
run_test test_sensitive_debug_redaction
run_test test_literal_aliases_and_run_fencing
run_test test_data_file_validation_and_limit
printf '%s similar-review tests passed\n' "$tests_run"

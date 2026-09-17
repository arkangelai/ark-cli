#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ARK="$ROOT/ark"
ORIGINAL_PATH="$PATH"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

pass_count=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "expected [$2], got [$1] — ${3:-}"
}

assert_jq() {
  jq -e "$2" "$1" >/dev/null || fail "jq assertion failed: $2"
}

setup_case() {
  local scenario="$1"
  CASE_DIR=$(mktemp -d "$TEST_ROOT/case.XXXXXX")
  export HOME="$CASE_DIR/home"
  mkdir -p "$HOME/.config/ark"
  printf 'url=http://fake.test\napi-key=test-key\n' >"$HOME/.config/ark/config"
  export PATH="$ROOT/tests/bin:$ORIGINAL_PATH"
  export FAKE_CURL_SCENARIO="$scenario"
  export FAKE_CURL_LOG="$CASE_DIR/curl.log"
  export FAKE_CURL_STATE="$CASE_DIR/curl.state"
  export FAKE_SLEEP_LOG="$CASE_DIR/sleep.log"
  export ARK_CLAIM_JITTER_PERCENT=0
  export ARK_CLAIM_BACKOFF_BASE_SECONDS=1
  export ARK_CLAIM_MAX_RETRIES=3
  unset ARK_IDEMPOTENCY_KEY ARK_WORKER_ID ARK_API_URL ARK_API_KEY ARK_CONFIG_FILE ARK_FORMAT ARK_DEBUG
  : >"$FAKE_CURL_LOG"
  : >"$FAKE_SLEEP_LOG"
}

run_claim() {
  set +e
  "$ARK" tasks claim-next >"$CASE_DIR/out.json" 2>"$CASE_DIR/err.json"
  RUN_CODE=$?
  set -e
}

test_contract_and_headers() {
  setup_case task
  export ARK_WORKER_ID=worker-alpha
  export ARK_IDEMPOTENCY_KEY=poll-1
  run_claim
  assert_eq "$RUN_CODE" 0 "claimed response"
  assert_jq "$CASE_DIR/out.json" '.data.task.id == "task-1" and .data.assignment.kind == "parent"'
  assert_eq "$(cut -f1 "$FAKE_CURL_LOG")" POST "HTTP method"
  assert_eq "$(cut -f2 "$FAKE_CURL_LOG")" http://fake.test/api/tasks/claim-next "endpoint"
  assert_eq "$(cut -f3 "$FAKE_CURL_LOG")" poll-1 "idempotency header"
  assert_eq "$(cut -f4 "$FAKE_CURL_LOG")" worker-alpha "worker header"
  assert_eq "$(cut -f5 "$FAKE_CURL_LOG")" absent "claim-next body"
  pass_count=$((pass_count + 1))
}

test_empty_queue_and_replay() {
  setup_case empty
  run_claim
  assert_eq "$RUN_CODE" 0 "empty queue"
  assert_jq "$CASE_DIR/out.json" '.data == null'

  setup_case replay
  run_claim
  assert_eq "$RUN_CODE" 0 "replay"
  assert_jq "$CASE_DIR/out.json" '.idempotent_replay == true and .data.task.id == "task-1"'
  pass_count=$((pass_count + 1))
}

test_stable_machine_worker_id() {
  setup_case task
  run_claim
  run_claim
  assert_eq "$(cut -f4 "$FAKE_CURL_LOG" | sort -u | wc -l | tr -d ' ')" 1 "stable derived worker ID"
  [[ -n "$(cut -f4 "$FAKE_CURL_LOG" | head -1)" ]] || fail "worker ID header is empty"
  pass_count=$((pass_count + 1))
}

test_permanent_errors_do_not_retry() {
  local scenario expected
  for scenario in 401 403 409 422; do
    setup_case "$scenario"
    case "$scenario" in 401|403) expected=3 ;; *) expected=5 ;; esac
    run_claim
    assert_eq "$RUN_CODE" "$expected" "$scenario exit code"
    assert_eq "$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')" 1 "$scenario call count"
    assert_jq "$CASE_DIR/err.json" '.error.retryable == false'
  done
  pass_count=$((pass_count + 1))
}

test_rate_limit_reuses_key_and_retry_after() {
  setup_case 429-then-task
  export ARK_IDEMPOTENCY_KEY=poll-rate-limit
  run_claim
  assert_eq "$RUN_CODE" 0 "429 recovery"
  assert_eq "$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')" 2 "429 call count"
  assert_eq "$(cut -f3 "$FAKE_CURL_LOG" | sort -u)" poll-rate-limit "429 idempotency key"
  assert_eq "$(<"$FAKE_SLEEP_LOG")" 2 "Retry-After delay"
  pass_count=$((pass_count + 1))
}

test_transient_server_and_network_errors() {
  local scenario
  for scenario in 500-then-task network-then-task; do
    setup_case "$scenario"
    export ARK_IDEMPOTENCY_KEY="poll-$scenario"
    run_claim
    assert_eq "$RUN_CODE" 0 "$scenario recovery"
    assert_eq "$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')" 2 "$scenario call count"
    assert_eq "$(cut -f3 "$FAKE_CURL_LOG" | sort -u | wc -l | tr -d ' ')" 1 "$scenario same key"
    assert_eq "$(<"$FAKE_SLEEP_LOG")" 1 "$scenario backoff"
  done
  pass_count=$((pass_count + 1))
}

test_exhausted_network_opens_circuit() {
  setup_case always-network
  export ARK_CLAIM_MAX_RETRIES=1
  export ARK_IDEMPOTENCY_KEY=poll-ambiguous
  run_claim
  assert_eq "$RUN_CODE" 1 "exhausted network"
  assert_eq "$(wc -l <"$FAKE_CURL_LOG" | tr -d ' ')" 2 "bounded network attempts"
  assert_jq "$CASE_DIR/err.json" '.error.code == "network_error" and .error.detail.idempotency_key == "poll-ambiguous" and .error.detail.attempts == 2'
  pass_count=$((pass_count + 1))
}

test_invalid_contract_is_rejected() {
  setup_case invalid
  run_claim
  assert_eq "$RUN_CODE" 1 "invalid contract"
  assert_jq "$CASE_DIR/err.json" '.error.code == "invalid_response" and .error.retryable == false'
  pass_count=$((pass_count + 1))
}

test_concurrent_claims_are_disjoint() {
  setup_case concurrent
  export ARK_WORKER_ID=soak-worker
  local outputs="$CASE_DIR/outputs"
  mkdir -p "$outputs"
  local pids=() i
  for i in $(seq 1 24); do
    ARK_IDEMPOTENCY_KEY="soak-poll-$i" "$ARK" tasks claim-next >"$outputs/$i.json" 2>"$outputs/$i.err" &
    pids+=("$!")
  done
  for i in "${pids[@]}"; do wait "$i" || fail "concurrent claim process failed"; done

  assert_eq "$(jq -r '.data.task.id' "$outputs"/*.json | wc -l | tr -d ' ')" 24 "soak result count"
  assert_eq "$(jq -r '.data.task.id' "$outputs"/*.json | sort -u | wc -l | tr -d ' ')" 24 "disjoint task IDs"
  assert_eq "$(cut -f3 "$FAKE_CURL_LOG" | sort -u | wc -l | tr -d ' ')" 24 "unique logical poll keys"
  pass_count=$((pass_count + 1))
}

test_contract_and_headers
test_empty_queue_and_replay
test_stable_machine_worker_id
test_permanent_errors_do_not_retry
test_rate_limit_reuses_key_and_retry_after
test_transient_server_and_network_errors
test_exhausted_network_opens_circuit
test_invalid_contract_is_rejected
test_concurrent_claims_are_disjoint

printf 'PASS: %s claim-next test groups\n' "$pass_count"

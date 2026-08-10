#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ARK="$ROOT_DIR/ark"
tests_run=0

assert_jq() {
  local json="$1" expression="$2"
  printf '%s' "$json" | jq -e "$expression" >/dev/null
}

test_stats_json() {
  local output
  output=$(
    source "$ARK"
    http_request() {
      [[ "$1" == "GET" && "$2" == "/api/tasks/stats" ]]
      HTTP_STATUS="200"
      HTTP_BODY='{"ok":true,"data":{"queued":2,"in_progress":3,"blocked":5,"review":12000,"done":42}}'
      HTTP_REQUEST_ID="request-stats"
      HTTP_IDEMPOTENT_REPLAY="false"
    }
    cmd_tasks_stats
  )

  assert_jq "$output" '.ok == true'
  assert_jq "$output" '.data.review == 12000 and .data.blocked == 5'
  assert_jq "$output" '.request_id == "request-stats"'
}

test_stats_human() {
  local output
  output=$(
    source "$ARK"
    HUMAN_OUTPUT=true
    http_request() {
      [[ "$1" == "GET" && "$2" == "/api/tasks/stats" ]]
      HTTP_STATUS="200"
      HTTP_BODY='{"ok":true,"data":{"queued":2,"blocked":5}}'
    }
    cmd_tasks_stats
  )

  [[ "$output" == $'queued: 2\nblocked: 5' ]]
}

test_stats_dispatch() {
  local output
  output=$(
    source "$ARK"
    http_request() {
      [[ "$1" == "GET" && "$2" == "/api/tasks/stats" ]]
      HTTP_STATUS="200"
      HTTP_BODY='{"ok":true,"data":{"queued":7}}'
      HTTP_REQUEST_ID="request-dispatch"
      HTTP_IDEMPOTENT_REPLAY="false"
    }
    main tasks stats
  )

  assert_jq "$output" '.data.queued == 7'
}

test_stats_rejects_arguments() {
  local output exit_code
  set +e
  output=$( {
    source "$ARK"
    cmd_tasks_stats --status queued
  } 2>&1)
  exit_code=$?
  set -e

  [[ "$exit_code" -eq 2 ]]
  assert_jq "$output" '.error.code == "bad_argument"'
}

test_stats_preserves_http_errors() {
  local output exit_code
  set +e
  output=$( {
    source "$ARK"
    http_request() {
      HTTP_STATUS="404"
      HTTP_BODY='{"ok":false,"error":{"code":"not_found","message":"Route not found","detail":{}}}'
      HTTP_REQUEST_ID="request-missing"
    }
    cmd_tasks_stats
  } 2>&1)
  exit_code=$?
  set -e

  [[ "$exit_code" -eq 4 ]]
  assert_jq "$output" '.error.code == "not_found" and .request_id == "request-missing"'
}

test_list_all_follows_cursor() {
  local output
  output=$(
    source "$ARK"
    request_number=0
    http_request() {
      request_number=$((request_number + 1))
      HTTP_STATUS="200"
      HTTP_REQUEST_ID="request-list-${request_number}"
      HTTP_IDEMPOTENT_REPLAY="false"
      if [[ "$2" == "/api/tasks?limit=100&status=review" ]]; then
        HTTP_BODY='{"ok":true,"data":[{"id":"one"},{"id":"two"}],"meta":{"count":2,"next_cursor":"cursor+2:next"}}'
      elif [[ "$2" == "/api/tasks?limit=100&status=review&cursor=cursor%2B2%3Anext" ]]; then
        HTTP_BODY='{"ok":true,"data":[{"id":"three"}],"meta":{"count":1,"next_cursor":null}}'
      else
        return 1
      fi
    }
    cmd_tasks_list --status review --all
  )

  assert_jq "$output" '.data | map(.id) == ["one", "two", "three"]'
  assert_jq "$output" '.meta.count == 3 and .meta.next_cursor == null'
}

test_list_all_human_includes_every_page() {
  local output
  output=$(
    source "$ARK"
    HUMAN_OUTPUT=true
    http_request() {
      HTTP_STATUS="200"
      if [[ "$2" == "/api/tasks?limit=100" ]]; then
        HTTP_BODY='{"ok":true,"data":[{"id":"one","status":"review","title":"First"}],"meta":{"count":1,"next_cursor":"cursor-2"}}'
      elif [[ "$2" == "/api/tasks?limit=100&cursor=cursor-2" ]]; then
        HTTP_BODY='{"ok":true,"data":[{"id":"two","status":"review","title":"Second"}],"meta":{"count":1,"next_cursor":null}}'
      else
        return 1
      fi
    }
    cmd_tasks_list --all
  )

  [[ "$output" == $'[review] one — First\n[review] two — Second\ncount: 2' ]]
}

run_test() {
  local name="$1"
  "$name"
  tests_run=$((tests_run + 1))
  printf 'ok - %s\n' "$name"
}

run_test test_stats_json
run_test test_stats_human
run_test test_stats_dispatch
run_test test_stats_rejects_arguments
run_test test_stats_preserves_http_errors
run_test test_list_all_follows_cursor
run_test test_list_all_human_includes_every_page
printf '%s tests passed\n' "$tests_run"

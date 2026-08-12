#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARK_BIN="${ROOT_DIR}/ark"
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/ark-config-test.XXXXXX")"

cleanup() {
  rm -rf -- "$TEST_HOME"
}
trap cleanup EXIT

export HOME="$TEST_HOME"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  [[ "$actual" == "$expected" ]] || fail "$message (expected '$expected', got '$actual')"
}

api_key="ark_live_test_secret_value"
set_output="$("$ARK_BIN" config set api-key "$api_key")"

assert_eq "api-key" "$(jq -r '.data.key' <<< "$set_output")" \
  "config set should identify the updated key"
assert_eq "ark_***" "$(jq -r '.data.value' <<< "$set_output")" \
  "config set should mask api-key values"
if grep -Fq "$api_key" <<< "$set_output"; then
  fail "config set output exposed the full api-key"
fi

config_file="${HOME}/.config/ark/config"
assert_eq "api-key=${api_key}" "$(grep '^api-key=' "$config_file")" \
  "config set should persist the full api-key"

config_mode="$(stat -c '%a' "$config_file" 2>/dev/null || stat -f '%Lp' "$config_file")"
assert_eq "600" "$config_mode" "config file should remain owner-readable only"

list_output="$("$ARK_BIN" config list)"
assert_eq "ark_***" "$(jq -r '.data["api-key"]' <<< "$list_output")" \
  "config list should use the same api-key masking rule"
if grep -Fq "$api_key" <<< "$list_output"; then
  fail "config list output exposed the full api-key"
fi

short_key="abc"
short_output="$("$ARK_BIN" config set api-key "$short_key")"
assert_eq "***" "$(jq -r '.data.value' <<< "$short_output")" \
  "short api-key values should be fully masked"
if grep -Fq "$short_key" <<< "$short_output"; then
  fail "config set output exposed a short api-key"
fi

api_url="https://api.example.test"
url_output="$("$ARK_BIN" config set url "$api_url")"
assert_eq "$api_url" "$(jq -r '.data.value' <<< "$url_output")" \
  "config set should continue echoing non-sensitive values"

printf 'PASS: config output masks api-key values\n'

#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ark_bin="${repo_dir}/ark"
fixture_dir="${repo_dir}/tests/fixtures"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

assert_jq() {
  local json="$1" expression="$2" message="$3"
  if ! printf '%s' "$json" | jq -e "$expression" >/dev/null; then
    printf 'FAIL: %s\n%s\n' "$message" "$json" >&2
    exit 1
  fi
}

canonical=$(
  "$ark_bin" --dry-run tasks comments post task-1 \
    --label blocker --body "Missing OCR"
)
assert_jq "$canonical" \
  '.data.would_send.body == {body:"Missing OCR",label:"blocker"}' \
  "--label should populate the API label field"

compatibility=$(
  "$ark_bin" --dry-run tasks comments post task-1 \
    --type blocker --body "Missing OCR"
)
assert_jq "$compatibility" \
  '.data.would_send.body == {body:"Missing OCR",label:"blocker"}' \
  "--type should remain a backward-compatible alias"

set +e
missing_label=$("$ark_bin" --dry-run tasks comments post task-1 --body "Missing OCR" 2>&1)
missing_label_status=$?
set -e
[[ $missing_label_status -eq 2 ]] || {
  printf 'FAIL: missing --label should exit 2, got %s\n' "$missing_label_status" >&2
  exit 1
}
assert_jq "$missing_label" \
  '.error.message == "--label and --body are required" and (.suggestion | contains("--label <label>"))' \
  "validation should teach the canonical --label spelling"

comments_help=$("$ark_bin" --help 2>&1 | awk '/^COMMENTS$/{found=1} /^OUTPUTS$/{found=0} found')
printf '%s' "$comments_help" | grep -Fq -- '--label=note|blocker|comment|approved|changes_requested' || {
  printf 'FAIL: comments help should document --label\n' >&2
  exit 1
}
if printf '%s' "$comments_help" | grep -Fq -- '--type'; then
  printf 'FAIL: comments help should keep the compatibility alias hidden\n' >&2
  exit 1
fi

skills=$("$ark_bin" skills)
assert_jq "$skills" \
  '.data.enums.comment_label == ["note","blocker","comment","approved","changes_requested"] and
   .data.resource_fields.comments.label and
   .data.resource_fields.outputs.output_type and
   .data.resource_fields.events.actor_type and
   .data.resource_fields.tasks.created_by_type' \
  "ark skills should document resource field names"

mkdir -p "${test_dir}/home/.config/ark"
printf 'api-key=test-key\nurl=http://example.test\n' > "${test_dir}/home/.config/ark/config"
human_output=$(
  HOME="${test_dir}/home" \
  PATH="${fixture_dir}:${PATH}" \
  MOCK_CURL_BODY='{"data":[{"label":"blocker","author_type":"agent","body":"Missing OCR"}]}' \
  "$ark_bin" --human tasks comments list task-1
)
[[ "$human_output" == '[blocker] agent: Missing OCR' ]] || {
  printf 'FAIL: human output should expose the comment label, got: %s\n' "$human_output" >&2
  exit 1
}

printf 'PASS: comments flag and field-name regression checks\n'

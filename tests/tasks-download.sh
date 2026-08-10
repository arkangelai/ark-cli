#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

fake_bin="$test_tmp/bin"
config_file="$test_tmp/config"
request_log="$test_tmp/requests.log"
mkdir -p "$fake_bin"
printf 'api-key=test-key\n' > "$config_file"

cat > "$fake_bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail

output_file=""
header_file=""
request_url=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|--dump-header|--write-out|-X|-H|--data)
      case "$1" in
        --output) output_file="$2" ;;
        --dump-header) header_file="$2" ;;
      esac
      shift 2
      ;;
    --fail|--silent|--show-error|--location)
      shift
      ;;
    *)
      request_url="$1"
      shift
      ;;
  esac
done

printf '%s\n' "$request_url" >> "$ARK_TEST_REQUEST_LOG"

case "$request_url" in
  */api/tasks/task%2F1/outputs)
    response="$ARK_TEST_OUTPUTS_RESPONSE"
    ;;
  */api/tasks/task%2F1/documents/output/report%2F3/url)
    if [[ "${ARK_TEST_MISSING_URL:-false}" == "true" ]]; then
      response='{"data":{"expires_at":"2026-08-10T18:00:00Z"}}'
    else
      response='{"data":{"url":"https://storage.example/latest-report","expires_at":"2026-08-10T18:00:00Z","storage_path":"storage://task-outputs/report-3.json"}}'
    fi
    ;;
  */api/tasks/task%2F1/documents/output/report-1/url)
    response='{"data":{"url":"https://storage.example/report-v1","expires_at":"2026-08-10T18:00:00Z","storage_path":"storage://task-outputs/report-1.json"}}'
    ;;
  */api/tasks/task%2F1/documents/output/artifact-2/url)
    response='{"data":{"url":"https://storage.example/artifact-v2","expires_at":"2026-08-10T18:00:00Z","storage_path":"storage://task-outputs/artifact-2.bin"}}'
    ;;
  */api/tasks/task%2F1/documents/input/input%2F9/url)
    response='{"data":{"url":"https://storage.example/input-9","expires_at":"2026-08-10T18:00:00Z","storage_path":"storage://task-inputs/input-9.csv"}}'
    ;;
  https://storage.example/*)
    if [[ "${ARK_TEST_FAIL_DOWNLOAD:-false}" == "true" ]]; then
      exit 22
    fi
    case "$request_url" in
      */latest-report) payload='{"decision":"latest"}' ;;
      */report-v1) payload='{"decision":"old"}' ;;
      */artifact-v2) payload='artifact bytes' ;;
      */input-9) payload='folio,total\nA-9,42' ;;
    esac
    if [[ -n "$output_file" ]]; then
      printf '%b' "$payload" > "$output_file"
    else
      printf '%b' "$payload"
    fi
    exit 0
    ;;
  *)
    response='{"error":{"code":"unexpected_request","message":"Unexpected test URL"}}'
    ;;
esac

printf '%s' "$response" > "$output_file"
[[ -z "$header_file" ]] || printf 'HTTP/1.1 200 OK\r\nX-Request-Id: request-123\r\n\r\n' > "$header_file"
printf '200'
CURL
chmod +x "$fake_bin/curl"

run_ark() {
  PATH="$fake_bin:$PATH" \
    ARK_CONFIG_FILE="$config_file" \
    ARK_API_URL='https://api.example.test' \
    ARK_TEST_REQUEST_LOG="$request_log" \
    ARK_TEST_OUTPUTS_RESPONSE="$ARK_TEST_OUTPUTS_RESPONSE" \
    ARK_TEST_MISSING_URL="${ARK_TEST_MISSING_URL:-false}" \
    ARK_TEST_FAIL_DOWNLOAD="${ARK_TEST_FAIL_DOWNLOAD:-false}" \
    "$repo_root/ark" "$@"
}

ARK_TEST_OUTPUTS_RESPONSE='{"data":[
  {"id":"report-1","label":"report","version":1,"output_type":"json"},
  {"id":"artifact-2","label":"artifact","version":2,"output_type":"file"},
  {"id":"report/3","label":"report","version":3,"output_type":"json"},
  {"id":"report-2","label":"report","version":2,"output_type":"json"}
]}'
export ARK_TEST_OUTPUTS_RESPONSE

latest=$(run_ark tasks outputs download 'task/1')
[[ "$latest" == '{"decision":"latest"}' ]]
tail -n 3 "$request_log" | grep -Fx 'https://api.example.test/api/tasks/task%2F1/outputs' >/dev/null
tail -n 3 "$request_log" | grep -Fx 'https://api.example.test/api/tasks/task%2F1/documents/output/report%2F3/url' >/dev/null
tail -n 3 "$request_log" | grep -Fx 'https://storage.example/latest-report' >/dev/null

old=$(run_ark tasks outputs download 'task/1' --version 1)
[[ "$old" == '{"decision":"old"}' ]]
tail -n 2 "$request_log" | grep -Fx 'https://api.example.test/api/tasks/task%2F1/documents/output/report-1/url' >/dev/null

artifact_file="$test_tmp/artifact.bin"
artifact_response=$(run_ark tasks outputs download 'task/1' --label artifact --version 2 -o "$artifact_file")
[[ "$(<"$artifact_file")" == 'artifact bytes' ]]
printf '%s' "$artifact_response" | jq -e \
  --arg local_path "$artifact_file" '
    .ok == true and
    .data.task_id == "task/1" and
    .data.output_id == "artifact-2" and
    .data.label == "artifact" and
    .data.version == 2 and
    .data.local_path == $local_path and
    .data.size_bytes == 14
  ' >/dev/null

input=$(run_ark tasks inputs download 'task/1' 'input/9')
[[ "$input" == $'folio,total\nA-9,42' ]]

input_file="$test_tmp/input.csv"
input_response=$(run_ark tasks inputs download 'task/1' 'input/9' --output="$input_file")
[[ "$(<"$input_file")" == $'folio,total\nA-9,42' ]]
printf '%s' "$input_response" | jq -e \
  --arg local_path "$input_file" '
    .ok == true and
    .data.task_id == "task/1" and
    .data.input_id == "input/9" and
    .data.kind == "input" and
    .data.local_path == $local_path and
    .data.size_bytes == 18
  ' >/dev/null

set +e
invalid_version=$(run_ark tasks outputs download 'task/1' --version nope 2>&1)
invalid_status=$?
missing_output_path=$(run_ark tasks inputs download 'task/1' 'input/9' --output= 2>&1)
missing_output_path_status=$?

ARK_TEST_OUTPUTS_RESPONSE='{"data":[{"id":"artifact-2","label":"artifact","version":2,"output_type":"file"}]}'
missing_output=$(run_ark tasks outputs download 'task/1' 2>&1)
missing_status=$?

ARK_TEST_OUTPUTS_RESPONSE='{"data":[{"id":"report/3","label":"report","version":3,"output_type":"json"}]}'
ARK_TEST_MISSING_URL=true
missing_url=$(run_ark tasks outputs download 'task/1' 2>&1)
missing_url_status=$?

ARK_TEST_MISSING_URL=false
ARK_TEST_FAIL_DOWNLOAD=true
failed_download=$(run_ark tasks outputs download 'task/1' 2>&1)
failed_download_status=$?
set -e

[[ "$invalid_status" -eq 2 ]]
printf '%s' "$invalid_version" | jq -e '.error.code == "bad_argument"' >/dev/null
[[ "$missing_output_path_status" -eq 2 ]]
printf '%s' "$missing_output_path" | jq -e '.error.code == "bad_argument"' >/dev/null
[[ "$missing_status" -eq 4 ]]
printf '%s' "$missing_output" | jq -e '.error.code == "not_found" and .error.detail.label == "report"' >/dev/null
[[ "$missing_url_status" -eq 1 ]]
printf '%s' "$missing_url" | jq -e '.error.code == "storage_error"' >/dev/null
[[ "$failed_download_status" -eq 1 ]]
printf '%s' "$failed_download" | jq -e '.error.code == "network_error" and .error.retryable == true' >/dev/null

printf 'task output and input downloads: ok\n'

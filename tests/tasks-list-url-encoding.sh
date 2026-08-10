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

printf '{"data":[],"meta":{"count":0}}' > "$output_file"
printf 'HTTP/1.1 200 OK\r\n' > "$header_file"
printf '%s\n' "$request_url" > "$ARK_TEST_CAPTURE_URL"
printf '200'
CURL
chmod +x "$fake_bin/curl"

HOME="$test_home" "$repo_root/ark" config set api-key test-key >/dev/null

cursor='2026-08-04T21:42:23.253953+00:00'
PATH="$fake_bin:$PATH" \
  HOME="$test_home" \
  ARK_API_URL='https://api.example.test' \
  ARK_TEST_CAPTURE_URL="$capture_url" \
  "$repo_root/ark" tasks list \
    --status 'needs review' \
    --priority 'high+urgent' \
    --limit 3 \
    --cursor "$cursor" >/dev/null

actual_url=$(<"$capture_url")
expected_url='https://api.example.test/api/tasks?limit=3&status=needs%20review&priority=high%2Burgent&cursor=2026-08-04T21%3A42%3A23.253953%2B00%3A00'

if [[ "$actual_url" != "$expected_url" ]]; then
  printf 'Expected URL:\n  %s\nActual URL:\n  %s\n' "$expected_url" "$actual_url" >&2
  exit 1
fi

printf 'tasks list URL encoding: ok\n'

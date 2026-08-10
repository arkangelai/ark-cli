#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ark-install-test.XXXXXX")"

cleanup() {
  rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "$2 (missing: $1)"
}

assert_not_exists() {
  [[ ! -e "$1" ]] || fail "$2 (unexpected: $1)"
}

make_fixture() {
  local fixture_dir="$1"
  mkdir -p "$fixture_dir/scripts" "$fixture_dir/skills"
  cp "$ROOT_DIR/install.sh" "$fixture_dir/install.sh"
  cp "$ROOT_DIR/skill.sh" "$fixture_dir/skill.sh"
  printf 'console.log("fixture");\n' > "$fixture_dir/scripts/fixture.ts"
  printf '%s\n' '# Fixture skill' > "$fixture_dir/skills/SKILL.md"
  cat > "$fixture_dir/ark" <<'ARK'
#!/usr/bin/env bash
ARK_VERSION="9.9.9"
set -euo pipefail
if [[ "${1:-}" != "version" ]]; then
  exit 2
fi
printf 'version\n' >> "${ARK_INSTALL_TEST_LOG:?}"
printf '{"ok":true,"cli_version":"%s","data":{"name":"tasks-ark","version":"%s"}}\n' "$ARK_VERSION" "$ARK_VERSION"
ARK
  chmod +x "$fixture_dir/ark"
}

# Explicit destinations install all shared data outside the binary directory.
explicit_fixture="$TEST_DIR/explicit-source"
explicit_prefix="$TEST_DIR/explicit prefix/bin"
explicit_share="$TEST_DIR/explicit share"
explicit_log="$TEST_DIR/explicit-version.log"
make_fixture "$explicit_fixture"

explicit_output=$(
  ARK_INSTALL_TEST_LOG="$explicit_log" \
    bash "$explicit_fixture/install.sh" \
      --prefix "$explicit_prefix" \
      --share-dir "$explicit_share"
)

assert_file "$explicit_prefix/ark" "installer should copy ark to --prefix"
assert_file "$explicit_prefix/skill.sh" "installer should copy skill.sh to --prefix"
assert_file "$explicit_share/install.sh" "installer should copy install.sh to --share-dir"
assert_file "$explicit_share/skills/SKILL.md" "installer should copy skills to --share-dir"
assert_file "$explicit_share/scripts/fixture.ts" "installer should copy scripts to --share-dir"
assert_not_exists "$explicit_prefix/scripts" "installer should not put scripts beside binaries"
[[ "$(cat "$explicit_log")" == "version" ]] || fail "installer should run the installed ark version command"
[[ "$explicit_output" == *"Installed version:   9.9.9"* ]] || fail "installer should print the verified version"

# Under sudo, the default share directory belongs to the invoking user, even if
# root's HOME and XDG_DATA_HOME are present.
sudo_fixture="$TEST_DIR/sudo-source"
sudo_prefix="$TEST_DIR/sudo-bin"
sudo_home="$TEST_DIR/daemon-home"
sudo_log="$TEST_DIR/sudo-version.log"
fake_bin="$TEST_DIR/fake-bin"
mkdir -p "$fake_bin" "$sudo_home"
make_fixture "$sudo_fixture"

cat > "$fake_bin/id" <<'ID'
#!/usr/bin/env bash
printf '0\n'
ID
cat > "$fake_bin/getent" <<GETENT
#!/usr/bin/env bash
printf '%s\n' 'daemon:x:1001:1001:Daemon:${sudo_home}:/bin/bash'
GETENT
chmod +x "$fake_bin/id" "$fake_bin/getent"

sudo_output=$(
  PATH="$fake_bin:$PATH" \
    HOME="$TEST_DIR/root-home" \
    XDG_DATA_HOME="$TEST_DIR/root-xdg" \
    SUDO_USER=daemon \
    ARK_INSTALL_TEST_LOG="$sudo_log" \
    bash "$sudo_fixture/install.sh" --prefix "$sudo_prefix"
)
sudo_share="$sudo_home/.local/share/tasks-ark-cli"
assert_file "$sudo_share/skills/SKILL.md" "sudo install should use SUDO_USER's home for skills"
assert_file "$sudo_share/scripts/fixture.ts" "sudo install should use SUDO_USER's home for scripts"
assert_not_exists "$TEST_DIR/root-xdg/tasks-ark-cli" "sudo install should not use root's XDG data directory"
[[ "$sudo_output" == *"Share files:         $sudo_share"* ]] || fail "installer should report the sudo user's share directory"

# Unknown options are argument errors.
set +e
bash "$explicit_fixture/install.sh" --unknown >"$TEST_DIR/unknown.out" 2>"$TEST_DIR/unknown.err"
unknown_status=$?
set -e
[[ $unknown_status -eq 2 ]] || fail "unknown install option should exit 2 (got $unknown_status)"

# Installation must fail when the installed CLI cannot start.
broken_fixture="$TEST_DIR/broken-source"
broken_prefix="$TEST_DIR/broken-bin"
broken_share="$TEST_DIR/broken-share"
make_fixture "$broken_fixture"
cat > "$broken_fixture/ark" <<'BROKEN'
#!/usr/bin/env bash
exit 7
BROKEN
chmod +x "$broken_fixture/ark"

set +e
ARK_INSTALL_TEST_LOG="$TEST_DIR/broken-version.log" \
  bash "$broken_fixture/install.sh" \
    --prefix "$broken_prefix" \
    --share-dir "$broken_share" \
    >"$TEST_DIR/broken.out" 2>"$TEST_DIR/broken.err"
broken_status=$?
set -e
[[ $broken_status -ne 0 ]] || fail "installer should fail when installed ark version fails"
grep -Fq 'installed ark failed to run' "$TEST_DIR/broken.err" || fail "installer should explain version verification failure"

# The runtime and updater must use the same shared scripts location as the
# installer so a later update does not move data back into the binary prefix.
audit_home="$TEST_DIR/audit-home"
audit_fake_bin="$TEST_DIR/audit-fake-bin"
audit_log="$TEST_DIR/audit-npx.log"
audit_script="$audit_home/.local/share/tasks-ark-cli/scripts/fixture.ts"
mkdir -p "$(dirname "$audit_script")" "$audit_fake_bin"
printf 'console.log("fixture");\n' > "$audit_script"
cat > "$audit_fake_bin/npx" <<'NPX'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${ARK_INSTALL_TEST_NPX_LOG:?}"
NPX
chmod +x "$audit_fake_bin/npx"

HOME="$audit_home" \
  PATH="$audit_fake_bin:$PATH" \
  ARK_INSTALL_TEST_NPX_LOG="$audit_log" \
  "$ROOT_DIR/ark" audit fixture
[[ "$(cat "$audit_log")" == "tsx $audit_script" ]] || fail "ark audit should default to the shared scripts directory"

# Updating an explicit installation must retain its bound share directory and
# must fetch from the documented default repository.
update_fake_bin="$TEST_DIR/update-fake-bin"
update_home="$TEST_DIR/update-home"
update_curl_log="$TEST_DIR/update-curl.log"
update_npx_log="$TEST_DIR/update-npx.log"
mkdir -p "$update_fake_bin" "$update_home"

cat > "$update_fake_bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
output_file=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output_file="$2"
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

printf '%s\n' "$url" >> "${ARK_INSTALL_TEST_CURL_LOG:?}"
case "$url" in
  https://api.github.com/repos/arkangelai/ark-cli/contents/scripts*)
    printf '%s\n' '[{"name":"fixture.ts"}]'
    ;;
  https://api.github.com/repos/arkangelai/ark-cli/contents/skills*)
    printf '%s\n' '[{"name":"SKILL.md"}]'
    ;;
  https://raw.githubusercontent.com/arkangelai/ark-cli/main/ark)
    cp "${ARK_INSTALL_TEST_SOURCE_DIR:?}/ark" "$output_file"
    ;;
  https://raw.githubusercontent.com/arkangelai/ark-cli/main/install.sh)
    cp "${ARK_INSTALL_TEST_SOURCE_DIR:?}/install.sh" "$output_file"
    ;;
  https://raw.githubusercontent.com/arkangelai/ark-cli/main/skill.sh)
    cp "${ARK_INSTALL_TEST_SOURCE_DIR:?}/skill.sh" "$output_file"
    ;;
  https://raw.githubusercontent.com/arkangelai/ark-cli/main/scripts/fixture.ts)
    printf 'console.log("updated");\n' > "$output_file"
    ;;
  https://raw.githubusercontent.com/arkangelai/ark-cli/main/skills/SKILL.md)
    printf '%s\n' '# Updated fixture skill' > "$output_file"
    ;;
  *)
    printf 'Unexpected URL: %s\n' "$url" >&2
    exit 22
    ;;
esac
CURL

cat > "$update_fake_bin/npx" <<'NPX'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${ARK_INSTALL_TEST_NPX_LOG:?}"
NPX
chmod +x "$update_fake_bin/curl" "$update_fake_bin/npx"

update_output=$(
  HOME="$update_home" \
    PATH="$update_fake_bin:$explicit_prefix:$PATH" \
    ARK_INSTALL_TEST_CURL_LOG="$update_curl_log" \
    ARK_INSTALL_TEST_SOURCE_DIR="$ROOT_DIR" \
    "$explicit_prefix/skill.sh"
)

printf '%s' "$update_output" | jq -e \
  --arg scripts_dir "$explicit_share/scripts" \
  '.data.scripts_dir == $scripts_dir' >/dev/null || fail "updater should report the bound shared scripts directory"
grep -Fq 'console.log("updated");' "$explicit_share/scripts/fixture.ts" || fail "updater should refresh scripts in the bound share directory"
assert_not_exists "$update_home/.local/share/tasks-ark-cli/scripts" "updater should not split an explicit installation into HOME"
assert_not_exists "$explicit_prefix/scripts" "updater should not place scripts beside binaries"

HOME="$update_home" \
  PATH="$update_fake_bin:$PATH" \
  ARK_INSTALL_TEST_NPX_LOG="$update_npx_log" \
  "$explicit_prefix/ark" audit fixture
[[ "$(cat "$update_npx_log")" == "tsx $explicit_share/scripts/fixture.ts" ]] || fail "updated ark should retain the installed share directory"

printf 'PASS: installer paths and verification\n'

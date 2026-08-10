#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARK_SRC="${SCRIPT_DIR}/ark"
SKILL_SRC="${SCRIPT_DIR}/skill.sh"
INSTALL_SRC="${SCRIPT_DIR}/install.sh"
SCRIPTS_SRC="${SCRIPT_DIR}/scripts"
SKILLS_SRC="${SCRIPT_DIR}/skills"

usage() {
  cat <<'EOF'
Usage: bash install.sh [--prefix <dir>] [--share-dir <dir>]

Options:
  --prefix <dir>     Directory for ark and skill.sh
  --share-dir <dir>  Directory for install.sh, skills/, and scripts/
  -h, --help         Show this help
EOF
}

PREFIX=""
SHARE_DIR=""
SUDO_SHARE_USER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      [[ $# -ge 2 && -n "$2" ]] || { echo "Error: --prefix requires a directory" >&2; exit 2; }
      PREFIX="$2"
      shift 2
      ;;
    --prefix=*)
      PREFIX="${1#*=}"
      [[ -n "$PREFIX" ]] || { echo "Error: --prefix requires a directory" >&2; exit 2; }
      shift
      ;;
    --share-dir)
      [[ $# -ge 2 && -n "$2" ]] || { echo "Error: --share-dir requires a directory" >&2; exit 2; }
      SHARE_DIR="$2"
      shift 2
      ;;
    --share-dir=*)
      SHARE_DIR="${1#*=}"
      [[ -n "$SHARE_DIR" ]] || { echo "Error: --share-dir requires a directory" >&2; exit 2; }
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$ARK_SRC" ]]; then
  echo "Error: task script not found at ${ARK_SRC}" >&2
  exit 1
fi

install_executable() {
  local src="$1" dest="$2" first_line
  {
    IFS= read -r first_line
    printf '%s\n' "$first_line"
    printf 'ARK_INSTALL_SHARE_DIR=%q\n' "$SHARE_DIR"
    cat
  } < "$src" > "$dest"
  chmod +x "$dest"
}

# Pick install prefix: /usr/local/bin if writable, else ~/.local/bin
if [[ -z "$PREFIX" ]]; then
  if [[ -w "/usr/local/bin" ]]; then
    PREFIX="/usr/local/bin"
  elif [[ "$(id -u)" -eq 0 ]]; then
    PREFIX="/usr/local/bin"
  else
    PREFIX="${HOME}/.local/bin"
  fi
fi
mkdir -p "$PREFIX"

# sudo commonly resets HOME and XDG_DATA_HOME to root. Shared files must remain
# readable from the invoking user's normal runtime environment.
resolve_user_home() {
  local user="$1" resolved=""
  if command -v getent >/dev/null 2>&1; then
    resolved="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 | head -n1)"
  elif command -v dscl >/dev/null 2>&1; then
    resolved="$(dscl . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  elif command -v python3 >/dev/null 2>&1; then
    resolved="$(python3 -c 'import pwd, sys; print(pwd.getpwnam(sys.argv[1]).pw_dir)' "$user" 2>/dev/null || true)"
  fi
  [[ -n "$resolved" ]] && printf '%s\n' "$resolved"
}

if [[ -z "$SHARE_DIR" ]]; then
  if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    if sudo_home="$(resolve_user_home "$SUDO_USER")"; then
      SHARE_DIR="${sudo_home}/.local/share/tasks-ark-cli"
      SUDO_SHARE_USER="$SUDO_USER"
    else
      SHARE_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/tasks-ark-cli"
      echo "Warning: could not resolve home for SUDO_USER=${SUDO_USER}; using ${SHARE_DIR}" >&2
    fi
  else
    SHARE_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/tasks-ark-cli"
  fi
fi
SHARE_COPY_AS_USER=false
if [[ -n "$SUDO_SHARE_USER" && "$EUID" -eq 0 ]] && command -v sudo >/dev/null 2>&1; then
  sudo -u "$SUDO_SHARE_USER" mkdir -p "$SHARE_DIR"
  SHARE_COPY_AS_USER=true
else
  mkdir -p "$SHARE_DIR"
fi

run_share_command() {
  if [[ "$SHARE_COPY_AS_USER" == "true" ]]; then
    sudo -u "$SUDO_SHARE_USER" "$@"
  else
    "$@"
  fi
}

DEST="${PREFIX}/ark"
install_executable "$ARK_SRC" "$DEST"

if [[ -f "$SKILL_SRC" ]]; then
  install_executable "$SKILL_SRC" "${PREFIX}/skill.sh"
fi

[[ -f "$INSTALL_SRC"  ]] && run_share_command cp "$INSTALL_SRC" "${SHARE_DIR}/install.sh"

if [[ -d "$SKILLS_SRC" ]]; then
  run_share_command mkdir -p "${SHARE_DIR}/skills"
  run_share_command cp -R "$SKILLS_SRC/." "${SHARE_DIR}/skills/"
fi

if [[ -d "$SCRIPTS_SRC" ]]; then
  run_share_command mkdir -p "${SHARE_DIR}/scripts"
  run_share_command cp -R "$SCRIPTS_SRC/." "${SHARE_DIR}/scripts/"
fi

if ! VERSION_JSON="$("$DEST" version)"; then
  echo "Error: installed ark failed to run: ${DEST} version" >&2
  exit 1
fi
if ! INSTALLED_VERSION="$(printf '%s' "$VERSION_JSON" | jq -er '(.data.version // .cli_version) | select(type == "string" and length > 0)')"; then
  echo "Error: installed ark returned an invalid version response" >&2
  exit 1
fi

echo "Tasks Ark installed: ${DEST}"
echo "Share files:         ${SHARE_DIR}"
echo "Installed version:   ${INSTALLED_VERSION}"

if ! command -v ark &>/dev/null; then
  echo ""
  echo "Note: ${PREFIX} is not in your PATH."
  echo "Add this to your shell profile:"
  echo "  export PATH=\"${PREFIX}:\$PATH\""
fi

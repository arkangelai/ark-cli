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
SYSTEM_SHARE=false
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

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required to verify the installed ark version. Install jq and retry." >&2
  exit 1
fi

install_executable() {
  local src="$1" dest="$2" first_line tmp
  tmp="$(mktemp "${dest}.tmp.XXXXXX")"
  {
    IFS= read -r first_line
    printf '%s\n' "$first_line"
    printf 'ARK_INSTALL_SHARE_DIR=%q\n' "$SHARE_DIR"
    sed '/^ARK_INSTALL_SHARE_DIR=/d'
  } < "$src" > "$tmp"
  chmod +x "$tmp"
  mv "$tmp" "$dest"
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
PREFIX="$(cd "$PREFIX" && pwd -P)"

if [[ -z "$SHARE_DIR" ]]; then
  if [[ "$(id -u)" -eq 0 ]]; then
    SHARE_DIR="$(dirname "$PREFIX")/share/tasks-ark-cli"
    SYSTEM_SHARE=true
    echo "Note: root installation uses the system shared directory: ${SHARE_DIR}" >&2
  else
    SHARE_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/tasks-ark-cli"
  fi
fi
mkdir -p "$SHARE_DIR"
SHARE_DIR="$(cd "$SHARE_DIR" && pwd -P)"

DEST="${PREFIX}/ark"

[[ -f "$INSTALL_SRC"  ]] && cp "$INSTALL_SRC" "${SHARE_DIR}/install.sh"

if [[ -d "$SKILLS_SRC" ]]; then
  mkdir -p "${SHARE_DIR}/skills"
  cp -R "$SKILLS_SRC/." "${SHARE_DIR}/skills/"
fi

if [[ -d "$SCRIPTS_SRC" ]]; then
  mkdir -p "${SHARE_DIR}/scripts"
  cp -R "$SCRIPTS_SRC/." "${SHARE_DIR}/scripts/"
fi

# Do not let a restrictive root umask make the machine-wide payload unreadable
# to daemon users, or leave its executable content writable by other accounts.
if [[ "$SYSTEM_SHARE" == "true" && "$EUID" -eq 0 ]]; then
  chown -R 0 "$SHARE_DIR"
  chmod -R u+rwX,go-w,a+rX "$SHARE_DIR"
fi

install_executable "$ARK_SRC" "$DEST"

if [[ -f "$SKILL_SRC" ]]; then
  install_executable "$SKILL_SRC" "${PREFIX}/skill.sh"
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

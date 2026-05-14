#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARK_SRC="${SCRIPT_DIR}/ark"
SKILL_SRC="${SCRIPT_DIR}/skill.sh"
SKILL_MD_SRC="${SCRIPT_DIR}/SKILL.md"
INSTALL_SRC="${SCRIPT_DIR}/install.sh"
SCRIPTS_SRC="${SCRIPT_DIR}/scripts"

if [[ ! -f "$ARK_SRC" ]]; then
  echo "Error: task script not found at ${ARK_SRC}" >&2
  exit 1
fi

# Pick install prefix: /usr/local/bin if writable, else ~/.local/bin
if [[ -w "/usr/local/bin" ]]; then
  PREFIX="/usr/local/bin"
elif [[ "$(id -u)" -eq 0 ]]; then
  PREFIX="/usr/local/bin"
else
  PREFIX="${HOME}/.local/bin"
  mkdir -p "$PREFIX"
fi

SHARE_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/tasks-ark-cli"
mkdir -p "$SHARE_DIR"

DEST="${PREFIX}/ark"
cp "$ARK_SRC" "$DEST"
chmod +x "$DEST"

if [[ -f "$SKILL_SRC" ]]; then
  cp "$SKILL_SRC" "${PREFIX}/skill.sh"
  chmod +x "${PREFIX}/skill.sh"
fi

[[ -f "$SKILL_MD_SRC" ]] && cp "$SKILL_MD_SRC" "${SHARE_DIR}/SKILL.md"
[[ -f "$INSTALL_SRC"  ]] && cp "$INSTALL_SRC"  "${SHARE_DIR}/install.sh"

if [[ -d "$SCRIPTS_SRC" ]]; then
  cp -r "$SCRIPTS_SRC" "$(dirname "$DEST")/scripts"
fi

echo "Tasks Ark installed: ${DEST}"
echo "Share files:         ${SHARE_DIR}"

if ! command -v ark &>/dev/null; then
  echo ""
  echo "Note: ${PREFIX} is not in your PATH."
  echo "Add this to your shell profile:"
  echo "  export PATH=\"${PREFIX}:\$PATH\""
fi

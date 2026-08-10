#!/usr/bin/env bash
# Self-updater for Tasks Ark. Refreshes `ark`, `skill.sh`, `SKILL.md`, and
# `install.sh` from the remote repo — no manual `git pull` required.
#
# Two modes, picked automatically:
#   git  — a checkout of the repo is present on disk (uses `git fetch` + files
#          from the checkout); works offline if origin is a local path
#   curl — no checkout found (pulls raw files from GitHub)
#
# Env vars:
#   ARK_UPDATE_SUDO=1          retry protected destinations via sudo
#   ARK_UPDATE_REPO=owner/name override (default: arkangelai/ark-cli)
#   ARK_SHARE_DIR=/path       override shared data directory
#   ARK_SCRIPTS_DIR=/path     override audit scripts directory
set -euo pipefail

REPO="${ARK_UPDATE_REPO:-arkangelai/ark-cli}"
REF="main"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REF}"
SHARE_DIR="${ARK_SHARE_DIR:-${ARK_INSTALL_SHARE_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/tasks-ark-cli}}"
SCRIPTS_DEST="${ARK_SCRIPTS_DIR:-${SHARE_DIR}/scripts}"

err() {
  local code="$1" msg="$2" cur="${3:-unknown}"
  printf '{"ok":false,"cli_version":"%s","error":{"code":"%s","message":"%s","retryable":false,"detail":{}}}\n' \
    "$cur" "$code" "$msg" >&2
}

resolve_path() {
  if readlink -f "$1" >/dev/null 2>&1; then readlink -f "$1"
  else python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1"
  fi
}

parse_version() { grep -m1 '^ARK_VERSION=' "$1" | cut -d'"' -f2; }

rewrite_share_dir_binding() {
  local file="$1" bind_share_dir="$2" tmp line wrote_first=false
  tmp="$(mktemp "${file}.share-dir.XXXXXX")"

  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" == ARK_INSTALL_SHARE_DIR=* ]] && continue
    if [[ "$wrote_first" == "false" ]]; then
      printf '%s\n' "$line" > "$tmp"
      if [[ "$bind_share_dir" == "true" ]]; then
        printf 'ARK_INSTALL_SHARE_DIR=%q\n' "$SHARE_DIR" >> "$tmp"
      fi
      wrote_first=true
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"

  if [[ "$wrote_first" == "false" ]]; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$file"
}

embed_share_dir() { rewrite_share_dir_binding "$1" true; }
strip_share_dir_binding() { rewrite_share_dir_binding "$1" false; }

# Walk up looking for a git worktree whose origin URL contains $REPO.
find_checkout() {
  local dir="$1"
  [ -n "$dir" ] || return 1
  while [ "$dir" != "/" ] && [ -n "$dir" ]; do
    if [ -e "$dir/.git" ]; then
      local origin
      origin="$(git -C "$dir" config --get remote.origin.url 2>/dev/null || true)"
      case "$origin" in *"${REPO}"*) echo "$dir"; return 0 ;; esac
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

# ─── locate installed ark ─────────────────────────────────────────────────────
TARGET_ARK="$(command -v ark || true)"
if [ -z "$TARGET_ARK" ]; then
  err "ark_not_found" "ark is not on PATH; install first via bash install.sh"
  exit 4
fi
TARGET_ARK="$(resolve_path "$TARGET_ARK")"
PREFIX_DIR="$(dirname "$TARGET_ARK")"
CUR="$(parse_version "$TARGET_ARK")"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# ─── fetch: stage all four files in $STAGE ────────────────────────────────────
MODE="curl"
CHECKOUT=""
if CHECKOUT="$(find_checkout "$TARGET_ARK" || find_checkout "$SHARE_DIR")"; then
  MODE="git"
  git -C "$CHECKOUT" fetch origin "$REF" --depth=1 >/dev/null 2>&1 || {
    err "git_fetch_failed" "git fetch origin ${REF} failed in ${CHECKOUT}" "$CUR"; exit 1; }
  git -C "$CHECKOUT" -c advice.detachedHead=false checkout -f --quiet FETCH_HEAD || {
    err "git_checkout_failed" "git checkout FETCH_HEAD failed in ${CHECKOUT}" "$CUR"; exit 1; }
  for F in ark install.sh skill.sh; do
    [ -f "$CHECKOUT/$F" ] || { err "missing_file" "${F} missing in checkout" "$CUR"; exit 1; }
    cp "$CHECKOUT/$F" "$STAGE/$F"
  done
  [ -d "$CHECKOUT/skills"  ] && cp -r "$CHECKOUT/skills"  "$STAGE/skills"
  [ -d "$CHECKOUT/scripts" ] && cp -r "$CHECKOUT/scripts" "$STAGE/scripts"
else
  for F in ark install.sh skill.sh; do
    curl -fsSL "${RAW_BASE}/${F}" -o "${STAGE}/${F}" || {
      err "download_failed" "Failed to download ${F} from ${RAW_BASE}" "$CUR"; exit 1; }
  done
  for FOLDER in skills scripts; do
    FOLDER_JSON="$(curl -fsSL "https://api.github.com/repos/${REPO}/contents/${FOLDER}?ref=${REF}" 2>/dev/null || true)"
    if [ -n "$FOLDER_JSON" ] && echo "$FOLDER_JSON" | jq -e '.[].name' >/dev/null 2>&1; then
      mkdir -p "${STAGE}/${FOLDER}"
      while IFS= read -r fname; do
        curl -fsSL "${RAW_BASE}/${FOLDER}/${fname}" -o "${STAGE}/${FOLDER}/${fname}" || {
          err "download_failed" "Failed to download ${FOLDER}/${fname}" "$CUR"; exit 1; }
      done < <(echo "$FOLDER_JSON" | jq -r '.[].name')
    fi
  done
fi

# Syntax-check every shell file in the stage before we touch the installed copy.
for F in ark install.sh skill.sh; do
  bash -n "${STAGE}/${F}" 2>/dev/null || {
    err "syntax_check_failed" "Staged ${F} failed bash -n" "$CUR"; exit 1; }
done

NEW="$(parse_version "${STAGE}/ark")"

# ─── no-op if already current ────────────────────────────────────────────────
if [ "$CUR" = "$NEW" ]; then
  jq -n --arg cli "$CUR" --arg cur "$CUR" --arg mode "$MODE" \
    '{ok:true,cli_version:$cli,data:{mode:$mode,already_current:true,previous_version:$cur,new_version:$cur}}'
  exit 0
fi

# ─── commit phase: backup + atomic replace ───────────────────────────────────
BACKUP="${TARGET_ARK}.bak.${CUR}"
SUDO_USED=""

do_cp() {
  local src="$1" dst="$2"
  cp -p "$src" "$dst" 2>/dev/null && return 0
  if [ "${ARK_UPDATE_SUDO:-}" = "1" ]; then sudo cp -p "$src" "$dst" && SUDO_USED="sudo" && return 0; fi
  return 1
}
do_mv() {
  local src="$1" dst="$2"
  mv "$src" "$dst" 2>/dev/null && return 0
  if [ "${ARK_UPDATE_SUDO:-}" = "1" ]; then sudo mv "$src" "$dst" && SUDO_USED="sudo" && return 0; fi
  return 1
}
shared_mkdir() {
  local dir="$1"
  mkdir -p "$dir" 2>/dev/null && return 0
  if [ "${ARK_UPDATE_SUDO:-}" = "1" ]; then sudo mkdir -p "$dir" && SUDO_USED="sudo" && return 0; fi
  return 1
}
shared_mv() {
  local src="$1" dst="$2"
  mv "$src" "$dst" 2>/dev/null && return 0
  if [ "${ARK_UPDATE_SUDO:-}" = "1" ]; then sudo mv "$src" "$dst" && SUDO_USED="sudo" && return 0; fi
  return 1
}
shared_rm_rf() {
  local path="$1"
  rm -rf "$path" 2>/dev/null && return 0
  if [ "${ARK_UPDATE_SUDO:-}" = "1" ]; then sudo rm -rf "$path" && SUDO_USED="sudo" && return 0; fi
  return 1
}
shared_preflight_dir() {
  local dir="$1"
  shared_mkdir "$dir" || return 1
  [[ -w "$dir" ]] && return 0
  if [ "${ARK_UPDATE_SUDO:-}" = "1" ]; then sudo test -w "$dir" && SUDO_USED="sudo" && return 0; fi
  return 1
}

# Check every destination before replacing the binary so a protected shared
# layout cannot leave an update half-applied.
shared_preflight_dir "$SHARE_DIR" || {
  err "write_denied" "cannot write shared directory ${SHARE_DIR}; re-run with ARK_UPDATE_SUDO=1" "$CUR"; exit 6; }
if [ -d "${STAGE}/scripts" ]; then
  shared_preflight_dir "$(dirname "$SCRIPTS_DEST")" || {
    err "write_denied" "cannot write scripts directory $(dirname "$SCRIPTS_DEST"); re-run with ARK_UPDATE_SUDO=1" "$CUR"; exit 6; }
fi

do_cp "$TARGET_ARK" "$BACKUP" || {
  err "write_denied" "cannot backup ${TARGET_ARK}; re-run with ARK_UPDATE_SUDO=1" "$CUR"; exit 6; }

if [ -n "$CHECKOUT" ] && [[ "$TARGET_ARK" == "$CHECKOUT"/* ]]; then
  strip_share_dir_binding "${STAGE}/ark"
  strip_share_dir_binding "${STAGE}/skill.sh"
else
  embed_share_dir "${STAGE}/ark"
  embed_share_dir "${STAGE}/skill.sh"
fi
chmod +x "${STAGE}/ark" "${STAGE}/install.sh" "${STAGE}/skill.sh"

do_mv "${STAGE}/ark" "$TARGET_ARK" || {
  err "write_denied" "cannot replace ${TARGET_ARK}; re-run with ARK_UPDATE_SUDO=1" "$CUR"; exit 6; }
do_mv "${STAGE}/skill.sh" "${PREFIX_DIR}/skill.sh" || {
  err "write_denied" "cannot place skill.sh in ${PREFIX_DIR}; re-run with ARK_UPDATE_SUDO=1" "$CUR"; exit 6; }

shared_mv "${STAGE}/install.sh" "${SHARE_DIR}/install.sh" || {
  err "write_denied" "cannot place install.sh in ${SHARE_DIR}; re-run with ARK_UPDATE_SUDO=1" "$CUR"; exit 6; }

if [ -d "${STAGE}/skills" ]; then
  shared_rm_rf "${SHARE_DIR}/skills" || {
    err "write_denied" "cannot replace skills/ in ${SHARE_DIR}; re-run with ARK_UPDATE_SUDO=1" "$CUR"; exit 6; }
  shared_mv "${STAGE}/skills" "${SHARE_DIR}/skills" || {
    err "write_denied" "cannot place skills/ in ${SHARE_DIR}; re-run with ARK_UPDATE_SUDO=1" "$CUR"; exit 6; }
fi

if [ -d "${STAGE}/scripts" ]; then
  shared_rm_rf "$SCRIPTS_DEST" || {
    err "write_denied" "cannot replace scripts/ in ${SCRIPTS_DEST}; re-run with ARK_UPDATE_SUDO=1" "$CUR"; exit 6; }
  shared_mv "${STAGE}/scripts" "$SCRIPTS_DEST" || {
    err "write_denied" "cannot place scripts/ in ${SCRIPTS_DEST}; re-run with ARK_UPDATE_SUDO=1" "$CUR"; exit 6; }
fi

jq -n \
  --arg cli "$NEW" --arg cur "$CUR" --arg new "$NEW" \
  --arg mode "$MODE" --arg checkout "$CHECKOUT" --arg ark "$TARGET_ARK" \
  --arg bak "$BACKUP" --arg skill "${PREFIX_DIR}/skill.sh" \
  --arg skills_dir "${SHARE_DIR}/skills" --arg install_sh "${SHARE_DIR}/install.sh" \
  --arg scripts_dir "$SCRIPTS_DEST" \
  --arg sudo_used "$SUDO_USED" \
  '{ok:true,cli_version:$cli,data:{
      mode:$mode, checkout:$checkout,
      previous_version:$cur, new_version:$new,
      ark_path:$ark, skill_path:$skill,
      skills_dir:$skills_dir, scripts_dir:$scripts_dir, install_sh_path:$install_sh,
      backup:$bak, sudo_used:$sudo_used
    }}'

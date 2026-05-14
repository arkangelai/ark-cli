# AGENTS.md — Agent Guide for Tasks Ark

This document is written for the AI agent. Read it before executing any task.

---

## Setup

```bash
ark config set url https://your-api-url
ark config set api-key your-api-key

ark auth status   # validates key against the API

# Discover capabilities
ark skills
```

---

## Capability Discovery

Run `ark skills` at cold-start to get the full capability map: workflows, exit codes, env vars, idempotency strategy, and confidence routing — all as JSON.

---

## Output Envelope

Every successful command outputs this shape to stdout:

```json
{
  "ok": true,
  "cli_version": "0.3.2",
  "data": { },
  "_links": { },
  "next_commands": {
    "claim":    "ark tasks claim <id>",
    "complete": "ark tasks complete <id> --confidence <0.0-1.0>",
    "block":    "ark tasks block <id> --reason \"<reason>\""
  },
  "idempotent_replay": false,
  "request_id": "uuid-or-null"
}
```

List responses add:
```json
"meta": { "count": 20, "next_cursor": "2026-04-15T08:30:00Z" }
```

Error envelope goes to **stderr**:
```json
{
  "ok": false,
  "cli_version": "0.3.2",
  "error": {
    "code": "invalid_status_transition",
    "message": "Cannot transition from 'in_progress' to 'draft'",
    "retryable": false,
    "detail": { "current": "in_progress", "allowed": ["blocked", "review", "done"] }
  },
  "suggestion": "Allowed transitions: blocked, review, done",
  "request_id": "uuid"
}
```

`next_commands` is the CAEOAS contract — always read it to know what to run next. Never hardcode status sequences.

---

## Exit Codes

| Code | Meaning | Action |
|------|---------|--------|
| `0`  | Success | Continue |
| `1`  | Network/generic error | Check `error.retryable`. Retry with same idempotency key if true. |
| `2`  | Bad arguments | Fix the command. Do not retry. |
| `3`  | Auth error 401/403 | Run `ark config set api-key <your-key>`. Do not retry. |
| `4`  | Not found 404 | Stop this branch. |
| `5`  | Conflict / invalid transition 409/422 | Read `error.detail`. Fix the request. |
| `29` | Rate limited 429 | Retry after delay with same idempotency key. |

---

## Idempotency Pattern

Generate one `TASK_RUN_ID` at the start of each execution run. Derive per-action keys from it. Never reuse keys across actions or across execution runs of the same task.

```bash
TASK_RUN_ID=$(ark gen-uuid)

# Claim
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:claim"
ark tasks claim "$TASK_ID"

# Set workspace
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:workspace"
ark tasks update "$TASK_ID" --log-path "storage://tasks/${TASK_ID}/workspace/"

# Upload the final output (format determined by task context)
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:output:report"
ark tasks outputs upload "$TASK_ID" /tmp/output-${TASK_ID}.ext --type file --label report

# Write execution metadata without replacing the human's instructions
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:context-set"
ark tasks context-set "$TASK_ID" --set email_sent=true --set sent_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Complete with the same confidence score
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:complete"
ark tasks complete "$TASK_ID" --confidence 0.92
```

On retry: set `ARK_IDEMPOTENCY_KEY` to the same key used in the first attempt before rerunning the command. The API returns the cached response without re-executing. `idempotent_replay: true` in the response confirms this.

A re-queued task starts a new execution run — generate a fresh `TASK_RUN_ID`.

---

## Confidence Routing

`ark tasks complete` routes automatically:
- `--confidence >= 0.85` → transitions to `done` (no human review)
- `--confidence < 0.85` → transitions to `review` (awaits human)

Score honestly. Do not optimistically inflate confidence.

---

## Commands Available to the Agent

Use these to read and mutate task state:

| Command | Purpose |
|---|---|
| `ark tasks list` | Fetch queued tasks |
| `ark tasks get <id>` | Read a single task with next_commands |
| `ark tasks claim <id>` | Transition queued → in_progress |
| `ark tasks update <id> --log-path` | Set workspace storage path |
| `ark tasks context-set <id> --set key=value` | **Merge fields into context** (preserves existing fields) |
| `ark tasks outputs upload <id>` | Push output file and record it |
| `ark tasks outputs submit <id>` | Register already-staged or inline output |
| `ark tasks complete <id> --confidence` | Transition to done or review |
| `ark tasks block <id> --reason` | Signal blocker, transition to blocked |
| `ark tasks comments post <id>` | Post a note or blocker comment |
| `ark tasks inputs list <id>` | List task inputs |
| `ark tasks create` | Create a follow-on task |

> **WARNING — human-only commands.**
> `ark tasks context <id> --data '<json>'` and `ark tasks context <id> --clear`
> replace the **entire** context object. Calling either as an agent destroys the
> human's instructions and any fields written by previous runs. Never call them.
> Use `ark tasks context-set` instead.

---

## Standard Workflows

### Workflow 1 — Execute a Queued Task

```bash
#!/usr/bin/env bash
set -euo pipefail

trap 'echo "[ERROR] exit $? on line $LINENO" >&2' ERR

export ARK_API_URL="${ARK_API_URL:-http://localhost:3000}"

TASK_RUN_ID=$(ark gen-uuid)

# Pick up a queued task
TASK_ID=$(ark tasks list --status queued --limit 1 | jq -r '.data[0].id')
if [[ -z "$TASK_ID" || "$TASK_ID" == "null" ]]; then
  echo '{"ok":false,"error":"No queued tasks"}' >&2; exit 0
fi

# Claim
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:claim"
ark tasks claim "$TASK_ID"

# Set workspace
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:workspace"
ark tasks update "$TASK_ID" --log-path "storage://tasks/${TASK_ID}/workspace/"

# Read inputs
ark tasks inputs list "$TASK_ID" | jq -r '.data[].path'

# Read task context
TASK=$(ark tasks get "$TASK_ID")
CONTEXT=$(echo "$TASK" | jq -c '.data.context')
DESCRIPTION=$(echo "$TASK" | jq -r '.data.description')

# ... do work ...

# Post a progress note
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:note"
ark tasks comments post "$TASK_ID" --type note --body "Completed analysis. Writing report."

# Determine confidence and post rationale as a comment
CONFIDENCE=0.92
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:note:confidence"
ark tasks comments post "$TASK_ID" --type note \
  --body "Confidence ${CONFIDENCE}: Verified findings against source data; no unresolved edge cases."

# Write the final output in the format the task context requires

# Upload the final output
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:output:report"
ark tasks outputs upload "$TASK_ID" /tmp/output-${TASK_ID}.ext --type file --label report

# Complete with the same confidence
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:complete"
ark tasks complete "$TASK_ID" --confidence $CONFIDENCE
```

### Workflow 2 — Create a Follow-on Task

```bash
# The agent creates a new task mid-execution
ark tasks create \
  --title "Enrich patient records for cohort Q2" \
  --status queued \
  --context '{"source_task":"'"$TASK_ID"'","cohort":"Q2"}'
```

### Workflow 3 — Access the Knowledge Base

Use this before executing audit tasks that require clinical guidelines, administrative rules, or billing tariffs.

```bash
# List all available files (returns signed URLs + metadata organized by category)
ark knowledge files list | jq '.data'

# Download a specific file to a local path
ark knowledge files url plantillas informe-template.docx --output /tmp/informe-template.docx

# Download a file from a subfolder
ark knowledge files url medico/guias-clinicas guia-hipertension.pdf --output /tmp/guia.pdf

# The response includes where the file was saved
# { "url": "...", "expires_at": "...", "path": "...", "local_path": "/tmp/guia.pdf", "size_bytes": 245120 }
```

The signed URL in the list response expires in ~1 hour. If it may have expired, use `ark knowledge files url` to get a fresh one and re-download.

### Workflow 4 — Signal a Blocker

```bash
# Block — posts comment then transitions status atomically
ark tasks block "$TASK_ID" --reason "Missing API credentials for DataSource X. Human must add DATASOURCE_X_KEY to context."
# Exit. The harness will re-trigger when a human re-queues.
```

### Workflow 5 — Handle a Re-queue (Changes Requested)

```bash
# A fresh execution run after human re-queued
TASK_RUN_ID=$(ark gen-uuid)

# Read the changes_requested comment
LATEST_COMMENT=$(ark tasks comments list "$TASK_ID" | jq '.data[-1]')
CHANGES=$(echo "$LATEST_COMMENT" | jq -r '.body')

# Claim
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:claim"
ark tasks claim "$TASK_ID"

# Continue from workspace — prior log_path is preserved
TASK=$(ark tasks get "$TASK_ID")
LOG_PATH=$(echo "$TASK" | jq -r '.data.log_path')

# ... apply changes, produce new output ...

# Re-determine confidence and post rationale as a comment
CONFIDENCE=0.90
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:note:confidence"
ark tasks comments post "$TASK_ID" --type note \
  --body "Confidence ${CONFIDENCE}: Addressed human feedback; <what changed and why>."

# Write the revised output in the format the task context requires

export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:output:report"
ark tasks outputs upload "$TASK_ID" /tmp/output-${TASK_ID}.ext --type file --label report

export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:complete"
ark tasks complete "$TASK_ID" --confidence $CONFIDENCE
```

### Workflow 6 — Ejecutar una tarea batch-denial-mail

```bash
TASK_RUN_ID=$(ark gen-uuid)

TASK_ID=$(ark tasks list --status queued --limit 1 | jq -r '.data[0].id')
TASK_TYPE=$(ark tasks list --status queued --limit 1 | jq -r '.data[0].task_type')

if [[ "$TASK_TYPE" != "batch-denial-mail" ]]; then
  echo '{"ok":false,"error":"task_type no es batch-denial-mail"}' >&2; exit 1
fi

# Claim
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:claim"
ark tasks claim "$TASK_ID"

# Ejecutar el script — sin razonamiento, sin interpretación
STDERR_FILE=$(mktemp)
if ark audit send-denial-mail "$TASK_ID" 2>"$STDERR_FILE"; then
  # Leer task_ids y sent_at del contexto de la tarea batch (ya actualizado por el script)
  BATCH_CTX=$(ark tasks get "$TASK_ID" | jq -c '.data.context')
  TASK_IDS=$(echo "$BATCH_CTX" | jq -r '.task_ids[]' 2>/dev/null || true)
  SENT_AT=$(echo "$BATCH_CTX" | jq -r '.sent_at // empty')
  [[ -z "$SENT_AT" ]] && SENT_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Actualizar cada tarea eps_audit individual con reply_sent
  PATCH_ERRORS=()
  for individual_task_id in $TASK_IDS; do
    export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:ctx:${individual_task_id}"
    if ! ark tasks context "$individual_task_id" \
        --data "{\"reply_sent\": true, \"reply_sent_at\": \"${SENT_AT}\"}" 2>/dev/null; then
      PATCH_ERRORS+=("$individual_task_id")
    fi
  done

  # Registrar fallos parciales como nota — no bloquear el flujo
  if [[ ${#PATCH_ERRORS[@]} -gt 0 ]]; then
    export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:note:patch-errors"
    ark tasks comments post "$TASK_ID" --type note \
      --body "PATCH reply_sent falló para las siguientes tareas eps_audit: ${PATCH_ERRORS[*]}"
  fi

  export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:complete"
  ark tasks complete "$TASK_ID" --confidence 1.0
else
  EXIT_CODE=$?
  STDERR_CONTENT=$(cat "$STDERR_FILE")
  FIRST_LINE=$(head -n1 "$STDERR_FILE")

  # Postear stderr como nota antes de bloquear
  export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:note"
  ark tasks comments post "$TASK_ID" --type note --body "$STDERR_CONTENT"

  # Bloquear con razón estructurada
  export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:block"
  ark tasks block "$TASK_ID" \
    --reason "script send-denial-mail falló con exit code ${EXIT_CODE}: ${FIRST_LINE}"
fi
rm -f "$STDERR_FILE"
```

---

## Manejo de errores del script send-denial-mail

Cuando `ark audit send-denial-mail` falla:

1. Capturar stderr completo antes de cualquier acción.
2. Postear el stderr como comentario tipo `note` en la tarea.
3. Bloquear la tarea con razón: `"script send-denial-mail falló con exit code {n}: {primer línea de stderr}"`.
4. No reintentar automáticamente — esperar input humano.

### Exit codes de referencia

| Exit code | Acción del agente |
|---|---|
| `0` | Actualizar tareas `eps_audit` con `reply_sent`, luego `ark tasks complete <id> --confidence 1.0` |
| `1` | Postear stderr como `note` · `ark tasks block <id> --reason "..."` |
| `2` | Postear stderr como `note` · `ark tasks block <id> --reason "argumento inválido o tarea no encontrada"` |

---

## Shell Script Harness Template

```bash
#!/usr/bin/env bash
set -euo pipefail

# Trap all errors
trap 'echo "[HARNESS] fatal: exit $? at line $LINENO" >&2' ERR

# Required env
: "${TASK_ID:?}"

TASK_RUN_ID=$(ark gen-uuid)

# Safe retry wrapper
ark_retry() {
  local cmd=("$@") attempt=0 max=3
  while (( attempt < max )); do
    local out err_out exit_code=0
    out=$("${cmd[@]}" 2>/tmp/ark_stderr) || exit_code=$?
    err_out=$(cat /tmp/ark_stderr)

    if [[ $exit_code -eq 0 ]]; then
      echo "$out"; return 0
    fi

    local retryable; retryable=$(echo "$err_out" | jq -r '.error.retryable // false')
    if [[ "$retryable" != "true" ]]; then
      echo "$err_out" >&2; exit $exit_code
    fi

    (( attempt++ ))
    sleep $(( 2 ** attempt ))
  done
  echo "$err_out" >&2; exit 1
}
```

# Tasks Ark

Tasks Ark is a bash CLI for AI agents to read, claim, execute, and report on tasks via the Tasks API.

## Requirements

- bash ≥ 3.2
- curl
- jq

## Install

```bash
# Option 1: run the installer
bash install.sh

# Option 2: manual
cp ark /usr/local/bin/ark
chmod +x /usr/local/bin/ark
```

## Update

Once installed, keep `ark`, `skill.sh`, and the `skills/` folder current with:

```bash
ark update
```

Uses `git pull` when a checkout is on disk, falls back to `curl` from
`raw.githubusercontent.com/arkangelai/ark-cli/main` otherwise. If the
install prefix is not writable (exit code `6`), re-run as
`ARK_UPDATE_SUDO=1 ark update`.

## Setup

```bash
ark config set url https://your-api-url
ark config set api-key your-api-key

ark auth status   # validates key against the API
```

## How It Works

Tasks Ark implements a task queue for AI agents. A human creates a task with
instructions and input data. The task can start frozen in `hold`, move to
`draft` for OCR/pre-processing, and only becomes agent-eligible once it reaches
`queued`. The API enforces every step — the agent cannot skip or reorder the
lifecycle.

### Task lifecycle

```
[human creates]
      │
   hold    (frozen: no OCR, no AI)
      │
   draft   (OCR can run; AI is frozen)
      │
   queued  (AI eligible) ◄───────────────────┐
      │                                       │
   in_progress  (agent claimed it)            │
      │                                       │
      ├── blocked  (agent hit a blocker) ─────┤  human resolves, re-queues
      │                                       │
      ├── review   (confidence < 0.85) ───────┤  human approves or requests changes
      │
      └── done     (confidence ≥ 0.85, or human approved)
```

To release a held task into OCR/pre-processing, run:

```bash
ark tasks status "$TASK_ID" --status draft
```

### What the agent does at each step

**1. Claim a queued task**
```bash
TASK_RUN_ID=$(ark gen-uuid)

TASK_ID=$(ark tasks list --status queued --limit 1 | jq -r '.data[0].id')

export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:claim"
ark tasks claim "$TASK_ID"
```

**2. Set up workspace and read inputs**
```bash
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:workspace"
ark tasks update "$TASK_ID" --log-path "storage://tasks/${TASK_ID}/workspace/"

ark tasks inputs list "$TASK_ID"   # paths the human declared for this task
```

**3. Do the work — post notes, register new sources**
```bash
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:note:1"
ark tasks comments post "$TASK_ID" --type note --body "Analysis in progress."

# If a new data source is discovered during execution:
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:input:1"
ark tasks inputs add "$TASK_ID" --path "storage://extra/data" --type storage
```

**4. Submit the final output (+ any supporting artifacts)**

The primary deliverable uses `--label report`. The format is determined by the
task's `context` field — it could be JSON, CSV, HTML, markdown, or any other
type.

```bash
# Upload the final output (primary deliverable)
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:output:report"
ark tasks outputs upload "$TASK_ID" /tmp/output-${TASK_ID}.ext \
  --type file --label report

# Complementary file supporting the deliverable (chart, raw data, etc.):
ark tasks outputs upload "$TASK_ID" ./chart.png \
  --type screenshot --label artifact

# Pre-staged file already in Supabase Storage (or files over 500 MB):
ark tasks outputs submit "$TASK_ID" \
  --type file --label artifact \
  --storage-path "storage://tasks/${TASK_ID}/workspace/result.pdf" \
  --size 2500000
```

### Bulk directory ingestion

Use `ingest-dir` when each subdirectory is one case/task and all files inside
that subdirectory should become inputs for that task:

```bash
ark tasks ingest-dir "./Solicitud Mundial Auditoria 2" \
  --map subdir-as-case \
  --task-type audit_soat \
  --status hold \
  --batch-id carga-soat-2026-07 \
  --concurrency 12 \
  --resume \
  --dry-run

ark tasks ingest-dir "./Solicitud Mundial Auditoria 2" \
  --map subdir-as-case \
  --task-type audit_soat \
  --status hold \
  --batch-id carga-soat-2026-07 \
  --concurrency 12 \
  --resume
```

The command excludes `.DS_Store`, `Thumbs.db`, dotfiles, and files inside dot
directories. It creates tasks through `POST /api/tasks/batch`, requests signed
URLs through `POST /api/tasks/{id}/inputs/batch`, uploads binaries with bounded
parallelism and retries, and prints the final JSON summary to stdout. Progress
logs go to stderr. Use `--include` and `--exclude` globs to narrow the file set.

Once a held batch is ready for OCR/pre-processing, release it gradually:

```bash
ark tasks release-batch --batch-id carga-soat-2026-07 --limit 100
```

**5. Complete with a confidence score**
```bash
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:complete"
ark tasks complete "$TASK_ID" --confidence 0.92
# ≥ 0.85 → done (no review)
# < 0.85 → review (human decides)
```

**6. Signal a blocker if stuck**
```bash
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:block"
ark tasks block "$TASK_ID" --reason "Missing AWS credentials for s3://bucket/data"
```

### After human feedback (re-queue)

If a human sends a task back from review, the agent reads the feedback and re-runs:

```bash
# New run ID for every re-execution
TASK_RUN_ID=$(ark gen-uuid)

# Read what the human wants changed
ark tasks comments list "$TASK_ID" | jq '.data[-1]'

# Re-claim, re-execute, re-submit, re-complete
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:claim"
ark tasks claim "$TASK_ID"
# ... repeat steps 2–5 ...
```

Prior workspace and inputs are preserved across re-runs. Output versions
auto-increment.

### Human operations — updating task context

A human can update or clear a task's `context` field at any point (before or
during agent execution). This is useful when instructions change after the task
was created, or when a blocked task needs new parameters to proceed.

```bash
# Replace context with a new JSON object
ark tasks context "$TASK_ID" --data '{"output_format":"csv","cohort":"Q2-2026"}'

# Clear context entirely
ark tasks context "$TASK_ID" --clear
```

The `context` field holds the human's instructions and must not be overwritten by
an agent. If context changes while an agent is executing, the agent will not
automatically re-read it; the task should be re-queued so the agent starts a
fresh run with the updated instructions.

### Agent operations — writing execution metadata to context

An agent can record facts produced during its run (e.g., `email_sent`, `sent_at`,
`batch_id`) without touching the human-written instructions by using
`context-set`. This command does a shallow merge — existing fields are preserved,
only the specified keys are added or updated.

```bash
# Mark that a batch email was sent
ark tasks context-set "$TASK_ID" --set email_sent=true --set sent_at="2026-05-08T12:00:00Z"

# Multiple fields, different value types
ark tasks context-set "$TASK_ID" \
  --set processed_count=42 \
  --set batch_id="batch-2026-05" \
  --set dry_run=false
```

> **Never call `ark tasks context --data` as an agent.** It replaces the entire
> context object and destroys the human's instructions.

---

## Command Reference

```
ark tasks list             [--status=] [--priority=] [--limit=20] [--cursor=] [--all]
ark tasks get <id>
ark tasks create           --title= [--description=] [--priority=] [--deadline=] [--context=] [--status=hold|draft|queued]
ark tasks update <id>      --log-path=
ark tasks context <id>     --data='<json>' | --clear          # human only
ark tasks context-set <id> --set key=value [--set key2=val2]  # agent only, shallow merge
ark tasks status <id>      --status= [--confidence=] [--comment-id=]
ark tasks claim <id>
ark tasks complete <id>    --confidence=
ark tasks block <id>       --reason=
ark tasks delete <id>
ark tasks ingest-dir <dir> --map=subdir-as-case --task-type= --batch-id=
                         [--status=hold|draft|queued] [--priority=]
                         [--concurrency=12] [--file-concurrency=12]
                         [--resume] [--dry-run] [--include=] [--exclude=]
ark tasks release-batch --batch-id= [--limit=]
ark tasks events <id>
ark tasks inputs list <id>
ark tasks inputs add <id>  --path= [--type=filesystem|storage|url] [--description=]
ark tasks inputs remove <id> <input-id>
ark tasks comments list <id>
ark tasks comments post <id>     --type=note|blocker|comment|approved|changes_requested --body=
ark tasks comments edit <id> <comment-id>   --body=
ark tasks comments delete <id> <comment-id>
ark tasks outputs list <id>
ark tasks outputs submit <id>  --type=json|text|file|screenshot --label= [--data=] [--storage-path=] [--size=]
ark tasks outputs get <id> <output-id>
ark knowledge files list [--task-type=audit|hospital_devolucion|hospital_preventiva]
ark knowledge files url <path> <name>   [--task-type=audit] [--output=<local-path>]
ark knowledge upload <file>    --folder= [--subfolder=] [--description=]
ark learnings files list       [--type=operacional|negocio]
ark learnings files url <path> <name>   [--output=<local-path>]
ark learnings upload           --filename= --size= --mime= --type=operacional|negocio
ark agents status
ark agents heartbeat           --agent-id= [--metadata=<json>]
ark auth status
ark config set <key> <value>
ark config get <key>
ark config list
ark skills
ark schema
ark gen-uuid
ark version
```

Global flags: `--human` (readable output), `--dry-run` (no side effects).

Run `ark --help` for the full reference including flags, environment variables,
and exit codes.

## Limits

| Constraint | Value | Notes |
|---|---|---|
| Upload size | 500 MB | Client-side check before hitting the API; override with `ARK_MAX_UPLOAD_BYTES` only when the API/bucket limit changes |
| JSON payload via `--data` / `--context` | No hard limit | Piped through stdin internally; not subject to OS `ARG_MAX` |
| Task list size | No hard limit | Use `--limit` and `--cursor` for pagination |

Earlier versions (< 0.2.5) passed large JSON through shell arguments, which
could crash on payloads exceeding ~1 MB (the OS `ARG_MAX` limit on macOS).
Upgrade to 0.2.5+ if you hit "Argument list too long" errors.

## Agent Guides

| File | Purpose |
|---|---|
| [AGENTS.md](AGENTS.md) | Quick reference — setup, output envelope, exit codes, idempotency pattern. Load this at cold-start. |
| [skills/SKILL.md](skills/SKILL.md) | Full execution skill — workflows, decision tables, gotchas, worked example. Load this when about to execute a task. |
| [skills/batch-denial-mail.md](skills/batch-denial-mail.md) | Skill for `batch-denial-mail` tasks — delegates to `ark audit send-denial-mail`, sends Excel via GOG, propagates `reply_sent`. |
| [skills/hospital-preventiva-batch-mail.md](skills/hospital-preventiva-batch-mail.md) | Skill for `hospital_preventiva_batch_mail` tasks — delegates to `ark audit send-preventiva-mail`, sends radicación Excel via GOG. |

### Skills overview

| Task type | Skill to load | Automation level |
|---|---|---|
| `general` | `skills/SKILL.md` — Workflow 1 | Agent reasons and executes |
| `eps_audit` | `skills/SKILL.md` — Workflow 1 | Agent audits medical invoice in 3 layers |
| `audit_soat` | `skills/SKILL.md` — Workflow 1 | Agent audits SOAT invoice |
| `hospital_preventiva` | `skills/SKILL.md` — Workflow 1 | Agent audits preventive hospital invoice |
| `hospital_devolucion` | `skills/SKILL.md` — Workflow 1 | Agent audits hospital return |
| `batch-denial-mail` | `skills/batch-denial-mail.md` | Script-only — no LLM reasoning over content |
| `hospital_preventiva_batch_mail` | `skills/hospital-preventiva-batch-mail.md` | Script-only — no LLM reasoning over content |

### Cross-cutting capabilities

| Capability | Commands | When to use |
|---|---|---|
| Learnings | `ark learnings files list`, `ark learnings files url`, `ark learnings upload` | Read prior knowledge before execution; contribute insights after |
| Agent health | `ark agents status`, `ark agents heartbeat` | Monitor agent health; send heartbeats in agent loops |

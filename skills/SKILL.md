---
name: tasks-ark-execution
description: >
  Execute tasks from a task queue using the Tasks Ark CLI (ark). Covers the full
  agent lifecycle: claiming a queued task, reading inputs, doing work, submitting
  outputs, and completing with a confidence score. Also handles blockers,
  follow-on task creation, and re-execution after human feedback. Use when you
  are an agent that needs to pick up and execute tasks from the queue.
version: "1.4"
compatibility: Requires ark CLI installed and configured with a valid api-key and url.
---

# Role

You are an agent executing tasks via the Tasks Ark CLI (`ark`). Your job is to
pick up queued tasks, execute them, and report back — with enough transparency
that a human reviewer can understand exactly what you did and why.

Each task has a clear lifecycle. Before agent work, a human may park it in
`hold` (no OCR, no AI), release it to `draft` (OCR may run, AI frozen), and move
it to `queued` when it is ready for an agent. Agents then claim it, do the work,
submit outputs, and close it with an honest confidence score. The API enforces
every transition; you cannot skip steps or take shortcuts. Follow `next_commands`
from each response — it tells you exactly what is valid next.

---

## Preconditions

Before starting any task work, verify:

```bash
ark auth status
```

Response must contain `"authenticated": true`. If not, run:

```bash
ark config set url <api-url>
ark config set api-key <your-key>
```

If `ark` is not installed, run `bash install.sh` from the tasks-ark-cli repository
or copy the `ark` script to a directory in your `$PATH`.

### Keeping the skill current

Run `ark update` at the start of a session to pull the latest `ark`, `skill.sh`,
and `SKILL.md` from the repo — no manual `git pull` required. The command
delegates to `skill.sh`, which uses a git pull when a checkout is on disk and
falls back to `curl` from `raw.githubusercontent.com/arkangelai/ark-cli/main`
otherwise.

```bash
ark update
```

Expect `{"ok": true, "data": {"mode": "git"|"curl", "previous_version": "...",
"new_version": "...", "already_current": false}}` on success. If `ok:false` with
`error.code: "write_denied"`, re-run as `ARK_UPDATE_SUDO=1 ark update` or surface
the message to the user. Exit code `6` means the install prefix is not writable.

---

## Task Types

| task_type | Qué hace el agente |
|---|---|
| `general` | Razona y ejecuta con instrucciones en `context` |
| `eps_audit` | Audita factura médica en 3 capas |
| `audit_soat` | Audita factura SOAT |
| `soat_glosa_mail` | Comunicación de glosas SOAT |
| `batch-denial-mail` | Delega a `ark audit send-denial-mail` — no razonar |

---

## Workflow 9 — Ejecutar una tarea batch-denial-mail

Este workflow se aplica cuando `.data[0].task_type` es `batch-denial-mail`. El agente no razona sobre el contenido — solo ejecuta el script y reporta el resultado.

### Paso 1: Detectar la tarea

```bash
ark tasks list --status queued --limit 1
```

Leer `.data[0].task_type`. Si es `batch-denial-mail`, seguir este workflow. Si no, usar Workflow 1.

### Paso 2: Tomar la tarea

```bash
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:claim"
ark tasks claim "$TASK_ID"
```

Verificar que `.data.status` sea `"in_progress"` antes de continuar.

### Paso 3: Ejecutar el script

```bash
ark audit send-denial-mail "$TASK_ID"
```

El script maneja internamente: consulta a la API, generación del Excel, envío del correo y cierre. El agente no interviene en ninguno de esos pasos.

### Paso 4: Actualizar las tareas eps_audit individuales

Si exit code `0`, antes de completar la tarea batch, actualizar cada tarea `eps_audit` referenciada en `context.task_ids`:

```bash
BATCH_CTX=$(ark tasks get "$TASK_ID" | jq -c '.data.context')
SENT_AT=$(echo "$BATCH_CTX" | jq -r '.sent_at // empty')
[[ -z "$SENT_AT" ]] && SENT_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

for individual_task_id in $(echo "$BATCH_CTX" | jq -r '.task_ids[]'); do
  export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:ctx:${individual_task_id}"
  ark tasks context "$individual_task_id" \
    --data "{\"reply_sent\": true, \"reply_sent_at\": \"${SENT_AT}\"}" || true
done
```

Si el PATCH de alguna tarea individual falla, registrarlo como comentario `note` en la tarea batch y continuar — no bloquear el flujo completo por un fallo parcial.

### Paso 5: Completar la tarea batch

```bash
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:complete"
ark tasks complete "$TASK_ID" --confidence 1.0
```

Si exit code ≠ `0` en el script: capturar stderr, postearlo como comentario `note` y bloquear la tarea (ver AGENTS.md — Manejo de errores del script send-denial-mail).

**Invariante:** El LLM no interpreta el contenido del Excel ni del correo. No toma decisiones sobre los datos. Solo ejecuta y reporta el resultado.

---

## Workflow 1 — Execute a Queued Task

This is the standard workflow. Follow every step in order.

If the request identifies an existing task by factura, siniestro, patient
document, or client case instead of UUID, resolve it first with:

```bash
ark tasks find "<business identifier>"
```

For exact first-class identifiers, use `ark tasks list --factura-key`,
`--client-ref`, `--batch-id`, or `--parent-task-id`.

### Step 1: Generate a run ID

Generate a unique ID for this execution run. Every idempotency key you use will
be derived from this ID.

```bash
TASK_RUN_ID=$(ark gen-uuid)
```

Never reuse a `TASK_RUN_ID` across different execution runs. If a task is
re-queued after review or a blocker, generate a fresh one.

### Step 2: Find a queued task

```bash
ark tasks list --status queued --limit 1
```

Read from the response:
- `.data[0].id` → store as `TASK_ID`. Required for all subsequent commands.
- `.data[0].title` → what the task is.
- `.data[0].description` → full human explanation of the goal.
- `.data[0].context` → structured JSON instructions. This is your primary input.
- `.meta.count` → if `0`, no work is available. Exit gracefully.

If `.meta.count` is `0`:

```json
{"ok": false, "error": "No queued tasks available"}
```

Exit with code `0`. Do not retry in a tight loop.

### Step 3: Claim the task

```bash
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:claim"
ark tasks claim "$TASK_ID"
```

Read from the response:
- `.data.status` → must be `"in_progress"`. If not, something is wrong — stop and report.
- `.idempotent_replay` → if `true`, this claim was already made in a prior attempt. Continue normally.
- `.next_commands` → the map of valid next operations. Read it. Follow it.

### Step 4: Set your workspace

```bash
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:workspace"
ark tasks update "$TASK_ID" --log-path "storage://tasks/${TASK_ID}/workspace/"
```

Read from the response:
- `.data.log_path` → confirms your workspace path. Write all intermediate artifacts,
  notes, downloaded files, and findings here.

The workspace is your private scratch folder. It is separate from inputs (what to
read) and outputs (what to deliver). It persists across re-runs — if the task is
re-queued, your prior work is still there.

### Step 5: Read all declared inputs

```bash
ark tasks inputs list "$TASK_ID"
```

Read from the response:
- `.data[*].path` → every path you must consult.
- `.data[*].path_type` → `filesystem`, `storage`, or `url`.
- `.data[*].description` → why this path is relevant.
- `.data[*].added_by_type` → `human` (declared by the requester) or `agent`
  (discovered by you in a prior run and registered then).

Process every path. If a path is inaccessible, note it. If it is blocking, go to
Workflow 3.

### Step 6: Do the work

Execute the task using the context from Step 2 and the inputs from Step 5.

**If you discover new data sources during execution** that were not in the input
list, register them:

```bash
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:input:1"
ark tasks inputs add "$TASK_ID" --path "<discovered-path>" --type <filesystem|storage|url>
```

Increment the suffix (`:input:1`, `:input:2`, ...) for each new discovery.

**Post a note** as you move between steps. Notes are tweets — one short line
per step — so a reviewer can scan what you are doing without opening anything:

```bash
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:note:1"
ark tasks comments post "$TASK_ID" --type note --body "Finished data collection, starting analysis."
```

Increment the suffix (`:note:1`, `:note:2`, ...) per note.

Notes are status pings. For anything the reviewer needs to *read* — a plan, a
reasoning writeup, findings with rationale — upload a progress milestone
instead (next subsection).

**Upload a progress milestone** at each phase boundary where you have produced
something a reviewer would want to read — a finished plan, a set of findings
with rationale, an intermediate analysis, a decision log. Milestones document
the reasoning and middle steps behind the final output. They are narrative
artifacts, not debug dumps. They land in the collapsible Progress section on
the task page and do not imply failure.

Rule of thumb: if you have only a one-line status update, post a note. If the
reviewer would want to read it on its own, upload a milestone. Skip phases
that produced nothing worth reading.

**Format.** Use whatever format suits the content — markdown, plain text,
JSON, a screenshot, a log file. Choose `--type` accordingly:

```bash
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:output:progress:1"
ark tasks outputs upload "$TASK_ID" ./phase-1-plan.md --type text --label progress
```

- Increment the idempotency suffix per milestone (`:progress:1`,
  `:progress:2`, ...). Each milestone is a separate upload, not a new version
  of the previous one. Version auto-increment is reserved for genuine
  revisions after `changes_requested`.

**Supporting evidence for a milestone** (screenshots, runtime logs,
intermediate data files) may also use `--label progress` when they belong to
the milestone narrative — not the final deliverable:

```bash
# Browser-state screenshot captured during phase 2
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:output:progress:2:screenshot"
ark tasks outputs upload "$TASK_ID" ./phase-2-browser.png --type screenshot --label progress

# Runtime log (tool transcript, coding-task trace) — not a milestone doc itself
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:output:progress:2:log"
ark tasks outputs upload "$TASK_ID" ./phase-2-trace.log --type log --label progress
```

Use `--label error_log` **only** when the file documents a failure — it is
rendered with emphasis. For milestone narrative and its supporting evidence,
always use `--label progress`.

### Step 7: Determine confidence

Before writing the report, reflect explicitly on the work you just did:

- **What's verified?** Which findings did you cross-check or back with a source?
- **What's uncertain?** Where are you extrapolating or relying on a single signal?
- **What edge cases remain?** What did you deliberately not cover, and why?

Pick a score in `0.0–1.0` using the confidence table in §Decision Table. Store
the score in a shell variable, then post the rationale as a note comment:

```bash
CONFIDENCE=0.87
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:note:confidence"
ark tasks comments post "$TASK_ID" --type note \
  --body "Confidence ${CONFIDENCE}: Verified against 2 source documents; one edge case unresolved: Q4 breakdown missing for region EU-West."
```

Score honestly. Confidence measures how verified and complete your output is,
not how hard you worked.

### Step 8: Upload the final output

Write the output file in whatever format the task's `context` requires. If
`context` specifies JSON, produce JSON. If it specifies CSV, produce CSV. If
it specifies HTML, produce HTML. If no format is specified, choose the format
that best serves the content.

```bash
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:output:report"
ark tasks outputs upload "$TASK_ID" /tmp/output-${TASK_ID}.ext \
  --type file --label report
```

Read from the response:
- `.data.version` → auto-incremented per `(type, label)`. On a re-run this will
  be `2`, `3`, etc. Expected, not an error.
- `.data.storage_path` → where the API stored the file.
- `.data.local_path` → the filesystem path you passed, kept as a trail for the
  reviewer.

### Step 9: Complete the task

Use the same score you posted in the confidence comment:

```bash
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:complete"
ark tasks complete "$TASK_ID" --confidence $CONFIDENCE
```

The CLI routes automatically:
- `≥ 0.85` → transitions to `done`. No human review.
- `< 0.85` → transitions to `review`. Human approves or requests changes.

Do not inflate confidence to skip review. The score in the confidence comment
and the score on the `complete` call must match.

Read from the response:
- `.data.status` → `done` or `review`.
- If `done` → task complete. Exit.
- If `review` → task is paused. Exit. The harness will re-trigger you if the human
  sends it back.

---

## Workflow 2 — Create a Follow-on Task

If during execution you identify additional work that should be done separately,
create a new task directly at `queued` status. It will be picked up immediately.

```bash
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:followon:1"
ark tasks create \
  --title "Follow-on: <what needs to be done>" \
  --status queued \
  --context "{\"source_task\": \"${TASK_ID}\", \"reason\": \"<why this is needed>\"}"
```

Read from the response:
- `.data.id` → the new task's ID. Log it in your current task's output or workspace
  so the human can trace the chain.

---

## Workflow 3 — Signal a Blocker

Use this when you cannot proceed and human intervention is required. Common reasons:
missing credentials, ambiguous instructions, inaccessible data sources.

```bash
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:block"
ark tasks block "$TASK_ID" --reason "<specific description of what is missing and what the human must do>"
```

Be specific in the reason. Write what is missing, why it is needed, and exactly
what the human must do to resolve it. Vague blockers ("couldn't access data")
delay resolution.

Good: `"Missing AWS credentials. Add AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY
to the task context so I can read from s3://company-data/reports/."`

Bad: `"Can't access the data."`

After blocking, exit. The harness will re-trigger you when a human re-queues the task.

Read from the response:
- `.data.status` → must be `"blocked"`. Your workspace is preserved.

---

## Workflow 4 — Handle a Re-queue (Changes Requested)

A human has reviewed your output and sent the task back. This is a new execution
run — generate a fresh `TASK_RUN_ID`.

```bash
TASK_RUN_ID=$(ark gen-uuid)
```

### Step 1: Read the feedback

```bash
ark tasks comments list "$TASK_ID"
```

Find the last comment where:
- `.author_type == "human"`
- `.label == "changes_requested"`

Read `.body` — this is what the human wants changed. If there are multiple
`changes_requested` comments, read them all in chronological order to understand
the full revision history.

### Step 2: Re-claim the task

```bash
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:claim"
ark tasks claim "$TASK_ID"
```

### Step 3: Read inputs again

```bash
ark tasks inputs list "$TASK_ID"
```

The human may have added new inputs since your last run. The list now includes
both your prior agent-discovered paths and any new human-added paths.

### Step 4: Retrieve your prior workspace

```bash
ark tasks get "$TASK_ID"
```

Read `.data.log_path` — your prior workspace still exists. Append to it rather
than starting fresh. Prior evidence is preserved.

### Step 5: Re-execute, re-determine confidence, write and upload the output

Re-run your work addressing the specific feedback. Re-run Workflow 1 Steps 7–8:
determine a fresh confidence score, post a new confidence comment, and upload
the revised output in the format the task context requires:

If the revision involves substantial new reasoning (a new plan, new findings, a
new analysis), upload new milestones as in Workflow 1 Step 6. Consider using a
`rev-N-` filename prefix — where `N` is the revision number — so the reviewer
can tell which run produced each milestone. (The API auto-increments
`(type, label)` versions across runs, so without a filename prefix the reviewer
cannot see the run boundary.)

```bash
CONFIDENCE=0.90
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:note:confidence"
ark tasks comments post "$TASK_ID" --type note \
  --body "Confidence ${CONFIDENCE}: Addressed <specific feedback>; <what changed and why>."

export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:output:report"
ark tasks outputs upload "$TASK_ID" /tmp/output-${TASK_ID}.ext \
  --type file --label report
```

The output version auto-increments. That is expected.

### Step 6: Complete with the new confidence score

```bash
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:complete"
ark tasks complete "$TASK_ID" --confidence $CONFIDENCE
```

---

## Workflow 5 — Attach an Input File

Use this when you need to add a file to a task as an input. Two common cases:

1. **Seeding a follow-on task.** You created a follow-on task (Workflow 2) and
   the downstream agent needs a file you generated.
2. **Registering a local artifact against the current task** so the reviewer can
   inspect it as context, separate from your deliverable.

```bash
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:input:upload:1"
ark tasks inputs upload "$TASK_ID" ./seed-data.csv \
  --description "Extracted from parent task <id>"
```

Increment the suffix (`:input:upload:1`, `:2`, …) for each file you upload in
the same run. The CLI auto-sets `local_path` to the absolute path of the file
you pass — override with `--local-path=` only when you are registering a file
that lives somewhere other than what you are handing to curl.

Read from the response:
- `.data.id` → the input ID. Log it in your output or in the follow-on task's
  `context` so the reviewer can trace the chain.
- `.data.storage_path` → where the API stored the file.
- `.data.path_type` → defaults to `filesystem` (because `--local-path` is set).
  Pass `--path-type storage` if the file lives in Supabase Storage, or `url` if
  it is a remote reference.

Note: `ark tasks inputs add` still exists for registering a **reference** to a
path without uploading anything. Use `inputs add` for paths you cannot or
should not upload (live data lakes, S3 buckets the reviewer already has access
to, public URLs). Use `inputs upload` for files that must travel with the task.

---

## Workflow 6 — Fetch a Stored Document

Use this to download an input or output file that was uploaded earlier. The API
hands back a short-lived (~1 hour) Supabase Storage signed URL; use it
immediately and do not cache it.

```bash
# Signed URL for an output
URL=$(ark tasks documents url "$TASK_ID" output "$OUTPUT_ID" | jq -r '.data.url')
curl -o ./artifact.pdf "$URL"

# Signed URL for an input
URL=$(ark tasks documents url "$TASK_ID" input "$INPUT_ID" | jq -r '.data.url')
curl -o ./seed.csv "$URL"
```

In `--human` mode the URL is printed directly so you can pipe into `xargs`:

```bash
ark --human tasks documents url "$TASK_ID" output "$OUTPUT_ID" | xargs curl -o out.pdf
```

Read from the response:
- `.data.url` → the signed URL. Open it or pass to `curl`.
- `.data.expires_at` → ISO timestamp. If you hit this endpoint again later,
  generate a fresh URL rather than trusting a stored one.
- `.data.storage_path` → the bucket key being signed (useful for logging).

Only records that were uploaded (and therefore have a `storage_path`) can be
fetched this way. A reference-only input registered with `inputs add` will
return `no_stored_file` — read it from its original path instead.

---

## Workflow 7 — Use the Learnings Base

Before starting execution, check if prior learnings exist for this type of work.
After completing a task, contribute new reusable insights.

### Reading learnings

```bash
# List all learnings
ark learnings files list

# Filter by type
ark learnings files list --type=operacional
ark learnings files list --type=negocio

# Download a specific learning
ark learnings files url operacional audit-pattern-eps.md --output /tmp/audit-pattern.md
```

Read from the response:
- For `files list`: `.data` contains files organized by type, each with `name`, `size`, and optionally `url`.
- For `files url`: the file is downloaded to `--output` path (default: `./<name>`). Response includes `url`, `expires_at`, `path`, `local_path`, `size_bytes`.

### Contributing a learning

When you discover a reusable pattern, insight, or operational knowledge during
task execution, request an upload URL:

```bash
ark learnings upload \
  --filename=eps-audit-pattern-duplicate-billing.md \
  --size=3072 \
  --mime=text/markdown \
  --type=operacional
```

Read from the response:
- `.data.upload_url` — use this to PUT the file content.
- `.data.path` — where the learning will be stored.

Types:
- `operacional` — execution patterns, common errors, workarounds, audit heuristics.
- `negocio` — domain rules, regulatory insights, business logic discoveries.

---

## Workflow 8 — Agent Health and Heartbeat

Agents running in a loop must send periodic heartbeats. Use `agents status` to
check health before starting work.

### Check agent health

```bash
ark agents status
```

Read from the response:
- `.data.status` — overall agent health (`active`, `idle`, `stale`).
- `.data.last_heartbeat_at` — when the last heartbeat was received.
- `.data.loop_running` — whether an agent loop is currently active.

### Send a heartbeat

```bash
ark agents heartbeat --agent-id "$AGENT_ID"
```

With diagnostics:

```bash
ark agents heartbeat --agent-id "$AGENT_ID" \
  --metadata '{"cpu_percent":45,"memory_mb":512,"tasks_completed":3,"current_task":"'"$TASK_ID"'"}'
```

Send heartbeats at regular intervals (every 60–120 seconds) during long-running
task execution. If heartbeats stop, the system may consider the agent stale and
re-queue its in-progress tasks.

---

## Output format guidelines

The task's `context` field determines the output format. Labels describe the
*role* of a file, not its format — `--label report` marks the final
deliverable whether it is JSON, CSV, HTML, markdown, a PDF, or any other type.

- **`--label report`** — the primary deliverable. Whatever format `context`
  requires. If `context` does not specify, choose the format that best serves
  the content.
- **`--label artifact`** — complementary files that support the primary
  deliverable (charts, raw data exports, reference files).
- **`--label progress`** — intermediate work products (plans, findings, traces)
  that document reasoning steps. Any format.
- **`--label error_log`** — failure traces only. Not for routine milestone
  narrative.

---

## Decision Table

### Confidence thresholds

| Score | Routes to | When to use |
|---|---|---|
| `0.90 – 1.00` | `done` | Output is verified, complete, and you are certain it is correct |
| `0.85 – 0.89` | `done` | Output is solid, minor uncertainty about edge cases |
| `0.70 – 0.84` | `review` | Output is good but you want a human to verify before it is acted on |
| `0.50 – 0.69` | `review` | Partial output or significant uncertainty |
| `< 0.50` | `review` | Very uncertain — consider blocking instead if missing critical inputs |

### Output delivery pathway

| Label | Shape | Command |
|---|---|---|
| `report` | **Final deliverable** — the primary output in whatever format the task context requires | `outputs upload <file> --type <t> --label report` |
| `artifact` | Complementary file that supports the primary deliverable — image, chart, raw data export | `outputs upload <file> --type <t> --label artifact` |
| `progress` | Intermediate work product (reasoning / plan / findings) the reviewer reads. Any format. Supporting evidence (screenshots, logs, intermediate data) also allowed when it belongs to the milestone narrative | `outputs upload <file> --type <t> --label progress` |
| `error_log` | Raw trace on failure only — highlighted as a failure signal. Do not use for routine milestone narrative (causes alarm fatigue) | `outputs upload <file.log> --type log --label error_log` |
| Any label, pre-staged in Storage | Registered by reference | `outputs submit --type <t> --label <l> --storage-path 'storage://...' --size <bytes>` |
| Any label, larger than 500 MB | Stage out-of-band first | Stage to Storage → `outputs submit --storage-path` |

### Status transitions available to you

Pre-agent states follow `hold -> draft -> queued`. A human can release a held
task with `ark tasks status <id> --status draft`; agents should only claim
`queued` work.

| From | To | Command |
|---|---|---|
| `queued` | `in_progress` | `ark tasks claim <id>` |
| `in_progress` | `done` | `ark tasks complete <id> --confidence ≥0.85` |
| `in_progress` | `review` | `ark tasks complete <id> --confidence <0.85` |
| `in_progress` | `blocked` | `ark tasks block <id> --reason "..."` |

Any other agent transition returns `422`. Read `.error.detail.allowed` to see
what is valid from the current state.

### Writing execution metadata to context

| Trigger | Command |
|---|---|
| Mark that an email was sent during a batch run | `ark tasks context-set <id> --set email_sent=true --set sent_at="<iso-ts>"` |
| Record an external ID produced during execution | `ark tasks context-set <id> --set external_id="<value>"` |
| Store any execution field without touching human-written fields | `ark tasks context-set <id> --set <key>=<value>` |

Use `context-set` whenever you need to annotate the task record with facts produced during your run. Never use `ark tasks context --data` — that replaces the entire context and destroys the human's instructions.

---

## Gotchas

**`review → queued` requires a `comment_id`.**
When a human re-queues a task from review, they must post a `changes_requested`
comment first and include its ID in the transition. This is enforced by the API.
As an agent, you do not perform this transition — the human does. But you must
read that comment to understand your new instructions (see Workflow 4, Step 1).

**Always follow `next_commands`, never hardcode sequences.**
Every task response includes a `next_commands` map of ready-to-run CLI commands
valid for the current state and actor. Read it. It is the contract. Do not assume
a status sequence based on what you think should come next.

**Idempotency keys must be unique per action and per run.**
`${TASK_RUN_ID}:claim` is valid for retrying the same claim in the same run.
It is not valid in a different run. A re-queued task is a new run — generate a
fresh `TASK_RUN_ID`. Reusing keys across runs causes the API to return a cached
response from the old run.

**Output versions increment automatically.**
Do not include a version field when submitting outputs. The API auto-increments
per `(task_id, output_type, label)`. On a re-run, version 2 is expected and correct.

**`ark tasks block` makes two API calls.**
It posts a `blocker` comment, then transitions status to `blocked`. The
idempotency key you set covers both calls internally. Do not try to split this
into separate comment + status calls.

**The `context` field is your instruction set.**
`tasks.context` is a JSON object the human wrote. It is not metadata — it is
your primary task instructions. Always read it from the initial `tasks list`
response. Parse it as JSON and use its fields to guide your execution.
A human can update it at any time via `ark tasks context <id> --data '<json>'`
or clear it with `--clear`. If context changes while you are running, you will
not be notified — the task must be re-queued for you to pick up the new
instructions.

**Never call `ark tasks context <id> --data` or `--clear` as an agent.**
Those commands replace the entire context object and are reserved for humans.
Calling them will destroy fields written by the human or by prior execution runs.

**To write fields into the context, use `ark tasks context-set`.**
When you need to record execution metadata (e.g., `email_sent`, `sent_at`,
`batch_id`) after completing an action, use:
```bash
ark tasks context-set <id> --set email_sent=true --set sent_at="2026-05-08T12:00:00Z"
```
This does a shallow merge at the root level — existing fields are preserved,
only the keys you specify are added or updated.

**`outputs submit` and `outputs upload` are different verbs for different
shapes.** `submit` is for inline JSON/text and for registering already-staged
Supabase Storage files (metadata only). `upload` is for binary content you
have locally — it pushes the file and records the row in one call. Never
inline binary content through `--data`, and never call `submit` with a local
filesystem path that has not been staged to Storage.

**Upload endpoints cap at 500 MB per file by default.** `ark tasks inputs upload` and
`ark tasks outputs upload` short-circuit before the HTTP call when the file is
larger. For anything bigger, stage the file to Supabase Storage directly and
register it with `outputs submit --storage-path` or `inputs add --path`.
Override `ARK_MAX_UPLOAD_BYTES` only if the backend limit changes.

**`--label progress` is for intermediate work products (and their supporting
evidence); `--label error_log` is for failures only.** Progress is the agent's
narrative — rendered in a collapsible section for the reviewer. error_log is a
failure signal and is highlighted. A runtime log under `--label progress` uses
`--type log` and is evidence for a milestone, not a milestone on its own.
Misusing `error_log` creates alarm fatigue.

**Signed URLs expire in ~1 hour.** `ark tasks documents url` hands you a fresh
one each call. Do not cache them between runs — generate one when you need to
download, and discard it after use.

**`inputs add` is a reference; `inputs upload` transports the file.** Use
`inputs add --path storage://…` or `--path https://…` to declare a path the
task should consult without moving any bytes. Use `inputs upload <file>` to
actually attach the file contents. Both are valid, and both show up in
`inputs list`; pick based on whether the file needs to travel with the task.

---

## Error Handling

### Transient errors (network, rate limit)

If a command fails with exit code `1` or `29`:

1. Read `error.retryable` from stderr.
2. If `true`: wait 2 seconds, set `ARK_IDEMPOTENCY_KEY` to the same key used in
   the first attempt, and retry the same command.
3. Retry at most 3 times with exponential backoff (2s, 4s, 8s).
4. If still failing after 3 attempts: block the task with reason
   `"Persistent network error after 3 retries. Last error: <error.message>"`.

### Invalid status transition (exit code 5)

Read `.error.detail.allowed` from stderr — it lists the valid next states from
the current status. Correct your command and retry.

### Auth error (exit code 3)

Run `ark auth status`. If `authenticated: false`, reconfigure:

```bash
ark config set api-key <correct-key>
```

### Not found (exit code 4)

The task ID does not exist. Stop this branch. Do not retry.

### Any unrecoverable error

Silent failure is never acceptable. On any unrecoverable error:

1. Upload the raw trace as an error log:

   ```bash
   export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:output:error_log"
   ark tasks outputs upload "$TASK_ID" /tmp/run.log --type log --label error_log
   ```

2. Complete with a low confidence score — routes to `review` for human triage:

   ```bash
   export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:complete"
   ark tasks complete "$TASK_ID" --confidence 0.10
   ```

---

## Postconditions

A successful task execution produces all of the following:

- Task status is `done` or `review` (or `blocked` if a genuine blocker was hit).
- At least one output has been submitted — either `--label report` on success, or `--label error_log` on failure.
- `log_path` is set on the task (workspace was created).
- A confidence score is recorded on the task.
- Every input path from `inputs list` was consulted or accounted for.

---

## Worked Example

```bash
# Setup
TASK_RUN_ID=$(ark gen-uuid)

# Find work
TASK_JSON=$(ark tasks list --status queued --limit 1)
TASK_ID=$(echo "$TASK_JSON" | jq -r '.data[0].id')
CONTEXT=$(echo "$TASK_JSON" | jq -c '.data[0].context')
# e.g. CONTEXT = {"analyze": "sales data", "output_format": "summary_json"}

# Claim
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:claim"
ark tasks claim "$TASK_ID"

# Set workspace
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:workspace"
ark tasks update "$TASK_ID" --log-path "storage://tasks/${TASK_ID}/workspace/"

# Read inputs
ark tasks inputs list "$TASK_ID" | jq -r '.data[].path'
# e.g. /data/sales/q1.csv, storage://reports/targets.json

# Post a progress note
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:note:1"
ark tasks comments post "$TASK_ID" --type note --body \
  "Loaded 2 input files. Starting analysis."

# Upload a progress milestone at the start of analysis (phase 1 plan)
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:output:progress:1"
ark tasks outputs upload "$TASK_ID" ./phase-1-plan.md --type text --label progress

# ... do the analysis ...

# Upload findings before final submission (phase 2)
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:output:progress:2"
ark tasks outputs upload "$TASK_ID" ./phase-2-findings.md --type text --label progress

# Determine confidence and post rationale as a comment
CONFIDENCE=0.91
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:note:confidence"
ark tasks comments post "$TASK_ID" --type note \
  --body "Confidence ${CONFIDENCE}: All figures verified against source CSVs; SKU ranking reproducible. No unresolved edge cases."

# Write the final output — context specifies output_format: summary_json
# so produce JSON with revenue/target/top-product fields

# Upload the final output
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:output:report"
ark tasks outputs upload "$TASK_ID" /tmp/output-${TASK_ID}.json \
  --type file --label report

# Complete with the same confidence
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:complete"
ark tasks complete "$TASK_ID" --confidence $CONFIDENCE
# → status: done (confidence ≥ 0.85, no human review needed)
```

---

## Quick Reference

```
ark tasks list --status queued --limit 1      Find available work
ark tasks find "<business identifier>"        Find an existing task
ark tasks list --factura-key "FE 57100"       Filter by exact business column
ark tasks claim <id>                          Claim it (queued → in_progress)
ark tasks update <id> --log-path <path>       Declare workspace
ark tasks inputs list <id>                    What to read
ark tasks inputs add <id> --path <p> --type   Register a reference-only source
ark tasks inputs upload <id> <file>           Upload a file as an input (≤ 500 MB)
ark tasks ingest-dir <dir> --map subdir-as-case --task-type <type> --batch-id <id>
                                              Bulk-create case tasks and upload inputs (hold requires human key + audit_soat)
ark tasks release-batch --batch-id <id> --limit <N>
                                              Release held batch tasks to draft (human key only)
ark tasks comments post <id> --type note      Post progress updates
ark tasks outputs upload <id> <file> --type <t> --label report
                                              Upload the final deliverable (format per task context)
ark tasks outputs upload <id> <file> --type <t> --label artifact
                                              Upload a complementary file supporting the deliverable
ark tasks outputs upload <id> <file> --type <t> --label progress
                                              Upload an intermediate work product
ark tasks outputs submit <id> --type --label  Deliver inline data or register a pre-staged storage path
ark tasks documents url <id> <kind> <rec-id>  Short-lived signed URL (~1h)
ark tasks complete <id> --confidence <score>  Close the task
ark tasks block <id> --reason <reason>        Signal a blocker
ark tasks comments list <id>                  Read human feedback on re-queue
ark tasks get <id>                            Fetch current state + next_commands
ark tasks create --title <t> --type <general|eps_audit|audit_soat|soat_glosa_mail>
                                              Create a task with an explicit type
ark check                                     Compare CLI fields against live API spec
```

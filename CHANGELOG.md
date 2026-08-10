# Changelog

All notable changes to Tasks Ark are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## Unreleased

### Added
- `ark tasks ingest-dir <dir>` — bulk directory ingestion where each
  subdirectory is a case/task. Supports `--map subdir-as-case`, `--task-type`,
  `--status`, `--priority`, `--batch-id`, bounded upload concurrency,
  `--resume`, `--dry-run`, and include/exclude globs.
- `ark tasks release-batch --batch-id <id> --limit <N>` — releases held batch
  tasks to `draft` gradually through the batch release API.
- Documented the `hold -> draft -> queued` task lifecycle and the `ark tasks status <id> --status draft` release command.
- Added `hold` and `draft` to task status help and surfaced task statuses in `ark skills`.

### Changed
- Raised the default client-side upload ceiling from 50 MB to 500 MB for task
  inputs, outputs, knowledge uploads, and bulk ingestion. The limit can still be
  overridden with `ARK_MAX_UPLOAD_BYTES` if the backend limit changes.
- Aligned `ingest-dir` with the Salmona bulk-ingest API on `main`: input batch
  registration now sends `files[]` with stable `client_ref` values and parses
  both `created` and `deduped` task rows on retry/resume.

### Fixed
- URL-encoded every `ark tasks list` query value so opaque pagination cursors
  containing `+` reach the API verbatim instead of being decoded as spaces.

---

## [0.5.0] — 2026-06-18

### Added
- **Learnings API** — 3 nuevos comandos para gestionar la base de aprendizajes:
  - `ark learnings files list [--type=operacional|negocio]` — lista archivos de aprendizajes
    con filtro opcional por tipo. Endpoint: `GET /api/learnings/knowledge/files`.
  - `ark learnings files url <path> <name> [--output=<path>]` — descarga un archivo de
    aprendizaje vía URL firmada. Endpoint: `GET /api/learnings/knowledge/files/url`.
  - `ark learnings upload --filename= --size= --mime= --type=` — solicita URL de carga
    para un aprendizaje (uso de agente). Endpoint: `POST /api/learnings/knowledge/upload`.
- **Agents API** — 2 nuevos comandos para monitoreo de agentes:
  - `ark agents status` — snapshot de salud de agentes (status, last_heartbeat_at,
    loop_running). Endpoint: `GET /api/agents/status`.
  - `ark agents heartbeat --agent-id= [--metadata=<json>]` — envía heartbeat periódico
    con diagnósticos opcionales. Endpoint: `POST /api/agents/heartbeat`.
- `ark skills` — nuevos workflows: `learnings_list`, `learnings_download`,
  `learnings_upload`, `agents_health`, `agents_heartbeat`.
- `AGENTS.md` — tabla de comandos actualizada con los 5 nuevos comandos.

---

## [0.4.0] — 2026-06-10

### Added
- `audit_soat` — nuevo task type para auditoría de facturas SOAT.
  Tarea de razonamiento simple: el agente lee el `context` y audita usando Workflow 1 (`execute_queued_task`).
  Listado en `ark skills`, `ark tasks create --type`, `README.md` y `skills/SKILL.md`.

---

## [0.3.5] — 2026-05-21

### Changed
- `ark knowledge files list` — agrega `--task-type=audit|hospital_devolucion|hospital_preventiva`
  (default: `audit`). Ruta al endpoint correcto según el dominio de la tarea:
  `audit` → `/api/audit/knowledge/files`,
  `hospital_devolucion` → `/api/hospitales/devolucion/knowledge/files`,
  `hospital_preventiva` → `/api/hospitales/preventiva/knowledge` (stub, retorna `[]`).
- `ark knowledge files url` — agrega `--task-type` (default: `audit`). Solo soporta `audit`;
  los demás tipos retornan error descriptivo (`hospital_devolucion` embebe las URLs en el
  list response; `hospital_preventiva` es stub).

---

## [0.3.4] — 2026-05-14

### Added
- `skills/` — nueva carpeta que organiza todos los documentos de skill por tipo de tarea.
  Contiene `SKILL.md` (skill general), `batch-denial-mail.md` y `hospital-preventiva-batch-mail.md`.
- `scripts/send-preventiva-mail.ts` — script batch para radicación preventiva hospitalaria.
  Lee los outputs de cada tarea `hospital_preventiva`, genera un Excel azul ("Facturas Radicadas"
  + "Resumen"), lo sube a Supabase Storage en `preventiva-mails/` y devuelve `local_path` para
  adjuntar vía GOG. Análogo a `send-denial-mail` pero orientado a pagadores.
- `skills/hospital-preventiva-batch-mail.md` — skill doc completo para tareas
  `hospital_preventiva_batch_mail`: 6 pasos (claim → ejecutar script → enviar GOG → propagar
  reply_sent → completar), tabla de errores e invariante de no-interpretación LLM.
- `skills/batch-denial-mail.md` — skill doc especializado para tareas `batch-denial-mail`:
  flujo de 6 pasos, harness bash completo, tabla de errores.
- `ark skills` — nuevo task type `hospital_preventiva_batch_mail` y operación
  `send-preventiva-mail` en `audit_subcommand`, workflow `batch_preventiva_mail`.

### Changed
- `scripts/send-denial-mail.ts` — Excel mejorado: frozen header row, fuente Calibri con
  constantes `FONT_BASE`/`FONT_HEADER`, formato contable (accounting) en columnas de valor,
  anchos de columna refinados. Guarda el archivo en `tmpdir()` antes de subir y expone
  `local_path` en el stdout para que el agente pueda adjuntarlo directamente con GOG.

### Fixed
- `ark tasks create --type` y `ark skills` ahora reconocen `hospital_devolucion_batch`.
  La API ya aceptaba el tipo (vive en `VALID_TASK_TYPES` de Salmona), pero el help del CLI
  y el mapa `task_types` de `ark skills` no lo listaban, así que los agentes no confiaban en
  él y caían a `hospital_devolucion`. Ahora el tipo de lote de glosas está advertido.

---

## [0.3.3] — 2026-05-07

### Added
- `SKILL.md` — tabla de task types reconocidos (`general`, `eps_audit`, `batch-denial-mail`)
- `SKILL.md` — Workflow 7: flujo para tareas `batch-denial-mail`. El agente detecta el tipo,
  toma la tarea, ejecuta `ark audit send-denial-mail <task_id>`, y completa con
  `confidence 1.0` o bloquea con el stderr completo. El LLM no razona sobre el contenido.
- `AGENTS.md` — Workflow 6: script de ejemplo con captura de stderr y bloqueo estructurado
  para tareas `batch-denial-mail`
- `AGENTS.md` — sección "Manejo de errores del script send-denial-mail": flujo de 4 pasos
  (capturar stderr, postear como `note`, bloquear con razón formateada, no reintentar) +
  tabla de exit codes de referencia (0/1/2)

---

## [0.3.2] — 2026-05-03

### Added
- `ark tasks context <id> --data '<json>'` — reemplaza el context de una tarea con un objeto JSON arbitrario (human only).
- `ark tasks context <id> --clear` — establece el context a null.

---

## [0.3.1] — 2026-04-30

### Changed
- Add `hospital_preventiva` and `hospital_devolucion` to `task_type` enum
- Add `critical` to `priority` enum
- Add `approved` and `changes_requested` to comment label enum
- Add `diff` to `output_label` enum in `ark skills` JSON response

---

## [0.3.0] — 2026-04-27

### Added
- `ark knowledge files list` — list all knowledge base files organized by category with inline signed URLs.
- `ark knowledge files url <path> <name>` — get a fresh signed URL for a specific knowledge base file and download it locally. Accepts `--output=<path>` (default: `./<name>`). Returns `{ url, expires_at, path, local_path, size_bytes }`.
- `ark knowledge upload <file>` — upload a file to the knowledge base. Requires `--folder`; optional `--subfolder` and `--description`.
- `ark tasks delete <id>` — delete a draft task (human-only, creator-only).
- `ark tasks comments edit <id> <comment-id> --body=<text>` — edit own comment body (human-only).
- `ark tasks comments delete <id> <comment-id>` — delete own comment (human-only).
- `.gitignore` — `.context` is now gitignored.

---

## [0.2.5] — 2026-04-24

### Fixed
- `ok_response()` crash on large payloads. Task data was passed to jq via
  `--argjson data "$data"`, a command-line argument subject to the OS
  `ARG_MAX` limit (~1 MB on macOS). Listing hundreds of tasks could exceed
  that limit and kill the process (exit 127, "Argument list too long").
  Data now flows through stdin (`printf '%s' "$data" | jq -n 'input as $data | …'`),
  which has no size constraint. Small metadata args (`links`, `cmds`, `meta`)
  remain as `--argjson` since they never approach the limit.
- Same `ARG_MAX` fix applied to `cmd_tasks_outputs_submit()` (`--data`),
  `cmd_tasks_create()` (`--context`), and `dry_run_response()` (`body`).
  All three accept user-supplied JSON that can exceed the limit.
- Replaced every `echo "$var" | jq` with `printf '%s' "$var" | jq`
  throughout the script. `echo` can misinterpret leading dashes as flags or
  expand backslash sequences in some shells; `printf '%s'` is immune.

### Bumped
- `ARK_VERSION` 0.2.4 → 0.2.5.

---

## [0.2.4] — 2026-04-22

### Changed
- Output labels are now format-agnostic. `--label report` marks the final
  deliverable in whatever format the task's `context` requires — no longer
  mandates HTML. `--label progress` accepts any format for intermediate work
  products. The task's `context` field is the sole authority on output format.
- Removed `§Report design guidelines` and the HTML template from `SKILL.md`.
  Replaced with a short `§Output format guidelines` section.
- Removed the `milestone-N-{descriptor}.md` naming convention and markdown
  requirement for progress uploads.
- Confidence rationale is now posted as a `--type note` comment rather than
  embedded in the output file. `Workflow 1` condensed from 10 to 9 steps
  (Steps 8 and 9 merged into "Upload the final output").
- Failure path simplified: upload `--label error_log` then
  `complete --confidence <low>`. No `--label report` required on failure.
- `diff` label removed from the `output_label` enum (undocumented, unused).
- `ark skills` workflow keys renamed: `upload_output_report` → `upload_output`,
  `upload_output_file` removed (merged into `upload_output`),
  `upload_output_file` (artifact role) → `upload_output_artifact` (new),
  `upload_progress_milestone` → `upload_progress`.
- `AGENTS.md` and `README.md` updated to remove HTML-specific framing.

### Bumped
- `ARK_VERSION` 0.2.3 → 0.2.4.
- `SKILL.md` frontmatter version 1.1 → 1.2.

---

## [0.2.3] — 2026-04-21

### Added
- `ark tasks create --type <general|eps_audit>` — set task type at creation time
  (immutable after creation; defaults to `general` if omitted).
- `ark check` — fetches the live API spec from `https://audit.arkangel.ai/api/openapi.json`
  and compares its Task schema fields against the CLI's known field list.
  Exits `0` when up-to-date, `1` when the API has fields the CLI doesn't know about.
  Override the spec URL with `ARK_CHECK_URL=<url>`.

### Bumped
- `ARK_VERSION` 0.2.2 → 0.2.3

---

## [0.2.2] — 2026-04-20

### Changed
- Agents now deliver their primary report as an HTML file uploaded via
  `ark tasks outputs upload <file.html> --type file --label report`, not as
  inline JSON. Reviewers get a readable, print-to-PDF-friendly page instead of
  raw JSON. `outputs submit --type json` still works but is no longer the
  documented default for `--label report`.
- `SKILL.md` Workflow 1 restructured from 8 to 10 steps. A new explicit
  "Determine confidence" step (Step 7) lands before writing the report;
  confidence now appears as a dedicated end-of-report section with a
  one-paragraph rationale, not a bare number.
- `SKILL.md` adds a new §"Report design guidelines" that ships a full HTML
  template + CSS. Fixed palette (warm white `#fafaf7`, near-black text `#111`,
  gray meta `#888`, faint dividers `#e5e5e0`), Arial-only, no JS, no
  animations, print-friendly `@page` and `@media print` rules.
- `SKILL.md` failure path now produces two outputs: a raw trace via
  `--type log --label error_log`, plus an HTML report summarizing the failure
  and referencing the attached log. Routes to `review` for human triage.
- If a task's `context` requests an alternate format (JSON, CSV, etc.), agents
  produce that file AND the HTML report; the alternate uploads as
  `--label artifact`. The `--label report` upload is always HTML.
- `AGENTS.md` and `README.md` updated to teach the new HTML-first default.
- `SKILL.md` §Report design guidelines now states the HTML must be standalone
  (no references to milestone filenames or other task-page artifacts), so the
  printed PDF survives outside the task page.
- `SKILL.md` Workflow 4 Step 5 teaches revision-run milestones to use a
  `rev-N-` filename prefix so reviewers can tell which run produced each
  milestone. (Prior: silence; API auto-increment collapsed original and
  revision milestones into one version stream with no boundary.)
- `ark skills` `execute_queued_task` workflow now teaches the HTML report
  upload, replacing the legacy JSON-submit example. New
  `upload_output_report` workflow makes the HTML default a first-class
  discovery entry parallel to `upload_progress_milestone`.

### Bumped
- `ARK_VERSION` 0.2.1 → 0.2.2.
- `SKILL.md` frontmatter version 1.0 → 1.1.

---

## [0.2.1] — 2026-04-20

### Docs

- Clarified `--label progress` semantics. Progress outputs are reasoning /
  plan / milestone documents the agent inserts so reviewers can see the middle
  steps behind the final output — not debug logs.
- Primary format is markdown (`--type text` with a `.md` file), detailed but
  not verbose. Filename convention: `milestone-N-{descriptor}.md`.
- Supporting evidence for a milestone (screenshots, runtime logs, intermediate
  JSON) may also use `--label progress` when it belongs to the milestone
  narrative. Use `--label error_log` only for failures.
- Added a Label Decision Table to SKILL.md next to the existing shape table.
- Added `upload_progress_milestone` to the `ark skills` workflow catalog.
  `upload_progress_log` remains (rewritten to demonstrate the runtime-log
  evidence case, not the primary milestone case).

---

## [0.2.0] — 2026-04-17

### Added
- `ark tasks inputs upload <id> <file>` — multipart upload of a local file as a
  task input. Sets `local_path` automatically to the file's absolute path. Flags:
  `--description`, `--local-path`, `--path-type`.
- `ark tasks outputs upload <id> <file> --type --label` — multipart upload of a
  binary deliverable (agent only). Accepts `--type=json|text|file|screenshot|log`
  and `--label=report|artifact|error_log|progress|diff`. Flag: `--local-path`.
- `ark tasks documents url <id> <input|output> <record-id>` — fetch a
  short-lived (~1 hour) Supabase Storage signed URL for a stored input or output.
- `http_upload` helper — shared curl wrapper for multipart/form-data requests,
  mirrors `http_request`'s status/replay/request-id capture.
- Client-side 50 MB ceiling check for both upload commands; exits with
  `payload_too_large` before hitting the API.
- `ark skills` now exposes `enums` (valid `output_type`, `output_label`,
  `path_type` values), `upload_limits`, and four new workflows:
  `upload_output_file`, `upload_progress_log`, `upload_input_file`,
  `fetch_document_url`.
- `next_cmds` recognizes `upload_input`, `upload_output`, and `document_url`
  link relations.

### Changed
- `SKILL.md` Workflow 1 Step 7 reworked around three delivery pathways
  (inline `--data`, `outputs upload`, pre-staged `--storage-path`) with a new
  decision table.
- `SKILL.md` adds Workflow 5 (Attach an Input File) and Workflow 6 (Fetch a
  Stored Document), plus four new gotchas covering upload vs. submit, size
  caps, progress vs. error_log labels, and signed-URL expiry.
- `ark tasks outputs submit` usage text now documents the full label set
  including the new `progress` label.

---

## [0.1.5] — 2026-04-17

### Added
- `skill.sh` — self-updater for `ark`, `SKILL.md`, and `install.sh`. Two-mode:
  `git fetch` + `install.sh` when a checkout is on disk; raw `curl` from
  `raw.githubusercontent.com/arkangelai/tasks-ark-cli/main` otherwise
- `ark update` command — delegates to sibling `skill.sh`, or bootstraps via
  `curl | bash` when no local `skill.sh` is present
- Exit code `6` — write denied on update; retry with `ARK_UPDATE_SUDO=1`
- `install.sh` now lays down `skill.sh` into the install prefix and copies
  `SKILL.md` + `install.sh` into `${XDG_DATA_HOME:-~/.local/share}/tasks-ark-cli`

### Changed
- `SKILL.md` gains a "Keeping the skill current" subsection documenting
  `ark update` for agents

---

## [0.1.4] — 2026-04-16

### Changed
- `README.md` rewritten to explain the full agent workflow: task lifecycle diagram,
  6-step execution flow with code, re-queue pattern, and agent guides table
  linking to `SKILL.md` and `AGENTS.md`

---

## [0.1.3] — 2026-04-16

### Added
- `SKILL.md` — framework-agnostic agent skill document (YAML frontmatter + Markdown)
  covering the full task execution lifecycle for any LLM-based agent
- 4 named workflows: Execute Queued Task, Create Follow-on Task, Signal Blocker,
  Handle Re-queue (Changes Requested)
- Decision tables for confidence thresholds, output storage mode, and valid status
  transitions
- Gotchas section documenting the 6 non-obvious behaviours that cause silent failures
- Error handling with explicit retry ladder (transient, invalid transition, auth, not found)
- Pre/postconditions and a fully worked end-to-end example

---

## [0.1.2] — 2026-04-16

### Changed
- `ark --help` and `ark help` now exit with code `0` (previously exited `2`)
- Help output reorganized into labeled sections: SETUP, TASKS, INPUTS, COMMENTS, OUTPUTS, CONFIG, UTILITY, GLOBAL FLAGS, ENVIRONMENT, EXIT CODES
- Each command now shows inline flag enums and valid values

---

## [0.1.1] — 2026-04-16

### Added
- `ark` — full bash CLI for AI agents to interact with the Tasks API
- `install.sh` — installer script; places `ark` in `/usr/local/bin` or `~/.local/bin`
- `AGENTS.md` — complete agent guide: setup, output envelope, idempotency pattern, confidence routing, 4 standard workflows, retry harness template
- `README.md` — quick start, full command reference, install instructions

### Authentication
- API key auth via `ark config set api-key <key>` — no login flow required
- `ark auth status` validates the key live against `GET /api/tasks?limit=1`; reports `authenticated: true/false` and masked key

### Commands
| Group | Commands |
|---|---|
| Tasks | `list`, `get`, `create`, `update`, `status`, `claim`, `complete`, `block`, `events` |
| Inputs | `inputs list`, `inputs add`, `inputs remove` |
| Comments | `comments list`, `comments post` |
| Outputs | `outputs list`, `outputs submit`, `outputs get` |
| Auth | `auth status` |
| Config | `config set`, `config get`, `config list` |
| Utility | `skills`, `schema`, `gen-uuid`, `version` |

### Output envelope
Every command returns a consistent JSON envelope:
```json
{
  "ok": true,
  "cli_version": "0.1.0",
  "data": {},
  "_links": {},
  "next_commands": {},
  "idempotent_replay": false,
  "request_id": "uuid"
}
```
Errors go to stderr with `ok: false`, machine-readable `error.code`, and `suggestion`.

### Exit codes
| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Network / generic error |
| `2` | Bad arguments |
| `3` | Auth error 401/403 |
| `4` | Not found 404 |
| `5` | Conflict / invalid transition 409/422 |
| `29` | Rate limited 429 |

### Bug fixes
- Fixed bash brace-expansion bug in `ok_response`: `${2:-{}}` was producing `{}}` when `$2` was already `{}`; replaced with intermediate variable pattern

### Removed
- `ark auth login` / `ark auth logout` — superseded by API key config
- `PROMPT.md` — superseded by implementation

---

## [0.1.0] — 2026-04-16

### Added
- Initial implementation brief (`PROMPT.md`)

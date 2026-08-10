---
status: complete
priority: p2
issue_id: "004"
tags: [bash, cli, tasks, downloads]
dependencies: []
---

# Download task outputs and inputs directly

## Problem Statement

Reading a stored task result currently requires listing outputs, selecting the
latest report version with `jq`, resolving a signed URL, and invoking `curl`.
Inputs require the same URL-resolution and download ceremony. This duplicates
error-prone shell logic in every CLI consumer.

## Findings

- `ark tasks outputs list` returns output metadata but not stored file content.
- `ark tasks documents url` resolves signed URLs for both input and output
  records, but callers must still invoke `curl` themselves.
- The CLI already contains signed-download patterns for knowledge and learning
  files, so task downloads can follow the same authentication and error
  conventions.
- Output lists may contain multiple labels and versions; selection must not
  depend on response order.

## Proposed Solutions

### Option 1: Compose existing endpoints in new CLI commands

**Approach:** Add `tasks outputs download` and `tasks inputs download`. Select
the highest matching output version by default, request its signed URL, and
stream the stored bytes to stdout or a requested file.

**Pros:** Solves the common workflow without requiring a new API endpoint and
keeps selection semantics in one maintained place.

**Cons:** An output download still performs two API requests internally.

**Effort:** Small

**Risk:** Low

### Option 2: Add a server-side resolved download endpoint

**Approach:** Ask the API to select the output and redirect or return content.

**Pros:** One API request from the CLI and one canonical server implementation.

**Cons:** Requires a coordinated backend release and does not help current API
deployments.

**Effort:** Medium

**Risk:** Medium

## Recommended Action

Implement Option 1 now. Default output selection to `label=report` and the
highest numeric version, support explicit `--label`, `--version`, and `-o` /
`--output`, and stream raw content to stdout when no destination is supplied.

## Technical Details

**Affected files:**

- `ark`
- `tests/tasks-download.sh`
- `README.md`
- `AGENTS.md`
- `skills/SKILL.md`
- `CHANGELOG.md`

**Database changes:** None.

## Resources

- GitHub issue: https://github.com/arkangelai/ark-cli/issues/12

## Acceptance Criteria

- [x] `tasks outputs download` defaults to the latest `report` output.
- [x] `--label` and `--version` select an explicit stored output.
- [x] `tasks inputs download` downloads a specified input record.
- [x] Both commands stream raw bytes to stdout when no output path is given.
- [x] Both commands support `-o` and `--output` and return download metadata.
- [x] Missing records, invalid versions, missing signed URLs, and failed
      downloads produce structured errors with appropriate exit codes.
- [x] Help, README, agent guidance, capability discovery, and changelog are
      updated.
- [x] Bash syntax, integration tests, full test suite, and diff checks pass.

## Work Log

### 2026-08-10 - Investigation and implementation started

**By:** Codex

**Actions:**

- Read GitHub issue #12 and traced output listing, document URL resolution, and
  existing signed-file download implementations.
- Confirmed the feature can be implemented entirely in the CLI against the
  current API contract.
- Chose order-independent maximum-version selection and raw stdout streaming.

**Learnings:**

- This is a read-only leaf path with no persisted state, callbacks, or
  idempotency interaction.
- File-mode metadata can follow the existing knowledge-download response shape,
  while stdout mode must contain only document bytes for pipeline safety.

### 2026-08-10 - Implementation completed

**By:** Codex

**Actions:**

- Added output selection by label and numeric version, defaulting to the latest
  `report`, with URI-encoded task and record identifiers.
- Added shared signed-document downloading with raw stdout mode and atomic
  file replacement plus standard download metadata in file mode.
- Added structured validation and failure responses for missing outputs,
  malformed flags, absent signed URLs, storage download failures, and invalid
  destinations.
- Added an integration-style fake API/storage test covering the full chain,
  and updated help, capability discovery, operator docs, agent guidance, and
  the unreleased changelog.
- Ran Bash syntax checks, every repository test, capability JSON assertions,
  composed-command dry runs, and `git diff --check`; all passed.

**Learnings:**

- Keeping raw stdout free of CLI metadata makes JSON and text outputs directly
  composable while file mode can still report traceable storage metadata.
- `shellcheck` and `shfmt` are not installed in this workspace, so linting was
  limited to `bash -n`, the complete shell test suite, and diff validation.

## Notes

- The optional `tasks show` bonus is outside the core issue acceptance scope.

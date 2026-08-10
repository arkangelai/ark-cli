---
status: complete
priority: p1
issue_id: "002"
tags: [bash, cli, search, tasks]
dependencies: []
---

# Find tasks by business identifier

## Problem Statement

Operators usually know a factura, siniestro, patient document, or client case
identifier—not the task UUID. The CLI can only fetch one task by UUID and does
not expose the proposed business-column filters or text-search endpoint.

## Findings

- `cmd_tasks_list` only forwards `status`, `priority`, `limit`, and `cursor`.
- There is no `tasks find` dispatch entry.
- The repository is CLI-only; server-side filters, search, and indexes must be
  deployed by the API repository.
- The live OpenAPI contract does not yet expose the proposed filters or
  `/tasks/search`, so the CLI and API changes require a coordinated rollout.

## Proposed Solutions

### Option 1: Expose only first-class column filters

**Approach:** Add `factura_key`, `client_ref`, `batch_id`, and `parent_task_id`
flags to `tasks list`.

**Pros:** Small and immediately useful for exact identifiers.

**Cons:** Does not cover context-only identifiers such as siniestro or patient
document.

**Effort:** Small

**Risk:** Low

### Option 2: Add filters and text search

**Approach:** Add the four list filters plus `ark tasks find <text>`, backed by
`GET /api/tasks/search?q=`.

**Pros:** Covers both first-class and context-based business identifiers.

**Cons:** Depends on matching backend routes and indexes.

**Effort:** Small in the CLI; backend work is separate.

**Risk:** Medium due to cross-repository rollout coordination.

## Recommended Action

Implement Option 2 using the API contract proposed in GitHub issue #10. Encode
all query values, retain pagination metadata, return only `id`, `status`, and
`title` from `tasks find`, and cover the real CLI-to-HTTP path with a local
stub integration test.

## Technical Details

**Affected files:**

- `ark`
- `tests/tasks-find.sh`
- `README.md`
- `AGENTS.md`
- `skills/SKILL.md`
- `CHANGELOG.md`

**Database changes:** None in this CLI repository. The API must independently
add the server filters, search route, and appropriate indexes.

## Resources

- GitHub issue: https://github.com/arkangelai/ark-cli/issues/10

## Acceptance Criteria

- [x] `tasks list` forwards `factura_key`, `client_ref`, `batch_id`, and
      `parent_task_id` with URI-component encoding.
- [x] `ark tasks find <text>` calls `/api/tasks/search?q=` and supports bounded
      pagination through `--limit` and `--cursor`.
- [x] Search output contains task `id`, `status`, and `title`, plus list
      metadata in JSON mode.
- [x] Missing search text and unknown options return a structured argument
      error with exit code 2.
- [x] CLI help, agent guidance, README, and changelog document the capability.
- [x] Bash syntax, integration tests, and diff checks pass.

## Work Log

### 2026-08-10 - Investigation and implementation started

**By:** Codex

**Actions:**

- Read GitHub issue #10 and traced the task list request/response path.
- Confirmed the repository contains only the CLI and supporting documentation.
- Checked the live OpenAPI document and confirmed the server contract is not
  deployed yet.
- Selected the issue's proposed list-filter and search endpoint contract.

**Learnings:**

- A local fake `curl` can exercise argument parsing, URL construction, HTTP
  response handling, and output projection without credentials.

### 2026-08-10 - Implementation completed

**By:** Codex

**Actions:**

- Added exact business-column filters and consistent URI-component encoding to
  `tasks list`.
- Added `tasks find`, JSON result projection, human-readable output, and command
  discovery through help and `ark skills`.
- Added an integration-style shell test for the full CLI-to-HTTP path,
  pagination metadata, human output, and structured argument failures.
- Updated operator and agent documentation plus the unreleased changelog.
- Ran `bash -n`, `tests/tasks-find.sh`, `ark skills` validation, and
  `git diff --check`; all passed.

**Learnings:**

- This is a read-only leaf path: it has no callbacks, persisted state, retry
  interaction, or parallel mutation interface that requires broader tests.
- `shellcheck` and `shfmt` are not installed in the workspace, so linting was
  limited to Bash syntax and diff validation.

## Notes

- Runtime availability depends on the corresponding API deployment.

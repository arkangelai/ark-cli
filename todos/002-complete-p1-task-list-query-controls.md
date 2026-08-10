---
status: complete
priority: p1
issue_id: "002"
tags: [cli, performance, tasks, pagination]
dependencies: []
---

# Add efficient task-list query controls

Implement GitHub issue #14 so callers can bound task listings by creation time,
choose deterministic ordering, and request only the fields they need.

## Problem Statement

`ark tasks list` only supports status, priority, limit, and cursor filters. At
production scale, callers must scan the full task history in the server's
implicit order and download complete descriptions and contexts for every task.

## Findings

- `cmd_tasks_list` builds a query string directly in `ark` and has no date,
  ordering, or projection options.
- The public API schema currently documents the legacy list parameters only, so
  the CLI change must preserve those defaults while forwarding the new API
  contract proposed in issue #14.
- The repository has no existing automated test harness; the command functions
  are sourceable, so list behavior can be tested with a mocked `http_request`
  boundary while exercising the real argument parser and output envelope.
- Documentation is duplicated across `README.md`, CLI help, `ark skills`, and
  `skills/SKILL.md` and must remain synchronized.

## Proposed Solutions

### Option 1: Forward server-side query controls

**Approach:** Add `--since`, `--until`, `--sort`, `--order`, `--fields`, and
`--brief`; map them to `created_after`, `created_before`, `sort`, `order`, and
`fields` query parameters. Make `--brief` a documented projection shorthand.

**Pros:** Reduces transfer size at the source; preserves list envelope and
pagination semantics; directly matches the issue.

**Cons:** Requires the API deployment to implement the forwarded parameters.

**Effort:** 2-3 hours

**Risk:** Low

---

### Option 2: Project and sort client-side

**Approach:** Download full pages and use `jq` to select fields, filter dates,
and sort results locally.

**Pros:** Works without API changes.

**Cons:** Does not solve the network payload or full-history pagination cost;
sorting a page is not equivalent to sorting the complete result set.

**Effort:** 2 hours

**Risk:** High due to misleading semantics

## Recommended Action

Implement Option 1 with URL-encoded query values, focused argument validation,
an executable Bash regression suite, and synchronized user/agent documentation.
Keep all existing defaults unchanged.

## Technical Details

**Affected files:**
- `ark` - list parser, query construction, capability map, and help
- `tests/tasks-list.sh` - command-level regression coverage
- `README.md` - user-facing reference and examples
- `skills/SKILL.md` - agent-facing command reference
- `CHANGELOG.md` - unreleased feature entry

**Database changes:** None in this repository.

## Resources

- GitHub issue: https://github.com/arkangelai/ark-cli/issues/14
- Live primary API schema: https://audit.arkangel.ai/api/openapi.json

## Acceptance Criteria

- [x] `--since` and `--until` forward URL-encoded `created_after` and `created_before` values.
- [x] `--sort` and `--order` forward ordering controls, with invalid order values rejected locally.
- [x] `--fields` forwards a validated comma-separated projection.
- [x] `--brief` requests the documented minimal projection and conflicts clearly with `--fields`.
- [x] Legacy invocations retain their existing query parameters and output envelope.
- [x] CLI help, README, changelog, capability map, and agent skill reference document the feature.
- [x] Automated task-list tests and Bash syntax checks pass.

## Work Log

### 2026-08-10 - Implementation started

**By:** Codex

**Actions:**
- Read GitHub issue #14 and confirmed there are no follow-up comments.
- Inspected `cmd_tasks_list`, help text, capability map, and documentation.
- Compared the current CLI contract with the live primary OpenAPI schema.
- Selected server-side query forwarding to address the measured payload cost.

**Learnings:**
- Client-side projection would make stdout smaller but would not address the
  issue's dominant network-transfer cost.
- The current branch is the dedicated Conductor branch `issue-14` at
  `origin/main`, so no branch change is needed.

### 2026-08-10 - Implementation completed

**By:** Codex

**Actions:**
- Added all six CLI controls and URL-encoded query forwarding in `ark`.
- Added structured validation for missing values, projection syntax,
  projection conflicts, and sort order.
- Added `tests/tasks-list.sh` with 18 assertions covering new, legacy, error,
  encoding, envelope, and forward-compatibility behavior.
- Updated CLI help, `ark skills`, README, AGENTS guide, and changelog.
- Ran Bash 3.2 syntax checks for every shell entrypoint, the regression suite,
  capability/help assertions, and `git diff --check` successfully.

**Learnings:**
- Query values need URI encoding because opaque cursors and ISO timestamps can
  contain reserved characters.
- Projection syntax should be validated without a static field allowlist so a
  newer API field can be requested before the next CLI release.

## Notes

- API implementation is outside this repository; this change defines and
  forwards the CLI side of the proposed contract.

---
status: complete
priority: p1
issue_id: "001"
tags: [bash, cli, pagination]
dependencies: []
---

# URL-encode task list query values

## Problem Statement

`ark tasks list --cursor <meta.next_cursor>` interpolates the opaque cursor
directly into the query string. A `+` in an ISO timestamp offset is decoded by
the server as a space, so valid page-two requests fail.

## Findings

- `cmd_tasks_list` concatenates `limit`, `status`, `priority`, and `cursor`
  without URL encoding in `ark`.
- The CLI already requires `jq`, whose `@uri` formatter can encode each value.
- The repository has no existing automated shell-test harness.

## Proposed Solutions

### Option 1: Encode only the cursor

**Approach:** Apply `jq @uri` only to `cursor`.

**Pros:** Smallest change.

**Cons:** Leaves the same query-construction bug in other user-provided values.

**Effort:** Small

**Risk:** Low

### Option 2: Encode every task-list query value

**Approach:** Add a small URI-component helper and apply it to all task-list
query parameters.

**Pros:** Consistent and robust for current parameters.

**Cons:** Slightly larger diff.

**Effort:** Small

**Risk:** Low

## Recommended Action

Implement Option 2 and add an integration-style shell regression test that
captures the URL passed to `curl`.

## Technical Details

**Affected files:**

- `ark`
- `tests/tasks-list-url-encoding.sh`
- `CHANGELOG.md`

## Resources

- GitHub issue: https://github.com/arkangelai/ark-cli/issues/5

## Acceptance Criteria

- [x] A cursor containing `+` is sent with `%2B` and round-trips verbatim.
- [x] All `tasks list` query values are URI-component encoded consistently.
- [x] A regression test exercises the real CLI-to-HTTP request construction.
- [x] Syntax checks and regression tests pass.
- [x] The unreleased changelog documents the fix.

## Work Log

### 2026-08-10 - Implementation started

**By:** Codex

**Actions:**

- Confirmed the raw query interpolation in `cmd_tasks_list`.
- Selected consistent URI-component encoding for all list query values.

**Learnings:**

- A fake `curl` can provide a lightweight integration boundary without adding
  a test-framework dependency.

### 2026-08-10 - Implementation completed

**By:** Codex

**Actions:**

- Added `uri_encode` and applied it to every `tasks list` query value.
- Added `tests/tasks-list-url-encoding.sh` to capture and assert the final URL.
- Documented the fix under the unreleased changelog.
- Ran `bash -n`, the regression test, and `git diff --check`; all passed.

**Learnings:**

- The request-construction path is a leaf change with no callbacks, state, or
  alternate interfaces requiring broader integration coverage.
- `shellcheck` is not installed in the workspace, so linting was limited to
  Bash syntax validation.

---
status: complete
priority: p2
issue_id: "004"
tags: [cli, tasks, filters, github-issue-7]
dependencies: []
---

# Expose task list filters

## Problem Statement

`ark tasks list` does not expose the API-supported `task_type` and
`created_by_type` filters. Operators should also be able to select tasks by
`parent_task_id` and `batch_id` without bypassing the CLI or reading API keys
from local configuration.

## Findings

- `cmd_tasks_list` already forwards `batch_id` and `parent_task_id` to the API.
- The CLI currently lacks `task_type` and `created_by_type` arguments.
- The issue proposes `--type` / `--task-type`, `--created-by-type`, `--parent`,
  and `--batch-id`; the CLI currently documents only `--parent-task-id`.
- This repository contains the CLI client, not the tasks API implementation.

## Proposed Solutions

### Option 1: Extend the existing list command

**Approach:** Add the missing filters and aliases to `cmd_tasks_list`, retaining
the current query construction and pagination behavior.

**Pros:** One request, backward compatible, follows existing CLI patterns.

**Cons:** Requires the deployed API to support each query parameter.

**Effort:** Small.

**Risk:** Low.

### Option 2: Add a separate tree command

**Approach:** Add `ark tasks tree <id>` backed by a dedicated API endpoint.

**Pros:** Purpose-built response for parent/child task views.

**Cons:** Larger API and CLI surface; does not solve general creator/type
filtering.

**Effort:** Medium to large.

**Risk:** Medium.

## Recommended Action

Extend `ark tasks list` with `--type` and `--task-type` aliases,
`--created-by-type`, `--parent` and `--parent-task-id` aliases, and the existing
`--batch-id`. Cover both `--flag=value` and `--flag value` forms, query URL
encoding, help output, and agent-facing documentation.

## Technical Details

**Affected files:**
- `ark`
- `tests/tasks-list.sh`
- `tests/tasks-find.sh`
- `README.md`
- `AGENTS.md`
- `skills/SKILL.md`
- `CHANGELOG.md`

**Database changes:** None in this repository.

## Resources

- GitHub issue: https://github.com/arkangelai/ark-cli/issues/7
- Related issue: https://github.com/arkangelai/ark-cli/issues/6

## Acceptance Criteria

- [x] `ark tasks list` accepts `--type` and `--task-type` in both forms.
- [x] `ark tasks list` accepts `--created-by-type` in both forms.
- [x] `ark tasks list` accepts `--parent` as an alias for `--parent-task-id`.
- [x] All filter values are URL-encoded and forwarded with exact API field names.
- [x] CLI and agent-facing documentation list the supported filters.
- [x] Existing and new tests pass.
- [x] Shell syntax validation passes.

## Work Log

### 2026-08-10 - Initial investigation

**By:** Codex

**Actions:**
- Read GitHub issue #7 and traced `cmd_tasks_list` query construction.
- Confirmed that batch and parent filtering already exist in the current branch.
- Selected a backward-compatible extension of `ark tasks list`.

**Learnings:**
- The CLI already uses a shared URL encoder for every list filter.
- The API implementation is outside this repository, so this change can expose
  only the endpoint parameters supported by the deployed service.

### 2026-08-10 - Implementation and verification

**By:** Codex

**Actions:**
- Added `task_type` and `created_by_type` query construction plus task-type and
  parent flag aliases in `ark`.
- Updated built-in help, `ark skills`, README, agent instructions, and changelog.
- Expanded task-list tests to cover spaced and equals forms, aliases, URL
  encoding, and structured errors for missing values.
- Ran all six repository test scripts, `bash -n`, `git diff --check`, and an
  `ark skills` discovery assertion successfully.

**Learnings:**
- The change is a leaf-node GET request builder: it has no persistence,
  callbacks, retries, or alternate state-mutating paths.
- `shellcheck` is not installed in this workspace; shell syntax and the complete
  executable test suite passed.

## Notes

- Preserve `--parent-task-id` for existing users while adding the issue's shorter
  `--parent` spelling.

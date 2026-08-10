---
status: complete
priority: p1
issue_id: "001"
tags: [cli, tasks, operations, performance]
dependencies: []
---

# Add an efficient task-status summary

## Problem Statement

Operators and agents cannot count tasks by status without paging through every
task. Large states take hundreds of requests and can exceed an agent's runtime.
The existing `--all` flag is also misleading because it only requests one page
of 100 tasks.

## Findings

- `ark tasks list` maps `--all` to `limit=100`; it does not traverse cursors.
- The CLI has no count or stats command.
- The issue explicitly prefers one request to `GET /api/tasks/stats` returning a
  status histogram.

## Proposed Solutions

1. Expose `meta.total` from list responses. This requires the API to include the
   total and still needs one request per status for a histogram.
2. Add `ark tasks count` with filters. This is efficient for one status but not
   for a complete operational overview.
3. Add `ark tasks stats` backed by `GET /api/tasks/stats`. This answers the main
   operational question in one request and is the issue's preferred option.

## Recommended Action

Add `ark tasks stats`, preserve the API's stats payload in the standard CLI
envelope, support human-readable output, surface it in help/capability docs, and
make the existing `--all` flag follow every pagination cursor instead of
silently truncating at 100 tasks.

## Acceptance Criteria

- [x] `ark tasks stats` makes one `GET /api/tasks/stats` request.
- [x] JSON output follows the standard success envelope.
- [x] Human output renders each returned status and count.
- [x] HTTP and argument errors follow existing CLI conventions.
- [x] Help, README, skills, AGENTS guide, and changelog document the command.
- [x] `--all` no longer implies an exhaustive list.
- [x] Syntax and command behavior are verified with automated or mock-server checks.

## Work Log

### 2026-08-10 - Implementation started

**By:** Codex

**Actions:**
- Read GitHub issue #6 and mapped the CLI list implementation.
- Selected the one-request stats endpoint approach proposed by the issue.

**Learnings:**
- This repository contains the Bash CLI and agent-facing documentation; the
  command should remain a thin adapter over the API aggregation endpoint.

### 2026-08-10 - Implementation completed

**By:** Codex

**Actions:**
- Added `ark tasks stats` with JSON, human-readable, and standard HTTP error
  behavior.
- Changed `ark tasks list --all` to traverse `meta.next_cursor` and aggregate
  every matching page.
- Updated help, discovery output, README, agent skill, AGENTS guide, and
  changelog.
- Added and ran seven Bash tests covering dispatch, output formats, errors, and
  multi-page list aggregation.

**Learnings:**
- The live OpenAPI does not yet expose `/api/tasks/stats`; the CLI command is the
  client half of the contract and requires the server aggregation route.
- The server caps pages at 100, confirming that cheap counts cannot be solved in
  the CLI alone.

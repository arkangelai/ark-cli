---
status: complete
priority: p1
issue_id: "001"
tags: [cli, bulk-upload, tasks]
dependencies: []
---

# Bulk Directory Ingestion

## Problem Statement

The CLI uploads task inputs one file per invocation and rejects files over 50 MB, which makes large case loads impractical and mismatches the backend bucket limit.

## Findings

- `ark` is a single Bash CLI with shared HTTP helpers, multipart upload helpers, and task command dispatch.
- The public OpenAPI spec does not yet expose the new batch endpoints, so the implementation must follow the issue contract and parse responses defensively.
- Existing upload commands use a single `ARK_MAX_UPLOAD_BYTES` constant set to 50 MB.

## Proposed Solutions

- Add first-class `ark tasks ingest-dir` and `ark tasks release-batch` commands in the existing Bash CLI.
- Reuse `http_request`, `ok_response`, and existing envelope conventions.
- Increase the shared upload limit to 500 MB and update docs/capability metadata.

## Recommended Action

Implement the commands directly in `ark`, document them in help/README/changelog, and validate with dry-run plus shell syntax checks.

## Acceptance Criteria

- [x] `ark tasks ingest-dir` enumerates subdirectories as cases and supports filtering, dry-run, resume, batch creation, batch signed URL creation, bounded uploads, retries, and JSON progress/summary.
- [x] `ark tasks release-batch --batch-id <id> --limit N` calls the release endpoint.
- [x] Upload guards for existing upload commands use 500 MB messaging/metadata.
- [x] README/help/skills/changelog mention the new commands and limits.
- [x] Syntax and dry-run checks pass locally.

## Work Log

### 2026-07-06 - Implementation

**By:** Codex

**Actions:**
- Created todo from GitHub issue #3 and started implementation on branch `issue-3`.
- Added `ark tasks ingest-dir` with subdirectory case enumeration, include/exclude filtering, resume status lookup, batch task creation, batch input signed URL requests, bounded PUT uploads, retry handling, and a final JSON summary.
- Added `ark tasks release-batch`.
- Raised the default upload guard to 500 MB and updated `ark skills`, help, README, `skills/SKILL.md`, and changelog.
- Verified with `bash -n ark`, dry-run ingest/release smoke checks, upload-limit failure behavior, and `git diff --check`.

**Learnings:**
- The batch endpoints are not in the live OpenAPI spec yet, so client-side schema tolerance is important.
- The repo runs on Bash 3.2, so the upload worker uses simple bounded waves instead of newer `wait -n` behavior.

# Story 4-1 — dry-run-mode

Status: ready-for-dev
Epic: 4 — Dry-run & CLI hardening

## Goal

Add a `--dry-run` flag to the `leanproxy-mcp server run` command so users can preview their token savings without making real tool calls.

## Acceptance Criteria

### AC1 — CLI flag is wired end-to-end

**Given** I run `leanproxy-mcp server run --dry-run --stdio`
**When** the proxy starts
**Then** every upstream tool call is intercepted and a synthetic response is returned
**And** the response is annotated with `dry_run: true` so the LLM can distinguish it.

### AC2 — Per-call savings are reported

**Given** the proxy is running with `--dry-run`
**When** at least one tool call has been intercepted
**Then** a tally is printed to stderr with: total calls, total tokens not spent, average ratio vs. native MCP.

### AC3 — Standard exit code on completion

**Given** a `--dry-run` session completes without internal error
**When** the user sends SIGTERM or the client disconnects
**Then** the proxy exits with code 0 and the savings report is written to `--report <path>` if set.

## Tasks / Subtasks

- [ ] Add `--dry-run` flag to `cmd/server/run.go`.
- [ ] Implement `internal/proxy/dryrun.go` with synthetic response generator.
- [ ] Add per-call savings tally in `internal/metrics/savings.go`.
- [ ] Write Go tests in `internal/proxy/dryrun_test.go` covering happy path + flag-parsing edge cases.
- [ ] Update README quickstart with `--dry-run` snippet.
- [ ] Mark story status `review` in `sprint-status.yaml`.

## Dev Notes

- Reuse the existing `internal/proxy/intercept.go` plumbing where possible.
- Dry-run responses must include the same tool name and shape as the live one so downstream agent prompts are unaffected.
- Match the savings calculation in `internal/metrics/savings.go` (already shipping).

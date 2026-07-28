---
name: bmad-dev-loop
description: 'Iterate over a list of story keys, executing the full delivery pipeline (dev → review → PR → CI → merge) for each one. Use when the user says "loop these stories [list]", "run the dev loop on [story keys]", "ship these stories", or "deliver these epics end-to-end".'
license: MIT
compatibility: opencode
metadata:
  audience: developers
  workflow: bmad
  pipeline: dev-review-pr-ci-merge
---

# Dev Loop Workflow

**Goal:** Deliver each story in an input list through the full pipeline: implement, review, branch, PR, CI-check, merge — then move to the next.

**Your Role:** Automated delivery orchestrator. You coordinate subagents, manage git, and drive PRs to merge. No human interaction inside the loop body.

## What this skill is

A standalone, hardened version of the loop orchestrator originally delivered as **`bmad-loop`** in [leanproxy-mcp#245](https://github.com/mmornati/leanproxy-mcp/pull/245). It is self-contained, configurable via a 3-layer TOML customization file, and ships with samples, a schema, and a CLI installer.

## What this skill is NOT

- Not a project planner. Stories must already exist as `{implementation_artifacts}/{key}.md`.
- Not a CI runner. It uses the GitHub CLI (`gh`) to drive PRs and CI status; no CI defined here.
- Not a substitute for `bmad-dev-story`. It *invokes* `bmad-dev-story` as a subagent per story.

## HALT protocol

To HALT with a final status and optional blocking condition:

1. If applicable, append a loop-status entry to `{loop_status_file}`.
2. Run: `python3 {project-root}/_bmad/scripts/resolve_customization.py --skill {skill-root} --key workflow.on_complete`
3. If the resolved `workflow.on_complete` is non-empty, follow it as the final instruction before exiting.
4. Stop the workflow.

The full taxonomy of terminal statuses is in [docs/safety.md](https://mmornati.github.io/bmad-dev-loop/guide/safety).

### Terminal status taxonomy

| Status | Meaning |
|---|---|
| `done` | All stories in `{validated_stories}` reached `merged`. |
| `blocked` | Work halted because an invariant failed (see blocking conditions below). |
| `halted_dry_run` | `workflow.dry_run = true` — plan displayed, no work executed. |

### Common blocking conditions

- `no subagents` — runtime cannot dispatch subagents synchronously.
- `no valid story keys found` — invocation prompt contained no `N-N` or `epic-N` tokens.
- `no ready-for-dev stories in input list` — all stories skipped due to status.
- `story dev failed: {key} — {details}` — dev subagent returned an error.
- `CI failures persisted after {n} retries for story {key} (PR #{n})` — CI failed too many times.
- `CI timeout for story {key} (PR #{n})` — total CI wait > `ci_timeout_minutes`.
- `merge failed for story {key} (PR #{n})` — `gh pr merge` returned non-zero.

## Subagents

Using subagents when instructed is mandatory. If you cannot, HALT with status `blocked` and blocking condition `no subagents`.

Invoke every subagent **synchronously**: launch it, wait for it to return within the same turn, then continue with its result. Never run a subagent in the background / detached / async (e.g. `run_in_background: true`), and never end your turn to await a completion notification. This workflow runs unattended: there is no event loop to resume a yielded turn, so a backgrounded subagent never hands control back and the run stalls. The only sanctioned way to end a turn is the HALT protocol above with an explicit terminal `status`.

### Subagent preconditions (bake into each prompt)

- `git rev-parse --abbrev-ref HEAD` — confirm clean working tree and target branch.
- `gh auth status` — confirm GitHub CLI is authenticated.
- Read-only filesystem access; no network egress outside `gh`, `git`, and the package registry.
- If `workflow.review_model_override` (or `ci_fix_agent_model_override`) is non-empty, the subagent prompt includes a routing instruction.

## Conventions

- Bare paths (e.g. `steps/step-01-ingest-input.md`) resolve from the skill root.
- `{skill-root}` resolves to this skill's installed directory (where `customize.toml` lives).
- `{project-root}`-prefixed paths resolve from the project working directory.
- `{skill-name}` resolves to the skill directory's basename.

## Input resolution

Parse the invocation prompt for space-separated story keys (e.g. `"4-1 4-2 4-3"`). Store as `{story_keys}` array, preserving order. If the prompt contains no recognizable story keys, HALT with status `blocked` and blocking condition `no story keys provided`.

Supported patterns per element:
- `N-N` — story key like `4-1`
- `epic-N` — epic key like `epic-4` (expanded later by step-01)

### Invocation examples

```
/bmad-dev-loop 4-1 4-2 4-3          # Three specific stories
/bmad-dev-loop 4-1                   # Single story
/bmad-dev-loop epic-4                # All ready-for-dev stories in epic 4
```

## On Activation

### Step 1: Resolve the Workflow Block

Run: `python3 {project-root}/_bmad/scripts/resolve_customization.py --skill {skill-root} --key workflow`

**If the script fails**, resolve the `workflow` block yourself by reading these three files in base → team → user order and applying the same structural merge rules as the resolver:

1. `{skill-root}/customize.toml` — defaults
2. `{project-root}/_bmad/custom/{skill-name}.toml` — team overrides
3. `{project-root}/_bmad/custom/{skill-name}.user.toml` — personal overrides

Any missing file is skipped. Scalars override, tables deep-merge, arrays of tables keyed by `code` or `id` replace matching entries and append new entries, and all other arrays append.

### Step 2: Execute Prepend Steps

Execute each entry in `{workflow.activation_steps_prepend}` in order before proceeding.

### Step 3: Load Persistent Facts

Treat every entry in `{workflow.persistent_facts}` as foundational context you carry for the rest of the workflow run. Entries prefixed `file:` are paths or globs under `{project-root}` — load the referenced contents as facts. All other entries are facts verbatim.

### Step 4: Load Config

Load config from `{project-root}/_bmad/bmm/config.yaml` and resolve:

- `project_name`, `planning_artifacts`, `implementation_artifacts`, `user_name`
- `communication_language`, `document_output_language`, `user_skill_level`
- `date` as system-generated current datetime
- `sprint_status` = `{implementation_artifacts}/sprint-status.yaml`
- `project_context` = `**/project-context.md` (load if exists)
- YOU MUST ALWAYS SPEAK OUTPUT in your Agent communication style with the config `{communication_language}`
- Language MUST be tailored to `{user_skill_level}`
- Generate all documents in `{document_output_language}`

Resolve customization overrides (with defaults):

- `review_model_override` = resolved value from `{workflow.review_model_override}` (default: empty)
- `ci_poll_interval_seconds` = resolved value from `{workflow.ci_poll_interval_seconds}` (default: 30)
- `ci_max_retries` = resolved value from `{workflow.ci_max_retries}` (default: 3)
- `ci_timeout_minutes` = resolved value from `{workflow.ci_timeout_minutes}` (default: 30)
- `merge_strategy` = resolved value from `{workflow.merge_strategy}` (default: `squash`)
- `branch_prefix` = resolved value from `{workflow.branch_prefix}` (default: `story/`)
- `ci_fix_agent_model_override` = resolved value from `{workflow.ci_fix_agent_model_override}` (default: empty)
- `dry_run` = resolved value from `{workflow.dry_run}` (default: false)

### Step 5: Greet the User

Greet `{user_name}`, speaking in `{communication_language}`.

### Step 6: Execute Append Steps

Execute each entry in `{workflow.activation_steps_append}` in order.

Activation is complete. If `activation_steps_prepend` or `activation_steps_append` were non-empty, confirm every entry was executed in order before proceeding. Do not begin the main workflow until all activation steps have been completed.

## Paths

- `sprint_status` = `{implementation_artifacts}/sprint-status.yaml`
- `loop_status_file` = `{implementation_artifacts}/loop-status.yaml`

## Dry run

If `{workflow.dry_run}` is true, after step-01's confirmation checkpoint, write the planned `loop_status_file` with all stories set to `pending`, print the plan, and HALT with status `halted_dry_run`.

## First workflow step

Read fully and follow: `./steps/step-01-ingest-input.md` to begin the workflow.

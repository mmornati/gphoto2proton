# bmad-dev-loop

Standalone BMAD dev-loop skill — automated multi-story delivery orchestrator.

This folder is the installable artifact. See [the project README](../../README.md) and the [documentation site](https://mmornati.github.io/bmad-dev-loop/) for installation and usage.

## What this folder contains

```
SKILL.md             # master instructions — entry point
customize.toml       # 3-layer customization surface
steps/
  step-01-ingest-input.md    # parse story keys, expand epic refs, plan display
  step-02-execute-loop.md    # 6-phase per-story delivery loop body
examples/
  sample-sprint-status.yaml  # sample INPUT (sprint status)
  sample-story.md            # sample INPUT (story file)
  sample-loop-status.yaml    # sample OUTPUT (loop status)
LICENSE
README.md            # this file
```

## Quick install

```bash
# From the project root
node /tmp/bmad-dev-loop/bin/bmad-dev-loop.js install

# Or copy this folder manually
cp -R skills/bmad-dev-loop /your/project/.opencode/skills/
```

## Invoke

```
/bmad-dev-loop 4-1 4-2 4-3
/bmad-dev-loop epic-4
```

The skill will:

1. Validate story keys against `{implementation_artifacts}/sprint-status.yaml`.
2. Confirm the plan with you.
3. For each story: dev subagent → review subagent → branch → PR → CI polling (with auto-fix retries) → merge.
4. Move to the next story until the list is exhausted.

See [SKILL.md](./SKILL.md) for the full state machine and customization keys.

## License

MIT. See [LICENSE](./LICENSE).

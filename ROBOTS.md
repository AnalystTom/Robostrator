# Robostrator

Maintained by AnalystTom, with upstream credit to Kun Chen.
This is a public independent adaptation with fresh Git history; [NOTICE.md](NOTICE.md) records the original author and source snapshots.

## What changed

- [robots-operations](.agents/skills/robots-operations/SKILL.md)

The user-facing roles are Boss, Robostrator, and workers.
The inherited contract maps those names in [AGENTS.md](AGENTS.md); internal identifiers such as `FM_HOME`, `bin/fm-*`, and `data/captain.md` remain compatible with existing homes.
Boss names the owner's role, not a required greeting in every reply.

The profile favors a specific requested outcome, remembered decisions, bounded clarification, and evidence that separates tested, merged, and live.
The runtime engines are unchanged.
Existing active skills, Firstmate homes, and the installed no-mistakes binary have not been replaced.

## Quality gate

Use upstream No Mistakes as the standard gate for projects configured with the `no-mistakes` delivery mode.
Keep Robostrator's task instructions and selected skills in this library, and project-specific checks in the project's gate configuration.
The upstream gate owns review, fixes, tests, documentation, push, PR creation, and CI; Robostrator owns the requested outcome, worker coordination, and the evidence needed for handoff.
Passing the gate does not establish that the requested user journey or live route works unless that acceptance check was actually exercised.

This is a composition policy, not a replacement validation engine or an automatic migration of existing homes.
Existing `direct-PR` and `local-only` project choices still apply; the [delivery contract](AGENTS.md#selected-delivery-path-and-merge-authority) owns their behavior and merge authority.
Pin and validate upstream upgrades before adopting them; branding alone is not a reason to fork the gate implementation.

## Use and edit

Open a fresh task and ask the agent to read the linked Robots skill for the task you want to perform.
Edit those files in this repository and review their behavior on the scenarios in the Robots Skills repository before rollout.
For a durable installation, select only the desired Robots skill directories in your harness's supported skill installer; avoid installing a second copy of every upstream skill.
Do not point an active Firstmate home or production gate at this checkout without a separate migration and isolated smoke test.

## Provenance and updates

- Upstream: https://github.com/kunchenguid/firstmate
- Starting commit: `350cb69dca8e157ee32fa533164f46b19b9c4a7d`.
- Snapshot fetched: 2026-11-04 UTC.
- Original licence: [LICENSE](LICENSE).
- Owner repository: https://github.com/AnalystTom/Robostrator

`origin` points to the AnalystTom repository.
Maintainers may add the original project as a read-only `upstream` remote for comparison.
The public release starts with a new root commit; compare upstream updates against the snapshot recorded in NOTICE.md.
Review upstream updates on a branch and rerun the relevant checks before adopting them.
Keep upstream notices and names in their original code; robot branding lives in the user-facing profile, not renamed binary interfaces.

## Validation boundary

Skill structure and document links can be checked mechanically.
That does not establish model behavior or a lower failure rate.
The scenario set is a calibration starting point, not a benchmark result.

## Code file size

The lint pipeline and both CI lint partitions run `python3 bin/fm-code-lines.py`.
New code files have a 1,000 physical-line maximum, including comments and blank lines.
Existing oversized files have exact reviewed ceilings in `.code-lines.json`; they may not grow.
When one shrinks, lower its ceiling, or remove its entry once it reaches 1,000 lines.
A deleted file must lose its entry too.
Split by responsibility and preserve public behavior; do not minify code, delete useful comments, or move it to a different extension to satisfy the check.
The checker includes tracked files and unignored new source files; generated source is not exempt.
Its header owns invocation; its `EXTENSIONS` and `NAMES` sets define the supported source types.

## Factory recipes and skills

An optional companion Robots Skills checkout supplies `factory/README.md` for skill selection, private input snapshots and evidence-backed outcome recording.
That companion repository is not part of this public release; when unavailable, use the built-in lifecycle without claiming recipe recording.
`robots-operations` loads that procedure for substantial measured work while the existing executor retains supervision and recovery.
The recorder does not launch workers or establish a production cloud factory.

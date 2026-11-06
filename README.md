# Robostrator 🤖

Your software-work supervisor, maintained by [AnalystTom](https://github.com/AnalystTom).
You are the **Boss**. **Robostrator** coordinates your **workers**, keeps decisions attached to the task, and reports what was actually verified.

Robostrator is a library of agent instructions, skills and orchestration tools.
Run your coding-agent harness inside the checkout; it reads the supervisor contract in [AGENTS.md](AGENTS.md).
This is an independent adaptation of **Firstmate by Kun Chen**, released with fresh Git history and the original MIT licence and attribution retained in [NOTICE.md](NOTICE.md) and [LICENSE](LICENSE).

## What it does

- Dispatches work to isolated workers and supervises their progress.
- Preserves accepted decisions, unpublished work and explicit merge authority.
- Separates local tests, PR readiness, merge and verified deployment.
- Uses upstream No Mistakes for projects that select its validation gate.
- Caps new code files at 1,000 lines and prevents inherited oversized files from growing.
- Leads PR descriptions with before/after evidence, including screenshots and video for visual changes.

These are workflow policies, not a promise of error-free software.

## Start

Use a fresh checkout for your operational home.
You need Git, an authenticated coding-agent harness and the dependencies for your selected runtime backend.
GitHub operations use your existing account sign-in.

```sh
gh auth login
git clone https://github.com/AnalystTom/Robostrator.git
cd Robostrator
claude
# Or launch codex from this directory.
```

Follow the [configuration guide](docs/configuration.md) and the setup for your chosen backend below.
Review requested installation or configuration changes before accepting them.
The distribution detects supported missing tools; cloning alone does not install every optional backend.

## Roles and compatibility

**Boss → Robostrator → workers** is the public vocabulary.
The inherited `fm-*` commands, `FM_HOME`, persisted formats and skill identifiers remain compatibility interfaces.
They are implementation names, not a second product or a request to migrate an existing home.
Use the existing `/updatefirstmate` compatibility command for guarded updates from this repository's `origin`; it does not select the original publisher automatically.

## Documentation

- [Robostrator guide](ROBOTS.md), [architecture](docs/architecture.md), [contributing](CONTRIBUTING.md), [vision](VISION.md) and [documentation ownership](docs/documentation-audiences.md).
- [Configuration](docs/configuration.md) and [wedge recovery](docs/wedge-alarm.md).
- Runtime setup: [tmux](docs/tmux-backend.md), [Herdr](docs/herdr-backend.md), [Zellij](docs/zellij-backend.md), [Orca](docs/orca-backend.md), [cmux](docs/cmux-backend.md), [Paseo](docs/paseo-backend.md), [Rex](docs/rex-backend.md), [T3 Code](docs/t3code-backend.md), [Tern](docs/tern-backend.md) and [hc](docs/hc-backend.md).
- [Remote supervisors](docs/remote-secondmates.md) and [harness verification records](docs/verification/runtime-backends.md).

## Two-tier skill layout

[Internal skills](.agents/skills/) operate within a Robostrator home.
[Public skills](skills/) are standalone and installer-facing.
The [Robostrator operations profile](.agents/skills/robots-operations/SKILL.md) is loaded before dispatch, escalation and delivery.
Historical verification records retain the original names and versions they actually tested; they are not evidence that this release has been live-tested on every harness.

## Privacy and provenance

Operational homes keep projects, state, preferences and credentials in ignored local directories.
This public repository contains source, documentation and regression fixtures; it does not include the maintainer's conversation logs, Langfuse dataset or private task history.
Fresh history does not mean the inherited implementation was written from scratch.
See [NOTICE.md](NOTICE.md) for the exact upstream snapshot and retained credit.

<!-- Compatibility anchors for existing documentation links. -->
<a id="built-in-skills"></a>
<a id="clones-the-project-under-projects-and-spawns-two-isolated-workers-in-the-active-backend"></a>
<a id="contributing"></a>
<a id="features"></a>
<a id="firstmate-checks-its-toolchain-asking-your-consent-before-installing-or-upgrading-anything"></a>
<a id="how-it-works"></a>
<a id="install-and-launch"></a>
<a id="license"></a>
<a id="minutes-later"></a>
<a id="more-backends"></a>
<a id="or-when-starting-from-inside-a-claude-code-pane"></a>
<a id="or-when-the-signed-wrapper-is-installed"></a>
<a id="original-upstream-documentation"></a>
<a id="quick-start"></a>
<a id="recommended-harnesses"></a>
<a id="requirements"></a>
<a id="robots-skills-model-invoked"></a>
<a id="star-history"></a>
<a id="talk-to-it"></a>
<a id="what-it-is"></a>

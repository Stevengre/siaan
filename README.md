# SIAAN **Skill Is All Agents Need**

An autonomous agent orchestrator that monitors GitHub Issues, dispatches AI coding agents, and lands PRs. You file issues, it ships code. You review PRs, it iterates. Self-loop software development.

**Today**: issue-driven orchestration → agent dispatch → PR → human review → merge. The loop runs, the code ships.

**Next**: continuous learning — agents automatically distill experience into skills, getting better at your codebase over time. See [Vision](#vision-skill-is-all-agents-need) for why we chose this name.

> **Self-hosting**: siaan develops itself. This repository's issues are triaged, implemented, reviewed, and landed by siaan — the first self-bootstrapping agent orchestrator.[^1]

## Quick Start

You need: **Docker** and a **`GITHUB_TOKEN`** with `repo` scope.

Load the setup skill into your AI coding agent (Claude Code, Codex, etc.) and let it walk you through the process:

```
Load docs/skills/siaan-setup/SKILL.md and set up siaan for <owner>/<repo>
```

The skill will create your config directory, write `.env` / `docker-compose.yml` / `WORKFLOW.md`, bootstrap the target repo, and start the loop.

Or follow the [setup skill](docs/skills/siaan-setup/SKILL.md) manually — it's a readable step-by-step guide.

> **Note**: This skill is not yet battle-tested. If something breaks, please [start a discussion](https://github.com/Stevengre/siaan/discussions/new).

For developing siaan itself, see [docs/developing.md](docs/developing.md).

## The Workflow

siaan operates on a simple issue-driven loop. Here is the full lifecycle:

```
You have an idea
    ↓
File a GitHub Issue (use /gh-issue-triage to structure it)
    ↓
Issue lands in status:triage
    ↓
You refine the issue — clarify scope, acceptance criteria, risks
    ↓
When satisfied, change label to status:ready
    ↓
siaan picks it up → moves to status:in-progress → creates a branch → works
    ↓
siaan opens a PR → moves issue to status:review
    ↓
You review the PR — leave comments on anything unsatisfactory
    ↓
siaan addresses comments, pushes updates, re-requests review
    ↓
You approve the PR
    ↓
siaan squash-merges and closes the issue
```

### Issue States

| Label | Meaning | Who acts |
|---|---|---|
| `status:triage` | Raw idea, needs refinement | You |
| `status:ready` | Refined and approved for work | siaan picks it up |
| `status:in-progress` | Agent is actively working | siaan |
| `status:review` | PR is open, waiting for your review | You |
| `closed` | Done | — |

### Tips for Good Issues

- Write clear acceptance criteria — siaan treats them as non-negotiable
- Include a `Validation` or `Test Plan` section if you want specific checks
- One concern per issue; siaan will file follow-ups for out-of-scope discoveries

## Recommended Setup: Hire a Bot

For the best experience, create a dedicated GitHub account (e.g., `siaan-bot`) and add it as a collaborator with write access to your repository. Use its PAT as the `GITHUB_TOKEN`.

This gives you a clean separation:

- **The bot** does the work — files workpad comments, pushes branches, opens PRs
- **You** do the review — approve, request changes, close

The self-loop: you think, the bot builds, you approve. The repository maintains itself.


## Vision: Skill Is All Agents Need

SKILL is becoming a de facto specification for long-term agent memory and capability. When a SKILL file can embed scripts — and is therefore Turing-complete — it becomes a new application paradigm: a declarative protocol that is both human-readable and machine-executable.

We believe this convergence is inevitable. Complex agent configurations — hooks, multi-agent orchestration, tool routing, memory systems — can all collapse into SKILL as a unified abstraction. The ecosystem hasn't standardized yet, but the pattern is clear across every agent framework we've tested.

This project exists to push that vision forward. GitHub-based software development is step one: proving that a SKILL-driven agent can autonomously ship production code through a real review loop. From here, we — currently just one maintainer and one tireless bot employee ([siaan-bot](https://github.com/siaan-bot)) — will keep building toward a unified SKILL standard.

If this resonates, watch the repo. The loop is running.

## Acknowledgments

Architecture inspired by [OpenAI Symphony](https://github.com/openai/symphony) (Apache-2.0). Core orchestration built on Elixir/OTP.

[^1]: siaan is in rapid iteration. You'll see direct commits alongside the PR-based flow in the [commit history](https://github.com/Stevengre/siaan/commits/main). The goal is to converge: let the bot do the dirty work, humans just review.

# siaan

**Skill Is All Agents Need**

An autonomous agent orchestrator that monitors GitHub Issues and dispatches AI coding agents with continuous learning capabilities.

## Core Concepts

- **Issue-driven orchestration**: Poll GitHub Issues → Dispatch agents → Resolve via PR → Land
- **Skill-defined agents**: Agent capabilities are bounded by declarative skill protocols
- **Continuous learning**: Agents accumulate knowledge (facts, instincts, SOPs) across runs via a persistent learning kernel

## Install On A GitHub Repo

The Elixir runtime includes an idempotent repository bootstrap task:

```bash
cd elixir
mix siaan.install
```

Run it the first time to install the expected label taxonomy, write `.github/siaan-security.yml`,
and align repository guardrails with the current maintainer list. Re-run it later to converge the
repo back to the desired state after collaborator, config, or version drift.

Useful flags:

- `--dry-run` shows the delta without applying it
- `--yes` accepts the detected defaults without prompting

Example output:

```text
siaan install for Stevengre/siaan
Current collaborators: @alice, @bob

1. Labels
   ✓ status:ready — already exists
   + status:in-progress — creating

2. Maintainer allowlist
   ? Confirm or edit maintainer list [alice, bob]:

3. Repository security
   ✓ Issue/PR restriction — enforced by repository guardrails
   ~ Branch protection on main — updating to match maintainer allowlist

4. Configuration
   + .github/siaan-security.yml — writing

5. Version
   ✓ siaan is up to date (v0.1.0)

Done. Run mix siaan.install again anytime.
```

The generated `.github/siaan-security.yml` file is self-documenting and also feeds the repository's
issue/PR restriction workflow.

## Acknowledgments

Architecture inspired by [OpenAI Symphony](https://github.com/openai/symphony) (Apache-2.0). Core orchestration built on Elixir/OTP.

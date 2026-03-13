# siaan

**Skill Is All Agents Need**

An autonomous agent orchestrator that monitors GitHub Issues and dispatches AI coding agents with continuous learning capabilities.

## Core Concepts

- **Issue-driven orchestration**: Poll GitHub Issues → Dispatch agents → Resolve via PR → Land
- **Skill-defined agents**: Agent capabilities are bounded by declarative skill protocols
- **Continuous learning**: Agents accumulate knowledge (facts, instincts, SOPs) across runs via a persistent learning kernel

## Acknowledgments

Architecture inspired by [OpenAI Symphony](https://github.com/openai/symphony) (MIT). Core orchestration built on Elixir/OTP.

# Architecture Thinking

_Source: *Fundamentals of Software Architecture*, Chapters 1–2, 19, and 27._

## Distinguish architecture from design

- Treat architecture as the important structure of a system: major elements, their relationships, boundaries, and decisions that materially affect system-wide qualities.
- Treat detailed implementation choices as design unless they have significant structural or system-wide consequences.
- Do not elevate every coding preference into an architectural decision. Do not dismiss a choice as "just implementation" when it changes deployment, coupling, data ownership, or operational behavior.

## Start with business drivers

- Translate business goals into technical concerns rather than assuming stakeholders will express requirements as technical quality attributes.
- Ask what outcomes matter: time to market, user experience, regulatory obligations, cost, competitive advantage, business continuity, and expected change.
- Identify constraints: existing systems, skills, budget, schedule, deployment environment, data, and organizational boundaries.
- Make implicit domain concerns explicit. A domain may carry important requirements that stakeholders omit because they consider them obvious.

## Analyze trade-offs objectively

For each consequential option:
- Identify the benefits and costs, including operational and organizational costs.
- Consider which architectural characteristics improve and which degrade.
- Distinguish facts, assumptions, and preferences.
- Avoid advocating for a technology or style before understanding the problem.
- Explain why an option is appropriate in this context, not why it is universally superior.

Use the book's central laws:
1. Everything in software architecture is a trade-off.
2. Why is more important than how.
3. Most architecture decisions exist on a spectrum between extremes, not as binary choices.

Look for missing trade-offs: a decision that appears to have only benefits is probably incompletely analyzed.

## Balance strategic and tactical work

- Preserve enough hands-on understanding to make decisions grounded in implementation reality.
- Keep architectural direction connected to the team's actual delivery work.
- Use broad technical knowledge to recognize options, but investigate unfamiliar technologies before relying on them.
- Avoid the "frozen caveman" behavior of rejecting unfamiliar approaches solely because they differ from established habits.
- Do not turn exploration into endless research: use a time-boxed investigation, then decide what evidence is still missing.

## Choose architecture styles contextually

- Do not select an architecture style because it is fashionable, familiar, or associated with a successful company.
- Compare styles against the system's domain, architectural characteristics, constraints, team structure, and operational capabilities.
- Prefer a monolith when it meets the needs; introduce modularity and distribution deliberately.
- Re-evaluate the choice as the system and its context evolve.

## Decision output

A useful architecture recommendation states:
- The problem and "why" behind the change.
- The relevant business drivers and constraints.
- The options considered.
- The trade-offs and consequences.
- The recommendation and the conditions under which it should be revisited.

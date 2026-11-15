# Architectural Decisions and Risk Analysis

_Source: *Fundamentals of Software Architecture*, Chapters 21–22._

## Make decisions at the right time

- Do not avoid a necessary decision out of fear of being wrong.
- Defer a decision only when waiting is useful and it remains possible to decide before the choice becomes costly or irreversible.
- Avoid repeatedly reopening settled decisions without new evidence.
- Do not make architecture through scattered email or undocumented conversations.
- Gather enough relevant information, make the decision, document it, and communicate it to affected stakeholders.

## Record significant decisions with ADRs

Create an Architecture Decision Record when a decision materially affects system structure, technology constraints, or architectural characteristics.

Include:
- **Title:** concise description of the decision.
- **Status:** proposed, accepted, superseded, or another clearly defined lifecycle state.
- **Context:** problem, drivers, constraints, and forces that led to the decision.
- **Decision:** what was chosen and why.
- **Consequences:** benefits, costs, risks, and follow-on work.
- **Compliance/validation:** how the implementation will be checked against the decision, when relevant.
- **Notes:** useful references or follow-up information.

Keep ADRs version-controlled near the project documentation. Update status through new records or an explicit history; do not silently rewrite the historical rationale.

## Assess risk

For each meaningful architectural risk:
- Describe the failure or undesirable outcome.
- Estimate likelihood and impact separately.
- Use a consistent risk matrix (the source illustrates low/medium/high ratings and multiplying the scores) to prioritize discussion.
- Record assumptions and uncertainty; risk scores are aids to comparison, not objective truth.
- Identify mitigation, owner, and evidence that would reduce the risk.
- Reassess after mitigation or when the system context changes.

Use risk-storming collaboratively:
1. Identify risks across the architecture.
2. Build shared understanding and reach consensus on important risks.
3. Prioritize and define mitigation actions.

Include operational risks (availability, elasticity, security, data integrity) and structural risks (coupling, dependency cycles, fragile boundaries).

## Connect risk to delivery

- Analyze risks in user stories and proposed changes, not only in high-level architecture reviews.
- Give special attention to changes affecting availability, security, data integrity, and system-wide dependencies.
- Prefer mitigation that addresses the root cause over documentation that merely records the risk.
- Do not let a low numerical score hide a catastrophic impact or a poorly understood failure mode.

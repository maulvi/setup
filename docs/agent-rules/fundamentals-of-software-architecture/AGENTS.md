# Software Architecture Rules

Use these rules when analyzing, designing, changing, or reviewing a software system. They distill *Fundamentals of Software Architecture* (Mark Richards and Neal Ford, 2nd ed.) into operational guidance.

## Operating rules

1. Understand the business/domain problem before proposing architecture.
2. Separate domain requirements from architectural characteristics. Elicit both; do not assume the latter are fully specified.
3. Treat architecture as the system's important structure and design as lower-level implementation detail. Escalate a design choice when it materially changes system structure or architectural characteristics.
4. Make trade-offs explicit. There is no universally best architecture style or technology.
5. Prefer the simplest architecture that satisfies the system's actual requirements and constraints. Do not introduce distribution, abstraction, or infrastructure without a demonstrated need.
6. Model the system as logical components with clear responsibilities before choosing classes, packages, services, or deployment units.
7. Preserve modularity: high cohesion, intentional coupling, explicit contracts, and controlled dependencies.
8. Define important architectural characteristics in measurable, context-specific terms. Replace vague goals such as "fast", "scalable", or "secure" with scenarios and measurable thresholds where possible.
9. Validate architecture continuously with tests, metrics, and fitness functions. Do not rely on documentation or review alone to prevent architectural erosion.
10. Record significant decisions, their context, alternatives, trade-offs, consequences, and status in an ADR.
11. Assess architectural risks by likelihood and impact; prioritize mitigation based on risk, not novelty or fashion.
12. Communicate architecture through purposeful diagrams and concise guidance. Keep diagrams consistent with the actual system.
13. Revisit decisions when business drivers, constraints, scale, team structure, or operational context change.

## Task routing

- For system structure, business drivers, and trade-offs: read `architecture-thinking.md`.
- For modules, components, cohesion, and coupling: read `modularity-components.md`.
- For quality attributes, measurement, and governance: read `characteristics-fitness-functions.md`.
- For architecture styles and selection: read `architecture-styles.md`.
- For decisions, ADRs, and risk: read `decisions-and-risk.md`.
- For diagrams, team collaboration, and implementation/operations intersections: read `communication-and-teams.md`.

## Required behavior when proposing a change

Before recommending a consequential architectural change:
- State the problem and relevant business/domain drivers.
- Identify the architectural characteristics affected.
- Compare viable alternatives and their trade-offs.
- Identify risks, migration implications, and operational consequences.
- Recommend the least-complex option that meets the stated needs.
- State assumptions and what evidence would change the recommendation.

Do not mechanically apply every rule to trivial code changes. Scale the analysis to the architectural significance of the change.

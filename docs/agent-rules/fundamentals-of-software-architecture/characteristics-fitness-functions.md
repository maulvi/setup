# Architectural Characteristics and Fitness Functions

_Source: *Fundamentals of Software Architecture*, Chapters 4–7._

## Identify characteristics from the problem

- Treat architectural characteristics as concerns important to system success that are not simply domain features.
- Discover them from domain concerns, explicit requirements, stakeholder conversations, and implicit domain knowledge.
- Do not assume a generic checklist is sufficient. Select characteristics that matter to this system.
- Distinguish operational characteristics (for example, availability, performance, scalability, elasticity, and recoverability), structural characteristics (for example, modularity, testability, and deployability), and cross-cutting concerns such as security.
- Recognize that characteristics can be composite. Decompose broad goals such as agility into more concrete contributing properties.

## Make characteristics precise

For every high-priority characteristic:
- Define what it means in this system.
- Identify the scenario, workload, operating conditions, and affected users or components.
- Define how it will be measured and what result is acceptable.
- Agree on the definition with the relevant stakeholders and delivery/operations teams.
- Avoid vague acceptance criteria such as "high performance" or "high availability".

Examples of useful measurement dimensions include latency percentiles, throughput, error rate, recovery time, deployment frequency, change lead time, and structural dependency measures. Choose measures that fit the actual requirement; do not assume every metric applies.

## Prioritize

- Separate essential characteristics from desirable ones.
- Identify conflicts between characteristics and make their trade-offs visible.
- Do not attempt to maximize every characteristic simultaneously.
- Scope characteristics to the relevant architectural quantum or bounded context. A characteristic may apply to one independently deployable part but not to every part of the system.
- Consider the effect of synchronous communication and other cross-boundary interactions on the scope of a characteristic.

## Govern with fitness functions

- Turn important architectural characteristics into automated or repeatable checks wherever practical.
- Use fitness functions to evaluate whether the architecture continues to satisfy a characteristic as the system evolves.
- Prefer checks that run continuously in the development or delivery process and provide actionable feedback.
- Add structural checks for dependency rules, cyclic dependencies, and other known architecture constraints.
- Combine automated checks with operational measurement and human review; no single metric proves architectural fitness.
- Review fitness functions when requirements or architecture change so that obsolete checks do not become false constraints.

## Interpret measurements carefully

- Treat metrics as evidence, not as the objective itself.
- Define measurement conditions and thresholds before using a metric to block delivery.
- Avoid optimizing a proxy metric at the expense of the underlying business or architectural goal.

# Architecture Styles and Selection

_Source: *Fundamentals of Software Architecture*, Chapters 9–20._

## Selection rules

- Choose a style only after identifying domain needs, architectural characteristics, constraints, and trade-offs.
- Compare topology, communication, data ownership/topology, deployment, failure behavior, governance, and team implications.
- Account for the operational maturity required by distributed styles: deployment automation, observability, security, resilience, testing, and production support.
- Do not assume that more services, more layers, or more infrastructure create better architecture.
- Start with the least-complex style that satisfies the requirements; evolve when evidence demonstrates a need.
- Evaluate the cost of migration and the consequences of changing boundaries later.

## Styles covered by the source

Use these as options to evaluate, not recipes to apply automatically:

- **Big ball of mud / unitary / client-server / three-tier:** understand the structural and deployment trade-offs of simple or historically common topologies.
- **Layered:** use clear layer responsibilities and deliberate dependency direction; avoid adding layers that only forward calls or obscure ownership.
- **Modular monolith:** preserve module boundaries and controlled communication while retaining a single deployable unit. Do not let the shared deployment become an excuse for unrestricted cross-module access.
- **Pipeline:** model processing as filters connected by pipes when a sequence of transformations is the natural problem structure. Define contracts and failure behavior between stages.
- **Microkernel:** isolate a stable core from plug-in capabilities when extensibility through independently replaceable plug-ins is central. Keep core contracts stable and manage plug-in dependencies.
- **Service-based:** define service boundaries and granularity deliberately; examine shared database implications, API gateway needs, and the operational cost of distributed deployment.
- **Event-driven:** distinguish events from commands/messages; define payloads, delivery guarantees, ordering, error handling, and data-loss prevention. Account for eventual consistency and debugging complexity.
- **Space-based:** consider distributed processing and data-grid approaches only when the workload and data-access patterns justify their complexity.
- **Orchestration-driven SOA:** examine service taxonomy, orchestration, reuse, and the coupling introduced by shared orchestration or message infrastructure.
- **Microservices:** align services with bounded contexts and data ownership; evaluate granularity, communication, transactions/sagas, operational reuse, and governance.

## Distributed architecture caution

Before splitting a monolith into distributed services, identify the concrete limitation being solved. Then account for:
- Network latency and partial failure.
- Distributed data ownership and consistency.
- Cross-service transactions and compensating actions.
- Observability, tracing, deployment, versioning, and operational support.
- Increased testing and debugging complexity.
- Team ownership and coordination boundaries.

Do not distribute components solely to achieve independent deployment if the organization cannot reliably operate the resulting system.

## Patterns are not architecture styles

Evaluate patterns such as hexagonal architecture, service mesh, CQRS, broker-domain, and orchestration/choreography as techniques for particular concerns. Do not treat a pattern as a complete architecture style or apply it without a matching problem.

# Modularity and Component-Based Thinking

_Source: *Fundamentals of Software Architecture*, Chapters 3 and 8._

## Design around logical responsibilities

- Model the system first as logical components that perform meaningful business or technical functions.
- Define each component by its responsibility, inputs, outputs, data it owns, and interactions with other components.
- Keep logical architecture distinct from physical deployment. A component does not automatically need its own process, container, service, or repository.
- Identify components from workflows, actors and actions, domain entities, and user stories. Do not let the noun/entity list alone dictate component boundaries.
- Assign responsibilities based on behavior and cohesive purpose, not merely on convenient CRUD groupings.

## Protect cohesion

- Keep closely related responsibilities together.
- Split a component when it contains unrelated responsibilities that change for different reasons or serve unrelated purposes.
- Avoid splitting a cohesive responsibility into many tiny components without a clear benefit.
- Evaluate granularity in context; there is no universally correct component size.

## Control coupling

- Make dependencies explicit and minimize unnecessary dependencies between components.
- Prefer stable, well-defined contracts over reaching into another component's internals.
- Avoid cyclic dependencies. Break cycles by revisiting ownership, introducing an appropriate abstraction, or changing dependency direction.
- Consider both static coupling (compile-time or structural dependencies) and dynamic/temporal coupling (runtime interactions and sequencing).
- Minimize knowledge of another component's internal structure; apply the Law of Demeter as a useful design constraint.
- Avoid coupling components through shared mutable data or assumptions about execution order unless that coupling is intentional and governed.

## Use metrics as signals, not verdicts

- Use cohesion, coupling, and dependency metrics to reveal structural problems.
- Interpret metrics in context; do not optimize a number without understanding the design it represents.
- Treat metrics as prompts for investigation, not proof that an architecture is good or bad.
- Watch for structural drift as the codebase changes.

## Component review questions

- Does each component have a clear responsibility?
- Are its responsibilities cohesive?
- Which components depend on it, and why?
- Are dependencies acyclic and directed intentionally?
- Does the public contract expose only what consumers need?
- Does a change in one component force unrelated components to change?
- Is the logical boundary being confused with a deployment boundary?

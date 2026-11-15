# Architecture Communication, Teams, and Delivery

_Source: *Fundamentals of Software Architecture*, Chapters 23–26._

## Create useful diagrams

- Create a diagram to answer a specific question for a specific audience.
- Use a meaningful title, clear labels, a key when needed, and consistent notation.
- Use layers semantically, not as decoration.
- Show only the elements and relationships needed to explain the view; avoid diagrams that imply precision they do not contain.
- Keep diagrams synchronized with the actual system or clearly label them as conceptual/proposed.
- Choose an appropriate notation such as C4, UML, or ArchiMate based on the audience and purpose; do not mix conventions casually.

## Work with the team

- Treat architecture as collaborative work, not a set of commands handed down by a distant architect.
- Provide constraints, boundaries, rationale, and guidance while leaving implementation decisions to the people closest to the code when appropriate.
- Avoid both control-freak behavior (unnecessary control of implementation) and armchair architecture (decisions detached from implementation reality).
- Stay engaged enough to understand delivery constraints and detect architectural drift.
- Watch for process loss, unclear ownership, and team assumptions that go unchallenged.
- Use checklists for repeatable quality and release concerns, but do not let checklists replace judgment.

## Lead pragmatically

- Be pragmatic while maintaining a long-term architectural direction.
- Explain the "why" behind constraints and decisions.
- Negotiate with stakeholders and developers by making goals, constraints, and trade-offs explicit.
- Preserve developer flow where possible; avoid unnecessary interruptions and approval gates.
- Demonstrate desired engineering behavior rather than relying only on authority.

## Connect architecture to implementation and operations

For any architectural proposal or significant change, consider:
- **Implementation:** can the team build and test it with its current skills and practices?
- **Operations:** how will it be deployed, monitored, secured, recovered, and maintained?
- **Structural integrity:** will module boundaries and dependencies remain sound?
- **Infrastructure:** what platform capabilities and constraints does the design rely on?
- **Data:** who owns data, how is it stored, and what are the read/write and consistency needs?
- **Integration:** what contracts, protocols, failure modes, and versioning are involved?
- **Business/enterprise:** does the solution fit business goals, organizational constraints, and existing systems?
- **Team topology:** do ownership and communication paths align with the architecture?

Do not treat architecture as a diagram-only activity. Validate that the implemented and operated system reflects the intended structure.

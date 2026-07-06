# ADR Template

Used by `/unix-architect adr`. Write ADRs in this format:

```markdown
# ADR-NNNN: [Title]

## Status

Proposed

## Context

[What is the problem or situation? Why does a decision need to be made?
Include relevant technical context, constraints, and prior art.]

## Decision

[What is the change that we're proposing and/or doing?]

### UNIX Philosophy Alignment

[For each relevant principle, explain how the decision aligns with or
intentionally deviates from it. Quote the principle, then explain.]

> Rule of X: "..."

[How this decision relates to the principle.]

### Platform Constraints

[If applicable: Which Claude Code platform constraints influenced this
decision? How do they shape or limit the design? If none apply, omit
this section.]

## Alternatives Considered

[For each alternative:]

### Alternative: [Name]

[Description, and why it was not chosen. Reference UNIX principles
where they informed the rejection.]

## Consequences

### Positive

- [Benefit 1]

### Negative

- [Cost or risk 1]

### Trade-offs

[Where did principles or goals conflict?
What was sacrificed and why was it acceptable?]
```

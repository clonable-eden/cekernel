# TDD (Test-Driven Development)

kernel follows TDD as its fundamental development practice.
For any work involving code changes, take a test-first approach.

## Red-Green-Refactor Cycle

```
RED ──→ GREEN ──→ REFACTOR ──→ (next cycle)
```

### RED — Write a failing test

Write a test that describes the expected behavior and **verify that it fails**.

- Always confirm the test fails (this proves the test itself works correctly)
- Do not touch implementation code at this stage
- Append `(RED)` suffix to the commit message

### GREEN — Make it pass with minimal code

Write the **minimum** code to make the test pass and **verify it succeeds**.

- "Minimum" is the key — do not write extra code
- Do not aim for perfect design; the goal is to make it work first
- Append `(GREEN)` suffix to the commit message

### REFACTOR — Improve the design

Improve the code while keeping all tests passing, then commit.

- Remove duplication
- Improve naming
- Restructure for clarity
- Always verify tests still pass before committing
- Append `(REFACTOR)` suffix to the commit message

## Testing Principles

### Test behavior, not internals

Test externally observable **behavior**, not internal state.

```
OK: "spawn-worker.sh returns exit 2 when max concurrency is exceeded"
NG: "internal counter variable equals 3"
```

### Test independence

Tests must not share state. Each test runs independently and does not depend on execution order.

### Mock external dependencies

Replace external dependencies (APIs, databases, filesystem, etc.) with mocks or stubs
to keep tests fast and reproducible.

### Cover edge cases

- null / empty string / empty array
- Boundary values (0, 1, max)
- Error paths (failure scenarios)

## Cycle Granularity

Break large changes into multiple small Red-Green-Refactor cycles.
The smaller each cycle, the easier it is to isolate problems.

## When to Skip TDD

TDD may be skipped for work such as:

- Documentation-only changes
- Configuration file changes
- Cases where tests are clearly unnecessary or inappropriate

The decision to skip is left to the implementer. When in doubt, write the test.

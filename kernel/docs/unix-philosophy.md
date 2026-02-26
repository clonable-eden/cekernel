# UNIX Philosophy

> Reference: [Basics of the Unix Philosophy](https://cscie2x.dce.harvard.edu/hw/ch01s06.html)
> — Eric S. Raymond, *The Art of Unix Programming*

## Principles

### Rule of Modularity

> Write simple parts connected by clean interfaces.

Build systems from simple components with well-defined boundaries.
This enables localized problem-solving and safe upgrades.

### Rule of Clarity

> Clarity is better than cleverness.

Code serves future maintainers as much as computers.
Prioritize readability over performance tricks.

### Rule of Composition

> Design programs to be connected with other programs.

Programs should accept and emit straightforward text streams.
This enables easy replacement without disrupting interconnected systems.

### Rule of Separation

> Separate policy from mechanism; separate interfaces from engines.

Policy and mechanism evolve at different rates.
Hardwiring them together rigidifies design.

### Rule of Simplicity

> Design for simplicity; add complexity only where you must.

Resist feature bloat. Favor simple and clear solutions over intricate ones.

### Rule of Parsimony

> Write a big program only when it is clear by demonstration that nothing else will do.

Large, complex codebases resist maintenance. Avoid substantial programs unless absolutely necessary.

### Rule of Transparency

> Design for visibility to make inspection and debugging easier.

Systems should be immediately understandable.
Include comprehensive debugging options.

### Rule of Robustness

> Robustness is the child of transparency and simplicity.

Transparency and simplicity enable developers to verify correctness and fix failures reliably.

### Rule of Representation

> Fold knowledge into data so program logic can be stupid and robust.

Shift complexity from code to data wherever possible,
improving comprehensibility and maintainability.

### Rule of Least Surprise

> In interface design, always do the least surprising thing.

Model interfaces on familiar conventions. Minimize the learning curve.

### Rule of Silence

> When a program has nothing surprising to say, it should say nothing.

Silence preserves attention for important information
and eases parsing when output becomes another program's input.

### Rule of Repair

> When you must fail, fail noisily and as soon as possible.

Never silently continue in a broken state.
Transparent failure modes enable straightforward diagnosis.

### Rule of Economy

> Programmer time is expensive; conserve it in preference to machine time.

Prioritize developer efficiency over computational resources.

### Rule of Generation

> Avoid hand-hacking; write programs to write programs when you can.

Code generators automate error-prone detail work.

### Rule of Optimization

> Prototype before polishing. Get it working before you optimize it.

Establish working implementations first, then systematically identify bottlenecks.

### Rule of Diversity

> Distrust all claims for "one true way."

Embrace multiple approaches, extensible architectures, and customization mechanisms.

### Rule of Extensibility

> Design for the future, because it will be here sooner than you think.

Avoid locking into initial design choices.
Create self-describing formats and organize code for effortless future additions.

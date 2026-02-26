# Glimmer

A place to nurture sparks of ideas. An experimental project for parallel agent workflows.

## Marketplace

This repository also serves as a Claude Code plugin marketplace.

```bash
/plugin marketplace add clonable-eden/glimmer
/plugin install cekernel@clonable-eden-glimmer
```

## Plugins

- **cekernel** — Parallel agent infrastructure. Provides the `/cekernel:orchestrate` skill and orchestrator/worker agents. Read `cekernel/CLAUDE.md` for development.

## Principles

- When uncertain about Claude Code specifications or behavior, always consult primary sources (official documentation, GitHub issues) before answering. Do not guess.

## Conventions

- Branch names: `issue/{number}-{short-description}`
- Commit message titles in English, body may be in Japanese
- PR body must include `closes #{issue-number}`
- Worktrees are created under `.worktrees/` (already in .gitignore)
- Commit messages follow conventional commits:
  - `feat:` New feature
  - `fix:` Bug fix
  - `docs:` Documentation only
  - `test:` Tests only
  - `refactor:` Refactoring
  - `release:` Version bump (CI auto-generated)

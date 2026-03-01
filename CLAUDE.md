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
- Links in CLAUDE.md are not references — they are part of the instructions. You MUST read linked documents and follow them.

## Conventions

- Branch names: `issue/{number}-{short-description}`
- Commit message titles in English, body preferably in English
- PR body must include `closes #{issue-number}`
- GitHub issues, issue comments, and PR descriptions are written in Japanese by default
- Never commit directly to main. Always create a feature branch and open a PR
- Use regular merge (not squash) for PRs unless explicitly told otherwise
- Worktrees are created under `.worktrees/` (already in .gitignore)
- Commit messages follow conventional commits:
  - `feat:` New feature
  - `fix:` Bug fix
  - `docs:` Documentation only
  - `test:` Tests only
  - `refactor:` Refactoring
  - `release:` Version bump (CI auto-generated)

## Safety

- Never delete the current working directory (CWD) or its parent during a session. If cleanup is needed, `cd` to a safe directory first
- When the user has a problem visible in terminal output, proactively diagnose it rather than asking what the problem is

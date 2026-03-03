---
name: git-commit
description: Create git commits following the Conventional Commits spec
user-invocable: true
---

# Git Commit (Conventional Commits)

Create a git commit following the [Conventional Commits](https://www.conventionalcommits.org/) specification.

## Step 1 — Inspect

Run these commands in parallel to understand the current state:

```
git status
git diff
git diff --staged
git log --oneline -5
```

If there are no changes (no untracked files, no modifications), stop and inform the user there is nothing to commit.

## Step 2 — Stage

Stage files for commit:

- Prefer staging specific files by name (`git add <file>...`) over `git add -A` or `git add .`
- **Never** stage files that likely contain secrets (`.env`, credentials, API keys, tokens)
- **Never** stage large binaries unless the user explicitly requests it
- If all changes are already staged, skip this step
- Include any plan files that were created during the session (e.g., files in `.claude/plans/`)
- If unsure which files to include, ask the user

## Step 3 — Analyze

Review the staged diff (`git diff --staged`) and determine:

- **What** changed (new feature, bug fix, refactor, etc.)
- **Why** it changed (the purpose, not just a restatement of the diff)
- **Scope** of the change (which module, component, or area of the codebase)
- Whether the change introduces a breaking change to a public API

## Step 4 — Generate commit message

Build a commit message following Conventional Commits:

### Format

```
<type>(<optional scope>): <description>

[optional body]

[optional footer(s)]
```

### Type (required)

Choose the most appropriate type:

| Type       | When to use                                          |
|------------|------------------------------------------------------|
| `feat`     | A new feature                                        |
| `fix`      | A bug fix                                            |
| `docs`     | Documentation only changes                           |
| `style`    | Formatting, whitespace, semicolons (not CSS changes) |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `perf`     | A code change that improves performance              |
| `test`     | Adding or updating tests                             |
| `build`    | Changes to build system or external dependencies     |
| `ci`       | Changes to CI configuration files and scripts        |
| `chore`    | Other changes that don't modify src or test files    |
| `revert`   | Reverts a previous commit                            |

### Scope (optional)

A noun describing the section of the codebase affected, in parentheses. Examples: `feat(auth):`, `fix(api):`, `docs(readme):`.

### Description (required)

- Use imperative, present tense: "add" not "added" nor "adds"
- Do not capitalize the first letter
- No period at the end
- Keep it under 70 characters

### Body (optional)

Use the body to explain **what** and **why** rather than **how**. Wrap at 72 characters. Separate from the subject with a blank line. Use the body when:

- The description alone doesn't capture the full context
- The change has non-obvious side effects
- There is important motivation or context to record

### Footer (optional)

- **Breaking changes:** Start with `BREAKING CHANGE: ` followed by a description of what broke and migration steps. Alternatively, append `!` after the type/scope (e.g., `feat(api)!: remove legacy endpoint`).
- **Issue references:** e.g., `Closes #123`, `Fixes #456`

### Examples

Simple:
```
feat(auth): add OAuth2 login support
```

With body:
```
fix(parser): handle empty input without crashing

Previously the parser threw a NullPointerException when given an empty
string. Now it returns an empty result set instead.
```

Breaking change:
```
feat(api)!: remove v1 endpoints

BREAKING CHANGE: All /api/v1/* endpoints have been removed.
Consumers must migrate to /api/v2/*.
```

## Step 5 — Commit

Execute the commit using a heredoc to preserve formatting:

```
git commit -m "$(cat <<'EOF'
<type>(<scope>): <description>

<body>

<footer>
EOF
)"
```

After committing, run `git status` to confirm the commit succeeded.

## Guidelines

- Do **not** amend existing commits unless the user explicitly asks
- Do **not** push to a remote unless the user explicitly asks
- If a pre-commit hook fails, diagnose the issue, fix it, re-stage, and create a **new** commit (do not `--amend`)
- When in doubt about what to include or how to describe the change, ask the user

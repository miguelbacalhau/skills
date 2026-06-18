# Commit agent

Create one Conventional Commit for a completed work item.

The task supplies `<worktree>`, `<run-dir>`, `<ID>`, and a title. Work exclusively in the item worktree.

Inspect `git status` and the complete diff. Stage item files by explicit name, never `git add -A`. Never stage secrets or unrelated files. The run metadata directory is outside the worktree and must not be staged.

Use `<type>(<scope>): <description>` in imperative lower-case, under 70 characters, without a trailing period. Add a body only when useful. Do not push or amend.

Describe only the code change. Never mention Codex, AI, agents, orchestration, the user, or generated/co-authored attribution.

Return the commit hash and full message.

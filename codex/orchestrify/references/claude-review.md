# Claude review prompt

Review one work item's uncommitted changes adversarially and read-only.

Values supplied by the orchestrator:

- Worktree: `<worktree>`
- Run directory: `<run-dir>`
- Item: `<ID>` — `<title>`
- Owned files: `<owned-files>`

Work exclusively in the current worktree. Do not modify source, plans, git state, or tests.

Read:

1. `<run-dir>/spec.md`, especially Interfaces
2. `<run-dir>/plans/<ID>.md`, including Deviations
3. `git status`, tracked diffs, and every untracked file belonging to the item

Assume at least one real defect and that tests are weaker than they appear. Hunt for bugs, edge cases, interface violations, regressions, unjustified out-of-ownership changes, unsafe assumptions, and missing tests. Attack error paths and boundaries specifically.

For every finding include:

- severity: Critical, High, Medium, or Low
- `file:line`
- the defect and its impact
- the missing or failing test
- fix ownership: local code, plan, spec/interface, or another work item

If no finding survives scrutiny, give an explicit approval with the commands and files inspected. Report only; do not edit.

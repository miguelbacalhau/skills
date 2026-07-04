# Implement agent

Implement one work item in its isolated worktree without committing.

The task supplies `<worktree>`, `<run-dir>`, `<ID>`, a title, and owned files. Other agents may be working concurrently in other worktrees; never revert their work or access their worktrees.

Work exclusively in `<worktree>`. Read, in order:

1. `<run-dir>/spec.md`
2. `<run-dir>/plans/<ID>.md`
3. every file in the plan's Read First section

Honor the spec interfaces exactly. Implement the checked steps, update the plan checkboxes, and run all Verification commands. Prefer small focused functions, descriptive intermediate variables, minimal mutable state, and existing repository conventions.

Stay within owned files and their tests. If a necessary change crosses ownership or the plan proves wrong, make the smallest safe adjustment and record it in `## Deviations` in the plan. Do not silently improvise.

Do not ask questions and do not commit. Apply the spec's Doubt Rule to local ambiguity. Return implemented changes, verification results, deviations, guesses, and exact blockers. Never report an incomplete item as implemented — an untouched or partial worktree sails through review as a clean pass. If the item cannot be implemented as specified, say so explicitly, with exactly where and why you stopped; the orchestrator escalates it.

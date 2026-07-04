# Fix agent

Apply one work item's independent review findings.

The task supplies `<worktree>`, `<run-dir>`, `<ID>`, a title, and `<review-file>`. Other agents may be active elsewhere; work exclusively in this worktree and never revert unrelated changes.

Read the spec, item plan, and review artifact in that order. When the task says the item has no plan file (the integration-fixes pass), skip the plan read: the spec is the sole intent reference, and anything these instructions direct to the plan file — Deviations, the Verification commands — goes in your return message instead, with the spec's own verification standing in. Fix every finding owned by local code, add the missing tests, and re-run the plan's Verification commands. Record material deviations in the plan.

Do not change findings rooted in the plan, spec/interfaces, or another item; report them as structural. You may decline an incorrect finding only with concrete evidence. Any Medium or Low finding you deliberately leave unfixed must be recorded in the plan's Deviations section with a concrete reason — an unrecorded finding may not ride along to commit.

Do not ask questions and do not commit. Return each finding as fixed, declined with reason, or structural; list tests added and final verification.

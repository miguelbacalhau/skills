// orchestrify work loop — Step 4 of the skill (work loop + integration
// verification) as a deterministic workflow.
//
// The main conversation runs Steps 1-3 (brief confirmation, pre-flights, spec,
// checkpoint, integration worktree) and Step 5 (report), then invokes this
// script via the Workflow tool with `scriptPath` and the args below. Everything
// the conversational loop enforced with prose is code here: a completion-driven
// scheduler (an item launches the moment its own dependencies merge — it never
// waits for an unrelated sibling), the 2-round fix cap, the commit-attribution
// check verified against `git log` itself, the 2-slot Codex review throttle,
// and the serialized merge queue with a merge-abort safety net. Resume comes
// from the workflow journal (`resumeFromRunId`); the token ceiling comes from
// `budget`.
//
// args: {
//   runDir            .orchestrify/<timestamp>-<slug> — spec.md, plans/, reviews/
//   repoRoot          parent of the bare repo; all worktrees live here
//   slug              run slug; integration worktree is <repoRoot>/orchestrify-<slug>
//   integrationBranch orchestrify/<slug>
//   reviewScript      absolute path to this skill's codex-review.sh
//   items             [{ id, title, deps: [ids], files: [paths] }] from the Work Breakdown
// }
//
// Every review prompt file (<runDir>/reviews/<ID>-prompt.md, plus
// integration-prompt.md) must exist before this workflow starts — the main
// conversation writes them in Step 4.

export const meta = {
  name: 'orchestrify-work-loop',
  description: 'Plan, implement, review, commit, and merge every work item, then verify integration',
  phases: [
    { title: 'Plan', detail: 'planners per readiness wave, then cross-plan reconciliation' },
    { title: 'Build', detail: 'worktree setup and implementation, pipelined per item' },
    { title: 'Review', detail: 'Codex review and fix rounds (max 2), throttled to 2 concurrent reviews' },
    { title: 'Merge', detail: 'commit, then serialized merges into the integration branch' },
    { title: 'Integrate', detail: 'full-feature verification in the integration worktree' },
  ],
}

const { runDir, repoRoot, slug, integrationBranch, reviewScript, items } = args
const integrationWt = `${repoRoot}/orchestrify-${slug}`

// ---------- structured-output schemas ----------
const VERDICT = { type: 'object', additionalProperties: false, required: ['total', 'criticalOrHigh'],
  properties: { total: { type: 'number' }, criticalOrHigh: { type: 'number' } } }
const MERGE = { type: 'object', additionalProperties: false, required: ['merged', 'detail'],
  properties: { merged: { type: 'boolean' }, detail: { type: 'string' } } }
const RECONCILE = { type: 'object', additionalProperties: false, required: ['clean', 'issues'],
  properties: { clean: { type: 'boolean' }, issues: { type: 'array', items: { type: 'string' } } } }
const ITEM_REASON = { type: 'object', additionalProperties: false, required: ['id', 'reason'],
  properties: { id: { type: 'string' }, reason: { type: 'string' } } }
const DEP_AMEND = { type: 'object', additionalProperties: false, required: ['id', 'dependsOn'],
  properties: { id: { type: 'string' }, dependsOn: { type: 'array', items: { type: 'string' } } } }
const ESCALATE = { type: 'object', additionalProperties: false, required: ['replan', 'cut', 'blocked', 'addDeps'],
  properties: {
    replan: { type: 'array', items: { type: 'string' } },
    cut: { type: 'array', items: ITEM_REASON },
    blocked: { type: 'array', items: ITEM_REASON },
    addDeps: { type: 'array', items: DEP_AMEND } } }
const BUILD_ESCALATE = { type: 'object', additionalProperties: false, required: ['action', 'reason'],
  properties: {
    action: { type: 'string', enum: ['rebuild', 'cut', 'block'] },
    reason: { type: 'string' } } }
const IMPLEMENT = { type: 'object', additionalProperties: false, required: ['completed', 'summary'],
  properties: { completed: { type: 'boolean' }, summary: { type: 'string' } } }
const INTEGRATION = { type: 'object', additionalProperties: false,
  required: ['features', 'fixesApplied', 'gaps'],
  properties: {
    features: { type: 'array', items: { type: 'object', additionalProperties: false,
      required: ['name', 'pass', 'detail'],
      properties: { name: { type: 'string' }, pass: { type: 'boolean' }, detail: { type: 'string' } } } },
    fixesApplied: { type: 'boolean' },
    gaps: { type: 'array', items: { type: 'string' } } } }

// ---------- helpers ----------
// agent() returns null when skipped or dead after retries; never dereference one.
const must = (result, what) => {
  if (result === null || result === undefined)
    throw new Error(`${what}: agent was skipped or returned no result`)
  return result
}

// The script has no shell access; deterministic commands run through a haiku
// agent. The command is wrapped so its exit status comes back as a short
// SH_RC marker the model cannot plausibly mangle — a failed command throws
// here instead of silently reading as success.
const sh = async (cmd, label, ph, opts = {}) => {
  // longRunning: the agent's Bash tool caps foreground calls at 10 minutes,
  // so commands that legitimately run longer must go through run_in_background.
  const raw = await agent(
    `Run exactly this command and return its complete output verbatim — plain text, no code fences, no commentary:\n{ ${cmd} ; } ; echo "SH_RC=$?"` +
    (opts.longRunning
      ? '\nThe command can legitimately run for up to an hour — far past your Bash tool\'s foreground timeout. Launch it with run_in_background: true, do nothing else while it runs, and return the complete output once it exits.'
      : ''),
    { model: 'haiku', effort: 'low', label, phase: ph })
  if (raw === null || raw === undefined) throw new Error(`${label}: command agent was skipped or died`)
  const out = raw.split('\n').filter(l => !/^\s*`{3,}/.test(l)).join('\n')
  const marks = [...out.matchAll(/SH_RC=(\d+)/g)]
  if (!marks.length) throw new Error(`${label}: no exit-status marker in command output: ${out.trim().slice(-300)}`)
  const m = marks[marks.length - 1]
  if (m[1] !== '0') throw new Error(`${label}: command exited ${m[1]}: ${out.slice(0, m.index).trim().slice(-300)}`)
  return out.slice(0, m.index).trim()
}

// Codex reviews contend for one Codex auth — cap concurrency at 2 (SKILL: review throttling).
const reviewSlots = { free: 2, queue: [] }
const withReviewSlot = async fn => {
  if (reviewSlots.free > 0) reviewSlots.free--
  else await new Promise(resolve => reviewSlots.queue.push(resolve))
  try { return await fn() }
  finally {
    const next = reviewSlots.queue.shift()
    if (next) next()
    else reviewSlots.free++
  }
}

// Serialized sections: a promise chain per resource. Merges must land one at a
// time, and reconcile/escalate can edit spec.md, so waves take that section in
// turn too. A failed section never poisons the chain for the next caller.
const chain = () => {
  let tail = Promise.resolve()
  return fn => {
    const next = tail.then(fn)
    tail = next.catch(() => {})
    return next
  }
}
const serializedMerge = chain()
const serializedSpec = chain()

const state = Object.fromEntries(items.map(i => [i.id, 'pending']))
const shipped = [], blocked = [], cut = []
// A cut item's feature was amended out of the spec (prefer-smaller-scope):
// terminal like merged/blocked, and it satisfies dependents — the spec no
// longer requires the work they were waiting on.
const cutItem = (id, reason) => {
  state[id] = 'cut'
  cut.push({ id, reason })
  log(`${id} cut: ${reason}`)
}
const block = (id, reason) => {
  state[id] = 'blocked'
  blocked.push({ id, reason })
  log(`${id} blocked: ${reason}`)
}

// One review pass: run the wrapper, gate on its exit status (exit 0 iff the
// artifact is non-empty — the WRAPPER_RC echo survives the haiku round-trip
// where a long transcript might not), archive the round, then count findings.
const review = async (id, worktree, round) => {
  const artifact = `${runDir}/reviews/${id}-codex.md`
  // longRunning: the wrapper's retries can total over an hour (4 × 15-minute
  // attempts plus backoff) — a foreground Bash call would be killed at 10min.
  const out = await withReviewSlot(() =>
    sh(`"${reviewScript}" "${worktree}" "${artifact}" "${runDir}/reviews/${id}-prompt.md" 2>/dev/null; rc=$?; ` +
       `if [ "$rc" -eq 0 ]; then cp "${artifact}" "${runDir}/reviews/${id}-codex.round${round}.md"; fi; echo "WRAPPER_RC=$rc"`,
       `review:${id}#${round}`, 'Review', { longRunning: true }))
  if (!out.includes('WRAPPER_RC=0'))
    throw new Error(`Codex review did not complete: ${out.trim().slice(-200)}`)
  return must(await agent(
    `Read ${artifact} and report two counts: the total number of findings, and how many of them have severity Critical or High. If it reports no findings, both counts are 0.`,
    { model: 'haiku', effort: 'low', label: `verdict:${id}#${round}`, phase: 'Review', schema: VERDICT }),
    `verdict:${id}#${round}`)
}

const planItem = i => agent(
  [`Run directory: ${runDir}`,
   `Item: ${i.id} — ${i.title}`,
   `Owned files: ${i.files.join(', ')}`,
   `Integration worktree: ${integrationWt}`].join('\n'),
  { agentType: 'orchestrify-plan', label: `plan:${i.id}`, phase: 'Plan' })

// Commit with the attribution rule enforced against the repository itself, not
// the agent's self-report: the actual `git log` message is what gets checked.
// Two agent attempts (reset between them), then a deterministic rewrite.
// The regex holds only unambiguous attribution markers: "ai" and "agent" are
// legitimate domain vocabulary ("user-agent header", "feat: add AI summarizer")
// that false-positives constantly; keeping them out of ordinary prose is the
// stage agents' own instruction, not something a regex can decide.
const banned = /claude|anthropic|co-authored-by|generated (with|by)/i
// The agent may have made several commits, so the banned check must read every
// message it created, never just the tip — a clean later commit would hide a
// banned trailer beneath it. One command returns both the tip message (the
// value reported for the item) and the whole span's messages (what is checked).
const tipAndSpan = async (wt, range, label) => {
  const out = await sh(
    `git -C "${wt}" log -1 --format=%B ; echo "@@SPAN@@" ; git -C "${wt}" log --format=%B "${range}"`,
    label, 'Merge')
  return { tip: out.split('@@SPAN@@')[0].trim(), clean: !banned.test(out) }
}
const commitItem = async (wt, id, title, extraLines = []) => {
  const head = async tag => (await sh(`git -C "${wt}" rev-parse HEAD`, `head:${id}#${tag}`, 'Merge')).trim()
  const base = await head('base')
  for (let attempt = 1; attempt <= 2; attempt++) {
    must(await agent(
      [`Worktree: ${wt}`, `Run directory: ${runDir}`, `Item: ${id} — ${title}`, ...extraLines,
       attempt > 1 ? 'A previous message violated the attribution rule; describe only the change itself.' : '']
        .filter(Boolean).join('\n'),
      { agentType: 'orchestrify-commit', label: `commit:${id}#${attempt}`, phase: 'Merge' }),
      `commit:${id}#${attempt}`)
    const now = await head(attempt)
    if (now === base) {
      if (attempt === 2) {
        // A rebuilt or resumed item may have nothing new to commit — its work
        // is already committed and only a later stage failed. That is success.
        const probe = await sh(
          `if [ -z "$(git -C "${wt}" status --porcelain)" ] && [ "$(git -C "${wt}" rev-list --count "${integrationBranch}..HEAD")" -gt 0 ]; then echo NOTHING_NEW; else echo NEEDS_COMMIT; fi`,
          `probe:${id}`, 'Merge')
        if (probe.includes('NOTHING_NEW')) {
          const prior = await tipAndSpan(wt, `${integrationBranch}..HEAD`, `message:${id}#prior`)
          if (prior.clean) return { hash: base, message: prior.tip }
        }
        throw new Error('commit agent made no commit')
      }
      continue
    }
    const msg = await tipAndSpan(wt, `${base}..HEAD`, `message:${id}#${attempt}`)
    if (msg.clean) return { hash: now, message: msg.tip }
    // ${base}, not HEAD~1: the agent may have made zero or several commits.
    if (attempt === 1) await sh(`git -C "${wt}" reset --soft ${base}`, `reset:${id}`, 'Merge')
  }
  const fallback = banned.test(title) ? `chore: complete work item ${id}` : `chore: ${title}`
  // reset + fresh commit, not --amend: the banned marker may sit in a commit
  // below the tip, and an amend rewrites only HEAD.
  await sh(`git -C "${wt}" reset --soft ${base} && git -C "${wt}" commit -m '${fallback.replace(/'/g, `'\\''`)}'`,
           `rewrite:${id}`, 'Merge')
  return { hash: await head('rewrite'), message: fallback }
}

// ---------- per-item pipeline: worktree → implement → review/fix loop → commit → merge ----------
const buildItem = async item => {
  const wt = `${repoRoot}/orchestrify-${slug}-${item.id}`
  const branch = `orchestrify/${slug}-${item.id}`
  // Single leaf segment (…-W1, not …/W1): a git ref cannot be both a file and a directory.
  // A blocked item keeps its worktree across runs, so a follow-up run resumes it
  // here rather than failing on the collision.
  // -C ${integrationWt}, not ${repoRoot}: the repo root is only a git context
  // via its .git pointer file, and when that file is absent git discovery
  // walks up from it — possibly into an enclosing repo. The integration
  // worktree always resolves to the right bare repo.
  // Three arrivals: the directory survives from a previous run (resume it in
  // place); the directory is gone but its branch survived a half-finished
  // cleanup (re-add the worktree on that branch — `-b` would fail on the
  // collision); a fresh item. `worktree prune` before the re-add drops any
  // stale registration whose directory was deleted by hand, which would
  // otherwise fail the add as "already checked out".
  const wtOut = await sh(
    `if [ -d "${wt}" ]; then echo WORKTREE_REUSED; ` +
    `elif git -C "${integrationWt}" rev-parse -q --verify "refs/heads/${branch}" >/dev/null; then ` +
    `git -C "${integrationWt}" worktree prune && git -C "${integrationWt}" worktree add "${wt}" "${branch}" && echo BRANCH_RESUMED; ` +
    `else git -C "${integrationWt}" worktree add "${wt}" -b "${branch}" "${integrationBranch}"; fi`,
    `worktree:${item.id}`, 'Build')
  if (wtOut.includes('WORKTREE_REUSED')) log(`${item.id}: resuming the worktree left by a previous run`)
  else if (wtOut.includes('BRANCH_RESUMED')) log(`${item.id}: re-created the worktree for the branch left by a previous run`)

  const impl = must(await agent(
    [`Worktree: ${wt}`, `Run directory: ${runDir}`,
     `Item: ${item.id} — ${item.title}`, `Owned files: ${item.files.join(', ')}`].join('\n'),
    { agentType: 'orchestrify-implement', label: `implement:${item.id}`, phase: 'Build', schema: IMPLEMENT }),
    `implement:${item.id}`)
  // "I could not implement this as specified" is a signal, not noise — without
  // this gate an untouched worktree sails through review (empty diff, zero
  // findings) and only trips at commit time, with the real reason lost.
  if (!impl.completed) throw specRooted(`implementation infeasible: ${impl.summary}`)

  // Review → fix → re-review, max 2 fix rounds, gate on Critical/High (SKILL: bounded loops).
  // A first review with no findings at all has nothing to fix and skips the loop.
  const first = await review(item.id, wt, 0)
  if (first.total > 0) {
    for (let round = 1; ; round++) {
      must(await agent(
        [`Worktree: ${wt}`, `Run directory: ${runDir}`, `Item: ${item.id} — ${item.title}`].join('\n'),
        { agentType: 'orchestrify-fix', label: `fix:${item.id}#${round}`, phase: 'Review' }),
        `fix:${item.id}#${round}`)
      const verdict = await review(item.id, wt, round)
      if (verdict.criticalOrHigh === 0) break
      if (round === 2) throw specRooted('fix rounds exhausted with Critical/High findings remaining')
    }
  }

  const commit = await commitItem(wt, item.id, item.title)

  const merge = await serializedMerge(async () => {
    // Self-heal before merging: a predecessor that died mid-conflict must not
    // leave the integration worktree in MERGING state for everyone after it.
    await sh(`git -C "${integrationWt}" merge --abort 2>/dev/null || true`, `merge-reset:${item.id}`, 'Merge')
    const tipBefore = (await sh(`git -C "${integrationWt}" rev-parse HEAD`, `merge-tip:${item.id}`, 'Merge')).trim()
    const m = must(await agent(
      [`Integration worktree: ${integrationWt}`, `Run directory: ${runDir}`,
       `Item: ${item.id} — ${item.title}`,
       `Item branch: ${branch}`, `Integration branch: ${integrationBranch}`].join('\n'),
      { agentType: 'orchestrify-merge', label: `merge:${item.id}`, phase: 'Merge', schema: MERGE }),
      `merge:${item.id}`)
    // The merge agent's commit message is repo state its schema never returns —
    // apply the same attribution backstop as commitItem. Inside the serialized
    // section (an amend must never rewrite a commit a later merge builds on),
    // and only on commits this merge created (tip moved), never pre-run history.
    if (m.merged) {
      const tipAfter = (await sh(`git -C "${integrationWt}" rev-parse HEAD`, `merge-tip2:${item.id}`, 'Merge')).trim()
      if (tipAfter !== tipBefore) {
        // --first-parent: only the commits the merge agent itself created on
        // the integration branch — the item-branch commits it merged in were
        // already checked by commitItem and cannot be rewritten from here.
        const msgs = await sh(`git -C "${integrationWt}" log --first-parent --format=%B "${tipBefore}..HEAD"`,
                              `merge-messages:${item.id}`, 'Merge')
        if (banned.test(msgs)) {
          const safe = banned.test(item.title) ? `merge work item ${item.id}` : `merge ${item.id}: ${item.title}`
          const belowTip = await sh(
            `git -C "${integrationWt}" log --first-parent --skip=1 --format=%B "${tipBefore}..HEAD"`,
            `merge-below-tip:${item.id}`, 'Merge')
          if (!banned.test(belowTip)) {
            // Only the tip is banned — amend keeps the merge parents intact.
            await sh(`git -C "${integrationWt}" commit --amend -m '${safe.replace(/'/g, `'\\''`)}'`, `merge-amend:${item.id}`, 'Merge')
          } else {
            // A banned message below the tip (a post-merge fix commit sits on
            // top of it) cannot be amended away. Squash the span into one
            // clean commit: content and the attribution guarantee are kept,
            // only the merge topology is given up.
            await sh(`git -C "${integrationWt}" reset --soft ${tipBefore} && git -C "${integrationWt}" commit -m '${safe.replace(/'/g, `'\\''`)}'`,
                     `merge-squash:${item.id}`, 'Merge')
          }
        }
      }
    }
    return m
  })
  if (!merge.merged) throw specRooted(`merge aborted: ${merge.detail}`)

  // Cleanup is best-effort: the item is already merged, so a dirty worktree
  // (stray build output) must never demote it to blocked.
  try {
    await sh(`git -C "${integrationWt}" worktree remove --force "${wt}" && git -C "${integrationWt}" branch -D "${branch}"`,
             `cleanup:${item.id}`, 'Merge')
  } catch (err) {
    log(`${item.id}: worktree cleanup failed (non-fatal): ${String((err && err.message) || err)}`)
  }
  return commit
}

// ---------- wave: plan in parallel → reconcile/escalate (serialized) → build survivors ----------
const reconcilePrompt = ids =>
  `Read ${runDir}/spec.md (the Interfaces section is the contract) and the plans ` +
  `${ids.map(id => `${runDir}/plans/${id}.md`).join(', ')}. Check each plan against that contract — a plan ` +
  `assuming an interface shape the spec does not define is a conflict even with no sibling — and check ` +
  `across plans for what no single planner could see: an undeclared cross-item dependency, two plans ` +
  `assuming different shapes for a shared contract, or heavy overlap in files both will edit. Report ` +
  `clean=true only on a genuinely clean pass.`

const escalatePrompt = issues =>
  `You are resolving plan-reconciliation issues for an orchestrify run. Issues: ${issues.join('; ')}. ` +
  `Read ${runDir}/spec.md and the plans under ${runDir}/plans/. For each issue: if a fix preserves the ` +
  `spec's outcome, features, and non-goals (it changes only how, not what), AMEND — edit spec.md's ` +
  `Interfaces yourself and append the decision to its "## Decisions" log, citing the Doubt Rule where ` +
  `it applied; list the item ids whose plans must be regenerated in "replan". When the spec's doubt rule ` +
  `is prefer-smaller-scope and an item's feature can be cleanly cut rather than blocked, cutting it is an ` +
  `amendment: edit spec.md to remove the feature, record the cut in "## Decisions", and list that item in ` +
  `"cut". If every fix would change what was agreed, list those items in "blocked" with a one-line reason ` +
  `and the options the user must choose between. When an amendment declares a dependency between work ` +
  `items that the breakdown lacked, also report it in "addDeps" as {id, dependsOn: [ids]} — the scheduler ` +
  `orders builds from addDeps alone, and a dependency written only into spec.md never changes build order. ` +
  `Report addDeps as [] when no dependencies changed. The run's item set is frozen: never add, split, ` +
  `merge, or rename work items in the breakdown — the scheduler executes only the items it was launched ` +
  `with plus the moves you report structurally (replan, cut, blocked, addDeps), and a restructure written ` +
  `into spec.md alone would silently never run. If the only real fix is a restructure, list the affected ` +
  `items in "blocked" instead. Never expand scope past a non-goal.`

// Dependency amendments must land in the scheduler, not only in spec.md: pump()
// orders builds from the in-memory `items`, so a dependency the escalation
// agent writes into the breakdown alone would never change build order. It
// reports them structurally in "addDeps"; they are applied here. Only ids from
// the breakdown, only items not already building (pending, or this wave's —
// still held by the serialized section), and never an edge that would create a
// cycle: a cycle would leave items pending forever and hang the scheduler.
const reaches = (from, to) => {
  const seen = new Set(), stack = [from]
  while (stack.length) {
    const cur = stack.pop()
    if (cur === to) return true
    if (seen.has(cur)) continue
    seen.add(cur)
    const it = items.find(i => i.id === cur)
    if (it) stack.push(...it.deps)
  }
  return false
}
const applyDepAmendments = (addDeps, wave) => {
  for (const a of addDeps || []) {
    const it = items.find(i => i.id === a.id)
    if (!it) continue
    const eligible = state[it.id] === 'pending' ||
      (state[it.id] === 'active' && wave.some(w => w.id === it.id))
    for (const dep of a.dependsOn) {
      if (dep === a.id || it.deps.includes(dep) || !items.some(i => i.id === dep)) continue
      if (!eligible) { log(`dependency ${a.id} → ${dep} not applied: ${a.id} is already building or done`); continue }
      if (reaches(dep, a.id)) { log(`dependency ${a.id} → ${dep} not applied: it would create a cycle`); continue }
      it.deps.push(dep)
      log(`dependency added: ${a.id} now waits for ${dep}`)
    }
  }
}

// Mid-build escalation: a failure that smells spec-rooted gets one amend-vs-block
// judgment and, on amendment, one replan + rebuild in the item's kept worktree
// before it can block. Anything else blocks immediately. Spec-rooted failures
// are tagged where they are thrown, never pattern-matched from the message —
// rewording a message must not silently disable escalation for its class.
const specRooted = reason => Object.assign(new Error(reason), { escalatable: true })
const buildEscalatePrompt = (item, failure) =>
  `An orchestrify work item failed mid-build. Item: ${item.id} — ${item.title}. Failure: ${failure}. ` +
  `Read ${runDir}/spec.md, the plan ${runDir}/plans/${item.id}.md, and this item's latest review artifact ` +
  `under ${runDir}/reviews/ if one exists. Apply the escalation rule. action="rebuild" when a spec-level ` +
  `fix preserves the spec's outcome, features, and non-goals (it changes only how, not what): edit spec.md's ` +
  `Interfaces yourself and append the decision to its "## Decisions" log, citing the Doubt ` +
  `Rule where it applied — the item is then re-planned and rebuilt once in its existing worktree. ` +
  `Never restructure the breakdown (add, split, merge, or rename work items): the scheduler executes only ` +
  `the item set it was launched with, so a restructure written into spec.md would silently never run — ` +
  `if only a restructure would fix this, choose "block". ` +
  `action="cut" when the doubt rule is prefer-smaller-scope and this item's feature can be cleanly cut ` +
  `rather than blocked: edit spec.md to remove the feature and record the cut in "## Decisions". ` +
  `action="block" when every fix would change what was agreed; reason = one line plus the options the ` +
  `user must choose between. Never expand scope past a non-goal.`

const runWave = async wave => {
  const tag = wave.map(i => i.id).join('+')
  const plans = await parallel(wave.map(i => () => planItem(i)))
  plans.forEach((p, idx) => { if (p === null || p === undefined) block(wave[idx].id, 'plan agent was skipped or died') })

  // Escalation edits spec.md, so waves take the reconcile section one at a time.
  await serializedSpec(async () => {
    let live = wave.filter(i => state[i.id] === 'active')
    if (!live.length) return
    let rec = must(await agent(reconcilePrompt(live.map(i => i.id)),
      { model: 'opus', effort: 'high', label: `reconcile:${tag}`, phase: 'Plan', schema: RECONCILE }),
      `reconcile:${tag}`)
    if (rec.clean) return
    log(`reconciliation issues: ${rec.issues.join('; ')}`)
    // Escalation, SKILL rules: amend when the fix changes only *how* (edit spec.md, replan);
    // block when any fix would change *what* the brief promised.
    const esc = must(await agent(escalatePrompt(rec.issues),
      { model: 'opus', effort: 'high', label: `escalate:${tag}`, phase: 'Plan', schema: ESCALATE }),
      `escalate:${tag}`)
    // Only ids actually in this wave — the schema cannot stop the model from
    // naming an item it was never asked about, and a stray id would corrupt
    // the state table and the final report.
    esc.blocked.filter(b => live.some(i => i.id === b.id)).forEach(b => block(b.id, b.reason))
    esc.cut.filter(c => live.some(i => i.id === c.id)).forEach(c => cutItem(c.id, c.reason))
    applyDepAmendments(esc.addDeps, wave)
    // A wave item whose amended dependencies are not all merged has not started
    // building (the build loop runs after this serialized section) — send it
    // back to pending; pump() relaunches it the moment they are.
    wave.filter(i => state[i.id] === 'active' &&
        i.deps.some(d => state[d] !== 'merged' && state[d] !== 'cut'))
      .forEach(i => { state[i.id] = 'pending'; log(`${i.id} deferred: an amended dependency must merge first`) })
    const replan = live.filter(i => esc.replan.includes(i.id) && state[i.id] === 'active')
    if (replan.length) {
      const second = await parallel(replan.map(i => () => planItem(i)))
      second.forEach((p, idx) => { if (p === null || p === undefined) block(replan[idx].id, 'plan agent was skipped or died') })
    }
    live = wave.filter(i => state[i.id] === 'active')
    if (!live.length) return
    // Always re-check after an amendment — even one that named no plans to
    // regenerate — so a fall-through never builds on plans that failed reconciliation.
    rec = must(await agent(reconcilePrompt(live.map(i => i.id)),
      { model: 'opus', effort: 'high', label: `reconcile#2:${tag}`, phase: 'Plan', schema: RECONCILE }),
      `reconcile#2:${tag}`)
    if (!rec.clean) live.forEach(i => block(i.id, `unresolved after amendment: ${rec.issues.join('; ')}`))
  })

  // No barrier from here: each survivor pipelines through build → merge on its
  // own, and every completion re-pumps the scheduler so dependents launch the
  // moment their own deps are in — never when the whole wave is.
  for (const item of wave.filter(i => state[i.id] === 'active')) {
    // runItem resolves for every failure it can judge, but it can still reject
    // — e.g. the budget ceiling makes its re-plan agent() call throw. Without
    // a rejection handler the item would stay active forever and `drained`
    // would never resolve.
    runItem(item)
      .catch(err => { if (state[item.id] === 'active') block(item.id, String((err && err.message) || err)) })
      .then(() => pump())
  }
}

// Build one item, with at most one escalation-backed retry: a spec-rooted
// failure (see `escalatable`) gets an amend-vs-block judgment, and an
// amendment replans and rebuilds the item once in its kept worktree.
const runItem = async item => {
  for (let attempt = 1; ; attempt++) {
    try {
      const commit = await buildItem(item)
      state[item.id] = 'merged'
      shipped.push({ id: item.id, title: item.title, hash: commit.hash, message: commit.message })
      log(`${item.id} merged (${commit.hash})`)
      return
    } catch (err) {
      const reason = String((err && err.message) || err)
      // A blocked item keeps its worktree and branch for a follow-up run (SKILL: escalation rule).
      if (attempt === 2 || !(err && err.escalatable)) return block(item.id, reason)
      let esc = null
      try {
        // Escalation edits spec.md — same serialized section as wave reconciliation.
        esc = await serializedSpec(() => agent(buildEscalatePrompt(item, reason),
          { model: 'opus', effort: 'high', label: `escalate:${item.id}`, phase: 'Build', schema: BUILD_ESCALATE }))
      } catch (e) { /* fall through: a dead escalation agent means block */ }
      if (!esc || esc.action === 'block') return block(item.id, (esc && esc.reason) || reason)
      if (esc.action === 'cut') return cutItem(item.id, esc.reason)
      log(`${item.id}: spec amended after "${reason}" — replanning and rebuilding once`)
      const p = await planItem(item)
      if (p === null || p === undefined) return block(item.id, 'plan agent was skipped or died during re-plan')
    }
  }
}

// ---------- completion-driven scheduler ----------
// States: pending → active (planning/building) → merged | cut | blocked. pump()
// runs after every completion: it blocks items whose dependencies can no longer
// merge, launches a wave of the items whose dependencies are all satisfied
// (merged, or cut out of the spec), and resolves `drained` once nothing is
// pending or active. It loops to a fixpoint so a
// cascade (budget stop → dependents unrunnable) settles in one call.
let finishRun
const drained = new Promise(resolve => { finishRun = resolve })

const pump = () => {
  for (;;) {
    const depBlocked = items.filter(i => state[i.id] === 'pending' && i.deps.some(d => state[d] === 'blocked'))
    depBlocked.forEach(i => block(i.id, `dependency blocked: ${i.deps.filter(d => state[d] === 'blocked').join(', ')}`))

    const wave = items.filter(i => state[i.id] === 'pending' &&
      i.deps.every(d => state[d] === 'merged' || state[d] === 'cut'))
    if (!wave.length) { if (!depBlocked.length) break; continue }

    if (budget.total && budget.remaining() < 50_000) {
      log('token budget nearly exhausted — not starting further items')
      wave.forEach(i => block(i.id, 'run stopped: token budget exhausted'))
      continue
    }

    wave.forEach(i => { state[i.id] = 'active' })
    runWave(wave)
      .catch(err => wave.filter(i => state[i.id] === 'active')
        .forEach(i => block(i.id, String((err && err.message) || err))))
      .then(() => pump())
  }
  if (!items.some(i => state[i.id] === 'pending' || state[i.id] === 'active')) finishRun()
}

// Fail fast on a malformed breakdown. An unknown dependency id or a dependency
// cycle can never satisfy the wave filter or the blocked cascade, so its item
// would sit `pending` forever and `await drained` would hang the run — with
// every already-merged item's work left unreported.
const knownIds = new Set(items.map(i => i.id))
if (knownIds.size !== items.length)
  throw new Error('invalid work breakdown: duplicate item ids')
const unknownDeps = items.flatMap(i => i.deps.filter(d => !knownIds.has(d)).map(d => `${i.id} depends on unknown ${d}`))
if (unknownDeps.length)
  throw new Error(`invalid work breakdown: ${unknownDeps.join('; ')}`)
const cyclic = items.filter(i => i.deps.some(d => reaches(d, i.id))).map(i => i.id)
if (cyclic.length)
  throw new Error(`invalid work breakdown: dependency cycle through ${cyclic.join(', ')}`)

pump()
await drained

// ---------- integration verification (the tail of SKILL Step 4) ----------
phase('Integrate')
let integration = { features: [], fixesApplied: false, gaps: ['skipped: no items merged'] }
if (shipped.length) {
  try {
    integration = must(await agent(
      [`Integration worktree: ${integrationWt}`, `Run directory: ${runDir}`].join('\n'),
      { agentType: 'orchestrify-integrate', label: 'integration-verify', schema: INTEGRATION }),
      'integration-verify')
  } catch (err) {
    // The run result must survive a dead verifier: hours of merged work stay
    // reported, and the missing verification lands as a gap — an uncaught
    // throw here would fail the workflow and lose {shipped, blocked} entirely.
    integration = { features: [], fixesApplied: false,
      gaps: [`integration verification did not complete: ${String((err && err.message) || err)}`] }
  }

  if (integration.fixesApplied) {
    // One review-fix pass over the fixes (SKILL Step 4 tail). A failed review is recorded
    // as a gap — never a reason to leave the fixes sitting uncommitted.
    try {
      const verdict = await review('integration', integrationWt, 0)
      if (verdict.total > 0)
        must(await agent(
          [`Worktree: ${integrationWt}`, `Run directory: ${runDir}`,
           `Item: integration — fixes applied during integration verification`,
           `There is no plan file for this item; the spec is the reference.`].join('\n'),
          { agentType: 'orchestrify-fix', label: 'fix:integration', phase: 'Review' }),
          'fix:integration')
    } catch (err) {
      const reason = String((err && err.message) || err)
      log(`integration review did not complete — committing the fixes unreviewed (${reason})`)
      integration.gaps.push(`integration fixes were committed without a completed Codex review: ${reason}`)
    }
    try {
      const status = await sh(
        `[ -n "$(git -C "${integrationWt}" status --porcelain)" ] && echo DIRTY || echo CLEAN`,
        'integration-status', 'Merge')
      if (status.includes('DIRTY')) {
        const c = await commitItem(integrationWt, 'integration', 'integration fixes from full-feature verification',
          ['There is no plan file for this item; commit the integration fixes only.'])
        log(`integration fixes committed (${c.hash})`)
      }
    } catch (err) {
      integration.gaps.push(`integration fixes could not be committed: ${String((err && err.message) || err)}`)
    }
  }
}

return { shipped, cut, blocked, integration, tokensSpent: budget.spent() }

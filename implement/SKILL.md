---
name: implement
description: Execute a plan file phase by phase, writing clean functional code with small focused functions and descriptive intermediate variables
args: <plan-file>
user-invocable: true
---

# Implement

Execute a plan file phase by phase, writing clean, well-structured code.

## Input

The user provides a plan file path as an argument: `/implement <plan-file>`

If no plan file is provided, look for plan files in `.plans/` and ask the user which one to implement. If no plans exist, tell the user to create one first (e.g., with `/breakdown`).

## Step 1 — Read and understand the plan

Read the plan file and understand:

- The overall objective
- The phases and their order
- The tasks within each phase
- The acceptance criteria for each phase

Identify the first phase that has incomplete tasks (unchecked checkboxes). This is the phase you will work on. If all phases are complete, inform the user the plan is fully implemented.

## Step 2 — Research before coding

Before writing any code for the current phase:

- Read relevant existing files to understand current patterns and conventions
- Identify where new code should live and what it should integrate with
- Note any dependencies the phase requires

## Step 3 — Implement the phase

Work through each task in the current phase. Follow these coding principles strictly:

### Prefer functional style

- Favor pure functions over classes and mutable state
- Use `map`, `filter`, `reduce`, and other higher-order functions instead of imperative loops when they improve clarity
- Avoid side effects where possible — isolate them at the edges of the system
- Prefer immutable data — create new values instead of mutating existing ones
- Use function composition to build complex behavior from simple pieces

### Write small, focused functions

- Each function should do **one thing** and do it well
- If a function is longer than ~15–20 lines, it is probably doing too much — split it
- Name functions after what they return or what effect they perform (e.g., `parseConfig`, `buildUserQuery`, `formatOutput`)
- Prefer extracting a named function over writing an inline anonymous function when the logic is non-trivial
- Functions should have clear inputs and outputs — avoid relying on external mutable state

### Use descriptive intermediate variables

- Break complex expressions into steps using well-named intermediate variables
- The variable name should make the value's purpose obvious without needing a comment
- Prefer `const activeUsers = users.filter(u => u.isActive)` over inlining the filter inside a larger expression
- Use intermediate variables to document the "what" at each step of a transformation pipeline
- When chaining operations, break the chain if an intermediate result has a meaningful name that aids understanding

**Bad — hard to follow:**
```
return data.filter(x => x.status === 'active' && x.role !== 'admin').map(x => ({ ...x, displayName: `${x.first} ${x.last}` })).sort((a, b) => a.displayName.localeCompare(b.displayName))
```

**Good — each step is clear:**
```
const activeNonAdmins = data.filter(x => x.status === 'active' && x.role !== 'admin')
const withDisplayNames = activeNonAdmins.map(x => ({ ...x, displayName: `${x.first} ${x.last}` }))
const sorted = withDisplayNames.sort((a, b) => a.displayName.localeCompare(b.displayName))
return sorted
```

### Frontend components

When working with React, Vue, Svelte, or other component-based frameworks:

- Break components into small, focused units — each component should have a **single clear responsibility**
- Extract distinct pieces of UI or behavior into their own components rather than building large monolithic ones
- Separate **logic from presentation** — use hooks (React), composables (Vue), or equivalent patterns to keep business logic out of the template/render
- If a component handles both data fetching and rendering, split it into a container (logic) and a presentational component (UI)
- Keep components easy to reason about — a developer should understand what a component does from its name and props alone
- Prefer composition over prop drilling — pass children or use slots instead of threading data through many layers

### General code quality

- Follow the existing conventions of the codebase (naming, file structure, formatting)
- Do not add unnecessary error handling, comments, or abstractions
- Write code that is correct and readable — do not over-engineer

## Step 4 — Verify the phase

After completing all tasks in the phase:

- Run any relevant tests, linters, or build steps to confirm nothing is broken
- Check the acceptance criteria for the phase — every criterion must be met
- If something fails, fix it before moving on

## Step 5 — Update the plan

Mark completed tasks and update the plan file:

- Check off completed tasks (`- [x]`)
- If the phase is fully done, note it in the plan (e.g., change the phase heading or add a status note)
- Save the updated plan file

## Step 6 — Report and continue

Tell the user:

- What was implemented in this phase
- Whether all acceptance criteria were met
- What the next phase is (if any)

Ask the user if they want to proceed to the next phase. Do **not** continue automatically — wait for confirmation.

## Guidelines

- Work on **one phase at a time** — do not skip ahead or combine phases
- If a task is ambiguous, ask the user for clarification before implementing
- If a task turns out to be unnecessary or wrong, flag it to the user instead of silently skipping it
- Keep commits granular — commit after each phase if the user has not asked you to commit earlier
- If the plan needs to change based on what you learn during implementation, propose the change to the user before modifying the plan

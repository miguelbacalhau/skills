#!/usr/bin/env node
//
// orchestrify stage 4c — run the independent, cross-model Codex reviewer over the
// uncommitted changes in ONE work item's worktree, deterministically.
//
// This drives Codex through @openai/codex-sdk instead of shelling out to the CLI.
// The SDK spawns the codex binary it exact-pins into node_modules, which reads the
// same ~/.codex auth that `codex login` writes — so subscription auth is unchanged,
// and the CLI-version-drift bug class (stdin-EOF hangs, flag incompatibilities)
// dies with the pin. Review runs read-only at the sandbox level, and findings come
// back as typed JSON via outputSchema, so the counts printed below are computed,
// never a model's reading of prose.
//
// Usage:
//   codex-review.mjs <run-dir> <worktree> <item-id> <round> [owned-file...]
//
//   <run-dir>      the run directory holding spec.md and plans/; the findings
//                  artifact is written to <run-dir>/reviews/<item-id>-codex.md
//                  (raw JSON beside it at .json), and on success the round is
//                  archived as <item-id>-codex.round<round>.md/.json
//   <worktree>     worktree to review from (the thread's workingDirectory;
//                  review is sandboxed read-only, so it never edits source)
//   <item-id>      the work item under review; the literal id "integration"
//                  selects the integration-fixes variant (whole Interfaces
//                  section in scope, no plan file, no ownership boundary)
//   <round>        non-negative review round, used only for the archive names
//   [owned-file]   the files the item owns, from the spec's Work Breakdown
//
// The adversarial review prompt is assembled here from the static template
// shipped next to this script (review-prompt.md) — only the run directory,
// plan path, and file ownership are substituted in. The template names
// spec.md and the plan by path, never pasting their text, so a review always
// reads the current (possibly mid-run-amended) contract.
//
// Env:
//   CODEX_REVIEW_TIMEOUT   seconds for the per-attempt timeout bound (default 900)
//   CODEX_REVIEW_ATTEMPTS  max attempts, backoff 5s/15s/45s between (default 4)
//
// Output: diagnostics on stderr; one machine-readable line on stdout, last:
//   CODEX_REVIEW: COMPLETED total=<n> critical_high=<m> <output-file>
//   CODEX_REVIEW: FAILED <reason>
//
// The counts ride the completion line itself so exactly one line has to survive
// the workflow invoker's round-trip, and completion-implies-counts is structural.
//
// Exit 0 iff the review completed with valid structured output and a non-empty
// markdown artifact was written; non-zero otherwise. `findings: []` from valid
// structured output is a legitimate clean pass; missing or unparseable structured
// output is a failure, never a clean pass — the SDK does not validate the model's
// final response against the schema, so the parse-and-validate here is the
// load-bearing invariant.

import { statSync } from "node:fs";
import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { Codex } from "@openai/codex-sdk";

const SEVERITIES = ["Critical", "High", "Medium", "Low"];

// Strict structured-output dialect: every property required, no additions.
// `file` and `line` are nullable on purpose — reviews legitimately produce
// location-less findings (untested error paths, cross-cutting interface
// complaints), and a schema that forces a location makes the model fabricate
// one for the fix agent to chase.
const FINDINGS_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["findings"],
  properties: {
    findings: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["severity", "file", "line", "title", "body", "fix_location"],
        properties: {
          severity: { type: "string", enum: SEVERITIES },
          file: { type: ["string", "null"] },
          line: { type: ["integer", "null"] },
          title: { type: "string" },
          body: { type: "string" },
          fix_location: { type: "string" },
        },
      },
    },
  },
};

const [runDir, worktree, itemId, roundArg, ...ownedFiles] = process.argv.slice(2);
const output =
  runDir && itemId ? path.join(runDir, "reviews", `${itemId}-codex.md`) : "";

// Fill the static template. Placeholders are checked before substitution so a
// template edit that drops one fails the review loudly instead of silently
// sending Codex a prompt with no spec path in it.
const buildPrompt = (template) => {
  const integration = itemId === "integration";
  const subject = integration
    ? "the uncommitted fixes applied during integration verification of the assembled feature"
    : "the uncommitted changes for ONE work item of a larger feature";
  const focus = integration
    ? "The whole Interfaces section is in scope for these fixes. There is no\n" +
      "plan file and no ownership boundary; the spec is the reference."
    : "The spec's Work Breakdown entry for this item and the plan name the\n" +
      "interfaces it implements or consumes.\n" +
      `Intent and recorded Deviations: ${runDir}/plans/${itemId}.md.\n` +
      `This item owns: ${ownedFiles.join(", ") || "the files its plan names"}.`;
  const body = template.replace(/^<!--[\s\S]*?-->\s*/, "");
  const subs = [
    ["{{SUBJECT}}", subject],
    ["{{RUN_DIR}}", runDir],
    ["{{FOCUS}}", focus],
  ];
  for (const [key] of subs)
    if (!body.includes(key)) throw new Error(`template is missing ${key}`);
  return subs.reduce((text, [key, value]) => text.split(key).join(value), body);
};

// A malformed knob ("15m", "four") must never become NaN: Node coerces a NaN
// setTimeout delay to ~1ms (every attempt aborts instantly) and `1 <= NaN` is
// false (the attempt loop never runs). Warn and fall back to the default.
const envInt = (name, fallback) => {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  const n = Number(raw);
  if (Number.isFinite(n) && n > 0) return n;
  console.error(`ignoring ${name}=${raw}: not a positive number, using ${fallback}`);
  return fallback;
};
const timeoutSecs = envInt("CODEX_REVIEW_TIMEOUT", 900);
const maxAttempts = envInt("CODEX_REVIEW_ATTEMPTS", 4);

const die = (reason) => {
  console.log(`CODEX_REVIEW: FAILED ${reason}`);
  process.exitCode = 1;
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const isDir = (p) => {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
};

// Validate the model's final response ourselves — run() hands back a plain
// string and the SDK never checks it against outputSchema.
const parseFindings = (text) => {
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    throw new Error("structured output is not valid JSON");
  }
  if (!data || typeof data !== "object" || !Array.isArray(data.findings))
    throw new Error("structured output has no findings array");
  for (const f of data.findings) {
    if (
      !f ||
      typeof f !== "object" ||
      !SEVERITIES.includes(f.severity) ||
      typeof f.title !== "string" ||
      typeof f.body !== "string" ||
      typeof f.fix_location !== "string" ||
      (f.file !== null && typeof f.file !== "string") ||
      (f.line !== null && !Number.isInteger(f.line))
    )
      throw new Error("a finding does not match the schema");
  }
  return data.findings;
};

// Render the artifact orchestrify-fix reads: grouped by severity, one section
// per finding, same taxonomy the review prompt template defines.
const render = (findings) => {
  if (!findings.length) return "# Codex review findings\n\nNo findings.\n";
  const sections = SEVERITIES.filter((sev) =>
    findings.some((f) => f.severity === sev),
  ).map((sev) => {
    const body = findings
      .filter((f) => f.severity === sev)
      .map((f) => {
        const loc =
          f.file === null
            ? ""
            : ` — \`${f.file}${f.line === null ? "" : `:${f.line}`}\``;
        return `### ${f.title}${loc}\n\n${f.body.trim()}\n\n**Fix belongs in:** ${f.fix_location.trim()}\n`;
      })
      .join("\n");
    return `## ${sev}\n\n${body}`;
  });
  return `# Codex review findings\n\n${sections.join("\n")}`;
};

// One review attempt. Read-only sandbox makes re-running on retry safe, and a
// fresh thread per attempt means a failed attempt's context never biases the
// next one. The AbortSignal is the timeout bound: the SDK passes it straight
// into child_process.spawn, so an abort kills the spawned codex process.
const attempt = async (codex, prompt) => {
  await writeFile(output, ""); // a stale artifact from a prior attempt never reads as success
  const thread = codex.startThread({
    sandboxMode: "read-only",
    workingDirectory: worktree,
    skipGitRepoCheck: true,
    // Explicit, not defaulted: a hung approval prompt inside an unattended run
    // is the worst available failure mode.
    approvalPolicy: "never",
  });
  const controller = new AbortController();
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutSecs * 1000);
  let turn;
  try {
    turn = await thread.run(prompt, {
      outputSchema: FINDINGS_SCHEMA,
      signal: controller.signal,
    });
  } catch (err) {
    if (timedOut) throw new Error(`timeout after ${timeoutSecs}s`);
    throw err;
  } finally {
    clearTimeout(timer);
  }
  const findings = parseFindings(turn.finalResponse ?? "");
  await writeFile(`${output}.json`, JSON.stringify({ findings }, null, 2) + "\n");
  await writeFile(output, render(findings));
  if (!(statSync(output).size > 0)) throw new Error("rendered artifact is empty");
  return {
    total: findings.length,
    criticalHigh: findings.filter(
      (f) => f.severity === "Critical" || f.severity === "High",
    ).length,
  };
};

const main = async () => {
  if (!runDir || !worktree || !itemId || roundArg === undefined)
    return die(
      "usage: codex-review.mjs <run-dir> <worktree> <item-id> <round> [owned-file...]",
    );
  if (!isDir(worktree)) return die(`worktree not a directory: ${worktree}`);
  if (!isDir(runDir)) return die(`run directory not a directory: ${runDir}`);
  const round = Number(roundArg);
  if (!Number.isInteger(round) || round < 0)
    return die(`round is not a non-negative integer: ${roundArg}`);
  let prompt;
  try {
    prompt = buildPrompt(
      await readFile(new URL("./review-prompt.md", import.meta.url), "utf8"),
    );
  } catch (err) {
    return die(`prompt template unusable: ${String((err && err.message) || err)}`);
  }
  await mkdir(path.dirname(output), { recursive: true });

  const codex = new Codex();
  let lastReason = "";
  let backoff = 5;
  for (let i = 1; i <= maxAttempts; i++) {
    try {
      const { total, criticalHigh } = await attempt(codex, prompt);
      // Archive the round only after a completed attempt — a stale or empty
      // artifact from a failed one must never be archived as a round result.
      const base = output.slice(0, -".md".length);
      await copyFile(output, `${base}.round${round}.md`);
      await copyFile(`${output}.json`, `${base}.round${round}.json`);
      console.log(
        `CODEX_REVIEW: COMPLETED total=${total} critical_high=${criticalHigh} ${output}`,
      );
      return;
    } catch (err) {
      lastReason = String((err && err.message) || err);
    }
    if (i < maxAttempts) {
      console.error(
        `review attempt ${i}/${maxAttempts} failed: ${lastReason} — retrying in ${backoff}s`,
      );
      await sleep(backoff * 1000);
      backoff *= 3;
    }
  }
  die(`Codex review did not complete after ${maxAttempts} attempts (${lastReason})`);
};

await main();

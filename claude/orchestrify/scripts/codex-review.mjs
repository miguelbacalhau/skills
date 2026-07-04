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
//   codex-review.mjs <worktree> <output-file> <prompt-file>
//
//   <worktree>     item worktree to review from (the thread's workingDirectory;
//                  review is sandboxed read-only, so it never edits source)
//   <output-file>  where the findings artifact is written (markdown, rendered
//                  from the structured findings; raw JSON lands at <output-file>.json)
//   <prompt-file>  file holding the assembled adversarial review prompt; the
//                  orchestrator owns its content, this script owns the mechanics
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
import { mkdir, readFile, writeFile } from "node:fs/promises";
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

const [worktree, output, promptFile] = process.argv.slice(2);

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
  if (!worktree || !output || !promptFile)
    return die("usage: codex-review.mjs <worktree> <output-file> <prompt-file>");
  if (!isDir(worktree)) return die(`worktree not a directory: ${worktree}`);
  let prompt;
  try {
    prompt = await readFile(promptFile, "utf8");
  } catch {
    prompt = "";
  }
  if (!prompt.trim()) return die(`prompt file missing or empty: ${promptFile}`);
  await mkdir(path.dirname(output), { recursive: true });

  const codex = new Codex();
  let lastReason = "";
  let backoff = 5;
  for (let i = 1; i <= maxAttempts; i++) {
    try {
      const { total, criticalHigh } = await attempt(codex, prompt);
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

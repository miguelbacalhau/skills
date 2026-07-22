// Parse-check a Workflow script the way the host runs it: exports hoisted
// out, body wrapped in an async function (top-level await + return legal).
const { readFileSync } = require('node:fs')
const vm = require('node:vm')
for (const f of process.argv.slice(2)) {
  const src = readFileSync(f, 'utf8').replace(/^export /gm, '')
  try {
    new vm.Script(`(async () => {\n${src}\n})`, { filename: f })
    console.log(`PARSE-OK ${f}`)
  } catch (e) {
    console.error(`PARSE-FAIL ${f}: ${e.message}`)
    process.exitCode = 1
  }
}

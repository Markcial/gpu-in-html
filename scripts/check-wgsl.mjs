#!/usr/bin/env node
// Validate every .wgsl in the repo.
//
// `vgpu check` takes one entry at a time and resolves its import graph, so we
// walk the tree and check each file. Modules are checked standalone too — a
// primitive that only compiles once some example happens to import it is a
// primitive with a hidden dependency.

import { execFile } from "node:child_process";
import { globSync } from "node:fs";
import { promisify } from "node:util";

const run = promisify(execFile);

const files = globSync([
  "packages/wgsl/src/**/*.wgsl",
  "examples/*/src/**/*.wgsl",
]).sort();

if (files.length === 0) {
  console.error("No .wgsl files found. Run this from the repository root.");
  process.exit(1);
}

let failed = 0;

for (const file of files) {
  try {
    const { stdout } = await run("npx", ["vgpu", "check", file, "--require-validation"]);
    const report = JSON.parse(stdout);
    const diagnostics = report.diagnostics ?? [];

    if (diagnostics.length > 0) {
      failed += 1;
      console.error(`FAIL ${file}`);
      for (const d of diagnostics) {
        console.error(`     ${d.code ?? "diagnostic"}: ${d.message ?? JSON.stringify(d)}`);
      }
      continue;
    }

    if (report.validation?.ok !== true) {
      failed += 1;
      console.error(`FAIL ${file} — validation did not pass: ${JSON.stringify(report.validation)}`);
      continue;
    }

    console.log(`ok   ${file}`);
  } catch (error) {
    failed += 1;
    console.error(`FAIL ${file}`);
    console.error(String(error.stdout || error.stderr || error.message).trim());
  }
}

console.log(`\n${files.length - failed}/${files.length} shaders valid`);
process.exit(failed === 0 ? 0 : 1);

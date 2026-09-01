#!/usr/bin/env node
// Compose the 05-forge scene with TypeGPU and write it out as a vgpu module.
//
// This is the whole seam between the two libraries, and it is one file write.
// TypeGPU runs at build time and emits WGSL; vgpu's resolver picks the result
// up as an ordinary module, which is why `pnpm check` validates it, the
// wgsl-std import resolves natively, and the browser never loads TypeGPU.

import { writeFileSync } from "node:fs";

import { module } from "../examples/05-forge/src/scene.def.ts";

const out = "examples/05-forge/src/scene.generated.wgsl";
writeFileSync(out, module);

const functions = (module.match(/^\s*(export )?fn\s+/gm) ?? []).length;
console.log(`${out} — ${module.length} chars, ${functions} functions`);

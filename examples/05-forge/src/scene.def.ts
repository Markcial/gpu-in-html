// The scene, composed. This file is the input to `pnpm generate`; nothing here
// ships to the browser.

import {
  at,
  box,
  displace,
  emitModule,
  marcher,
  normals,
  smoothUnion,
  sphere,
  subtract,
  torus,
} from "./forge.ts";

const scene = displace(
  smoothUnion(
    subtract(sphere(1.0), at(box([0.62, 0.62, 1.5], 0.06), [0.62, 0.52, 0.0])),
    at(torus(0.68, 0.19), [1.62, 0.05, 0.0]),
    0.42,
  ),
  0.05,
  3.2,
);

// Stable names, because the entry shader imports these by name.
const march = marcher(scene).$name("march");
const normalAt = normals(scene).$name("normalAt");

export const module = emitModule({
  imports: ['import { fbmSimplex3d } from "@vgpu/wgsl-std/noise/simplex";'],
  items: [march, normalAt],
  exports: ["march", "normalAt"],
});

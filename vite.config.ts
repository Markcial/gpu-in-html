import { readdirSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { defineConfig } from "vite";
import { wgslVitePlugin } from "@vgpu/wgsl/loader-vite";

// One Vite app rooted at the repository, so `/` is the gallery and every
// example is reachable at its own path on the same server. Each example still
// has its own package.json and resolves @gpu-in-html/wgsl by package name —
// the thing that proves the library is actually consumable.
const examplesDir = resolve(import.meta.dirname, "examples");

const examplePages = Object.fromEntries(
  readdirSync(examplesDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && existsSync(resolve(examplesDir, entry.name, "index.html")))
    .map((entry) => [entry.name, resolve(examplesDir, entry.name, "index.html")]),
);

export default defineConfig(({ mode }) => ({
  // Project Pages is served at /gpu-in-html/. `vite build` and `vite preview`
  // both run in production mode; `pnpm dev` stays at / on localhost.
  base: mode === "production" ? "/gpu-in-html/" : "/",
  plugins: [wgslVitePlugin()],
  build: {
    // init() is awaited at the top level. Vite's default target (es2020)
    // rejects top-level await; every browser that ships WebGPU supports it.
    target: "es2022",
    rollupOptions: {
      input: {
        gallery: resolve(import.meta.dirname, "index.html"),
        ...examplePages,
      },
    },
  },
}));

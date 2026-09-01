import { defineConfig } from "vite";
import { wgslVitePlugin } from "@vgpu/wgsl/loader-vite";

export default defineConfig({
  plugins: [wgslVitePlugin()],
  build: {
    // init() is awaited at the top level. Vite's default target (es2020)
    // rejects top-level await; every browser that ships WebGPU supports it.
    target: "es2022",
  },
});

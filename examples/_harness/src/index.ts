// Shared dev glue for the examples: mount a fullscreen fragment shader on a
// canvas, feed it a `params` uniform every frame, and hand back a stop handle.
//
// This is NOT part of the published library — @gpu-in-html/wgsl stays pure
// WGSL. Everything here is convenience for the gallery, and any example is
// free to drop it and talk to vgpu directly.

import { clock, effect, frameLoop, init, surface } from "vgpu";
import type { Effect, ShaderSource, Surface } from "vgpu";

export interface PointerState {
  /** Canvas-relative, 0..1, top-origin — the same space as vgpu's `uv`. */
  readonly position: readonly [number, number];
  readonly down: boolean;
}

export interface FrameContext {
  readonly time: number;
  readonly deltaTime: number;
  readonly frameCount: number;
  readonly resolution: readonly [number, number];
  readonly pointer: PointerState;
}

export interface MountOptions {
  /**
   * Extra members merged into the `params` uniform each frame. Declare them in
   * the entry shader's own struct, in the same order you return them.
   */
  readonly uniforms?: (ctx: FrameContext) => Record<string, unknown>;
  /** Device pixel ratio, or a [min, max] clamp. Defaults to a 1–2 clamp. */
  readonly dpr?: number | readonly [number, number];
  /** Cap the loop. Omit to run at display refresh rate. */
  readonly fps?: number;
}

export interface Sketch {
  readonly output: Surface;
  readonly shader: Effect;
  stop(): void;
}

function trackPointer(canvas: HTMLCanvasElement): {
  read(): PointerState;
  dispose(): void;
} {
  let position: readonly [number, number] = [0.5, 0.5];
  let down = false;

  // Listen on the window, not the canvas. A canvas used as a page background
  // sits behind the DOM, so pointer events over any UI on top of it would
  // never reach it and the tracked position would freeze.
  const onMove = (event: PointerEvent) => {
    const rect = canvas.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) return;
    position = [
      (event.clientX - rect.left) / rect.width,
      (event.clientY - rect.top) / rect.height,
    ];
  };
  const onDown = () => {
    down = true;
  };
  const onUp = () => {
    down = false;
  };

  window.addEventListener("pointermove", onMove);
  window.addEventListener("pointerdown", onDown);
  window.addEventListener("pointerup", onUp);
  window.addEventListener("pointercancel", onUp);

  return {
    read: () => ({ position, down }),
    dispose() {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerdown", onDown);
      window.removeEventListener("pointerup", onUp);
      window.removeEventListener("pointercancel", onUp);
    },
  };
}

// `source` is whatever you hand vgpu: an inline WGSL string, or the
// ShaderSource object the .wgsl loader produces on import.
export async function mount(
  canvas: HTMLCanvasElement,
  source: string | ShaderSource,
  opts: MountOptions = {},
): Promise<Sketch> {
  const gpu = await init();
  const output = surface(gpu, canvas, { dpr: opts.dpr ?? [1, 2] });
  const shader = effect(gpu, source);
  const time = clock(gpu);
  const pointer = trackPointer(canvas);

  const loop = frameLoop(
    gpu,
    (currentFrame) => {
      const ctx: FrameContext = {
        time: time.time,
        deltaTime: time.deltaTime,
        frameCount: time.frameCount,
        resolution: output.size,
        pointer: pointer.read(),
      };

      // `set()` writes straight to the GPU with no change detection, so this
      // is one write per frame for values that genuinely change every frame.
      shader.set({
        params: {
          resolution: [ctx.resolution[0], ctx.resolution[1]],
          time: ctx.time,
          ...opts.uniforms?.(ctx),
        },
      });

      currentFrame.pass(output, shader);
    },
    opts.fps === undefined ? undefined : { fps: opts.fps },
  );

  return {
    output,
    shader,
    stop() {
      loop.stop();
      pointer.dispose();
      output.dispose();
    },
  };
}

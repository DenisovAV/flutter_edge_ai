// Stands in for @litertjs/core. The test decides what a compile returns via
// globalThis.__compile(accelerator), which may throw to reject that accelerator.
export async function loadLiteRt() {}
export async function loadAndCompile(_path, { accelerator }) {
  return globalThis.__compile(accelerator);
}
export class Tensor {}

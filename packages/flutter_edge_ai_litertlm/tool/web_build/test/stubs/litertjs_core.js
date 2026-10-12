// Stands in for @litertjs/core. The test decides what a compile returns via
// globalThis.__compile(accelerator), which may throw to reject that accelerator.
export async function loadLiteRt() {}
export async function loadAndCompile(_path, { accelerator }) {
  return globalThis.__compile(accelerator);
}
// Records every tensor the bundle creates, so a test can read the ids it ran
// and check that each one was freed.
export class Tensor {
  constructor(data, shape) {
    this.data = data;
    this.shape = shape;
    this.deleted = false;
    (globalThis.__tensors ??= []).push(this);
  }
  delete() {
    this.deleted = true;
  }
}

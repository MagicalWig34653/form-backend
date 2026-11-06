// SPDX-License-Identifier: AGPL-3.0-only
/** Owns raw secret buffers for one operation. Lock disposes synchronously, even during awaits. */
export class KeyOperation {
  private buffers = new Set<Uint8Array>();
  private disposed = false;
  constructor(
    private current: () => boolean = () => true,
    private release = () => {},
  ) {}
  check(): void {
    if (this.disposed || !this.current()) throw new Error('Schlüssel wurden gesperrt');
  }
  track(buffer: Uint8Array): Uint8Array {
    if (this.disposed || !this.current()) {
      buffer.fill(0);
      this.check();
    }
    this.buffers.add(buffer);
    return buffer;
  }
  copy(buffer: Uint8Array): Uint8Array {
    this.check();
    return this.track(buffer.slice());
  }
  dispose(): void {
    this.disposed = true;
    for (const buffer of this.buffers) buffer.fill(0);
    this.buffers.clear();
    this.release();
  }
}

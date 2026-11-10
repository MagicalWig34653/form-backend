import { afterEach } from 'vitest';
import { cleanup } from '@testing-library/svelte';

// jsdom has no layout engine and no ResizeObserver (used by bind:clientWidth).
if (typeof globalThis.ResizeObserver === 'undefined') {
  globalThis.ResizeObserver = class {
    observe(): void {}
    unobserve(): void {}
    disconnect(): void {}
  };
}

afterEach(() => cleanup());

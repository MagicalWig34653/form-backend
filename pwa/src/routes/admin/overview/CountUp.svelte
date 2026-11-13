<script lang="ts">
  import { untrack } from 'svelte';
  import { motion } from '$lib/motion';

  interface Props {
    value: number;
    /** Formats the shown number (default: German grouping, whole numbers). */
    format?: (n: number) => string;
    /** Duration in ms for the first appearance and for later changes. */
    duration?: number;
    class?: string;
  }
  const defaultFormat = (n: number): string =>
    new Intl.NumberFormat('de-DE', { maximumFractionDigits: 0 }).format(n);
  let { value, format = defaultFormat, duration = 600, class: className }: Props = $props();

  // Start at 0 only when the animation will actually run, so the end value never flashes first.
  let shown = $state(untrack(() => (motion.reduced ? value : 0)));
  let frame = 0;

  $effect(() => {
    const target = value;
    cancelAnimationFrame(frame);
    if (motion.reduced || typeof requestAnimationFrame !== 'function') {
      shown = target;
      return;
    }
    const from = untrack(() => shown);
    const started = performance.now();
    const step = (now: number): void => {
      const p = Math.min(1, (now - started) / duration);
      const eased = 1 - Math.pow(1 - p, 3);
      shown = from + (target - from) * eased;
      if (p < 1) frame = requestAnimationFrame(step);
      else shown = target;
    };
    frame = requestAnimationFrame(step);
    return () => cancelAnimationFrame(frame);
  });
</script>

<!-- Screen readers get the end value only; the running number is decorative. -->
<span class={className}>
  <span aria-hidden="true" data-testid="countup-visual">{format(shown)}</span>
  <span class="sr-only" data-testid="countup-value">{format(value)}</span>
</span>

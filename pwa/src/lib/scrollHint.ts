/**
 * Svelte action for horizontally scrolling regions: sets data-more="true" while content is
 * hidden to the right, so CSS (.scroll-hint) can fade the edge. Nothing is cut off silently.
 */
export function scrollHint(node: HTMLElement): { destroy(): void } {
  const update = (): void => {
    const more = node.scrollWidth - node.clientWidth - node.scrollLeft > 2;
    node.dataset.more = more ? 'true' : 'false';
  };
  node.classList.add('scroll-hint');
  update();
  node.addEventListener('scroll', update, { passive: true });
  const observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(update);
  observer?.observe(node);
  window.addEventListener('resize', update);
  return {
    destroy(): void {
      node.removeEventListener('scroll', update);
      window.removeEventListener('resize', update);
      observer?.disconnect();
    },
  };
}

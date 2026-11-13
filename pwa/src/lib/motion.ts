/** Whether the system asks for reduced motion (read on demand, so changes apply without a reload). */
export const motion = {
  get reduced(): boolean {
    return (
      typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches
    );
  },
};

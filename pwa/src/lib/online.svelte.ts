/** Reactive browser connectivity; the top bar shows an "Offline" chip while it is false. */
const state = $state({ online: typeof navigator === 'undefined' ? true : navigator.onLine });

if (typeof window !== 'undefined') {
  window.addEventListener('online', () => (state.online = true));
  window.addEventListener('offline', () => (state.online = false));
}

export const connectivity = {
  get online(): boolean {
    return state.online;
  },
};

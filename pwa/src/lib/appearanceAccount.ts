// The application's single preferences sync (account <-> browser cache).
import { adminApi } from './api';
import { createAppearanceSync } from './appearanceSync.svelte';
import { theme } from './theme.svelte';

export const appearanceSync = createAppearanceSync({ api: adminApi, theme });

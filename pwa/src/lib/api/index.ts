import { createAdminApi } from './admin';
import { createAuthApi } from './auth';
import { createHttp } from './http';

/** The application's single transport: login, session and administration share one CSRF token. */
export const http = createHttp();
export const authApi = createAuthApi({ http });
export const adminApi = createAdminApi(http);

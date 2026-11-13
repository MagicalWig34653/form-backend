import { execFileSync } from 'node:child_process';
import { env } from './helpers';

// Database access of the migration end-to-end spec (backend/e2e-migration.sh). Both MariaDB servers are throw-away containers.

function run(container: string, password: string, db: string, statement: string): string {
  return execFileSync(
    'docker',
    ['exec', '-i', '-e', `MYSQL_PWD=${password}`, container, 'mariadb', '-uroot', '-N', db],
    { input: statement, encoding: 'utf8' },
  ).trim();
}

/** Target database (the new system). */
export const target = (statement: string): string =>
  run(env('E2E_DB_CONTAINER'), env('E2E_DB_PASSWORD'), 'e2e', statement);

/** Frozen legacy source (root of the throw-away container; the import itself only has a SELECT account). */
export const source = (statement: string): string =>
  run(
    env('E2E_LEGACY_CONTAINER'),
    env('E2E_LEGACY_ROOT_PASSWORD'),
    env('E2E_LEGACY_DB'),
    statement,
  );

export const uuidBin = (uuid: string) => `UNHEX('${uuid.replace(/-/g, '')}')`;

/** The admin budget is 120 requests per minute and IP; the SPA polls, so the counters are cleared between big steps. */
export const resetBudget = () => target('DELETE FROM auth_throttles');

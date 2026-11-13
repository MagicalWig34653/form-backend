import { execFileSync } from 'node:child_process';
import { env } from './helpers';

// Helpers of the operator path (backend/e2e-operator.sh). Database access only for counting and for checks the page cannot show; every
// change goes through the browser like an operator does it. Values of the real dump are never printed (counts, formats, codes only).

function run(container: string, password: string, db: string, statement: string): string {
  return execFileSync(
    'docker',
    ['exec', '-i', '-e', `MYSQL_PWD=${password}`, container, 'mariadb', '-uroot', '-N', db],
    { input: statement, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 },
  ).trim();
}

export const target = (statement: string): string =>
  run(env('E2E_DB_CONTAINER'), env('E2E_DB_PASSWORD'), env('E2E_DB_NAME'), statement);
export const source = (statement: string): string =>
  run(
    env('E2E_LEGACY_CONTAINER'),
    env('E2E_LEGACY_ROOT_PASSWORD'),
    env('E2E_LEGACY_DB'),
    statement,
  );
export const uuidBin = (uuid: string) => `UNHEX('${uuid.replace(/-/g, '')}')`;
/** The admin budget is per IP and minute; the SPA polls, so the counters are cleared between big steps. */
export const resetBudget = () => target('DELETE FROM auth_throttles');

/** Runs an action of the run's control script (restart, recreate, kill, update, image). */
export const ctl = (action: string): string =>
  execFileSync(env('E2E_CTL'), [action], { encoding: 'utf8', timeout: 600_000 }).trim();

const t0 = Date.now();
let last = Date.now();
/** One protocol line per step: STEP <name> ok <seconds>s (the shell copies these lines into the run log). */
export function stepDone(name: string, detail = '') {
  const now = Date.now();
  console.log(
    `STEP ${name} ok ${((now - last) / 1000).toFixed(1)}s (T+${Math.round((now - t0) / 1000)}s)${detail ? ' ' + detail : ''}`,
  );
  last = now;
}
export const note = (text: string) => console.log(`NOTE ${text}`);
export const finding = (text: string) => console.log(`FINDING ${text}`);

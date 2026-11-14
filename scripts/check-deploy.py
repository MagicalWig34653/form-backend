#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Isolated deployment contract checks. Command doubles never contact a Docker daemon."""
import json
import os
from pathlib import Path
import pty
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REAL_DOCKER = shutil.which('docker')
IMAGE = 'ghcr.io/magicalwig34653/form-backend:test'
SOURCE_KEYS = set('''FORM_HTTP_HOST FORM_PUBLIC_PORT FORM_INTERNAL_PORT FORM_PUBLIC_DASHBOARD FORM_PUBLIC_DASHBOARD_HOSTS FORM_PUBLIC_TRUSTED_PROXIES FORM_INTERNAL_TRUSTED_PROXIES FORM_LOG_LEVEL FORM_DB_HOST FORM_DB_PORT
FORM_DB_USER FORM_DB_PASSWORD FORM_DB_PASSWORD_FILE FORM_DB_NAME FORM_DB_TLS FORM_ALLOW_INSECURE_DEV
FORM_SCHEMA_FILE FORM_PUBLIC_DIR FORM_TRUSTED_PROXIES FORM_MAIL_ALLOWED_NETS FORM_SERVER_KEY_FILE
FORM_ADMIN_ORIGIN FORM_RP_ID FORM_BOOTSTRAP_PASSWORD_FILE FORM_SDK_DIR LOG_LEVEL'''.split())
MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args=sys.argv[1:]
base=pathlib.Path(os.environ['MOCK_STATE'])
name=pathlib.Path(sys.argv[0]).name
if not (name=='curl' and any('ghcr.io' in x for x in args)):
 with (base/'commands').open('a') as f: f.write(json.dumps([name]+args)+'\n')
if name in ('curl','sleep'): sys.exit(0)
a=' '.join(args)
if args[:2]==['info','--format']: print('true')
elif args[:2]==['image','inspect']: print('ghcr.io/magicalwig34653/form-backend@sha256:'+'a'*64)
elif args[:2]==['secret','inspect']: sys.exit(0 if (base/('secret-'+args[2])).exists() else 1)
elif args[:2]==['secret','create']: (base/('secret-'+args[2])).touch()
elif args[:2]==['network','inspect']:
 if '--format' in args: print('bridge' if os.environ['MOCK_MODE']=='compose' else 'overlay')
elif args[:2]==['service','inspect']:
 if args[2].endswith(('_migrate','_dbcheck')): sys.exit(1)
 print('completed')
elif args[:2]==['service','ls']:
 service=args[args.index('--filter')+1].removeprefix('name=')
 replicas=(os.environ.get('FORM_PINNED_REPLICAS','1') if os.environ.get('FORM_PINNED_NODE') else '0') if service.endswith('_app-pinned') else os.environ.get('FORM_REPLICAS','3')
 if service.endswith('_app-pinned') and os.environ.get('FAIL_PINNED')=='1': print(service+' 0/'+replicas)
 else: print(service+' '+replicas+'/'+replicas)
 # Deliberately include a prefix match: rollout must compare the exact service name.
 print(service+'-other 99/99')
elif args[:2] in (['stack','config'], ['stack','deploy']):
 (base/('render-'+args[1])).write_text(sys.stdin.read())
elif args[:2]==['service','ps']: print('migration-task' if '_migrate' in a else 'db-task')
elif args and args[0]=='inspect':
 if 'ExitCode' in a: print('0')
 else: print('failed' if (args[-1]=='migration-task' and os.environ.get('FAIL_MIGRATION')=='1') or (args[-1]=='db-task' and os.environ.get('FAIL_DB')=='1') else 'complete')
elif args and args[0]=='run':
 cmd=args[args.index('-c')+3:]
 if cmd[0]=='mariadb-dump': print('CREATE TABLE entries (id INT); INSERT INTO entries VALUES (1),(2);')
 elif '-e' in cmd or '-Nse' in cmd:
  marker='-e' if '-e' in cmd else '-Nse'
  sql=cmd[cmd.index(marker)+1]
  if sql.startswith('CREATE DATABASE') and os.environ.get('RESTORE_EXISTS')=='1': sys.exit(1)
  if 'SELECT 1' in sql and os.environ.get('FAIL_DB')=='1': sys.exit(1)
  if 'SELECT TABLE_NAME' in sql: print('entries')
  elif 'SELECT COUNT' in sql: print('2')
elif args and args[0]=='compose':
 sys.stdin.read()
 if 'run' in args and os.environ.get('FAIL_MIGRATION')=='1': sys.exit(23)
'''


def run(args, env=None, ok=True, input_text=None):
    try:
        result = subprocess.run(args, cwd=ROOT, env=env, input=input_text, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
                                stdin=None if input_text is not None else subprocess.DEVNULL)
    except subprocess.TimeoutExpired as exc:
        raise AssertionError(('HANG nach 120s', args, (exc.stderr or b'')[-1500:]))
    assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
    return result


def menu_double(folder, answers):
    """whiptail-Double: liefert Antworten 'rc|text' der Reihe nach (leer = Abbrechen) und protokolliert die Argumente."""
    folder.mkdir(exist_ok=True)
    queue, log = folder / 'answers', folder / 'calls.jsonl'
    queue.write_text('\n'.join(answers) + '\n')
    log.write_text('')
    stub = folder / 'whiptail'
    stub.write_text('#!/usr/bin/env python3\nimport json, pathlib, sys\n'
                    f'p = pathlib.Path({str(queue)!r})\nwith open({str(log)!r}, "a") as f: f.write(json.dumps(sys.argv[1:]) + "\\n")\n'
                    'q = [l for l in p.read_text().splitlines() if l != ""]\n'
                    'if not q:\n    sys.exit(1)\nrc, _, out = q[0].partition("|")\np.write_text("\\n".join(q[1:]) + "\\n")\n'
                    'sys.stderr.write(out)\nsys.exit(int(rc))\n')
    stub.chmod(0o755)
    return log


def run_tty(args, env):
    """Skript mit Pseudo-Terminal als stdin/stdout starten (Dialog-Pfad), stderr getrennt."""
    master, slave = pty.openpty()
    proc = subprocess.Popen(args, cwd=ROOT, env=env, stdin=slave, stdout=slave, stderr=subprocess.PIPE, text=True)
    os.close(slave)
    chunks = []
    while True:
        try:
            data = os.read(master, 4096)
        except OSError:
            break
        if not data:
            break
        chunks.append(data)
    err = proc.stderr.read()
    proc.wait()
    os.close(master)
    return proc.returncode, b''.join(chunks).decode(errors='replace'), err


def menu_texts(log):
    """Alle Textargumente der protokollierten Dialogaufrufe (msgbox/yesno/inputbox)."""
    return '\n'.join('\n'.join(a) for a in (json.loads(l) for l in log.read_text().splitlines()))


def commands(state):
    path = state / 'commands'
    return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []


def is_migration(c):
    return c[-1:] == ['migrate'] and ('create' in c or 'run' in c)


def is_rollout(c):
    return c[1:3] == ['stack', 'deploy'] or (c[1:2] == ['compose'] and 'up' in c)


for mode in ('swarm', 'compose'):
    path = ROOT / 'deploy' / mode / ('stack.env.example' if mode == 'swarm' else '.env.example')
    keys = set(re.findall(r'^#?\s*([A-Z][A-Z0-9_]+)=', path.read_text(), re.M))
    assert SOURCE_KEYS <= keys, SOURCE_KEYS - keys
# Use the current registry, not an unrelated branch snapshot.
registry = (ROOT / 'backend/Sources/FormCore/SettingsRegistry.swift').read_text()
registry_envs = set(re.findall(r'\.init\([^\n]*?"(FORM_[A-Z0-9_]+)"', registry))
SOURCE_KEYS |= registry_envs | {'FORM_INTERNAL_SECOND_FACTOR'}
for mode in ('swarm', 'compose'):
    path = ROOT / 'deploy' / mode / ('stack.env.example' if mode == 'swarm' else '.env.example')
    keys = set(re.findall(r'^#?\s*([A-Z][A-Z0-9_]+)=', path.read_text(), re.M))
    assert SOURCE_KEYS <= keys, SOURCE_KEYS - keys
    yaml_path = ROOT / 'deploy' / mode / ('stack.yaml' if mode == 'swarm' else 'compose.yaml')
    yaml_text = yaml_path.read_text()
    wrapper_text = (ROOT / 'deploy/docker-entrypoint.sh').read_text()
    for key in registry_envs:
        assert re.search(r'^\s+' + key + ':', yaml_text, re.M), key
        assert key + '_FILE:' in yaml_text, key
        assert key in wrapper_text, key

with tempfile.TemporaryDirectory(prefix='form-deploy-check-') as tmp:
    base = Path(tmp)
    copy = base / 'repo'
    shutil.copytree(ROOT / 'deploy', copy / 'deploy', ignore=shutil.ignore_patterns('secrets', 'stack.env', '.env'))
    shutil.copytree(ROOT / 'scripts', copy / 'scripts')
    state = base / 'state'
    state.mkdir()
    bindir = base / 'bin'
    bindir.mkdir()
    for name in ('docker', 'curl', 'sleep'):
        path = bindir / name
        path.write_text(MOCK)
        path.chmod(0o755)
    env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ['PATH'], MOCK_STATE=str(state), DB_PRECHECK='1', FORM_TAG_LOOKUP='0')
    for mode in ('swarm', 'compose'):
        env['MOCK_MODE'] = mode
        folder = copy / 'deploy' / mode
        template = folder / ('stack.env.example' if mode == 'swarm' else '.env.example')
        config = folder / ('stack.env' if mode == 'swarm' else '.env')
        secrets = folder / 'secrets'
        secrets.mkdir()
        (secrets / 'db_password').write_text('synthetic-db-password')
        (secrets / 'server_key').write_text('b' * 64)
        (secrets / 'bootstrap_password').write_text('FORM_OPTIONAL_UNSET')
        config.write_text(template.read_text())
        for action in ('setup', 'update'):
            script = str(folder / (action + '.sh'))
            run([script, '--help'], env)
            before = config.read_bytes()
            run([script, '--dry-run', '--non-interactive', '--image', IMAGE], env)
            assert config.read_bytes() == before
            assert not commands(state), 'Dry run contacted external commands'
        update = str(folder / 'update.sh')
        # Persistence must retain unset vs explicit empty and JSON list text.
        roundtrip = """
MODE=$1 ACTION=setup BASE=$2
source "$BASE/../swarm/lib.sh"
initialize --dry-run --non-interactive --env-file "$3"
save_config
! [[ "$CONFIG_KEYS" == *" FORM_SERVER_KEY "* ]]
! [[ "$CONFIG_KEYS" == *" FORM_DB_PASSWORD "* ]]
[[ "$(cat "$ENV_FILE")" != *synthetic-process-secret* ]]
unset FORM_PUBLIC_TRUSTED_PROXIES FORM_MCP_TOKEN_RATE_LIMIT FORM_ABUSE_UA_PATTERNS
read_config "$ENV_FILE"
[[ -z "${FORM_PUBLIC_TRUSTED_PROXIES+x}" ]]
[[ -n "${FORM_INTERNAL_TRUSTED_PROXIES+x}" && -z "$FORM_INTERNAL_TRUSTED_PROXIES" ]]
[[ "$FORM_MCP_TOKEN_RATE_LIMIT" == 77 ]]
[[ "$FORM_ABUSE_UA_PATTERNS" == '["synthetic-bot"]' ]]
"""
        run(['bash', '-c', roundtrip, 'roundtrip', mode, str(folder), str(base / (mode + '-roundtrip.env'))],
            dict(env, FORM_SERVER_KEY='synthetic-process-secret', FORM_DB_PASSWORD='synthetic-process-secret',
                 FORM_INTERNAL_TRUSTED_PROXIES='', FORM_MCP_TOKEN_RATE_LIMIT='77',
                 FORM_ABUSE_UA_PATTERNS='["synthetic-bot"]'))
        # Port files must fail before Docker/migration, even when files could swap listeners.
        for port_key in ('FORM_PUBLIC_PORT', 'FORM_INTERNAL_PORT'):
            port_file = base / 'port-override'
            port_file.write_text('8080\n')
            run([update, '--non-interactive', '--dry-run'],
                dict(env, **{port_key + '_FILE': str(port_file)}), ok=False)
            assert not commands(state)
        for failure in ('FAIL_DB', 'FAIL_MIGRATION'):
            before = config.read_bytes()
            run([update, '--non-interactive', '--image', IMAGE], dict(env, **{failure: '1'}), ok=False)
            log = commands(state)
            assert not any(is_rollout(c) for c in log), 'Failed precondition rolled app'
            if failure == 'FAIL_DB':
                assert not any(is_migration(c) for c in log), 'Failed DB check started migration'
            elif mode == 'swarm':
                assert not any(c[1:3] == ['config', 'rm'] for c in log), 'Unclear migration unlocked'
            elif mode == 'compose':
                assert Path(str(config) + '.deploy-lock').is_dir()
                Path(str(config) + '.deploy-lock').rmdir()
            assert config.read_bytes() == before
            (state / 'commands').unlink()
        run([update, '--non-interactive', '--tag', 'new-release'], env)
        log = commands(state)
        migrate = next(i for i, c in enumerate(log) if is_migration(c))
        rollout = next(i for i, c in enumerate(log) if is_rollout(c))
        dbcheck = next(i for i, c in enumerate(log) if ('--name' in c and c[c.index('--name') + 1].endswith('_dbcheck')) or ('run' in c and 'SELECT 1' in c))
        assert dbcheck < migrate < rollout
        (state / 'commands').unlink()
        run([update, '--non-interactive', '--tag', 'new-release-2'], dict(env, DB_PRECHECK='0'))
        log2 = commands(state)
        assert not any(('--name' in c and c[c.index('--name') + 1].endswith('_dbcheck')) or ('run' in c and 'SELECT 1' in c) for c in log2), 'Default must not use the MariaDB client image'
        assert any(is_migration(c) for c in log2) and any(is_rollout(c) for c in log2)
        assert not any('CREATE DATABASE' in ' '.join(c) for c in log), 'Setup/update created DB'
        # Der Digest gilt nur im Lauf (Rollout mit @sha256), gespeichert bleibt der Tag; ein alter gespeicherter Digest hält nichts fest.
        assert not re.search(r'^FORM_IMAGE="[^"]*@sha256', config.read_text(), re.M) and re.search(r'^FORM_IMAGE_TAG="new-release-2"', config.read_text(), re.M)
        old = base / 'old-digest.env'
        old.write_text(config.read_text().replace('FORM_IMAGE=""', 'FORM_IMAGE="ghcr.io/magicalwig34653/form-backend@sha256:' + 'b' * 64 + '"'))
        old.chmod(0o600)
        res = run([update, '--non-interactive', '--dry-run', '--env-file', str(old)], env)
        assert 'b' * 64 not in res.stdout, 'alter gespeicherter Digest wurde weiterverwendet'
        assert config.stat().st_mode & 0o777 == 0o600
        assert 'synthetic-db-password' not in config.read_text()
        assert 'synthetic-db-password' not in (state / 'commands').read_text()
        (state / 'commands').unlink()
        run([update, '--non-interactive', '--dry-run'], dict(env, FORM_DB_HOST='override.example.org', FORM_INTERNAL_PORT='9090',
                                       **({'FORM_PUBLISH_PORT': '19090'} if mode == 'swarm' else {'PUBLISHED_PORT': '19090'}), FORM_IMAGE_TAG='env-tag'))
        result = run([update, '--non-interactive', '--dry-run'], dict(env, FORM_DB_HOST='override.example.org', FORM_IMAGE_TAG='env-tag'))
        assert 'override.example.org' in result.stdout and ':env-tag' in result.stdout
        result = run([update, '--non-interactive', '--dry-run', '--tag', 'cli-tag'], dict(env, FORM_IMAGE_TAG='env-tag'))
        assert ':cli-tag' in result.stdout
        config.write_text(template.read_text() + '\nFORM_LOG_LEVEL=$(touch /tmp/form-must-not-exist)\n')
        run([update, '--non-interactive', '--dry-run'], env, ok=False)
        config.write_text(template.read_text() + '\nPATH=/untrusted\n')
        run([update, '--non-interactive', '--dry-run'], env, ok=False)
        config.write_text(template.read_text())
        run([update, '--non-interactive', '--dry-run'], dict(env, FORM_DB_TLS='disable', FORM_ALLOW_INSECURE_DEV='0'), ok=False)
        assert not commands(state)
    env['MOCK_MODE'] = 'swarm'
    folder = copy / 'deploy/swarm'
    (folder / 'stack.env').unlink()
    result = run([str(folder / 'setup.sh'), '--dry-run'], env,
                 input_text='probe\nhttps://admin.example.org:8443\n\nexternal-db.example.org\n3307\noperator\nexisting\nverify\nfixed\n2\nnode.role==worker\nspread=node.labels.zone\nworker-a\n2\nreserved\n18080\n\n18081\ningress\n\n')
    assert 'operator@external-db.example.org:3307/existing' in result.stdout
    assert 'Gesamt: 4 Replikate' in result.stdout
    assert 'app=18080; app-pinned=18081' in result.stdout
    assert not (folder / 'stack.env').exists()
    # Setup-Menü (Dialog-Pfad mit Pseudo-Terminal und whiptail-Double): Felder, Ablehnung, Passwort, Sperren, Abbruch, Trockenlauf.
    PW = 'S3cret-Menue-Pass-4711'
    menu_dir = base / 'menu-bin'
    menu_env = dict(env, PATH=str(menu_dir) + os.pathsep + env['PATH'], MOCK_MODE='swarm')
    menu_env.pop('FORM_PLAIN_PROMPT', None)
    swarm_env_file = folder / 'stack.env'
    secrets = folder / 'secrets'
    (secrets / 'db_password').unlink()  # frische Installation: noch kein Passwort
    # Abbrechen nach einer Änderung: nichts geschrieben, keine externen Kommandos.
    log = menu_double(menu_dir, ['0|STACK', '0|changed', '1|'])
    rc, out, err = run_tty([str(folder / 'setup.sh')], menu_env)
    assert rc != 0 and 'abgebrochen' in err and not swarm_env_file.exists() and not commands(state), (rc, out, err, menu_texts(log))
    # Installieren blockiert: Pflichtfeld fehlt, Platzhalter, kein Passwort; ungültige Eingabe wird abgelehnt (erneut gefragt).
    log = menu_double(menu_dir, ['0|INSTALL', '0|', '0|FORM_DB_HOST', '0|db host', '0|db.kunde.test', '0|INSTALL', '0|', '1|'])
    rc, out, err = run_tty([str(folder / 'setup.sh')], dict(menu_env, FORM_DB_HOST=''))
    texts = menu_texts(log)
    assert rc != 0 and not swarm_env_file.exists() and not commands(state)
    assert 'FORM_DB_HOST: Host oder IP' in texts and 'Platzhalter' in texts and 'DB-Passwort nicht gesetzt' in texts, texts
    assert 'Eingabe ungültig' in texts, texts  # "db host" abgelehnt
    # Trockenlauf im Menü zeigt den Plan, schreibt nichts; Passwort bleibt unsichtbar.
    log = menu_double(menu_dir, ['0|FORM_ADMIN_ORIGIN', '0|https://forms.kunde.test:8443', '0|FORM_DB_HOST', '0|db.kunde.test',
                                 '0|FORM_DB_PASSWORD', '0|' + PW, '0|DRYRUN', '0|', '1|'])
    rc, out, err = run_tty([str(folder / 'setup.sh')], menu_env)
    texts = menu_texts(log)
    assert rc != 0 and 'Trockenlauf (swarm/setup)' in texts and 'form@db.kunde.test:3306/form' in texts
    assert 'gesetzt' in texts and PW not in texts + out + err and not swarm_env_file.exists() and not commands(state)
    # Vollständiger Lauf: RP-ID folgt dem Origin, TLS disable fragt die Entwicklungsfreigabe, Passwort nur in der Secret-Datei.
    for stale in state.glob('secret-*'):
        stale.unlink()
    log = menu_double(menu_dir, ['0|STACK', '0|probe', '0|FORM_ADMIN_ORIGIN', '0|ftp://bad', '0|https://forms.kunde.test:8443',
                                 '0|FORM_DB_HOST', '0|db.kunde.test', '0|FORM_DB_PASSWORD', '0|' + PW,
                                 '0|FORM_DB_TLS', '0|disable', '0|1', '0|FORM_REPLICAS', '0|2', '0|INSTALL', '0|'])
    rc, out, err = run_tty([str(folder / 'setup.sh')], menu_env)
    assert rc == 0, (out, err)
    saved = swarm_env_file.read_text()
    assert 'FORM_RP_ID="forms.kunde.test"' in saved and 'FORM_ADMIN_ORIGIN="https://forms.kunde.test:8443"' in saved
    assert 'FORM_DB_TLS="disable"' in saved and 'FORM_ALLOW_INSECURE_DEV="1"' in saved and 'FORM_REPLICAS="2"' in saved
    assert 'STACK="probe"' in saved and swarm_env_file.stat().st_mode & 0o777 == 0o600
    assert PW not in saved and PW not in out + err + menu_texts(log) + (state / 'commands').read_text()
    assert (secrets / 'db_password').read_text().strip() == PW
    swarm_env_file.unlink()
    (secrets / 'db_password').unlink()
    (secrets / 'db_password').write_text('synthetic-db-password')
    for stale in state.glob('secret-*'):
        stale.unlink()
    (state / 'commands').unlink()
    # Compose: Menü bis zum Trockenlauf über die CLI-Option.
    compose_env = dict(menu_env, MOCK_MODE='compose')
    log = menu_double(menu_dir, ['0|FORM_ADMIN_ORIGIN', '0|https://forms.kunde.test', '0|FORM_DB_HOST', '0|db.kunde.test',
                                 '0|FORM_DB_PASSWORD', '0|' + PW, '0|INSTALL', '0|'])
    compose_file = base / 'compose-menu.env'
    rc, out, err = run_tty([str(copy / 'deploy/compose/setup.sh'), '--dry-run', '--env-file', str(compose_file)], compose_env)
    assert rc == 0 and 'Trockenlauf (compose/setup)' in out and 'form@db.kunde.test:3306/form' in out, (out, err)
    assert PW not in out + err and not compose_file.exists() and 'FORM_REPLICAS' not in menu_texts(log)
    (menu_dir / 'whiptail').unlink()
    print('setup.sh: Menü (Pseudo-Terminal, whiptail-Double) für Swarm/Compose bestanden.')
    # Actual setup execution with command doubles, existing external password, no DB creation.
    run([str(folder / 'setup.sh'), '--non-interactive', '--db-password-file', str(folder / 'secrets/db_password')], env)
    assert not any('CREATE DATABASE' in ' '.join(c) for c in commands(state))
    assert 'synthetic-db-password' not in (folder / 'stack.env').read_text()
    (state / 'commands').unlink()

    # Swarm placement contract, including pin removal on a subsequent update.
    update = str(folder / 'update.sh')
    placement = dict(env, FORM_PINNED_NODE='worker-a', FORM_PINNED_REPLICAS='2',
                     FORM_EXCLUDE_LABEL='reserved', FORM_PLACEMENT_CONSTRAINTS='node.role==worker,node.labels.disk==ssd',
                     FORM_PLACEMENT_PREFERENCES='spread=node.labels.zone,spread=node.labels.rack')
    result = run([update, '--non-interactive', '--dry-run'], placement)
    assert 'Gesamt: 5 Replikate' in result.stdout and 'worker-a' in result.stdout
    assert not commands(state)
    run([update, '--non-interactive'], placement)
    for c in commands(state):
        if c[1:3] == ['service', 'create']:
            assert c[c.index('--constraint') + 1] == 'node.labels.reserved!=true'
    rendered = (state / 'render-deploy').read_text()
    assert 'node.role==worker' in rendered and 'node.labels.reserved!=true' in rendered
    assert 'spread: "node.labels.zone"' in rendered
    assert rendered == (state / 'render-config').read_text()
    (state / 'commands').unlink()
    # Desired 2 replicas with no running pinned tasks must fail even if app is ready.
    run([update, '--non-interactive'], dict(placement, FAIL_PINNED='1', WAIT_SECONDS='1'), ok=False)
    assert not any(c[1:3] == ['config', 'rm'] for c in commands(state))
    (state / 'commands').unlink()
    run([update, '--non-interactive'], dict(env, FORM_PINNED_NODE=''))
    assert 'FORM_PINNED_NODE=""' in (folder / 'stack.env').read_text()
    (state / 'commands').unlink()
    for overrides in ({'FORM_PINNED_REPLICAS': '0'}, {'FORM_PINNED_NODE': 'bad"node'},
                      {'FORM_EXCLUDE_LABEL': 'reserved:true'}, {'FORM_PLACEMENT_CONSTRAINTS': 'node.role==worker,'},
                      {'FORM_PLACEMENT_CONSTRAINTS': 'node.role==worker,,node.labels.zone==a'},
                      {'FORM_PLACEMENT_PREFERENCES': 'binpack=node.labels.zone'},
                      {'FORM_PUBLISH_PORT': '0'}, {'FORM_PUBLISH_PORT': '65536'},
                      {'FORM_PINNED_PUBLISH_PORT': 'abc'}, {'FORM_PUBLISH_PORT': '8080', 'FORM_PINNED_PUBLISH_PORT': '08080'},
                      {'FORM_PUBLISH_BIND': '127.0.0.1'}, {'PUBLISH_MODE': 'invalid'}):
        run([update, '--non-interactive', '--dry-run'], dict(env, **overrides), ok=False)
    assert not commands(state)
    result = run([update, '--dry-run'], env, input_text='-\n-\nworker-b\n3\n-\n\n18080\n18081\ningress\n\n')
    assert 'Gesamt: 6 Replikate' in result.stdout and 'Ausschluss: aus' in result.stdout
    result = run([update, '--dry-run'], env, input_text='-\n-\n-\n\n-\n-\n-\n-\ningress\n-\n')
    assert 'Gesamt: 3 Replikate' in result.stdout and 'Knoten=aus' in result.stdout
    assert not commands(state)
    publish_env = dict(placement, FORM_PUBLISH_PORT='18080', FORM_PINNED_PUBLISH_PORT='18081')
    result = run([update, '--non-interactive', '--dry-run'], publish_env)
    assert 'app=18080; app-pinned=18081' in result.stdout
    run([update, '--non-interactive'], publish_env)
    assert (state / 'render-config').read_text() == (state / 'render-deploy').read_text()
    assert 'published: 18080' in (state / 'render-deploy').read_text()
    assert 'published: 18081' in (state / 'render-deploy').read_text()
    (state / 'commands').unlink()
    run([update, '--non-interactive'], dict(env, FORM_PUBLISH_PORT='', FORM_PUBLIC_PUBLISH_PORT='', FORM_PINNED_NODE=''))
    assert 'published:' not in (state / 'render-deploy').read_text()
    (state / 'commands').unlink()

    # Real Docker CLI rendering is daemon-free; command doubles above test orchestration.
    if REAL_DOCKER:
        render_script = '''set -euo pipefail
BASE="$PWD/deploy/swarm"; MODE=swarm; ACTION=setup
source "$BASE/lib.sh"
initialize --dry-run --non-interactive --env-file "$RENDER_ENV_FILE"
render_swarm | "$REAL_DOCKER" stack config -c - | "$REAL_DOCKER" compose -f - config --format json
'''
        for node in ('', 'worker-a', 'abcde12345abcde12345abcde1'):
            for exclude in ('', 'reserved'):
                render_env = dict(env, REAL_DOCKER=REAL_DOCKER, RENDER_ENV_FILE=str(base / 'absent.env'),
                                  FORM_PINNED_NODE=node, FORM_PINNED_REPLICAS='2', FORM_EXCLUDE_LABEL=exclude,
                                  # Defaults publish both listeners (commit 260a255); this case checks the unpublished layout.
                                  FORM_PUBLISH_PORT='', FORM_PUBLIC_PUBLISH_PORT='',
                                  FORM_PLACEMENT_CONSTRAINTS='node.role == worker,node.labels.disk==ssd',
                                  FORM_PLACEMENT_PREFERENCES='spread=node.labels.zone')
                model = json.loads(run(['bash', '-c', render_script], render_env).stdout)
                app, pinned = (model['services'][k] for k in ('app', 'app-pinned'))
                assert app['deploy']['replicas'] == 3
                assert app['deploy']['endpoint_mode'] == pinned['deploy']['endpoint_mode'] == 'dnsrr'
                assert pinned['deploy']['replicas'] == (2 if node else 0)
                constraints = app['deploy']['placement']['constraints']
                assert constraints[:2] == ['node.role == worker', 'node.labels.disk==ssd']
                assert ('node.labels.reserved!=true' in constraints) == bool(exclude)
                assert app['deploy']['placement']['preferences'] == [{'spread': 'node.labels.zone'}]
                expected = ('node.id==' if len(node) == 25 else 'node.hostname==') + node
                if node: assert pinned['deploy']['placement']['constraints'] == [expected]
                assert 'node.labels.reserved!=true' not in pinned['deploy']['placement']['constraints']
                for key in ('image', 'environment', 'secrets', 'healthcheck', 'configs', 'networks'):
                    assert app[key] == pinned[key], key
                for key in ('update_config', 'rollback_config', 'resources', 'restart_policy'):
                    assert app['deploy'][key] == pinned['deploy'][key], key
                assert app['networks']['backend']['aliases'] == ['form-public', 'form-internal']
                assert not app.get('ports') and not pinned.get('ports')
        publish_cases = [
            ('', '', 'ingress', 'worker-a'),
            ('18080', '', 'ingress', 'worker-a'),
            ('', '18081', 'ingress', 'worker-a'),
            ('18080', '18081', 'ingress', 'worker-a'),
            ('', '18081', 'host', 'worker-a'),
            ('18080', '18081', 'host', 'worker-a'),
            ('18080', '18081', 'ingress', ''),
        ]
        for app_port, pinned_port, publish_mode, node in publish_cases:
            render_env = dict(env, REAL_DOCKER=REAL_DOCKER, RENDER_ENV_FILE=str(base / 'absent.env'),
                              FORM_PUBLISH_PORT=app_port, FORM_PINNED_PUBLISH_PORT=pinned_port, FORM_PUBLIC_PUBLISH_PORT='',
                              PUBLISH_MODE=publish_mode, FORM_PINNED_NODE=node, FORM_EXCLUDE_LABEL='reserved',
                              FORM_PUBLISH_BIND='0.0.0.0', FORM_PINNED_REPLICAS='1',
                              UPDATE_ORDER='stop-first', ROLLBACK_ORDER='stop-first')
            model = json.loads(run(['bash', '-c', render_script], render_env).stdout)
            for name, port in [('app', app_port), ('app-pinned', pinned_port if node else '')]:
                service = model['services'][name]
                ports = service.get('ports', [])
                assert len(ports) == bool(port)
                if port:
                    assert ports[0]['published'] == str(port)
                    assert ports[0]['target'] == 8081
                    assert ports[0]['mode'] == publish_mode and ports[0]['protocol'] == 'tcp'
                    assert not ports[0].get('host_ip')
                assert service['deploy']['endpoint_mode'] == ('vip' if port and publish_mode == 'ingress' else 'dnsrr')
                assert service['networks']['backend']['aliases'] == ['form-public', 'form-internal']
        # P11-A: independent optional public/internal publications, including pinned services.
        for internal, public in [('', ''), ('', '19080'), ('19081', ''), ('19081', '19080')]:
            render_env = dict(env, REAL_DOCKER=REAL_DOCKER, RENDER_ENV_FILE=str(base / 'absent.env'),
                FORM_PUBLISH_PORT=internal, FORM_PUBLIC_PUBLISH_PORT=public, FORM_PINNED_NODE='worker-a',
                FORM_PINNED_PUBLISH_PORT='19083', FORM_PINNED_PUBLIC_PUBLISH_PORT='19082',
                FORM_INTERNAL_PORT='9081', FORM_PUBLIC_PORT='9080')
            model = json.loads(run(['bash', '-c', render_script], render_env).stdout)
            ports = model['services']['app'].get('ports', [])
            assert {p['target'] for p in ports} == ({9081} if internal else set()) | ({9080} if public else set())
            assert {p['target'] for p in model['services']['app-pinned']['ports']} == {9080, 9081}
            compose_script = render_script.replace('deploy/swarm', 'deploy/compose').replace('MODE=swarm', 'MODE=compose').replace('source "$BASE/lib.sh"', 'source "$BASE/../swarm/lib.sh"').replace('render_swarm | "$REAL_DOCKER" stack config -c - | ', 'render_compose | ')
            compose_env = dict(render_env, PUBLISHED_PORT=internal, FORM_REPLICAS='1', NETWORK_DRIVER='bridge', BIND_ADDR='127.0.0.1')
            model = json.loads(run(['bash', '-c', compose_script], compose_env).stdout)
            ports = model['services']['app'].get('ports', [])
            assert {p['target'] for p in ports} == ({9081} if internal else set()) | ({9080} if public else set())
        # Render both orchestrators with absent, empty and explicit per-listener proxy overrides.
        for mode in ('swarm', 'compose'):
            script = render_script if mode == 'swarm' else compose_script
            for overrides in ({}, {'FORM_PUBLIC_TRUSTED_PROXIES': ''},
                              {'FORM_PUBLIC_TRUSTED_PROXIES': '192.0.2.10/32',
                               'FORM_INTERNAL_TRUSTED_PROXIES': '192.0.2.11/32'}):
                config_env = dict(env, REAL_DOCKER=REAL_DOCKER, RENDER_ENV_FILE=str(base / 'absent.env'),
                                  FORM_TRUSTED_PROXIES='192.0.2.0/24', FORM_REPLICAS='1' if mode == 'compose' else '3',
                                  NETWORK_DRIVER='bridge' if mode == 'compose' else 'overlay', BIND_ADDR='127.0.0.1' if mode == 'compose' else '0.0.0.0',
                                  FORM_MCP_TOKEN_RATE_LIMIT='77', FORM_MIGRATION_ALLOWED_NETS='198.51.100.10/32',
                                  FORM_ABUSE_UA_PATTERNS='["synthetic-bot"]', **overrides)
                model = json.loads(run(['bash', '-c', script], config_env).stdout)
                for service in model['services'].values():
                    values = service['environment']
                    assert values['FORM_TRUSTED_PROXIES'] == '192.0.2.0/24'
                    for key in ('FORM_PUBLIC_TRUSTED_PROXIES', 'FORM_INTERNAL_TRUSTED_PROXIES'):
                        assert values.get(key) == overrides.get(key), (mode, key, values.get(key))
                    assert values['FORM_MCP_TOKEN_RATE_LIMIT'] == '77'
                    assert values['FORM_MIGRATION_ALLOWED_NETS'] == '198.51.100.10/32'
                    assert values['FORM_ABUSE_UA_PATTERNS'] == '["synthetic-bot"]'
                    assert values.get('FORM_OPS_THRESHOLD') is None
        print('Audit: Proxy-Fallback/Leerwert/Override und optionale Registry-ENVs für Compose/Swarm bestanden.')
        print('P11-A: je vier öffentliche/interne Swarm- und Compose-Portkombinationen bestanden.')
        print('Docker stack config: 6 Platzierungs- und 7 Veröffentlichungsvarianten bestanden (ohne Daemon).')
    else:
        print('Grenze: Docker CLI fehlt; echtes stack config nicht geprüft, nur Rendering mit Kommando-Doubles.')

    backup_script = str(copy / 'scripts/backup-db.sh')
    restore_script = str(copy / 'scripts/restore-db.sh')
    backup = base / 'backup'
    password = base / 'password'
    password.write_text('synthetic-db-password')
    db_env = dict(env, FORM_DB_HOST='external-db.example.org', FORM_DB_PASSWORD_FILE=str(password),
                  FORM_BACKUP_ALLOW_PLAINTEXT='1')
    run([backup_script, str(base / 'backup-noenc')], {k: v for k, v in db_env.items() if k != 'FORM_BACKUP_ALLOW_PLAINTEXT'}, ok=False)  # fail-closed without recipient
    for script, args in [(backup_script, [str(backup)]), (restore_script, [str(backup), 'restore_probe'])]:
        run([script, '--help'], db_env)
        run([script, *args, '--dry-run'], db_env)
    assert not commands(state)
    run([backup_script, str(backup)], db_env)
    assert backup.stat().st_mode & 0o777 == 0o700
    assert (backup / 'database.sql').stat().st_mode & 0o777 == 0o600
    assert '--ssl-verify-server-cert' in (state / 'commands').read_text()
    assert 'synthetic-db-password' not in (state / 'commands').read_text()
    run([backup_script, str(backup)], db_env, ok=False)
    run([restore_script, str(backup), 'restore_probe'], db_env)
    (state / 'commands').unlink()
    run([restore_script, str(backup), 'restore_probe'], dict(db_env, RESTORE_EXISTS='1'), ok=False)
    log = commands(state)
    assert len(log) == 2 and 'max_allowed_packet' in log[0][-1] and 'CREATE DATABASE' in log[1][-1]
    (state / 'commands').unlink()
    (backup / 'database.sql').write_text('corrupted')
    run([restore_script, str(backup), 'restore_other'], db_env, ok=False)
    for target in ('form', 'restore_x;DROP_DATABASE', 'restore_x`y'):
        run([restore_script, str(backup), target, '--dry-run'], db_env, ok=False)
    assert not commands(state)

    # Exercise the real entrypoint without a backend binary. Output contains synthetic data only.
    wrapper = str(copy / 'deploy/docker-entrypoint.sh')
    dumper = base / 'inspect-env'
    dumper.write_text('''#!/usr/bin/env python3
import json, os, pathlib, stat
key = pathlib.Path(os.environ['FORM_SERVER_KEY_FILE']) if os.environ.get('FORM_SERVER_KEY_FILE') else None
print(json.dumps({'host': os.environ.get('FORM_DB_HOST'), 'bootstrap': os.environ.get('FORM_BOOTSTRAP_PASSWORD_FILE'),
                 'legacy_proxy': os.environ.get('FORM_TRUSTED_PROXIES'), 'public_proxy': os.environ.get('FORM_PUBLIC_TRUSTED_PROXIES'),
                 'mcp_limit': os.environ.get('FORM_MCP_TOKEN_RATE_LIMIT'), 'key_mode': stat.S_IMODE(key.stat().st_mode) if key else None, 'key': key.read_text() if key else None}))
''')
    dumper.chmod(0o755)
    scalar = base / 'host'; scalar.write_text('file-db.example.org\n')
    optional = base / 'bootstrap'; optional.write_text('FORM_OPTIONAL_UNSET\n')
    wrapper_env = dict(env, FORM_APP_BINARY=str(dumper), TMPDIR=str(base), FORM_DB_HOST='default', FORM_DB_HOST_FILE=str(scalar),
                       FORM_SERVER_KEY='c' * 64, FORM_BOOTSTRAP_PASSWORD_FILE=str(optional))
    data = json.loads(run([wrapper, 'serve'], wrapper_env).stdout)
    assert data['host'] == 'file-db.example.org' and data['bootstrap'] is None
    assert data['key_mode'] == 0o400 and data['key'] == 'c' * 64
    run([wrapper, 'serve'], dict(wrapper_env, FORM_SERVER_KEY_FILE=str(password)), ok=False)
    run([wrapper, 'serve'], dict(wrapper_env, FORM_DB_PASSWORD='synthetic', FORM_DB_PASSWORD_FILE=str(password)), ok=False)
    run([wrapper, 'serve'], dict(wrapper_env, FORM_DB_HOST_FILE=str(base / 'missing')), ok=False)
    proxy_file = base / 'proxy-cidrs'; proxy_file.write_text('192.0.2.10/32\n')
    mcp_file = base / 'mcp-limit'; mcp_file.write_text('77\n')
    data = json.loads(run([wrapper, 'serve'], dict(wrapper_env,
        FORM_TRUSTED_PROXIES_FILE=str(proxy_file), FORM_MCP_TOKEN_RATE_LIMIT_FILE=str(mcp_file))).stdout)
    assert data['legacy_proxy'] == '192.0.2.10/32' and data['public_proxy'] is None
    assert data['mcp_limit'] == '77'
    for key in ('FORM_PUBLIC_PORT', 'FORM_INTERNAL_PORT'):
        # Both swap directions and unreadable files are rejected, without executing the app.
        for value in ('8080', '8081', '9080'):
            scalar.write_text(value)
            result = run([wrapper, 'serve'], dict(wrapper_env, **{key + '_FILE': str(scalar)}), ok=False)
            assert result.returncode == 64 and key + '_FILE' in result.stderr


    # ---- settings.sh (Menü/CLI zum Bearbeiten der Env-Datei) und seine Tabellen -------------------------------------------------
    def bash_44():
        for cand in (shutil.which('bash'), '/opt/homebrew/bin/bash', '/usr/local/bin/bash', '/usr/bin/bash', '/bin/bash'):
            if not cand or not os.access(cand, os.X_OK):
                continue
            probe = subprocess.run([cand, '-c', '[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }'])
            if probe.returncode == 0:
                return cand
        return None

    # Karte 14BCA75F: jede FORM_*-Variable, die compose.yaml durchreicht, steht in der Compose-Vorlage (sonst "Unbekannte Variable").
    import re as _re
    _cy = (ROOT / 'deploy/compose/compose.yaml').read_text()
    _ce = (ROOT / 'deploy/compose/.env.example').read_text()
    _passed = set(_re.findall(r'^\s+(FORM_[A-Z0-9_]+):', _cy, _re.M))
    _missing = sorted(v for v in _passed if not _re.search(r'^#?\s*' + v + r'=', _ce, _re.M) and not v.endswith('_FILE'))
    assert not _missing, ('Compose reicht durch, aber .env.example kennt nicht', _missing)

    def table_rows(name):
        rows = {}
        for line in (ROOT / 'deploy/swarm' / name).read_text().splitlines():
            if line and not line.startswith('#'):
                cells = line.split('\t')
                assert len(cells) == 11, (name, cells[0], len(cells))
                assert cells[0] not in rows, cells[0]
                assert cells[8] in ('live', 'restart', 'envOnly') and cells[9] in ('0', '1'), cells[0]
                kind = cells[2].split(':')[0]
                assert kind in ('int', 'number', 'bool', 'choice', 'secret', 'text'), (cells[0], cells[2])
                if kind == 'text':
                    assert cells[6].isdigit(), (cells[0], 'max fehlt')
                if kind in ('int', 'number'):
                    assert cells[5] and cells[6], (cells[0], 'Grenzen fehlen')
                if kind == 'choice':
                    assert cells[7], (cells[0], 'Auswahl fehlt')
                rows[cells[0]] = cells
        return rows

    registry_rows, extra_rows = table_rows('config-registry.tsv'), table_rows('config-extra.tsv')
    assert not set(registry_rows) & set(extra_rows)
    assert set(registry_rows) == registry_envs, set(registry_rows) ^ registry_envs
    assert not any(r[9] == '1' and r[3] for r in list(registry_rows.values()) + list(extra_rows.values())), 'Secret mit Default'
    tables = {**registry_rows, **extra_rows}
    table_used = set()
    for mode in ('swarm', 'compose'):
        tpl = ROOT / 'deploy' / mode / ('stack.env.example' if mode == 'swarm' else '.env.example')
        text = tpl.read_text()
        tpl_keys = set(re.findall(r'^#?\s*([A-Z][A-Z0-9_]+)=', text, re.M))
        active = dict(re.findall(r'^([A-Z][A-Z0-9_]+)=(.*)$', text, re.M))
        table_used |= tpl_keys
        for key in tpl_keys:
            # Jede Variable der Vorlage hat Metadaten, oder sie ist KEY_FILE einer Tabellenvariable.
            assert key in tables or (key.endswith('_FILE') and key[:-5] in tables), f'{mode}: {key} fehlt in den Tabellen'
        for key, value in active.items():
            if key in tables and tables[key][8] == 'envOnly' and key not in ('BIND_ADDR', 'PUBLISH_MODE', 'FORM_REPLICAS', 'NETWORK_DRIVER'):
                assert tables[key][3] == value, f'{mode}: Default von {key}: Tabelle {tables[key][3]!r}, Vorlage {value!r}'
        for key in registry_rows:
            assert key in tpl_keys, (mode, key)
    for key in extra_rows:
        assert key in table_used, f'{key} in config-extra.tsv, aber in keiner Vorlage'
    help_keys = [l.split('\t')[0] for l in (ROOT / 'deploy' / 'swarm' / 'config-help.tsv').read_text().splitlines() if l and not l.startswith('#')]
    assert len(help_keys) == len(set(help_keys)), 'config-help.tsv: doppelte Schlüssel'
    assert all(k in tables for k in help_keys), [k for k in help_keys if k not in tables]

    bash44 = bash_44()
    if bash44 is None:
        print('Grenze: keine Bash 4.4+ gefunden; settings.sh (CLI/Menü) nicht ausgeführt, nur Tabellenkonsistenz geprüft.')
    else:
        def settings(mode, envfile, *args, ok=None, input_text='', extra_env=None):
            script = ROOT / 'deploy' / mode / 'settings.sh'
            result = subprocess.run([bash44, str(script), '--env', str(envfile), *args], cwd=ROOT, input=input_text, text=True,
                                    env=dict(os.environ, **(extra_env or {})), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if ok is not None:
                assert (result.returncode == 0) == ok, (mode, args, result.returncode, result.stdout, result.stderr)
            return result

        def backups(envfile):
            return sorted(p.name for p in envfile.parent.glob(envfile.name + '.bak.*'))

        for mode in ('swarm', 'compose'):
            work = base / ('settings-' + mode)
            work.mkdir()
            tmpl = ROOT / 'deploy' / mode / ('stack.env.example' if mode == 'swarm' else '.env.example')
            # Realistischer Ausgangspunkt: genau das Format, das save_config von setup.sh/update.sh schreibt.
            run(['bash', '-c', 'MODE=$1 ACTION=setup BASE=$2; source "$BASE/../swarm/lib.sh"; initialize --dry-run --non-interactive --env-file "$3"; save_config',
                 'seed', mode, str(ROOT / 'deploy' / mode), str(work / 'seed.env')], env)
            envfile = work / 'cfg.env'
            shutil.copy(work / 'seed.env', envfile)
            envfile.chmod(0o600)
            (work / 'cfg.env.bak').write_text('alte-sicherung')
            help_text = settings(mode, envfile, '--help', ok=True).stdout
            assert all(opt in help_text for opt in ('--list', '--get', '--set', '--unset', '--check')), help_text
            # unveränderte Datei: keine Fehler
            result = settings(mode, envfile, '--check', ok=True)
            assert 'Ergebnis: 0 Fehler' in result.stdout, result.stdout
            listing = settings(mode, envfile, '--list', ok=True).stdout
            assert 'FORM_MCP_TOKEN_RATE_LIMIT' in listing and 'FORM_DB_PASSWORD' in listing and (mode == 'compose' or '(Secret)' in listing), listing
            assert settings(mode, envfile, '--get', 'FORM_DB_PORT', ok=True).stdout == '3306\n'
            leaked_env = {'FORM_DB_PASSWORD': 'sekret-db-4711'}
            # Ausführliche Erklärungen: Ports sind gegeneinander abgegrenzt, Secrets bleiben ohne Wert
            for key, needles in (('FORM_PUBLIC_PORT', ('INNERHALB des Containers', 'FORM_PUBLIC_PUBLISH_PORT')),
                                 ('FORM_INTERNAL_PORT', ('Dashboard', 'PUBLISHED_PORT'))):
                info = settings(mode, envfile, '--info', key, ok=True).stdout
                assert all(n in info for n in needles) and 'Default:' in info, (key, info)
            assert settings(mode, envfile, '--info', 'NICHT_DA', ok=False).stdout == ''
            if mode == 'swarm':
                settings(mode, envfile, '--generate', 'FORM_SERVER_KEY', ok=False)
            assert 'sekret' not in settings(mode, envfile, '--info', 'FORM_DB_PASSWORD', ok=True, extra_env=leaked_env).stdout
            # Geheimnisse: nie ausgeben, nie schreiben (auch nicht aus dem Prozess-ENV)
            leaked = {'FORM_DB_PASSWORD': 'sekret-db-4711', 'FORM_SERVER_KEY': 'sekret-key-4711'}
            for secret_key, secret_value in leaked.items():
                if mode == 'compose':
                    continue  # Compose: einfache ENV, eigener Test unten
                result = settings(mode, envfile, '--get', secret_key, ok=False, extra_env=leaked)
                assert result.stdout == '' and secret_value not in result.stderr
                result = settings(mode, envfile, '--set', f'{secret_key}={secret_value}', ok=False, extra_env=leaked)
                assert secret_value not in result.stdout + result.stderr
            # Automatischer Tag: der Commit-Tag mit dem Digest von latest wird gewählt und gespeichert (Registry per curl-Double)
            tagdir = work / 'tagbin'; tagdir.mkdir()
            sha_new, sha_old = 'c' * 40, 'd' * 40
            (tagdir / 'curl').write_text('''#!/usr/bin/env bash
case "$*" in
  *token*) echo '{"token":"t"}' ;;
  *api.github.com*) printf '[\\n  {\\n    "sha": "%s",\\n    "parents": [{"sha": "%s"}]\\n  },\\n  {\\n    "sha": "%s"\\n  }\\n]\\n' ;;
  *manifests/latest*|*manifests/%s*) printf 'HTTP/2 200\\r\\ndocker-content-digest: sha256:%s\\r\\n\\r\\n' ;;
  *manifests/*) printf 'HTTP/2 200\\r\\ndocker-content-digest: sha256:%s\\r\\n\\r\\n' ;;
esac
''' % (sha_old, 'e' * 40, sha_new, sha_new, '1' * 64, '2' * 64))
            (tagdir / 'curl').chmod(0o755)
            auto = work / 'auto.env'
            shutil.copy(work / 'seed.env', auto); auto.chmod(0o600)
            out = run(['bash', '-c', 'MODE=$1 ACTION=update BASE=$2; source "$BASE/../swarm/lib.sh"; initialize --dry-run --non-interactive --env-file "$3"; echo "TAG=$FORM_IMAGE_TAG"; save_config',
                       'auto', mode, str(ROOT / 'deploy' / mode), str(auto)], dict(env, PATH=str(tagdir) + os.pathsep + env['PATH'], FORM_TAG_LOOKUP='1')).stdout
            assert f'TAG={sha_new}' in out and 'Neuester Image-Tag' in out, out
            assert f'FORM_IMAGE_TAG="{sha_new}"' in auto.read_text()
            out = run(['bash', '-c', 'MODE=$1 ACTION=update BASE=$2; source "$BASE/../swarm/lib.sh"; initialize --dry-run --non-interactive --env-file "$3"; echo "TAG=$FORM_IMAGE_TAG"',
                       'auto', mode, str(ROOT / 'deploy' / mode), str(auto)], dict(env, PATH=str(tagdir) + os.pathsep + env['PATH'], FORM_IMAGE_TAG='mein-tag', FORM_TAG_LOOKUP='1')).stdout
            assert 'TAG=mein-tag' in out, out
            # Altlast FORM_HTTP_PORT: update/setup lesen die Datei weiter, settings.sh warnt und entfernt die Zeile
            legacy = work / 'legacy.env'
            legacy.write_text(envfile.read_text() + 'FORM_HTTP_PORT="8081"\n'); legacy.chmod(0o600)
            res = settings(mode, legacy, '--check', ok=True)
            assert 'FORM_HTTP_PORT' in res.stdout and 'FEHLER   FORM_HTTP_PORT' not in res.stdout, res.stdout
            run(['bash', '-c', 'MODE=$1 ACTION=update BASE=$2; source "$BASE/../swarm/lib.sh"; initialize --dry-run --non-interactive --env-file "$3"; save_config',
                 'legacy', mode, str(ROOT / 'deploy' / mode), str(legacy)], env)
            assert 'FORM_HTTP_PORT' not in legacy.read_text()
            # Umgezogener Installationsort: gespeicherter Secret-Pfad existiert nicht mehr -> Standard, nichts Festes gespeichert
            moved = work / 'moved.env'
            moved.write_text(legacy.read_text() + 'DB_PASSWORD_SOURCE_FILE="/opt/alt/form-backend/deploy/' + mode + '/secrets/db_password"\n'); moved.chmod(0o600)
            out = run(['bash', '-c', 'MODE=$1 ACTION=update BASE=$2; source "$BASE/../swarm/lib.sh"; initialize --dry-run --non-interactive --env-file "$3"; save_config',
                       'moved', mode, str(ROOT / 'deploy' / mode), str(moved)], env).stdout
            assert 'existiert nicht mehr' in out and '/opt/alt/' not in moved.read_text()
            assert 'sekret' not in settings(mode, envfile, '--list', ok=True, extra_env=leaked).stdout
            assert 'sekret' not in settings(mode, envfile, '--check', extra_env=leaked).stdout
            assert 'sekret' not in envfile.read_text() and not backups(envfile)
            if mode == 'compose':
                # Compose: Geheimnisse sind einfache ENV (verdeckt angezeigt, Datei 0600), Server-Key mit Formprüfung
                sec = work / 'sec.env'
                shutil.copy(envfile, sec); sec.chmod(0o600)
                key64 = 'ab' * 32
                settings(mode, sec, '--set', 'FORM_DB_PASSWORD=pw-4711', '--set', f'FORM_SERVER_KEY={key64}', ok=True)
                text = sec.read_text()
                assert 'FORM_DB_PASSWORD="pw-4711"' in text and f'FORM_SERVER_KEY="{key64}"' in text and sec.stat().st_mode & 0o777 == 0o600
                for out in (settings(mode, sec, '--list', ok=True).stdout, settings(mode, sec, '--check', ok=True).stdout,
                            settings(mode, sec, '--info', 'FORM_DB_PASSWORD', ok=True).stdout):
                    assert 'pw-4711' not in out and key64 not in out
                assert settings(mode, sec, '--get', 'FORM_DB_PASSWORD', ok=False).stdout == ''
                settings(mode, sec, '--set', 'FORM_SERVER_KEY=zz', ok=False)
                # Zufällig erzeugen: Key nie ausgegeben, Bootstrap-Passwort einmalig; vorhandene Secret-Datei sperrt den Key
                settings(mode, sec, '--unset', 'FORM_SERVER_KEY', ok=True)
                gen = settings(mode, sec, '--generate', 'FORM_SERVER_KEY', ok=True).stdout
                assert re.search(r'^FORM_SERVER_KEY="[0-9a-f]{64}"$', sec.read_text(), re.M)
                assert re.search(r'FORM_SERVER_KEY="([0-9a-f]{64})"', sec.read_text()).group(1) not in gen
                gen = settings(mode, sec, '--generate', 'FORM_BOOTSTRAP_PASSWORD', ok=True).stdout
                pw = re.search(r'FORM_BOOTSTRAP_PASSWORD="([^"]{24})"', sec.read_text()).group(1)
                assert pw in gen
                settings(mode, sec, '--generate', 'FORM_DB_PASSWORD', ok=False)
                (ROOT / 'deploy' / 'compose' / 'secrets').mkdir(exist_ok=True)
                existing = ROOT / 'deploy' / 'compose' / 'secrets' / 'server_key'
                had = existing.exists()
                if not had:
                    existing.write_text('x\n')
                    try:
                        settings(mode, sec, '--generate', 'FORM_SERVER_KEY', ok=False)
                    finally:
                        existing.unlink()
                settings(mode, sec, '--set', f'FORM_SERVER_KEY={key64}', '--set', 'FORM_DB_PASSWORD=pw-4711', ok=True)
                settings(mode, sec, '--set', 'FORM_DB_PASSWORD=a"b', ok=False)
                # lib.sh liest die Datei und behält die Werte beim Speichern; sie landen nicht im Dry-run-Plan
                keep = work / 'keep.env'
                shutil.copy(sec, keep); keep.chmod(0o600)
                run(['bash', '-c', 'MODE=compose ACTION=update BASE=$1; source "$BASE/../swarm/lib.sh"; initialize --dry-run --non-interactive --env-file "$2"; save_config',
                     'keep', str(ROOT / 'deploy' / 'compose'), str(keep)], env)
                assert 'FORM_DB_PASSWORD="pw-4711"' in keep.read_text() and f'FORM_SERVER_KEY="{key64}"' in keep.read_text()
                settings(mode, sec, '--unset', 'FORM_DB_PASSWORD', '--unset', 'FORM_SERVER_KEY', ok=True)
                assert 'pw-4711' not in sec.read_text() and key64 not in sec.read_text()
            before = envfile.read_bytes()
            # ungültige Werte werden abgelehnt: Datei und Sicherungen bleiben unberührt
            for pair in ('FORM_MCP_TOKEN_RATE_LIMIT=0', 'FORM_MCP_TOKEN_RATE_LIMIT=abc', 'FORM_MCP_TOKEN_RATE_LIMIT=060',
                         'FORM_MCP_TOKEN_RATE_LIMIT=', 'FORM_DB_TLS=maybe', 'FORM_DB_PORT=70000', 'FORM_ADMIN_ORIGIN=http://x.example.org',
                         'FORM_ADMIN_ORIGIN=https://x.example.org/pfad', 'FORM_ABUSE_HASHES=["zz"]', 'FORM_ABUSE_UA_PATTERNS=nojson',
                         'FORM_OPS_RECIPIENT=kein-mail', 'FORM_OPS_CONNECTION=nicht-uuid', 'FORM_TRUSTED_PROXIES=300.1.1.1/8',
                         'FORM_LOG_LEVEL=laut', 'FORM_MAIL_RESTRICTED=TRUE', 'FORM_SDK_DIR=relativ', 'FORM_RP_ID=Gross.example.org',
                         'FORM_ABUSE_BLOCKED_NETS=10.0.0.0/33', 'FORM_MCP_TOKEN_RATE_LIMIT=1$2', 'FORM_IMAGE_TAG=a b',
                         'FORM_INTERNAL_PORT_FILE=/x', 'FORM_UNBEKANNT=1', 'LOG_LEVEL=laut'):
                result = settings(mode, envfile, '--set', pair, ok=False)
                assert result.returncode in (2, 3), (pair, result.returncode, result.stderr)
                assert envfile.read_bytes() == before and not backups(envfile), pair
            # gültige Änderung: gequoteter Wert, 0600, genau eine Sicherung, bestehende .bak unberührt
            result = settings(mode, envfile, '--set', 'FORM_MCP_TOKEN_RATE_LIMIT=77', ok=True)
            assert 'Sicherung:' in result.stdout and 'Gespeichert' in result.stdout, result.stdout
            assert re.search(r'^FORM_MCP_TOKEN_RATE_LIMIT="77"$', envfile.read_text(), re.M)
            assert envfile.stat().st_mode & 0o777 == 0o600
            made = backups(envfile)
            assert len(made) == 1 and re.fullmatch(r'cfg\.env\.bak\.\d{8}-\d{6}', made[0]), made
            assert (envfile.parent / made[0]).read_bytes() == before and (envfile.parent / made[0]).stat().st_mode & 0o777 == 0o600
            assert (work / 'cfg.env.bak').read_text() == 'alte-sicherung'
            # idempotent
            after = envfile.read_bytes()
            result = settings(mode, envfile, '--set', 'FORM_MCP_TOKEN_RATE_LIMIT=77', ok=True)
            assert envfile.read_bytes() == after and backups(envfile) == made, result.stdout
            assert settings(mode, envfile, '--get', 'FORM_MCP_TOKEN_RATE_LIMIT', ok=True).stdout == '77\n'
            # JSON-Liste (einfache Anführungszeichen), danach muss lib.sh die Datei weiter lesen
            settings(mode, envfile, '--set', 'FORM_ABUSE_UA_PATTERNS=["bot","spam"]', ok=True)
            assert "FORM_ABUSE_UA_PATTERNS='[\"bot\",\"spam\"]'" in envfile.read_text()
            assert settings(mode, envfile, '--get', 'FORM_ABUSE_UA_PATTERNS', ok=True).stdout == '["bot","spam"]\n'
            result = settings(mode, envfile, '--check', ok=True)
            assert 'Ergebnis: 0 Fehler' in result.stdout, result.stdout
            # expliziter Leerwert (sperrt im Dashboard) und mehrere Aktionen in einem Aufruf
            settings(mode, envfile, '--set', 'FORM_OPS_RECIPIENT=', '--set', 'FORM_LOG_LEVEL=debug', ok=True)
            assert re.search(r'^FORM_OPS_RECIPIENT=""$', envfile.read_text(), re.M) and re.search(r'^FORM_LOG_LEVEL="debug"$', envfile.read_text(), re.M)
            # Konflikt: einzeln abgelehnt (nichts gespeichert), gemeinsam erlaubt
            before = envfile.read_bytes(); count = len(backups(envfile))
            result = settings(mode, envfile, '--set', 'FORM_DB_TLS=disable', ok=False)
            assert envfile.read_bytes() == before and len(backups(envfile)) == count, result.stderr
            settings(mode, envfile, '--set', 'FORM_DB_TLS=disable', '--set', 'FORM_ALLOW_INSECURE_DEV=1', ok=True)
            before = envfile.read_bytes()
            settings(mode, envfile, '--unset', 'FORM_ALLOW_INSECURE_DEV', ok=False)
            assert envfile.read_bytes() == before
            settings(mode, envfile, '--unset', 'FORM_DB_TLS', '--unset', 'FORM_ALLOW_INSECURE_DEV', ok=True)
            assert 'Ergebnis: 0 Fehler' in settings(mode, envfile, '--check', ok=True).stdout
            # unset: Zeile wird auskommentiert, wiederholt ohne Änderung
            settings(mode, envfile, '--unset', 'FORM_MCP_TOKEN_RATE_LIMIT', ok=True)
            assert re.search(r'^# FORM_MCP_TOKEN_RATE_LIMIT="77"$', envfile.read_text(), re.M)
            assert not re.search(r'^FORM_MCP_TOKEN_RATE_LIMIT=', envfile.read_text(), re.M)
            after = envfile.read_bytes(); count = len(backups(envfile))
            settings(mode, envfile, '--unset', 'FORM_MCP_TOKEN_RATE_LIMIT', ok=True)
            assert envfile.read_bytes() == after and len(backups(envfile)) == count
            assert settings(mode, envfile, '--get', 'FORM_MCP_TOKEN_RATE_LIMIT', ok=True).stdout == '60\n'
            assert envfile.stat().st_mode & 0o777 == 0o600
            settings(mode, envfile, '--unset', 'NICHT_DA', ok=False)
            # --check findet kaputte Dateien; Geheimnisse bleiben unsichtbar, --unset löscht sie
            broken = work / 'broken.env'
            broken.write_text(envfile.read_text() + 'FOO_BAR="1"\nFORM_DB_PASSWORD="leak-4711"\nFORM_MCP_TOKEN_RATE_LIMIT="0"\nFORM_DB_PORT="1"\nFORM_DB_PORT="2"\nkaputt\n')
            broken.chmod(0o644)
            result = settings(mode, broken, '--check', ok=False)
            out = result.stdout
            assert 'leak-4711' not in out + result.stderr
            for needle in ('FOO_BAR', *(() if mode == 'compose' else ('FORM_DB_PASSWORD',)), 'FORM_MCP_TOKEN_RATE_LIMIT=0', 'FORM_DB_PORT steht', 'Dateimodus ist 644', 'Zeile'):
                assert needle in out, (needle, out)
            broken.write_text(envfile.read_text() + 'FORM_DB_PASSWORD="leak-4711"\n')
            settings(mode, broken, '--unset', 'FORM_DB_PASSWORD', ok=True)
            assert 'leak-4711' not in broken.read_text()
            # fehlende Datei: Anzeigen geht, Schreiben nie (würde das Setup überspringen)
            missing = work / 'fehlt.env'
            assert 'Ergebnis: 0 Fehler' in settings(mode, missing, '--check', ok=True).stdout
            settings(mode, missing, '--set', 'FORM_MCP_TOKEN_RATE_LIMIT=5', ok=False)
            assert not missing.exists()
            # Symlink wird nie beschrieben; laufender Rollout sperrt
            link = work / 'link.env'
            link.symlink_to(envfile)
            before = envfile.read_bytes()
            settings(mode, link, '--set', 'FORM_MCP_TOKEN_RATE_LIMIT=5', ok=False)
            assert envfile.read_bytes() == before
            (work / 'cfg.env.deploy-lock').mkdir()
            settings(mode, envfile, '--set', 'FORM_MCP_TOKEN_RATE_LIMIT=5', ok=False)
            (work / 'cfg.env.deploy-lock').rmdir()
            assert envfile.read_bytes() == before
            # Menü mit Whiptail-Double: Wert wählen, speichern; "Anwenden" nur als Trockenlauf
            stubdir = work / 'bin'
            stubdir.mkdir()
            answers = work / 'answers'
            stub = stubdir / 'whiptail'
            stub.write_text('#!/usr/bin/env python3\nimport pathlib, sys\n'
                            f'p = pathlib.Path({str(answers)!r})\nq = p.read_text().splitlines() if p.exists() else []\n'
                            'if not q:\n    sys.exit(1)\nrc, _, out = q[0].partition("|")\np.write_text("\\n".join(q[1:]) + "\\n")\n'
                            'sys.stderr.write(out)\nsys.exit(int(rc))\n')
            stub.chmod(0o755)
            menu_env = {'PATH': str(stubdir) + os.pathsep + os.environ['PATH'], 'SETTINGS_ROWS': '40', 'SETTINGS_COLS': '120'}
            answers.write_text('\n'.join(['0|Hosts und Listener', '0|FORM_INTERNAL_SECOND_FACTOR', '0|', '0|1', '1|', '1|', '0|S', '0|', '0|', '0|']) + '\n')
            before = envfile.read_bytes(); count = len(backups(envfile))
            settings(mode, envfile, ok=True, extra_env=menu_env, input_text='\n' * 40)
            assert re.search(r'^FORM_INTERNAL_SECOND_FACTOR="1"$', envfile.read_text(), re.M)
            assert len(backups(envfile)) == count + 1 and envfile.stat().st_mode & 0o777 == 0o600
            # Menüpunkt "Pflichtangaben": Mindestangaben für den Ersatz des alten Backends
            plog = menu_double(work / 'pflicht', ['0|Pflichtangaben', '1|', '1|'])
            settings(mode, envfile, ok=True, extra_env=dict(menu_env, PATH=str(work / 'pflicht') + os.pathsep + os.environ['PATH']), input_text='\n' * 40)
            ptext = menu_texts(plog)
            lst = settings(mode, envfile, '--list', ok=True).stdout
            assert ('DB_PASSWORD_SECRET' in lst) == (mode == 'swarm'), mode
            host_key = 'PUBLISHED_PORT' if mode == 'compose' else 'FORM_PUBLISH_PORT'
            for needle in ('Pflichtangaben', 'FORM_ADMIN_ORIGIN', 'FORM_RP_ID', 'FORM_DB_HOST', 'FORM_PUBLIC_PUBLISH_PORT', host_key,
                           'FORM_TRUSTED_PROXIES', 'FORM_MIGRATION_ALLOWED_NETS'):
                assert needle in ptext, (mode, needle)
            answers.write_text('\n'.join(['0|Anwenden', '0|D', '1|']) + '\n')
            before = envfile.read_bytes()
            result = settings(mode, envfile, ok=True, extra_env=menu_env, input_text='\n' * 40)
            assert envfile.read_bytes() == before
            assert not commands(state), 'Trockenlauf im Menü hat externe Kommandos gestartet'
            # ohne whiptail/dialog: klare Meldung, CLI geht weiter
            nodialog = work / 'nodialog'
            nodialog.mkdir()
            for tool in ('bash', 'env', 'awk', 'sed', 'cat', 'date', 'mktemp', 'chmod', 'cp', 'mv', 'rm', 'sort', 'dirname', 'stat', 'diff', 'tr', 'cksum', 'grep', 'tput', 'stty', 'chown'):
                found = shutil.which(tool)
                if found:
                    (nodialog / tool).symlink_to(found)
            result = settings(mode, envfile, extra_env={'PATH': str(nodialog)})
            assert result.returncode != 0 and 'whiptail' in result.stderr and '--list' in result.stderr, result.stderr
        print('settings.sh: --list/--get/--set/--unset/--check, Ablehnung ungültiger Werte, Sicherung/0600, Secret-Schutz, Idempotenz und Menü (Whiptail-Double) für Compose/Swarm bestanden.')


print('Geprüft: ENV-Inventar/Priorität, Help/Dry-run/Dialog, externe DB-Prüfung ohne Anlage, Migration vor Rollout, Fehlersperre, Digest/0600, Secret-/Dateiwrapper, Swarm-Platzierung und Backup/Restore-Verträge. Orchestrierung mit Kommando-Doubles; keine Docker-Laufzeitprüfung.')

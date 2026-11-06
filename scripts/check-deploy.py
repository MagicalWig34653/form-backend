#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Isolated deployment contract checks. Command doubles never contact a Docker daemon."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REAL_DOCKER = shutil.which('docker')
IMAGE = 'ghcr.io/magicalwig34653/form-backend:test'
SOURCE_KEYS = set('''FORM_HTTP_HOST FORM_HTTP_PORT FORM_PUBLIC_PORT FORM_INTERNAL_PORT FORM_PUBLIC_DASHBOARD FORM_PUBLIC_DASHBOARD_HOSTS FORM_PUBLIC_TRUSTED_PROXIES FORM_INTERNAL_TRUSTED_PROXIES FORM_LOG_LEVEL FORM_DB_HOST FORM_DB_PORT
FORM_DB_USER FORM_DB_PASSWORD FORM_DB_PASSWORD_FILE FORM_DB_NAME FORM_DB_TLS FORM_ALLOW_INSECURE_DEV
FORM_SCHEMA_FILE FORM_PUBLIC_DIR FORM_TRUSTED_PROXIES FORM_MAIL_ALLOWED_NETS FORM_SERVER_KEY_FILE
FORM_ADMIN_ORIGIN FORM_RP_ID FORM_BOOTSTRAP_PASSWORD_FILE FORM_SDK_DIR LOG_LEVEL'''.split())
MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args=sys.argv[1:]
base=pathlib.Path(os.environ['MOCK_STATE'])
name=pathlib.Path(sys.argv[0]).name
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
    result = subprocess.run(args, cwd=ROOT, env=env, input=input_text, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
    return result


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
    env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ['PATH'], MOCK_STATE=str(state))
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
        for port_key in ('FORM_HTTP_PORT', 'FORM_PUBLIC_PORT', 'FORM_INTERNAL_PORT'):
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
        assert not any('CREATE DATABASE' in ' '.join(c) for c in log), 'Setup/update created DB'
        assert '@sha256:' in config.read_text()
        assert config.stat().st_mode & 0o777 == 0o600
        assert 'synthetic-db-password' not in config.read_text()
        assert 'synthetic-db-password' not in (state / 'commands').read_text()
        (state / 'commands').unlink()
        run([update, '--non-interactive', '--dry-run'], dict(env, FORM_DB_HOST='override.example.org', FORM_HTTP_PORT='9090',
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
                 input_text='probe\nhttps://admin.example.org:8443\n\nexternal-db.example.org\n3307\noperator\nexisting\nverify\nfixed\n2\nnode.role==worker\nspread=node.labels.zone\nworker-a\n2\nreserved\n\n18080\n18081\ningress\n\n')
    assert 'operator@external-db.example.org:3307/existing' in result.stdout
    assert 'Gesamt: 4 Replikate' in result.stdout
    assert 'app=18080; app-pinned=18081' in result.stdout
    assert not (folder / 'stack.env').exists()
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
    run([update, '--non-interactive'], dict(env, FORM_PUBLISH_PORT='', FORM_PINNED_NODE=''))
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
                              FORM_PUBLISH_PORT=app_port, FORM_PINNED_PUBLISH_PORT=pinned_port,
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
    db_env = dict(env, FORM_DB_HOST='external-db.example.org', FORM_DB_PASSWORD_FILE=str(password))
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
    assert len(log) == 1 and 'CREATE DATABASE' in log[0][-1]
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
    for key in ('FORM_HTTP_PORT', 'FORM_PUBLIC_PORT', 'FORM_INTERNAL_PORT'):
        # Both swap directions and unreadable files are rejected, without executing the app.
        for value in ('8080', '8081', '9080'):
            scalar.write_text(value)
            result = run([wrapper, 'serve'], dict(wrapper_env, **{key + '_FILE': str(scalar)}), ok=False)
            assert result.returncode == 64 and key + '_FILE' in result.stderr


print('Geprüft: ENV-Inventar/Priorität, Help/Dry-run/Dialog, externe DB-Prüfung ohne Anlage, Migration vor Rollout, Fehlersperre, Digest/0600, Secret-/Dateiwrapper, Swarm-Platzierung und Backup/Restore-Verträge. Orchestrierung mit Kommando-Doubles; keine Docker-Laufzeitprüfung.')

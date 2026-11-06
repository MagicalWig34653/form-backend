#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Offline-Prüfung der P2-4-Verträge und synthetischen Fixtures, keine Engine."""
import copy
import hashlib
import json
import re
from datetime import datetime
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker, SchemaError, ValidationError
from referencing import Registry, Resource

ROOT = Path(__file__).resolve().parent
BASE = 'https://form-backend.invalid/contracts/flow/0.1.0/'
FORMATS = FormatChecker()


@FORMATS.checks('date-time', raises=(ValueError, OverflowError))
def date_time_format(value):
    # Local RFC3339 syntax/calendar check: optional format extra is not installed.
    # Accepts second 60 syntactically; does not verify a historical leap-second table.
    if not isinstance(value, str):
        return True
    if not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})', value):
        return False
    normalized = value.upper()
    if normalized[17:19] == '60':
        normalized = normalized[:17] + '59' + normalized[19:]
    return datetime.fromisoformat(normalized.replace('Z', '+00:00')).tzinfo is not None


def load(path):
    def unique_keys(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Doppelter JSON-Schlüssel: ' + key)
            result[key] = value
        return result
    return json.loads(path.read_text(), object_pairs_hook=unique_keys)


def digest(value):
    # Fixture convention only, not a production signature canonicalization.
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
    return hashlib.sha256(encoded.encode()).hexdigest()


def instant(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def walk(value):
    yield value
    if isinstance(value, dict):
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def check_graph(graph):
    nodes = graph['nodes']
    require(graph['entryNode'] in nodes, 'Einstieg fehlt')
    require(nodes[graph['entryNode']]['kind'] == 'entry', 'Einstieg ist kein Eingang')
    require(sum(n['kind'] == 'entry' for n in nodes.values()) == 1, 'Mehrere Eingänge')
    ports = {
        'entry': {'next'}, 'block': {'next'}, 'script': {'next'},
        'subflow': {'next'}, 'condition': {'true', 'false'},
        'loop': {'body', 'done'}, 'wait': {'resume'},
        'approval': {'approved', 'rejected'}, 'end': set(),
    }
    outgoing = {key: {} for key in nodes}
    for edge in graph['edges']:
        a, port, b = edge['from'], edge['port'], edge['to']
        require(a in nodes and b in nodes, 'Kante referenziert unbekannten Knoten')
        allowed = ports[nodes[a]['kind']] | ({'error'} if nodes[a]['kind'] != 'end' else set())
        require(port in allowed, 'Port passt nicht zum Knotentyp')
        require(port not in outgoing[a], 'Mehrdeutiger Port')
        outgoing[a][port] = b
    for key, node in nodes.items():
        require(ports[node['kind']] <= outgoing[key].keys(), 'Pflichtport fehlt')
        for binding in node.get('inputBindings', {}).values():
            require(binding['sourceNode'] in nodes, 'Unbekannte Bindungsquelle')
    reached = set()
    def visit(key):
        if key in reached:
            return
        reached.add(key)
        for target in outgoing[key].values():
            visit(target)
    visit(graph['entryNode'])
    require(reached == set(nodes), 'Unerreichbarer Knoten')
    require(any(n['kind'] == 'end' for n in nodes.values()), 'Endknoten fehlt')
    # Removing explicit loop nodes must leave an acyclic graph.
    done, active = set(), set()
    def acyclic(key):
        if nodes[key]['kind'] == 'loop' or key in done:
            return
        require(key not in active, 'Zyklus ohne kontrollierten Schleifenknoten')
        active.add(key)
        for target in outgoing[key].values():
            acyclic(target)
        active.remove(key)
        done.add(key)
    for key in nodes:
        acyclic(key)


def check_semantics(value, schema_name):
    for item in walk(value):
        if isinstance(item, dict) and set(item) == {'id', 'version', 'sha256'}:
            target = definitions.get((item['id'], item['version']))
            if target is not None:
                require(item['sha256'] == digest(target), 'Fixture-Hash stimmt nicht')
            else:
                require(item in sandbox_requirements, 'Nicht deklarierte Referenz')
    if schema_name == 'form.schema.json':
        names = [f['name'] for f in value['fields'].values()]
        require(len(names) == len(set(names)), 'Doppelter HTML-Feldname')
        for field in value['fields'].values():
            Draft202012Validator.check_schema(field['validation'])
            if field['locked']:
                Draft202012Validator(field['validation'], format_checker=FORMATS).validate(field['fixedValue'])
    if schema_name == 'view.schema.json':
        form = definitions[(value['form']['id'], value['form']['version'])]
        ids = []
        for step in value['steps']:
            ids.append(step['id'])
            for section in step['sections']:
                ids.append(section['id'])
                for placement in section['fields']:
                    require(placement['fieldId'] in form['fields'], 'Unbekanntes Ansichts-Feld')
                    require(not form['fields'][placement['fieldId']]['hidden'], 'Verborgenes Feld wird gerendert')
        require(len(ids) == len(set(ids)), 'Doppelte Ansichtskennung')
    if schema_name == 'graph.schema.json':
        check_graph(value)
    if schema_name == 'execution.schema.json':
        require(instant(value['startedAt']) < instant(value['deadlineAt']), 'Ungültige Deadline')
        budget = value['budget']
        require(budget['stepsConsumed'] <= budget['limits']['maxSteps'], 'Schrittbudget überschritten')
        require(budget['activeMsConsumed'] <= budget['limits']['activeTimeoutMs'], 'Zeitbudget überschritten')
        release = definitions[(value['release']['id'], value['release']['version'])]
        graph = definitions[(release['flow']['id'], release['flow']['version'])]
        require(value['checkpoint']['nextNode'] in graph['nodes'], 'Checkpoint-Knoten fehlt')
        for key in value['checkpoint']['nodeVisits']:
            require(key in graph['nodes'], 'Besuch unbekannten Knotens')
        for key, attempt in value['checkpoint']['nodeAttempts'].items():
            require(key in graph['nodes'], 'Versuch unbekannten Knotens')
            require(attempt['visit'] <= value['checkpoint']['nodeVisits'].get(key, 0), 'Versuch ohne Knotenbesuch')
        for key, count in value['checkpoint']['loopIterations'].items():
            require(key in graph['nodes'] and graph['nodes'][key]['kind'] == 'loop', 'Unbekannte Schleife')
            require(count <= graph['nodes'][key]['maxIterations'], 'Schleifenlimit überschritten')
        for effect in value['effects']:
            require(effect['nodeId'] in graph['nodes'], 'Effekt-Knoten fehlt')
        if 'lease' in value:
            require(instant(value['lease']['acquiredAt']) < instant(value['lease']['expiresAt']) <= instant(value['deadlineAt']), 'Ungültige Lease-Zeit')
        if 'suspension' in value:
            suspension = value['suspension']
            if suspension['kind'] == 'manual-resend':
                require(any(e['effectId'] == suspension['effectId'] and e['kind'] == 'mail' for e in value['effects']), 'Mail-Effekt fehlt')
            elif suspension['kind'] != 'crash-recovery':
                require(suspension['nodeId'] == value['checkpoint']['nextNode'], 'Suspendierter Knoten stimmt nicht')
    if schema_name == 'debug-event.schema.json':
        start, event, end = map(instant, (value['recordingStartedAt'], value['occurredAt'], value['expiresAt']))
        require((end - start).total_seconds() == 900 and start <= event < end, 'Debug-TTL verletzt')
    if schema_name == 'script-artifact.schema.json':
        require(hashlib.sha256(value['source'].encode()).hexdigest() == value['sourceSha256'], 'Skripthash stimmt nicht')


def main():
    global definitions, sandbox_requirements
    schemas = {path.name: load(path) for path in ROOT.glob('*.schema.json')}
    registry = Registry().with_resources((v['$id'], Resource.from_contents(v)) for v in schemas.values())
    validators = {}
    for name, schema in schemas.items():
        Draft202012Validator.check_schema(schema)
        validators[name] = Draft202012Validator(schema, registry=registry, format_checker=FORMATS)
        # Resolve every static schema reference, including branches unused by fixtures.
        resolver = registry.resolver(schema['$id'])
        for item in walk(schema):
            if isinstance(item, dict) and '$ref' in item:
                target = item['$ref']
                if target == 'https://json-schema.org/draft/2020-12/schema':
                    continue  # Built-in jsonschema metaschema; never retrieved over the network.
                require(not target.startswith(('http:', 'https:')) or target.startswith(BASE), 'Fremde Schema-Referenz')
                resolver.lookup(target)
    manifest = load(ROOT / 'examples/manifest.json')
    require(set(manifest) == {f.name for f in (ROOT / 'examples').glob('*.json')} - {'manifest.json'}, 'Fixture fehlt im Manifest')
    examples = {name: load(ROOT / 'examples' / name) for name in manifest}
    definitions = {(v['id'], v['version']): v for v in examples.values() if 'id' in v and 'version' in v}
    sandbox_requirements = examples['package.json']['sandboxRequirements']
    identity = load(ROOT.parent / 'data/identity-example.json')
    require(identity['adminFormUrl'].endswith('/forms/' + examples['form.json']['id']), 'Admin-/Flow-ID weicht ab')
    require(identity['sqlFormIdHex'] == examples['form.json']['id'].replace('-', ''), 'SQL-/Flow-ID weicht ab')
    require(identity['sqlBindings']['workflow_runs']['release_id'] == examples['execution.json']['release']['id'], 'SQL-/Release-ID weicht ab')
    require(identity['sqlBindings']['workflow_runs']['checkpoint_object_id'] == examples['execution.json']['checkpoint']['payload']['objectId'], 'SQL-/Checkpoint-ID weicht ab')
    for name, value in examples.items():
        validators[manifest[name]].validate(value)
        check_semantics(value, manifest[name])
        # Check nested definition semantics in the package, too.
        if name == 'package.json':
            for key, schema in [('forms', 'form'), ('views', 'view'), ('flows', 'graph'), ('scripts', 'script-artifact')]:
                for definition in value[key]:
                    check_semantics(definition, schema + '.schema.json')
    negative_count = 0
    def reject(example, mutate, semantic=False):
        nonlocal negative_count
        value = copy.deepcopy(examples[example + '.json'])
        mutate(value)
        try:
            validators[manifest[example + '.json']].validate(value)
            if semantic:
                check_semantics(value, manifest[example + '.json'])
        except (ValueError, ValidationError, SchemaError):
            negative_count += 1
            return
        raise ValueError('Negativfall unerwartet akzeptiert: ' + example)
    # ADR 0004: declarative continuation gate and closed workflow rights.
    crash = copy.deepcopy(examples['execution-waiting.json'])
    crash['state'] = 'waiting-manual'
    crash['suspension'] = {'kind': 'crash-recovery', 'requiresHumanRelease': True}
    validators['execution.schema.json'].validate(crash)
    check_semantics(crash, 'execution.schema.json')
    reject('execution-waiting', lambda x: x.pop('continuationPolicy'))
    reject('execution-waiting', lambda x: x.update(continuationPolicy='automatic'))
    reject('execution-paused', lambda x: x['suspension'].update(resumePermission='flow.unknown'))
    reject('form', lambda x: x['security'].update(encryptionProfile='sym-v2'))
    # Vertragsrunde 3 R05: Transportpolitik ist geschlossen (off|offered|required).
    for policy in ('off', 'offered', 'required'):
        positive = copy.deepcopy(examples['form.json'])
        positive['security']['transport'] = policy
        validators['form.schema.json'].validate(positive)
    reject('form', lambda x: x['security'].update(transport='optional'))
    reject('form', lambda x: x['security'].update(transport=True))
    reject('graph', lambda x: x['nodes']['approval'].update(permission='flow.unknown'))
    reject('form', lambda x: x['fields']['channel'].pop('fixedValue'))
    reject('form', lambda x: x['fields']['email'].update(fixedValue='synthetisch'))
    reject('form', lambda x: x['fields']['email'].update(validation={'type':7}))
    reject('form', lambda x: x['fields']['channel'].update(fixedValue='manipuliert'), True)
    reject('form', lambda x: x['fields']['email'].update(name='kanal'), True)
    reject('form', lambda x: x['storage'].update(adapter='s3'))
    reject('form', lambda x: x['storage'].update(onFailure='ignore'))
    reject('view', lambda x: x['steps'][0]['sections'][0]['fields'][0].update(fieldId='channel'), True)
    reject('graph', lambda x: x['limits'].update(maxSteps=0))
    reject('graph', lambda x: x['nodes']['loop'].update(maxIterations=0))
    reject('graph', lambda x: x['nodes']['script'].pop('sandboxProfile'))
    reject('graph', lambda x: x['edges'][0].update(to='missing'), True)
    reject('graph', lambda x: x['edges'].append({'from':'validate','port':'error','to':'validate'}), True)
    reject('graph', lambda x: x['edges'].append(copy.deepcopy(x['edges'][0])))
    reject('execution', lambda x: x.pop('lease'))
    reject('execution-waiting', lambda x: x.pop('suspension'))
    reject('execution', lambda x: x['lease'].update(fence=0))
    reject('execution', lambda x: x['lease'].update(expiresAt='2026-10-26T09:00:00Z'), True)
    reject('execution', lambda x: x['budget'].update(stepsConsumed=1001), True)
    reject('execution', lambda x: x['checkpoint'].update(plaintext={'email':'synthetisch'}))
    reject('execution-manual', lambda x: x['effects'][0].update(attempt=0))
    reject('execution-paused', lambda x: x['suspension'].pop('resumePermission'))
    reject('execution', lambda x: x['checkpoint']['nodeAttempts']['entry'].update(attempts=0))
    reject('mail-block', lambda x: x['retry'].update(mode='automatic'))
    reject('block', lambda x: x['retry'].update(mode='automatic'))
    reject('release', lambda x: x['publication'].update(actorKind='mcp-token'))
    reject('debug-event', lambda x: x.update(ttlSeconds=901))
    reject('debug-event', lambda x: x.update(expiresAt='2026-10-26T10:16:00Z'), True)
    reject('debug-event', lambda x: x['input'][0].update(display='unmaskiert'))
    reject('debug-event', lambda x: x.update(authorization='synthetisch'))
    reject('debug-event', lambda x: x.update(mode='observe',effectMode='simulate'))
    reject('statistics-visit', lambda x: x.update(ip='192.0.2.1'))
    reject('statistics-visit', lambda x: x.update(retentionMonths=12))
    reject('statistics-visit', lambda x: x.update(visitPseudonym='a' * 33))
    reject('form', lambda x: x.update(id='synthetic-form'))
    reject('form', lambda x: x['security'].update(customerKeyGeneration=1))
    reject('form', lambda x: x['fields']['email'].update(name='csrf_token'))
    reject('package', lambda x: x['flows'][0]['nodes']['validate']['config'].update(SeCrEt='synthetisch'))
    reject('statistics-submit', lambda x: x.pop('submissionId'))
    reject('statistics-abandon', lambda x: x.pop('abandonmentEvidence'))
    reject('statistics-visit', lambda x: x.update(occurredAt='kein-datum'))
    reject('package', lambda x: x.update(credentials={}))
    reject('package', lambda x: x['connections'][0].update(password='synthetisch'))
    reject('package', lambda x: x['flows'][0]['nodes']['validate']['config'].update(nested={'secret':'synthetisch'}))
    reject('package', lambda x: x['importPolicy'].update(mode='publish'))
    reject('script-artifact', lambda x: x.update(source='return null;'), True)
    print(f'{len(schemas)} Draft-2020-12-Schemas gültig; alle lokalen $ref aufgelöst.')
    print(f'{len(examples)} Beispiele gültig; Referenz-/Hash-/Graph-/Zeitprüfungen erfolgreich.')
    print(f'{negative_count} Negativfälle wie erwartet abgelehnt. Keine Engine-/DB-/Sandbox-Integration geprüft.')


if __name__ == '__main__':
    main()

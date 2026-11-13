"""Statische Offline-Prüfung von P2-5; kein Laufzeit-/Sicherheitsnachweis.
SPDX-License-Identifier: AGPL-3.0-only
Benötigt lokal PyYAML und jsonschema; installiert nichts und verwendet kein Netz.
"""
from pathlib import Path
import copy
import json
import re
from urllib.parse import unquote, urlparse

import yaml
from jsonschema import Draft202012Validator, FormatChecker
from jsonschema_specifications import REGISTRY as META_REGISTRY
from referencing import Registry, Resource
from referencing.jsonschema import DRAFT202012

ROOT = Path(__file__).resolve().parent
CONTRACTS = ROOT.parent
API = ROOT / 'admin-api.openapi.yaml'


class UniqueLoader(yaml.SafeLoader):
    pass


def unique_mapping(loader, node, deep=False):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in result:
            raise ValueError(f'Doppelter YAML-Schlüssel: {key}')
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)
api = yaml.load(API.read_text(), Loader=UniqueLoader)
assert api['openapi'] == '3.1.0'
assert api['x-proposal-status'] == 'VORGESCHLAGEN'
assert api['security'] == [{'Session': []}, {'BearerToken': []}]

# Resolve static references locally; use the bundled metaschema without network.
documents = {API: api}
seen = set()
ref_count = 0


def document(path):
    path = path.resolve()
    if not path.is_relative_to(CONTRACTS):
        raise ValueError('Referenz außerhalb contracts/: ' + str(path))
    if path not in documents:
        documents[path] = json.loads(path.read_text())
    return documents[path]


def pointer(data, fragment):
    if not fragment:
        return data
    assert fragment.startswith('/')
    for part in unquote(fragment)[1:].split('/'):
        part = part.replace('~1', '/').replace('~0', '~')
        data = data[int(part)] if isinstance(data, list) else data[part]
    return data


def walk(node, base):
    global ref_count
    if isinstance(node, dict):
        if '$ref' in node:
            target = node['$ref']
            if target == 'https://json-schema.org/draft/2020-12/schema':
                META_REGISTRY.get_or_retrieve(target)
                ref_count += 1
                continue_local = True
            else:
                continue_local = False
            parts = urlparse(target)
            if not continue_local:
                assert not parts.scheme and not parts.netloc, target
                path = (base.parent / unquote(parts.path)).resolve() if parts.path else base
                resolved = pointer(document(path), parts.fragment)
                ref_count += 1
                key = (path, parts.fragment)
                if key not in seen:
                    seen.add(key)
                    walk(resolved, path)
        for key, value in node.items():
            if key != '$ref':
                walk(value, base)
    elif isinstance(node, list):
        for value in node:
            walk(value, base)


walk(api, API)
# Include the companion ingest contract, including new transport/legacy statuses.
INGEST = CONTRACTS / 'ingest/ingest.openapi.yaml'
ingest = yaml.load(INGEST.read_text(), Loader=UniqueLoader)
documents[INGEST] = ingest
walk(ingest, INGEST)
for schema in ingest['components']['schemas'].values():
    Draft202012Validator.check_schema(schema)
for schema in api['components']['schemas'].values():
    Draft202012Validator.check_schema(schema)

# Check declared permissions, path parameters, session gates and CSRF coverage.
rights = (ROOT / 'rechte.md').read_text()
permissions = set(re.findall(r'\b[a-z]+(?:-[a-z]+)?\.[a-z]+\b', rights))
scopes = {'statistik.lesen', 'konfiguration.lesen', 'entwurf.schreiben', 'test.ausfuehren', 'debug.maskiert'}
operation_ids = set()
operations = {}
for path, item in api['paths'].items():
    for method, op in item.items():
        assert method in {'get', 'post', 'patch', 'delete', 'put', 'head', 'options'}
        name = op['operationId']
        assert name not in operation_ids, name
        operation_ids.add(name)
        operations[name] = op
        assert op['x-proposal-status'] == 'VORGESCHLAGEN'
        assert op['x-legacy-routes'] and op['responses']
        assert set(op['x-permissions']) <= permissions, op['x-permissions']
        if 'x-required-scope' in op:
            assert op['x-required-scope'] in scopes
        for condition in op.get('x-conditional-permissions', {}).values():
            assert set(condition['permissions']) <= permissions
            assert condition['tokenScope'] in scopes
        params = [pointer(api, p['$ref'].split('#', 1)[1]) if '$ref' in p else p for p in op.get('parameters', [])]
        path_params = {p['name'] for p in params if p['in'] == 'path' and p['required']}
        assert path_params == set(re.findall(r'\{([^}]+)\}', path)), path
        assert len({(p['in'], p['name']) for p in params}) == len(params)
        if method not in {'get', 'head', 'options'}:
            assert any(p['name'] == 'X-CSRF-Token' for p in params), name
        if op.get('x-human-confirmation-required'):
            assert op['security'] == [{'Session': []}], name
        if path.startswith(('/auth/', '/me/')):
            assert op['security'] in ([], [{'Session': []}]), name
        assert all('$ref' in r or 'description' in r for r in op['responses'].values())
for name in ['confirmPublication', 'publishRelease', 'resendEntry', 'getCiphertext', 'createDomain', 'grantKeyAccess', 'createToken']:
    assert operations[name]['security'] == [{'Session': []}]
assert operations['publishRelease']['requestBody']['content']['application/json']['schema']['$ref'].endswith('/PublishInput')
assert 'Idempotency' in str(operations['publishRelease']['parameters'])
assert set(operations['resendEntry']['x-permissions']) >= {'content.decrypt', 'content.resend'}
assert set(operations['getDebugPlaintextEnvelope']['x-permissions']) >= {'debug.plaintext', 'content.decrypt'}
assert operations['exportDebug']['x-required-scope'] == 'debug.maskiert'

# Exercise publication payloads, injected properties and cross-package references.
registry = META_REGISTRY
for path, data in documents.items():
    resource = Resource.from_contents(data, default_specification=DRAFT202012)
    registry = registry.with_resource(path.as_uri(), resource)
    if '$id' in data:
        registry = registry.with_resource(data['$id'], resource)


def validator(name):
    schema = {'$ref': API.as_uri() + '#/components/schemas/' + name}
    return Draft202012Validator(schema, registry=registry, format_checker=FormatChecker())


count = 0


def check(name, value, valid):
    global count
    errors = list(validator(name).iter_errors(value))
    assert bool(errors) != valid, (name, valid, [e.message for e in errors])
    count += 1


uid = '10000000-0000-4000-8000-000000000001'
publication = {'draftId': uid, 'revision': 1, 'hash': 'a' * 64, 'confirmationId': uid}
check('PublishInput', publication, True)
for field in publication:
    candidate = copy.deepcopy(publication)
    del candidate[field]
    check('PublishInput', candidate, False)
check('PublishInput', dict(publication, actorKind='human'), False)
check('PublishInput', dict(publication, confirmed=True), False)
check('PublishInput', dict(publication, revision=0), False)
check('PublishInput', dict(publication, hash='falsch'), False)
check('PublishInput', dict(publication, confirmationId='keine-uuid'), False)
check('SecondFactorPassword', {'method': 'password', 'password': 'synthetischer-wert'}, True)
check('SecondFactorPassword', {'method': 'totp', 'code': '123456'}, False)
check('TotpVerify', {'code': '123456'}, True)
check('TotpVerify', {'code': '12345'}, False)
check('TotpVerify', {'code': '123456', 'subjectId': uid}, False)
token = {'label': 'synthetisch', 'expiresInDays': 1, 'scopes': ['statistik.lesen'], 'tenantIds': [uid], 'formIds': [uid]}
check('TokenInput', token, True)
check('TokenInput', dict(token, scopes=['release.publish']), False)
check('TokenInput', dict(token, expiresInDays=91), False)
check('TokenInput', dict(token, formIds=[]), False)
check('DebugInput', {'releaseId': uid, 'mode': 'observe'}, True)
check('DebugInput', {'releaseId': uid, 'mode': 'production'}, False)
check('DebugInput', {'releaseId': uid, 'mode': 'observe', 'plaintext': True}, False)
domain = {'hostname': 'formular.example.invalid', 'tenantId': uid, 'formId': uid,
          'viewId': uid, 'mode': 'testing', 'enabled': False, 'confirm': True}
check('DomainCreateInput', domain, True)
check('DomainCreateInput', dict(domain, enabled=True), False)
check('DomainCreateInput', dict(domain, mode='production'), False)
check('ExportInput', {'entryIds': [uid], 'format': 'json'}, True)
check('ExportInput', {'entryIds': [uid, uid], 'format': 'json'}, False)
# Reuse a synthetic P2-4 fixture to verify the external release schema binding.
release = json.loads((CONTRACTS / 'flow/examples/release.json').read_text())
check('Release', release, True)
release['publication']['actorKind'] = 'token'
check('Release', release, False)

# Technical review regressions: exact package wire shape and multi-object hold.
export_schema = operations['exportDraft']['responses']['200']['content']['application/json']['schema']
assert export_schema == {'$ref': '../flow/package.schema.json'}
package_validator = Draft202012Validator(
    {'$ref': (CONTRACTS / 'flow/package.schema.json').as_uri()},
    registry=registry, format_checker=FormatChecker())
package = json.loads((CONTRACTS / 'flow/examples/package.json').read_text())
package_validator.validate(package)
assert list(package_validator.iter_errors({'id': uid, 'revision': 1, 'document': {}}))
count += 2
hold_object = {'objectId': uid, 'expectedRevision': 0, 'expectedSha256': 'a' * 64,
               'sourceGenerationId': uid}
check('HoldInput', {'held': True, 'objects': [hold_object]}, True)
check('HoldInput', {'held': True, 'protectedPackage': 'old-single-package'}, False)
check('HoldInput', {'held': True, 'objects': []}, False)
check('HoldInput', {'held': True, 'objects': [dict(hold_object, objectId='portable-object')]}, False)
check('HoldInput', {'held': True, 'objects': [dict(hold_object, expectedRevision=-1)]}, False)
check('HoldInput', {'held': True, 'objects': [dict(hold_object, replacementPackage='plaintext')]}, False)

# ADR 0004: unknown rights fail in all writable DTOs and the DDL catalog agrees.
catalog = set(api['components']['schemas']['Permission']['enum'])
assert {'flow.execute', 'flow.approve', 'flow.resume'} <= catalog
sql = (CONTRACTS / 'data/schema-entwurf.sql').read_text()
seed = sql.split('INSERT INTO permission_catalog (permission) VALUES', 1)[1].split(';', 1)[0]
assert set(re.findall(r"'([^']+)'", seed)) == catalog
assert 'uq_view_host (host_ascii)' in sql
legacy_ddl = sql.split('CREATE TABLE legacy_statistics', 1)[1].split('CREATE TABLE', 1)[0]
assert "origin ENUM('legacy')" in legacy_ddl and 'expires_at' not in legacy_ddl
for value, valid in [('flow.execute', True), ('flow.approve', True), ('flow.resume', True),
                     ('flow.unknown', False), ('*', False)]:
    check('Permission', value, valid)
scope = {'kind': 'customer', 'tenantId': uid, 'formId': uid}
check('PermissionScope', scope, True)
check('PermissionScope', {'kind': 'system'}, True)
check('PermissionScope', {'kind': 'system', 'tenantId': uid}, False)
check('PermissionScope', {'kind': 'customer', 'formId': uid}, False)
group = {'name': 'Eigene Gruppe', 'scope': scope, 'permissions': ['flow.resume'], 'expectedRevision': 0}
check('PermissionGroupInput', group, True)
check('PermissionGroupInput', dict(group, permissions=[]), True)
check('PermissionGroupInput', dict(group, permissions=['flow.unknown']), False)
assignment = {'subjectId': uid, 'scope': scope, 'permissions': ['form.read'],
              'groupIds': [], 'expectedRightsVersion': 0}
check('PermissionAssignmentInput', assignment, True)
check('PermissionAssignmentInput', dict(assignment, permissions=['unknown.right']), False)
proof = {'objects': [dict(hold_object, cek='A' * 43 + '=')]}
# OriginalObjectProof and HoldObject deliberately share revision/digest, not generation.
proof['objects'][0].pop('sourceGenerationId')
resend = {'mode': 'testing', 'scope': 'both', 'generationId': uid, 'sourceHash': 'a' * 64,
          'fields': {}, 'expectedRevision': 0, 'manifestHash': 'b' * 64, 'originalProof': proof}
check('ResendInput', resend, True)
original_only = copy.deepcopy(resend)
original_only.pop('fields')
original_only.pop('generationId')
check('ResendInput', original_only, True)
for key in ['originalProof', 'manifestHash', 'expectedRevision']:
    candidate = copy.deepcopy(resend)
    del candidate[key]
    check('ResendInput', candidate, False)
check('ResendInput', dict(resend, edit=True), False)
bad = copy.deepcopy(resend)
bad['originalProof']['objects'][0]['cek'] = 'not-a-key'
check('ResendInput', bad, False)
resume = {'expectedRevision': 0, 'checkpointHash': 'a' * 64, 'originalProof': proof}
check('FlowResumeInput', resume, True)
check('FlowResumeInput', dict(resume, actorKind='human'), False)
for name in ['approveFlow', 'resumeFlow']:
    assert operations[name]['security'] == [{'Session': []}]
    assert operations[name]['x-human-confirmation-required'] is True
transport_validator = Draft202012Validator(
    {'$ref': INGEST.as_uri() + '#/components/schemas/TransportEnvelope'},
    registry=registry, format_checker=FormatChecker())
envelope = {'version': 'transport-v1', 'formId': uid, 'keyVersion': 1, 'requestId': uid,
            'timestamp': '1793000000', 'nonce': 'A' * 16, 'ciphertext': 'A' * 22 + '=='}
transport_validator.validate(envelope)
count += 1
for candidate in [dict(envelope, keyVersion=0), dict(envelope, nonce='short'),
                  dict(envelope, version='sym-v2'), dict(envelope, formId='unknown'),
                  dict(envelope, extra=True)]:
    assert list(transport_validator.iter_errors(candidate))
    count += 1
for path, item in ingest['paths'].items():
    for op in item.values():
        if path.startswith('/api/transport/v1/'):
            params = [pointer(ingest, p['$ref'].split('#', 1)[1]) if '$ref' in p else p for p in op['parameters']]
            assert all(p['required'] for p in params if p['name'] in {'X-Kubus-Timestamp', 'X-Kubus-Signature'})
        if 'submit' in op['operationId'].lower():
            assert {'418', '424'} <= set(op['responses'])


# Vertragsrunde 3: R01 Domainbindung, R02 Abrufpfad, R03/R05 DDL, R04 Testzielrecht, R07 Manifest, R08 DDL, M02 Fixtures.
assert 'test-target.manage' in catalog
check('Permission', 'test-target.manage', True)
assert operations['createTestTarget']['x-permissions'] == ['test-target.manage']
assert operations['updateTestTarget']['x-permissions'] == ['test-target.manage']
assert operations['listTestTargets']['x-permissions'] == ['test.run']
assert 'test-target.manage' in (ROOT / 'rechte.md').read_text()
target = {'name': 'Synthetisches Ziel', 'targetKind': 'mail-sink', 'enabled': True, 'confirm': True}
check('TestTargetInput', target, True)
check('TestTargetInput', dict(target, password='geheim'), False)
check('TestTargetInput', dict(target, targetKind='production'), False)
domain_update = {'hostname': 'formular.example.invalid', 'tenantId': uid, 'formId': uid, 'viewId': uid,
                 'mode': 'production', 'enabled': True, 'releaseId': uid, 'confirm': True}
check('DomainInput', domain_update, True)
no_release = dict(domain_update)
del no_release['releaseId']
check('DomainInput', no_release, False)
check('DomainInput', dict(no_release, enabled=False), True)
object_ref = {'objectId': uid, 'role': 'data', 'ordinal': 0, 'revision': 1, 'packageSha256': 'a' * 64,
              'payloadSha256': 'b' * 64, 'generationId': uid, 'wrap': 'hpke', 'byteCount': 10, 'access': 'allowed'}
check('StoredObjectRef', object_ref, True)
check('StoredObjectRef', dict(object_ref, role='debug'), False)
check('StoredObjectRef', dict(object_ref, plaintext='x'), False)
check('StoredObjectRef', dict((k, v) for k, v in object_ref.items() if k != 'payloadSha256'), False)
context = {'runId': uid, 'state': 'waiting-manual', 'revision': 3, 'checkpointHash': 'c' * 64,
           'checkpoint': dict(object_ref, role='checkpoint'), 'manifestObjectId': uid,
           'requiredObjects': [object_ref], 'blocked': []}
check('ResumeContext', context, True)
check('ResumeContext', dict(context, blocked=['unbekannt']), False)
check('ResumeContext', dict(context, state='running'), False)
check('EntryObjects', {'entryId': uid, 'manifestState': 'missing', 'manifestObjectId': None, 'objects': [object_ref]}, True)
check('StoredObjectCiphertext', {'object': object_ref, 'package': 'KUBUS-AEAD:2|synthetisch'}, True)
check('StoredObjectCiphertext', {'object': object_ref}, False)
execute = {'submissionId': uid, 'releaseId': uid, 'runSlot': 'slot-a'}
check('FlowExecuteInput', execute, True)
check('FlowExecuteInput', dict(execute, originalProof=proof), True)
check('FlowExecuteInput', dict(execute, originalProof={'objects': []}), False)
for name, perm in [('getResumeContext', 'flow.resume'), ('getRunCheckpointCiphertext', 'flow.resume'),
                   ('listEntryObjects', 'content.read')]:
    assert operations[name]['x-permissions'] == [perm], name
assert set(operations['getObjectCiphertext']['x-permissions']) == {'content.read', 'content.decrypt'}
# DDL: Release-/Revisionsbindung, getrennte Signierer, Transportpolitik, Objektidentitaet, Legacy-OAuth.
domain_ddl = sql.split('CREATE TABLE domain_bindings', 1)[1].split('CREATE TABLE', 1)[0]
for needle in ['release_id', 'revision', 'confirmation_audit_id', 'REFERENCES release_views(customer_id,form_id,release_id,view_id)',
               'uq_view_host (host_ascii)']:
    assert needle in domain_ddl, needle
assert 'CREATE TABLE adapter_signers' in sql and 'service_cert_sha256' in sql
assert 'signature_key_version' not in sql.split('CREATE TABLE legacy_adapter_bindings', 1)[1].split('CREATE TABLE', 1)[0]
assert "transport_policy ENUM('off','offered','required')" in sql
assert 'payload_sha256 BINARY(32) NOT NULL' in sql
# ADR 0005 D4: keine Tokenuebernahme, kein legacy-unbound
assert 'legacy-unbound' not in sql and 'resource_binding' not in sql and 'ck_refresh_family' not in sql
api_ddl = sql.split('CREATE TABLE api_host_forms', 1)[1].split('CREATE TABLE', 1)[0]
for needle in ['release_id', 'binding_revision', 'confirmation_audit_id', 'REFERENCES releases(customer_id,form_id,id)']:
    assert needle in api_ddl, needle
assert "('test-target.manage')" in seed
manifest_schema = json.loads((CONTRACTS / 'data/resend-manifest.schema.json').read_text())
Draft202012Validator.check_schema(manifest_schema)
manifest_validator = Draft202012Validator(manifest_schema, format_checker=FormatChecker())
manifest_example = json.loads((CONTRACTS / 'data/resend-manifest.example.json').read_text())
manifest_validator.validate(manifest_example)
for mutate in [lambda m: m['objects'][0].update(packageSha256='a' * 64),
               lambda m: m['objects'][0].update(payloadSha256='A' * 64),
               lambda m: m['deliveries'][0].pop('recipients'),
               lambda m: m.update(manifestVersion='resend-manifest-v2'),
               lambda m: m['deliveries'][0].update(key='geheim')]:
    candidate = copy.deepcopy(manifest_example)
    mutate(candidate)
    assert list(manifest_validator.iter_errors(candidate))
    count += 1
legacy_schema = json.loads((CONTRACTS / 'ingest/legacy-validation.schema.json').read_text())
Draft202012Validator.check_schema(legacy_schema)
legacy_fixtures = json.loads((CONTRACTS / 'ingest/legacy-validation-fixtures.json').read_text())
Draft202012Validator(legacy_schema).validate(legacy_fixtures['adapter'])
assert len(legacy_fixtures['cases']) == len({c['id'] for c in legacy_fixtures['cases']})
assert any(c['expected'] == 'php-reference-required' for c in legacy_fixtures['cases'])
count += 2

print(f'OK: YAML ohne doppelte Schlüssel; {len(operation_ids)} Operationen, {ref_count} Referenzvorkommen, {len(documents)} lokale Dokumente.')
print(f'OK: Komponenten-Metaschemata, Rechte-/Scope-/Pfad-/CSRF-/Sitzungsdeklarationen; {count} gezielte Payloadfälle.')
print('Grenze: kein vollständiger OpenAPI-Spezifikationsvalidator; keine Autorisierungs-, DB-, HTTP-, OAuth- oder WebAuthn-Laufzeittests.')

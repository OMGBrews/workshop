#!/usr/bin/env python3
"""Validate Codex declarations and render manual setup/start instructions; never launch."""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path, PurePosixPath
import re
import shlex
import sys

sys.dont_write_bytecode = True

# Share the established strict JSON/parser and repository identity primitives.
_spec = importlib.util.spec_from_file_location('cloud_declaration', Path(__file__).with_name('claude-code-web.py'))
if _spec is None or _spec.loader is None:
    raise RuntimeError("cannot load declaration primitives")
common = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(common)
Error = common.DeclarationError
DOCUMENT = Path('docs/work/codex-cloud.md')
BEGIN = '<!-- WORKSHOP-CODEX-CLOUD:BEGIN -->'
END = '<!-- WORKSHOP-CODEX-CLOUD:END -->'


def obj(value, required, context, optional=()):
    if not isinstance(value, dict):
        raise Error(f'{context}: expected an object')
    common.require_exact_keys(value, set(required), context, set(optional))


def string(value, context):
    if not isinstance(value, str) or not value.strip() or any(ord(c) < 32 for c in value):
        raise Error(f'{context}: expected a nonempty single-line string')
    return value


def path(root, value, context):
    value = string(value, context)
    candidate = PurePosixPath(value)
    if value.startswith('-') or candidate.is_absolute() or '..' in candidate.parts or str(candidate) != value:
        raise Error(f'{context}: expected a normalized repository-relative file path')
    try:
        resolved = (root / value).resolve()
    except (OSError, RuntimeError) as error:
        raise Error(f'{context}: cannot resolve repository file') from error
    if not resolved.is_relative_to(root) or not resolved.is_file():
        raise Error(f'{context}: file must exist within the repository')
    return value


def domains(value, context):
    if not isinstance(value, list) or any(not isinstance(x, str) for x in value):
        raise Error(f'{context}: expected an array of domains')
    if value != sorted(set(value)) or any(not common.DOMAIN.fullmatch(x) for x in value):
        raise Error(f'{context}: expected sorted unique bare DNS domains')


def command(root, value, context):
    if not isinstance(value, list) or len(value) < 2 or value[0] != 'bash':
        raise Error(f'{context}: expected ["bash", "repository/script.sh", ...]')
    for item in value:
        string(item, context)
    path(root, value[1], context)


def validate(root):
    config = common.extract(root / DOCUMENT, BEGIN, END)
    obj(config, ('version', 'availability', 'primaryRepository', 'additionalRepositories'),
        'configuration', ('environment', 'reason', 'readiness'))
    if type(config['version']) is not int or config['version'] != 1:
        raise Error('configuration.version: only integer 1 is supported')
    primary = string(config['primaryRepository'], 'primaryRepository')
    if not common.REPOSITORY.fullmatch(primary):
        raise Error('primaryRepository: expected owner/repo')
    additional = common.validate_repository_list(config['additionalRepositories'], 'additionalRepositories')
    if primary in additional:
        raise Error('additionalRepositories: must not repeat primaryRepository')
    if common.checkout_repository(root) != primary:
        raise Error('primaryRepository does not match checkout origin')
    availability = config['availability']
    if not isinstance(availability, str) or availability not in ('configured', 'not-configured', 'unsupported'):
        raise Error('availability: expected configured, not-configured, or unsupported')
    if availability != 'configured':
        if 'environment' in config or 'readiness' in config:
            raise Error('negative availability forbids environment and readiness')
        string(config.get('reason'), 'reason')
        return config
    if 'reason' in config:
        raise Error('configured availability forbids reason')
    env = config.get('environment')
    obj(env, ('name', 'configId', 'versionId', 'checkoutPath', 'installScript',
              'startCommand', 'commandPrefix', 'network', 'bindings'), 'environment')
    for key in ('name', 'configId', 'versionId'):
        string(env[key], f'environment.{key}')
    checkout = string(env['checkoutPath'], 'checkoutPath')
    if not checkout.startswith('/') or '..' in PurePosixPath(checkout).parts or str(PurePosixPath(checkout)) != checkout:
        raise Error('checkoutPath: expected a normalized absolute POSIX path')
    path(root, env['installScript'], 'installScript')
    command(root, env['startCommand'], 'startCommand')
    command(root, env['commandPrefix'], 'commandPrefix')
    if env['startCommand'].count('{source}') != 1:
        raise Error('startCommand: requires exactly one standalone {source} argument')
    if any('{' in x or '}' in x for x in env['startCommand'] if x != '{source}'):
        raise Error('startCommand: unsupported placeholder')
    if any('{' in x or '}' in x for x in env['commandPrefix']):
        raise Error('commandPrefix: placeholders are forbidden')
    net = env['network']
    obj(net, ('access', 'includePackageManagers', 'allowedDomains'), 'network')
    if net['access'] not in ('restricted', 'full') or type(net['includePackageManagers']) is not bool:
        raise Error('network: expected restricted/full access and boolean includePackageManagers')
    domains(net['allowedDomains'], 'network.allowedDomains')
    bindings = env['bindings']
    if not isinstance(bindings, list):
        raise Error('bindings: expected an array')
    names = []
    for binding in bindings:
        obj(binding, ('name', 'kind', 'required'), 'binding', ('allowedDomains',))
        name = string(binding['name'], 'binding.name')
        if not common.VARIABLE.fullmatch(name) or type(binding['required']) is not bool:
            raise Error('binding: invalid name or required flag')
        names.append(name)
        if binding['kind'] == 'network-secret':
            domains(binding.get('allowedDomains'), 'binding.allowedDomains')
            if not binding['allowedDomains']:
                raise Error('network-secret requires allowedDomains')
        elif binding['kind'] != 'variable' or 'allowedDomains' in binding:
            raise Error('binding: expected variable without domains or network-secret with domains')
    if names != sorted(set(names)):
        raise Error('bindings: names must be sorted and unique')
    readiness = config.get('readiness')
    obj(readiness, ('state',), 'readiness', ('evidence',))
    if readiness['state'] == 'recorded':
        path(root, readiness.get('evidence'), 'readiness.evidence')
    elif readiness['state'] != 'unverified' or 'evidence' in readiness:
        raise Error('readiness: expected recorded with evidence or unverified without evidence')
    return config


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('validate', 'show', 'render-setup', 'render-start'))
    parser.add_argument('repository')
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--source', help='full intended source SHA for render-start')
    args = parser.parse_args(argv)
    if args.json and args.command != 'show':
        parser.error('--json is only valid with show')
    if (args.command == 'render-start') != (args.source is not None):
        parser.error('--source is required only for render-start')
    if args.source is not None and not re.fullmatch('[0-9a-f]{40}', args.source):
        parser.error('--source must be a full lowercase commit SHA')
    try:
        root = common.repository_root(args.repository)
        config = validate(root)
        if args.command == 'validate':
            print(f'ok: {root / DOCUMENT} (schema/files only; live readiness not verified)')
        elif args.command == 'show':
            if args.json:
                print(json.dumps(config, indent=2, sort_keys=True))
            else:
                print(f"Availability: {config['availability']}")
                if config['availability'] != 'configured':
                    print(f"Reason: {config['reason']}")
                else:
                    print(f"Environment: {config['environment']['name']}")
                    print(f"Configuration: {config['environment']['configId']}")
                    print(f"Published version: {config['environment']['versionId']}")
                    print(f"Evidence: {config['readiness']['state']} (not independently verified)")
        else:
            if config['availability'] != 'configured':
                raise Error('cannot render for a negative availability state')
            env = config['environment']
            cd = 'cd ' + shlex.quote(env['checkoutPath'])
            if args.command == 'render-setup':
                print('#!/usr/bin/env bash\nset -euo pipefail\n' + cd)
                print(shlex.join(['bash', env['installScript']]))
            else:
                print(f"Expected source: {args.source}. Preserve local work; stop on a mismatch.")
                print('Read AGENTS.md from the intended source revision before startup.')
                print(cd)
                print(shlex.join([args.source if x == '{source}' else x for x in env['startCommand']]))
                print('For EVERY subsequent command shell, use this prefix after changing to the checkout:')
                print(shlex.join(env['commandPrefix']) + ' <command> [args...]')
                print('Report configuration/version and runtime identities separately. Startup is agent-invoked.')
        return 0
    except (Error, OSError, UnicodeError) as error:
        print(f'error: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())

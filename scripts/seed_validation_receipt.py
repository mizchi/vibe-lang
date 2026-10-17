#!/usr/bin/env python3
"""Bind a successful flat-source seed validation to its reusable product.

Receipts are a local optimization, not authority over untrusted source trees.
The immutable heap-policy harness always compiles instead. Unknown environment
settings are included by digest; no inherited secret values are written out.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

SCHEMA = 1
# These select build orchestration or observation, not the compiler request.
# Actual normalized runner options are captured separately below. Unknown names
# remain in the environment digest rather than silently becoming irrelevant.
ORCHESTRATION = {
    '_', 'SHLVL', 'PWD', 'OLDPWD',
    'GITHUB_ENV', 'GITHUB_OUTPUT', 'GITHUB_PATH', 'GITHUB_STATE', 'GITHUB_STEP_SUMMARY', 'GITHUB_ACTION',
    # Cache producers and consumers can be different CI jobs/runs. Exclude
    # their identity, not whole GITHUB_/RUNNER_ namespaces: unknown settings
    # still invalidate reuse. Actual root and executable hashes remain bound.
    'GITHUB_JOB', 'GITHUB_WORKFLOW', 'GITHUB_WORKFLOW_REF', 'GITHUB_WORKFLOW_SHA',
    'GITHUB_RUN_ID', 'GITHUB_RUN_NUMBER', 'GITHUB_RUN_ATTEMPT',
    'GITHUB_ACTOR', 'GITHUB_ACTOR_ID', 'GITHUB_TRIGGERING_ACTOR', 'GITHUB_EVENT_PATH',
    'RUNNER_NAME', 'RUNNER_TRACKING_ID', 'RUNNER_TEMP',
    'VIBE_PROJECT_ROOT', 'VIBE_COMPILER_DIR', 'VIBE_SOURCE_MANIFEST',
    'VIBE_BUNDLE_OUT', 'VIBE_ADAPTER_BUNDLE_OUT', 'VIBE_RUNTIME_ENTRY_BUNDLE_OUT',
    'VIBE_ADAPTER_MODULE_SOURCE_OUT', 'VIBE_COMPILE_ONLY_MODULE_SOURCE_OUT',
    'VIBE_BUNDLE_EXTRA_ENTRIES', 'VIBE_BUNDLE_CHUNK_SIZE',
    'VIBE_ADAPTER_MODULE_SOURCE_FROM_MERGED', 'VIBE_REGEN_MODULE_SOURCE',
    'VIBE_MODULE_SOURCE_ENTRY_NAME', 'VIBE_PREBUILT_MODULE_SOURCE',
    'VIBE_PREBUILT_MODULE_SOURCE_SHA256', 'VIBE_GENERATION_RUNNER_SCRIPT',
    'VIBE_GENERATION_VALIDATE_WASM', 'VIBE_GENERATION_VALIDATE_RUN',
    'VIBE_GENERATION_ALLOW_UNPINNED_SEED', 'VIBE_GENERATION_CLI_INVOKE',
    'VIBE_GENERATION_SELFBUILD_INVOKE', 'VIBE_GENERATION_FLAT_CLI_SOURCE',
    'VIBE_GENERATION_AUTO_FETCH_SEED', 'VIBE_GENERATION_NODE_STACK_SIZE',
    'VIBE_GENERATION_WASM_PRE_GROW_PAGES',
    'VIBE_GENERATION_DISABLE_PERSISTENT_ARTIFACT_CACHE',
    'VIBE_GENERATION_SKIP_RUN_INIT', 'VIBE_GENERATION_WASMTIME_FLAGS',
    'VIBE_BUILD_CLI_WASM_NO_CACHE', 'VIBE_BUILD_CLI_WASM_CACHE_DIR',
    'VIBE_TRACE_OUT', 'VIBE_TRACEPARENT', 'VIBE_TRACE_MONOTONIC',
    'VIBE_MEM', 'VIBE_WASM_MEMORY_STATS',
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


def file_hash(path):
    return digest(Path(path).read_bytes())


def request(args):
    # Flat source paths are interchangeable only on the ordinary flat route.
    # Source-location/FS/emission modes and policy evaluations compile afresh.
    for name, value in os.environ.items():
        if value and (name in {'VIBE_POLICY_RAW_FS_ROOT', 'VIBE_INPUT', 'VIBE_OUTPUT',
                               'VIBE_ENTRY', 'VIBE_COV_OUT', 'VIBE_PROFILE_TSV',
                               'VIBE_WASM_NAMES', 'VIBE_NODE_EXTRA_FLAGS'} or
                      (name.startswith('VIBE_') and name.endswith('_OUT') and name not in ORCHESTRATION) or
                      (name == 'VIBE_BACKEND' and value not in {'', 'linear'}) or
                      name.startswith(('VIBE_EMIT_', 'VIBE_LINE_MAP')) or
                      (name == 'VIBE_FS_COMPILE' and value != '0')):
            raise ValueError('request requires a fresh compile: ' + name)
    root = args.root.resolve()
    if args.runner.resolve() != (root / 'scripts/run_wasm_vibe_host_runner.sh').resolve():
        raise ValueError('custom runner requires a fresh compile')
    env = {k: v for k, v in os.environ.items() if k not in ORCHESTRATION}
    defaults = {
        'VIBE_RC': '0', 'VIBE_INTERNAL_TRUSTED_SOURCE': '1',
        'VIBE_IMPORT_ABI': 'raw', 'VIBE_PREOPEN_DIR': str(root),
        'VIBE_WASM_PRE_GROW_PAGES': '0',
        'VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE': '1', 'VIBE_SKIP_RUN_INIT': '1',
        'VIBE_NODE_WASM_FLAGS': '--experimental-wasm-exnref --stack-size=131072',
    }
    for key, value in defaults.items():
        env.setdefault(key, value)
    host = {path.name: file_hash(path) for path in sorted(args.scripts.glob('wasm_vibe_host_*.*')) if path.is_file()}
    host['selected_runner'] = file_hash(args.runner)
    host['receipt_helper'] = file_hash(__file__)
    tools = {}
    for name in ['node', 'bash']:
        path = shutil.which(name)
        if path is None:
            raise ValueError('missing runner tool: ' + name)
        tools[name] = {'path': str(Path(path).resolve()), 'sha256': file_hash(path)}
    return {'schema': SCHEMA, 'root': str(root), 'source_sha256': file_hash(args.source),
            'seed_sha256': file_hash(args.seed), 'entry': args.entry,
            'invoke': 'cli_main', 'host': host, 'tools': tools,
            'environment_sha256': digest(encoded(env))}


def atomic_write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(data)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def sidecars(source):
    return Path(str(source) + '.seed-validation.wasm'), Path(str(source) + '.seed-validation.json')


def publish(args):
    before = json.loads(args.request.read_bytes())
    if not isinstance(before, dict) or before != request(args):
        raise ValueError('validation inputs changed during compilation')
    product = args.product.read_bytes()
    if not product:
        raise ValueError('validation produced no Wasm')
    source = args.source.read_bytes()
    if digest(source) != before['source_sha256']:
        raise ValueError('candidate source changed before publication')
    wasm, receipt = sidecars(args.destination)
    # Publish the source only after a successful validation. Publishing the
    # receipt LAST makes interruption a harmless miss, never a stale hit.
    atomic_write(args.destination, source)
    atomic_write(wasm, product)
    atomic_write(receipt, encoded({'schema': SCHEMA, 'request': before,
                                  'product_sha256': digest(product)}))


def consume(args):
    wasm, receipt_path = sidecars(args.receipt_source)
    receipt = json.loads(receipt_path.read_bytes())
    if not isinstance(receipt, dict):
        raise ValueError('invalid validation receipt')
    selected = request(args)
    previous = receipt.get('request')
    if not isinstance(previous, dict):
        raise ValueError('invalid validation request in receipt')
    if receipt.get('schema') != SCHEMA or previous != selected:
        changed = sorted(k for k in set(previous) | set(selected) if previous.get(k) != selected.get(k))
        raise ValueError('validation receipt does not match selected request: ' + ', '.join(changed))
    if file_hash(args.receipt_source) != receipt['request']['source_sha256']:
        raise ValueError('published validation source changed')
    product = wasm.read_bytes()
    if not product or digest(product) != receipt['product_sha256']:
        raise ValueError('validation product changed or is incomplete')
    # Read into private host bytes before publishing; a later writer cannot
    # change the product being copied into this stage's output.
    atomic_write(args.destination, product)
    print('[selfhost-gen] reuse verified seed validation as stage1', file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['request', 'publish', 'consume'])
    for key in ['root', 'scripts', 'source', 'seed', 'runner']:
        parser.add_argument('--' + key, type=Path, required=True)
    parser.add_argument('--entry', required=True)
    for key in ['request', 'product', 'destination', 'receipt-source']:
        parser.add_argument('--' + key, type=Path)
    args = parser.parse_args()
    try:
        if args.mode == 'request':
            sys.stdout.buffer.write(encoded(request(args)))
        elif args.mode == 'publish':
            publish(args)
        else:
            consume(args)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('seed validation receipt: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

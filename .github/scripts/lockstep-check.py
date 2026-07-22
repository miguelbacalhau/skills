#!/usr/bin/env python3
"""Lockstep check for the contract vocabulary duplicated across the three
config validators: scripts/config.sh (the sole writer), and the two
sandboxed workflow scripts that carry literal copies because they cannot
read files (scripts/work-loop.workflow.js, scripts/debug-loop.workflow.js).
A value accepted by one validator but rejected by another bricks launches
until the config file is hand-edited — so CI fails when the lists drift.
"""
import re
import sys

FILES = {
    'config.sh': 'scripts/config.sh',
    'work-loop': 'scripts/work-loop.workflow.js',
    'debug-loop': 'scripts/debug-loop.workflow.js',
}


def strings_of(blob):
    return re.findall(r"'([a-z-]+)'", blob)


def list_literal(src, name, path):
    """The bracketed list assigned to `name`, spreads NOT resolved."""
    m = re.search(re.escape(name) + r"\s*=\s*\[(.*?)\]", src, re.S)
    if not m:
        sys.exit(f"lockstep: no {name} list found in {path}")
    return m.group(1)


def js_vocab(path):
    src = open(path).read()
    stages_blob = list_literal(src, 'const STAGES', path)
    # resolve one level of ...SPREAD against its own const list
    for spread in re.findall(r"\.\.\.([A-Z_]+)", stages_blob):
        stages_blob = stages_blob.replace(
            f"...{spread}", list_literal(src, f"const {spread}", path))
    return {
        'STAGES': strings_of(stages_blob),
        'MODELS': strings_of(list_literal(src, 'const MODELS', path)),
        'EFFORTS': strings_of(list_literal(src, 'const EFFORTS', path)),
    }


def sh_vocab(path):
    src = open(path).read()
    return {
        'STAGES': strings_of(list_literal(src, 'STAGES', path)),
        'MODELS': strings_of(list_literal(src, 'MODELS', path)),
        'EFFORTS': strings_of(list_literal(src, 'EFFORTS', path)),
    }


vocabs = {
    'config.sh': sh_vocab(FILES['config.sh']),
    'work-loop': js_vocab(FILES['work-loop']),
    'debug-loop': js_vocab(FILES['debug-loop']),
}

ok = True
for key in ('STAGES', 'MODELS', 'EFFORTS'):
    # order differs legitimately (each script lists its own tunables first);
    # the contract is the SET of accepted values
    sets = {name: sorted(v[key]) for name, v in vocabs.items()}
    if len({tuple(s) for s in sets.values()}) != 1:
        ok = False
        print(f"lockstep: {key} drifted across the three validators:")
        for name, values in sets.items():
            print(f"  {name}: {values}")

if not ok:
    sys.exit(1)
for name, v in vocabs.items():
    print(f"lockstep: {name}: "
          f"{len(v['STAGES'])} stages, {len(v['MODELS'])} models, "
          f"{len(v['EFFORTS'])} efforts — in lockstep")

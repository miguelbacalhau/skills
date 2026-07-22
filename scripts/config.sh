#!/usr/bin/env bash
#
# orca config — the sole reader/writer of <repo-root>/.orca/config.json.
# The orca:config skill stays the conversational shell (presentation,
# advice, failure translation); this script owns the parse, the validation,
# the merge/removal semantics, and the canonical write. preflight.sh and
# review.sh read the file with grep, justified by the guarantee that lives
# HERE: this script is the only writer, and it only ever writes the
# canonical shape below.
#
# Usage:
#   config.sh show
#   config.sh validate
#   config.sh set <field>=<value> [...]     # plan.model=sonnet reviewer=claude
#   config.sh clear <field> [...]           # plan.model reviewer
#   config.sh reset [stage]
#
# Output contract — one machine-readable line per fact, fields TAB-separated:
#
#   show (read-only; a file that fails validation FAILs — fix via set/clear/reset):
#     REVIEWER:<TAB><codex|claude><TAB>pinned      or  REVIEWER:<TAB>absent
#     EDITOR:<TAB><nvim|vscode|none|absent>
#     TERMINAL:<TAB><tmux|none|absent>
#     OVERRIDE:<TAB><stage><TAB><model|effort><TAB><value>    one per set field
#     DEFAULT:<TAB><stage><TAB><model><TAB><effort>           from the plugin's
#       agents/<stage>.md frontmatter, stages in vocabulary order. The review
#       stage appears twice, as review-codex AND review-claude — the caller
#       renders the row for the effective reviewer, which this script never
#       resolves: detection is preflight.sh's job (its REVIEWER: line), and
#       the caller composes the two outputs.
#
#   validate (read-only):
#     VALID:<TAB><compact-json>    exit 0 — the canonical launch block: the
#       pinned reviewer plus the agents overrides, exactly what the run
#       skills hold for the Workflow args. editor/terminal are validated but
#       excluded — they are orca:review preferences, not launch args. An
#       absent file is a valid state: VALID:<TAB>{}
#
#   set / clear / reset (write): the resulting state as show emits it
#   (DEFAULT lines included), plus
#     WROTE:<TAB><path>       or  DELETED:<TAB><path>
#   set assigns field=value; the value `default` clears that field instead.
#   clear removes bare fields (<stage>.<model|effort> or a top-level key).
#   reset <stage> clears one stage; reset with no argument clears everything
#   — file deletion included, and it works even on an unparseable file (the
#   recovery path: a full reset never needs a parse).
#   Writes are reject-all-or-write-nothing: every bad assignment (and any
#   pre-existing bad value the merge would preserve) gets its own FAIL line,
#   and nothing is written on a nonzero exit.
#
#   any subcommand:
#     FAIL:<TAB><reason><TAB><detail>    exit 1, nothing written
#       reasons: NOT_GIT NO_PYTHON3 BAD_ARGS PARSE_ERROR DUPLICATE_KEY
#                BAD_SHAPE UNKNOWN_KEY UNKNOWN_STAGE UNKNOWN_MODEL
#                UNKNOWN_EFFORT SPEC_EFFORT UNKNOWN_REVIEWER UNKNOWN_EDITOR
#                UNKNOWN_TERMINAL
#
# Canonical write shape — the contract the grep-readers in preflight.sh and
# review.sh assume (they stay grep-only BECAUSE this script is the sole
# writer): one line, compact separators, trailing newline, fixed key order
# (reviewer, editor, terminal, agents; stages in vocabulary order; model
# before effort), no empty stage objects, no empty agents block, cleared
# keys removed entirely (never null or "default"), and a file that would be
# {} is deleted instead.
#
# Works in both layouts: the bare-with-worktrees layout orca:init creates
# (.orca/ sits beside the bare repo, outside every worktree) and a
# conventional checkout — where <repo-root> IS a working tree, so when this
# script writes there it also ensures `.orca/` is listed in
# <git-common-dir>/info/exclude (the per-clone ignore file), keeping a stray
# `git add -A` from committing per-machine preferences.

set -uo pipefail

fail() { # <reason> <detail> — typed failure, exit 1, nothing written
  printf 'FAIL:\t%s\t%s\n' "$1" "$2"
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
agents_dir="$script_dir/../agents"

command -v python3 >/dev/null 2>&1 \
  || fail NO_PYTHON3 "python3 not on PATH — required for strict JSON handling"

# Resolve repo root in either layout: the parent of the git common dir is the
# directory that holds (or will hold) .orca/. No bare-layout requirement —
# the config is legitimate in a repo orca:init has not converted yet.
resolve_repo() {
  common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -z "$common_dir" ]]; then
    fail NOT_GIT "not inside a git repository — the config is per-repository"
  fi
  is_bare="$(git --git-dir="$common_dir" rev-parse --is-bare-repository 2>/dev/null || true)"
  repo_root="$(dirname "$common_dir")"
  config_file="$repo_root/.orca/config.json"
}

# Stage defaults from the plugin's own agent definitions — read fresh, never
# recited, so a plugin update moves these lines with it.
emit_defaults() {
  local stage file model effort
  for stage in spec plan implement review-codex review-claude fix commit merge integrate reproduce hypothesize verify diagnose; do
    file="$agents_dir/$stage.md"
    [[ -f "$file" ]] || continue
    model="$(awk '/^---$/{n++; next} n==1 && sub(/^model:[ \t]*/,""){print; exit}' "$file")"
    effort="$(awk '/^---$/{n++; next} n==1 && sub(/^effort:[ \t]*/,""){print; exit}' "$file")"
    printf 'DEFAULT:\t%s\t%s\t%s\n' "$stage" "${model:-unset}" "${effort:-unset}"
  done
}

# Conventional checkout only (the bare layout's .orca/ is outside every
# worktree): make sure the per-clone ignore file excludes .orca/. Idempotent,
# and only once .orca/ actually exists.
ensure_exclude() {
  [[ "$is_bare" == "true" ]] && return 0
  [[ -e "$repo_root/.orca" ]] || return 0
  local exclude="$common_dir/info/exclude"
  mkdir -p "$common_dir/info"
  grep -qxF '.orca/' "$exclude" 2>/dev/null || printf '.orca/\n' >>"$exclude"
}

# All JSON handling — strict parse, validation, merge, canonical write —
# lives in python3 (present on every target platform; jq is not guaranteed).
py() {
  python3 - "$@" <<'PY'
import json, os, sys, tempfile

# One shared validation vocabulary kept in lockstep across three code
# validators: this script, work-loop.workflow.js, and debug-loop.workflow.js.
# The workflow scripts run sandboxed with no filesystem access, so they carry
# their own literal copies — a value accepted here but rejected there bricks
# that verb's launches until the config file is hand-edited.
STAGES = ['spec', 'plan', 'implement', 'review', 'fix', 'commit', 'merge', 'integrate',
          'reproduce', 'hypothesize', 'verify', 'diagnose']
MODELS = ['haiku', 'sonnet', 'opus', 'fable']
EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max']
TOP_VALUES = {'reviewer': ['codex', 'claude'],
              'editor': ['nvim', 'vscode', 'none'],
              'terminal': ['tmux', 'none']}
TOP_FAIL = {'reviewer': 'UNKNOWN_REVIEWER', 'editor': 'UNKNOWN_EDITOR', 'terminal': 'UNKNOWN_TERMINAL'}
SPEC_EFFORT_MSG = ('spec.effort is not supported — the spec agent is spawned conversationally, '
                   'where only model can be overridden')

errors = []
def err(reason, detail):
    errors.append((reason, detail))

def bail_if_errors():
    if errors:
        for reason, detail in errors:
            print(f'FAIL:\t{reason}\t{detail}')
        sys.exit(1)

def no_dupes(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            raise ValueError(f'duplicate key "{k}"')
        d[k] = v
    return d

def load(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path) as f:
            cfg = json.load(f, object_pairs_hook=no_dupes)
    except ValueError as e:
        if 'duplicate key' in str(e):
            err('DUPLICATE_KEY', f'{e} in {path} — fix by hand or config.sh reset')
        else:
            err('PARSE_ERROR', f'{path} is not valid JSON ({e}) — fix by hand or config.sh reset')
        return None
    if not isinstance(cfg, dict):
        err('PARSE_ERROR', f'{path} must hold a JSON object, got {type(cfg).__name__}')
        return None
    return cfg

def validate_cfg(cfg):
    for k, v in cfg.items():
        if k == 'agents':
            if not isinstance(v, dict):
                err('BAD_SHAPE', f'agents must be an object keyed by stage, got {json.dumps(v)}')
                continue
            for stage, sc in v.items():
                if stage not in STAGES:
                    err('UNKNOWN_STAGE', f'agents.{stage} — stages are {", ".join(STAGES)}')
                    continue
                if not isinstance(sc, dict):
                    err('BAD_SHAPE', f'agents.{stage} must be an object with model/effort, got {json.dumps(sc)}')
                    continue
                for f, val in sc.items():
                    if f == 'model':
                        if val not in MODELS:
                            err('UNKNOWN_MODEL', f'agents.{stage}.model={json.dumps(val)} — models are {", ".join(MODELS)}')
                    elif f == 'effort':
                        if stage == 'spec':
                            err('SPEC_EFFORT', SPEC_EFFORT_MSG)
                        elif val not in EFFORTS:
                            err('UNKNOWN_EFFORT', f'agents.{stage}.effort={json.dumps(val)} — efforts are {", ".join(EFFORTS)}')
                    else:
                        err('UNKNOWN_KEY', f'agents.{stage}.{f} — a stage takes only model and effort')
        elif k in TOP_VALUES:
            if v not in TOP_VALUES[k]:
                err(TOP_FAIL[k], f'{k}={json.dumps(v)} — allowed values: {", ".join(TOP_VALUES[k])}')
        else:
            err('UNKNOWN_KEY', f'{k} — top-level keys are reviewer, editor, terminal, agents')

# Canonical shape: fixed key order, stages in vocabulary order, model before
# effort, empties dropped. Only ever called on a cfg that passed validate_cfg,
# so it can never silently drop an unknown key.
def canonical(cfg):
    out = {}
    for k in ['reviewer', 'editor', 'terminal']:
        if k in cfg:
            out[k] = cfg[k]
    ag = cfg.get('agents') or {}
    stages = {}
    for s in STAGES:
        sc_in = ag.get(s) or {}
        sc = {f: sc_in[f] for f in ['model', 'effort'] if f in sc_in}
        if sc:
            stages[s] = sc
    if stages:
        out['agents'] = stages
    return out

def compact(obj):
    return json.dumps(obj, separators=(',', ':'))

def emit_state(cfg):
    if 'reviewer' in cfg:
        print(f'REVIEWER:\t{cfg["reviewer"]}\tpinned')
    else:
        print('REVIEWER:\tabsent')
    for k in ['editor', 'terminal']:
        print(f'{k.upper()}:\t{cfg.get(k, "absent")}')
    ag = cfg.get('agents') or {}
    for s in STAGES:
        sc = ag.get(s) or {}
        for f in ['model', 'effort']:
            if f in sc:
                print(f'OVERRIDE:\t{s}\t{f}\t{sc[f]}')

def write_result(path, cfg):
    can = canonical(cfg)
    emit_state(can)
    if not can:
        if os.path.exists(path):
            os.remove(path)
            print(f'DELETED:\t{path}')
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # Atomic: temp file + rename, so a concurrent preflight/review grep can
    # never observe a truncated file.
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix='.config.json.')
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(compact(can) + '\n')
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
    print(f'WROTE:\t{path}')

# ('top', key) or ('stage', stage, field); records an error and returns None
# on anything else. Clearing spec.effort is allowed — removal is the remedy
# for a file that wrongly holds it.
def parse_field(tok, clearing=False):
    if '.' in tok:
        stage, _, field = tok.partition('.')
        if stage not in STAGES:
            err('UNKNOWN_STAGE', f'{tok} — stages are {", ".join(STAGES)}')
            return None
        if field not in ('model', 'effort'):
            err('UNKNOWN_KEY', f'{tok} — a stage takes model or effort')
            return None
        if stage == 'spec' and field == 'effort' and not clearing:
            err('SPEC_EFFORT', SPEC_EFFORT_MSG)
            return None
        return ('stage', stage, field)
    if tok in TOP_VALUES:
        return ('top', tok)
    err('UNKNOWN_KEY', f'{tok} — settable fields are <stage>.model, <stage>.effort, reviewer, editor, terminal')
    return None

# Shape guards mirror clear/reset's defensiveness: a hand-mangled file
# ({"agents":[]}, {"agents":{"plan":3}}) yields a typed FAIL at the next
# bail, never a Python traceback.
def apply_ops(cfg, ops):
    for op in ops:
        if op[0] == 'set':
            _, spec, value = op
            if spec[0] == 'top':
                cfg[spec[1]] = value
            else:
                ag = cfg.setdefault('agents', {})
                if not isinstance(ag, dict):
                    err('BAD_SHAPE', f'agents must be an object keyed by stage, got {json.dumps(ag)} — fix by hand or config.sh reset')
                    return
                sc = ag.setdefault(spec[1], {})
                if not isinstance(sc, dict):
                    err('BAD_SHAPE', f'agents.{spec[1]} must be an object with model/effort, got {json.dumps(sc)} — config.sh reset {spec[1]} clears it')
                    return
                sc[spec[2]] = value
        else:  # clear
            _, spec = op
            if spec[0] == 'top':
                cfg.pop(spec[1], None)
            else:
                ag = cfg.get('agents')
                if isinstance(ag, dict):
                    sc = ag.get(spec[1])
                    if isinstance(sc, dict):
                        sc.pop(spec[2], None)

mode, path = sys.argv[1], sys.argv[2]
rest = sys.argv[3:]

if mode == 'show':
    cfg = load(path)
    bail_if_errors()
    validate_cfg(cfg)
    bail_if_errors()
    emit_state(cfg)

elif mode == 'validate':
    cfg = load(path)
    bail_if_errors()
    validate_cfg(cfg)
    bail_if_errors()
    out = {}
    if 'reviewer' in cfg:
        out['reviewer'] = cfg['reviewer']
    can = canonical(cfg)
    if 'agents' in can:
        out['agents'] = can['agents']
    print(f'VALID:\t{compact(out)}')

elif mode == 'set':
    ops = []
    for tok in rest:
        if '=' not in tok:
            err('BAD_ARGS', f'{tok} — set takes <field>=<value> assignments')
            continue
        field, _, value = tok.partition('=')
        spec = parse_field(field, clearing=(value == 'default'))
        if spec is None:
            continue
        if value == 'default':
            ops.append(('clear', spec))
            continue
        if spec[0] == 'top':
            if value not in TOP_VALUES[spec[1]]:
                err(TOP_FAIL[spec[1]], f'{tok} — allowed values: {", ".join(TOP_VALUES[spec[1]])}, default')
                continue
        else:
            f = spec[2]
            allowed = MODELS if f == 'model' else EFFORTS
            if value not in allowed:
                err('UNKNOWN_MODEL' if f == 'model' else 'UNKNOWN_EFFORT',
                    f'{tok} — allowed values: {", ".join(allowed)}, default')
                continue
        ops.append(('set', spec, value))
    bail_if_errors()
    cfg = load(path)
    bail_if_errors()
    apply_ops(cfg, ops)
    # Validate the merged result, not just the assignments: a pre-existing bad
    # value the merge would preserve fails loudly here, named, before any write.
    validate_cfg(cfg)
    bail_if_errors()
    write_result(path, cfg)

elif mode == 'clear':
    ops = []
    for tok in rest:
        if '=' in tok:
            err('BAD_ARGS', f'{tok} — clear takes bare fields, no "="')
            continue
        spec = parse_field(tok, clearing=True)
        if spec is not None:
            ops.append(('clear', spec))
    bail_if_errors()
    cfg = load(path)
    bail_if_errors()
    apply_ops(cfg, ops)
    validate_cfg(cfg)
    bail_if_errors()
    write_result(path, cfg)

elif mode == 'reset':
    if not rest:
        # Full reset never parses — it is the recovery path for a mangled file.
        emit_state({})
        if os.path.exists(path):
            os.remove(path)
            print(f'DELETED:\t{path}')
    else:
        stage = rest[0]
        if stage not in STAGES:
            err('UNKNOWN_STAGE', f'{stage} — stages are {", ".join(STAGES)}')
        bail_if_errors()
        cfg = load(path)
        bail_if_errors()
        ag = cfg.get('agents')
        if isinstance(ag, dict):
            ag.pop(stage, None)
        validate_cfg(cfg)
        bail_if_errors()
        write_result(path, cfg)
PY
}

sub="${1:-}"
[[ $# -gt 0 ]] && shift

case "$sub" in
  show)
    resolve_repo
    py show "$config_file" || exit 1
    emit_defaults
    exit 0
    ;;
  validate)
    resolve_repo
    py validate "$config_file"
    exit $?
    ;;
  set)
    [[ $# -ge 1 ]] || fail BAD_ARGS "usage: config.sh set <field>=<value> [...]"
    resolve_repo
    py set "$config_file" "$@" || exit 1
    ensure_exclude
    emit_defaults
    exit 0
    ;;
  clear)
    [[ $# -ge 1 ]] || fail BAD_ARGS "usage: config.sh clear <field> [...]"
    resolve_repo
    py clear "$config_file" "$@" || exit 1
    ensure_exclude
    emit_defaults
    exit 0
    ;;
  reset)
    [[ $# -le 1 ]] || fail BAD_ARGS "usage: config.sh reset [stage]"
    resolve_repo
    py reset "$config_file" "$@" || exit 1
    ensure_exclude
    emit_defaults
    exit 0
    ;;
  *)
    fail BAD_ARGS "usage: config.sh show | validate | set <field>=<value>... | clear <field>... | reset [stage]"
    ;;
esac

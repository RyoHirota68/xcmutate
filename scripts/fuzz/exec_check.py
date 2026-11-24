#!/usr/bin/env python3
"""Checks, on generated programs, P4 (with all mutants off the instrumented program behaves as the original) and
P5 (with one mutant on it behaves as the program with that one change written into the source).
usage: python3 exec_check.py <tool> <gen.py> <outdir> <seed_from> <seed_to> [--p5-every N] [--p5-max K] [--jobs 3] [--default-ops]
Results: <outdir>/results.jsonl (one line per program)."""
import sys, os, json, subprocess, time, re, random, shutil, argparse
from concurrent.futures import ThreadPoolExecutor
ap = argparse.ArgumentParser()
ap.add_argument('tool'); ap.add_argument('gen'); ap.add_argument('outdir'); ap.add_argument('lo', type=int); ap.add_argument('hi', type=int)
ap.add_argument('--p5-every', type=int, default=3); ap.add_argument('--p5-max', type=int, default=25); ap.add_argument('--jobs', type=int, default=3)
ap.add_argument('--default-ops', action='store_true'); ap.add_argument('--reached-only', action='store_true'); ap.add_argument('--source-dir')
A = ap.parse_args()
SWIFTC = subprocess.check_output(['xcrun', '-f', 'swiftc'], text=True).strip()
os.environ['SDKROOT'] = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
ENABLE = [] if A.default_ops else sum((['--enable-operator', o] for o in ['arithmetic', 'nil-coalescing-default', 'guard-removal', 'compound-assignment']), [])
ERR = re.compile(r'^(.*?):(\d+):(\d+): error: (.*)$')
REPLACES = {'early-return', 'loop-control', 'compound-assignment', 'switch-case-removal'}
REMOVES = {'side-effect-removal', 'empty-body'}

def run(cmd, cwd=None, timeout=120, env=None):
    try:
        e = dict(os.environ); e.pop('XCMUTATE_ACTIVE', None)
        if env: e.update(env)
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, timeout=timeout, env=e)
        return p.returncode, p.stdout.decode('utf8', 'replace'), p.stderr.decode('utf8', 'replace')
    except subprocess.TimeoutExpired:
        return 'timeout', '', ''
def compile_(src, exe):
    return run([SWIFTC, '-swift-version', '5', '-suppress-warnings', '-Onone', '-o', exe, src], timeout=300)
def execute(exe, env=None):
    rc, so, se = run([exe], timeout=3, env=env)
    return [rc, so]
def errs(se):
    return sorted({(int(m.group(2)), m.group(4)) for m in map(ERR.match, se.splitlines()) if m})
def naive(src, m):
    op = m['operator']
    rep = m['mutatedExpression'] if op in REPLACES else '()' if op in REMOVES else '(' + m['mutatedExpression'] + ')'
    return src[:m['region']['start']] + rep.encode() + src[m['region']['end']:]

def check(seed):
    d = os.path.join(A.outdir, 'w', str(seed)); shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    res = {'seed': seed}
    main = os.path.join(d, 'main.swift')
    if A.source_dir: shutil.copy(os.path.join(A.source_dir, '%d.swift' % seed), main)
    else: open(main, 'wb').write(subprocess.check_output([sys.executable, A.gen, str(seed)]))
    src = open(main, 'rb').read()
    rc, so, se = compile_(main, os.path.join(d, 'orig'))
    if rc != 0: res['status'] = 'gen-invalid'; res['errors'] = errs(se)[:5]; return res
    rc, so, se = run([A.tool, 'instrument', '--root', d, '--output-dir', os.path.join(d, 'inst'), '--manifest', os.path.join(d, 'm.json')] + ENABLE + ['main.swift'], cwd=d)
    res['instrument_rc'] = rc
    if rc != 0: res['status'] = 'instrument-fail'; res['stderr'] = se[-800:]; return res
    muts = json.load(open(os.path.join(d, 'm.json')))['files'][0]['mutants']
    res['mutants'] = len(muts)
    ops = {}
    for m in muts: ops[m['operator']] = ops.get(m['operator'], 0) + 1
    res['ops'] = ops
    rc, so, se = compile_(os.path.join(d, 'inst', 'main.swift'), os.path.join(d, 'instexe'))
    if rc != 0:
        e = errs(se); res['status'] = 'inst-compile-fail'; res['errors'] = e[:10]
        lines = {l for l, _ in e}
        res['suspects'] = [[m['id'], m['operator'], m['start']['line'], m['original'][:60], m['mutatedExpression'][:80]] for m in muts
                           if any(m['regionLines']['start'] <= l <= m['regionLines']['end'] for l in lines)][:30]
        if not e: res['stderr'] = se[-800:]
        return res
    o = execute(os.path.join(d, 'orig')); n = execute(os.path.join(d, 'instexe'))
    res['orig_rc'] = o[0]
    res['P4'] = 'ok' if o == n else 'fail'
    res['status'] = 'ok'
    if o != n: res['p4_diff'] = [o[0], n[0]]; return res
    if seed % A.p5_every != 0: os.remove(os.path.join(d, 'orig')); os.remove(os.path.join(d, 'instexe')); return res
    # Prefer the switches that the run with all mutants off evaluated (the mutants that are reached)
    tr = os.path.join(d, 'trace.txt')
    execute(os.path.join(d, 'instexe'), {'XCMUTATE_TRACE': tr})
    reached = set()
    if os.path.exists(tr):
        for l in open(tr):
            if l.startswith('R '): reached.add(int(l[2:]))
    res['reached'] = len(reached)
    rnd = random.Random(seed); pool = [m for m in muts if m['id'] in reached] if A.reached_only else muts
    sel = pool if len(pool) <= A.p5_max else rnd.sample(pool, A.p5_max)
    p5 = {'checked': 0, 'fail': [], 'naive_compile_fail': [], 'killed': 0, 'timeout': 0}
    for m in sel:
        ns = os.path.join(d, 'n%d.swift' % m['id']); ne = os.path.join(d, 'n%d' % m['id'])
        open(ns, 'wb').write(naive(src, m))
        rc, so, se = compile_(ns, ne)
        if rc != 0:
            p5['naive_compile_fail'].append([m['id'], m['operator'], m['start']['line'], errs(se)[:2]]); continue
        x = execute(ne); y = execute(os.path.join(d, 'instexe'), {'XCMUTATE_ACTIVE': str(m['id'])})
        p5['checked'] += 1
        if x != o: p5['killed'] += 1
        if x[0] == 'timeout': p5['timeout'] += 1
        if x != y: p5['fail'].append([m['id'], m['operator'], m['start']['line'], m['original'][:60], m['mutatedExpression'][:80], x[0], y[0]])
        else: os.remove(ns)
        os.remove(ne)
    res['P5'] = p5
    os.remove(os.path.join(d, 'orig')); os.remove(os.path.join(d, 'instexe'))
    return res

os.makedirs(A.outdir, exist_ok=True)
rp = os.path.join(A.outdir, 'results.jsonl'); done = set()
if os.path.exists(rp):
    for l in open(rp): done.add(json.loads(l)['seed'])
todo = [s for s in range(A.lo, A.hi) if s not in done]
with open(rp, 'a') as out, ThreadPoolExecutor(A.jobs) as ex:
    for n, r in enumerate(ex.map(check, todo)):
        out.write(json.dumps(r, ensure_ascii=False) + '\n'); out.flush()
        if n % 20 == 0: print(n, time.strftime('%H:%M:%S'), flush=True)
print('ALL_DONE')

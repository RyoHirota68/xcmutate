#!/usr/bin/env python3
"""Runs `xcmutate instrument` on every Swift file of a corpus and checks P1 (no crash), P2 (still parses),
P3 (still type-checks, with --typecheck), P6 (same lines) and P7 (deterministic).
usage: python3 -I corpus_check.py <tool> <corpus_root> <filelist> <outdir> [--typecheck] [--default-ops] [--jobs 3]
Results are appended to <outdir>/results.jsonl, one line per file (files already done are skipped on a rerun)."""
import sys, os, json, subprocess, time, re, hashlib, shutil, argparse
from concurrent.futures import ThreadPoolExecutor

ap = argparse.ArgumentParser()
ap.add_argument('tool'); ap.add_argument('root'); ap.add_argument('filelist'); ap.add_argument('outdir')
ap.add_argument('--typecheck', action='store_true'); ap.add_argument('--jobs', type=int, default=3)
ap.add_argument('--default-ops', action='store_true')
A = ap.parse_args()
SWIFTC = subprocess.check_output(['xcrun', '-f', 'swiftc'], text=True).strip()
os.environ['SDKROOT'] = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
ENABLE = [] if A.default_ops else sum((['--enable-operator', o] for o in ['arithmetic', 'nil-coalescing-default', 'guard-removal', 'compound-assignment']), [])
MARK = b'// xcmutate: generated helper. Do not edit.'
ENABLE = ENABLE + os.environ.get('MUTATOR_EXTRA', '').split()
ERR = re.compile(r'^(.*?):(\d+):(\d+): error: (.*)$')

def run(cmd, cwd=None, timeout=120):
    t = time.time()
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, timeout=timeout)
        return p.returncode, p.stdout.decode('utf8', 'replace'), p.stderr.decode('utf8', 'replace'), time.time() - t
    except subprocess.TimeoutExpired:
        return 'timeout', '', '', time.time() - t

def errors(text):
    s = set()
    for l in text.splitlines():
        m = ERR.match(l)
        if m: s.add((int(m.group(2)), m.group(4)))
    return s

def check(idx_rel):
    idx, rel = idx_rel
    d = os.path.join(A.outdir, 'w', '%05d' % idx)
    shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    res = {'idx': idx, 'file': rel}
    src = open(os.path.join(A.root, rel), 'rb').read()
    res['bytes'] = len(src); res['lines'] = src.count(b'\n')
    outs = []
    for k in (1, 2):
        rc, so, se, dt = run([A.tool, 'instrument', '--root', A.root, '--output-dir', os.path.join(d, 'r%d' % k), '--manifest', os.path.join(d, 'm%d.json' % k)] + ENABLE + [rel], cwd=A.root, timeout=300)
        outs.append((rc, so, se, dt))
    rc, so, se, dt = outs[0]
    res['rc'] = rc; res['time'] = round(dt, 3); res['stderr'] = se[-2000:]
    if rc not in (0, 2):
        res['P1'] = 'fail'
        return res
    res['P1'] = 'ok'
    if rc == 2: res['verification_failed'] = True
    try:
        man = json.load(open(os.path.join(d, 'm1.json')))['files'][0]
    except Exception as e:
        res['manifest_error'] = str(e); return res
    res['skipped'] = man.get('skippedReason')
    res['verification'] = man.get('verification')
    muts = man['mutants']; res['mutants'] = len(muts); res['ignored'] = len(man['ignored'])
    # P7
    p1 = os.path.join(d, 'r1', rel); p2 = os.path.join(d, 'r2', rel)
    o1 = open(p1, 'rb').read() if os.path.exists(p1) else None
    o2 = open(p2, 'rb').read() if os.path.exists(p2) else None
    m1 = open(os.path.join(d, 'm1.json'), 'rb').read(); m2 = open(os.path.join(d, 'm2.json'), 'rb').read()
    res['P7'] = 'ok' if (o1 == o2 and m1 == m2 and outs[0][0] == outs[1][0]) else 'fail'
    keys = [m['key'] for m in muts]
    res['dup_keys'] = len(keys) - len(set(keys))
    shutil.rmtree(os.path.join(d, 'r2'), ignore_errors=True); os.remove(os.path.join(d, 'm2.json'))
    if o1 is None:
        return res
    # P6: the number of lines, and the lines outside the ranges of the mutants, are as in the original
    if muts:
        pos = o1.find(MARK)
        body = o1[:pos] if pos >= 0 else o1
        ol = src.split(b'\n'); bl = body.split(b'\n')
        if not src.endswith(b'\n'): bl = bl[:-1] if bl and bl[-1] == b'' else bl
        if ol and ol[-1] == b'': ol = ol[:-1]
        if bl and bl[-1] == b'': bl = bl[:-1]
        p6 = 'ok'
        if pos < 0 or len(ol) != len(bl): p6 = 'fail-count'
        else:
            touched = set()
            for m in muts:
                for l in range(m['regionLines']['start'], m['regionLines']['end'] + 1): touched.add(l)
            bad = [i + 1 for i in range(len(ol)) if (i + 1) not in touched and ol[i] != bl[i]]
            if bad: p6 = 'fail-untouched'; res['p6_lines'] = bad[:10]
            # A range over several lines is put on one line; no switch may appear on a line outside the ranges
        res['P6'] = p6
    else:
        res['P6'] = 'ok' if o1 == src else 'fail-nomutant-changed'
    if not muts: return res
    # P2: swiftc -parse
    rc0, _, se0, _ = run([SWIFTC, '-frontend', '-parse', os.path.join(A.root, rel)], timeout=120)
    rc1, _, se1, _ = run([SWIFTC, '-frontend', '-parse', p1], timeout=120)
    e0, e1 = errors(se0), errors(se1)
    new = sorted(e1 - e0)
    res['parse_orig_errors'] = len(e0); res['P2'] = 'ok' if not new and (rc1 == rc0 or rc1 == 0) else 'fail'
    if new: res['p2_new'] = new[:8]
    if rc1 != rc0: res['p2_rc'] = [rc0, rc1]
    # P3: swiftc -typecheck
    if A.typecheck:
        lib = [] if rel.startswith('swift/') else ['-parse-as-library']
        base = [SWIFTC, '-typecheck', '-swift-version', '5', '-suppress-warnings'] + lib
        rc0, _, se0, t0 = run(base + [os.path.join(A.root, rel)], timeout=90)
        if rc0 == 'timeout' or (isinstance(rc0, int) and (rc0 < 0 or rc0 > 1)):
            res['P3'] = 'skip-orig-' + str(rc0); return res
        rc1, _, se1, t1 = run(base + [p1], timeout=180)
        e0, e1 = errors(se0), errors(se1)
        res['tc_orig_ok'] = (rc0 == 0); res['tc_orig_errors'] = len(e0); res['tc_time'] = [round(t0, 2), round(t1, 2)]
        if rc1 == 'timeout' or (isinstance(rc1, int) and (rc1 < 0 or rc1 > 1)):
            res['P3'] = 'fail-inst-' + str(rc1); res['p3_tail'] = se1[-600:]; return res
        new = sorted(e1 - e0); lost = sorted(e0 - e1)
        res['P3'] = 'ok' if not new else 'fail'
        if new: res['p3_new'] = new[:12]; res['p3_new_count'] = len(new)
        res['p3_lost_count'] = len(lost)
    return res

files = [l.strip() for l in open(A.filelist) if l.strip()]
os.makedirs(A.outdir, exist_ok=True)
rp = os.path.join(A.outdir, 'results.jsonl')
done = set()
if os.path.exists(rp):
    for l in open(rp):
        try: done.add(json.loads(l)['file'])
        except Exception: pass
todo = [(i, f) for i, f in enumerate(files) if f not in done]
print('todo', len(todo), 'done', len(done), flush=True)
with open(rp, 'a') as out, ThreadPoolExecutor(A.jobs) as ex:
    for n, r in enumerate(ex.map(check, todo)):
        out.write(json.dumps(r, ensure_ascii=False) + '\n'); out.flush()
        if n % 200 == 0: print(n, time.strftime('%H:%M:%S'), flush=True)
print('ALL_DONE')

#!/usr/bin/env python3
"""Generates a self-contained Swift program from a grammar, mechanically (for the comparison of runs, P4 / P5).
usage: python3 gen.py <seed> > main.swift
The same seed gives the same program. It reads no input, no random source and no clock, and prints its results."""
import random, sys

PRELUDE = '''
enum Kind { case a, b, c
    var weight: Int { switch self { case .a: return 1; case .b: return 2; case .c: return 3 } }
}
struct Boom: Error {}
final class Node {
    var value: Int; var name: String; var flag: Bool; var next: Node?
    var touched = 0
    init(_ value: Int, _ name: String, _ flag: Bool, _ next: Node? = nil) { self.value = value; self.name = name; self.flag = flag; self.next = next }
    func touch() { touched += 1 }
    func label() -> String { "\\(name)#\\(value)" }
}
final class Counter {
    var total = 0 { didSet { if total > 100 { total = 100 } } }
    var calls: [String] = []
    func add(_ n: Int) { total += n; calls.append("add") }
    func reset() { total = 0; calls.append("reset") }
    @discardableResult func take(_ n: Int) -> Int { total -= n; return total }
}
func emit(_ s: String) { print(s) }
func twice(_ x: Int) -> Int { x &* 2 }
func isEven(_ x: Int) -> Bool { x % 2 == 0 }
func parsePositive(_ s: String) throws -> Int { guard let v = Int(s), v >= 0 else { throw Boom() }; return v }
func describe(_ k: Kind) -> String { switch k { case .a: return "A"; case .b: return "B"; case .c: return "C" } }
func classify(_ x: Int) -> Kind { x < 0 ? .a : (x == 0 ? .b : .c) }
func asyncValue(_ x: Int) async -> Int { x &+ 1 }
func bump(_ x: inout Int, _ d: Int) { x += d }
'''
PARAMS = '_ a: Int, _ b: Int, _ s: String, _ o: Int?, _ xs: [Int], _ k: Kind, _ n: Node?, _ flag: Bool, _ ctr: Counter'
ARGS = [
    '3, 1, "Abc", 5, [1, 2, 3], .a, Node(4, "Nd", true, Node(7, " x ", false)), true',
    '1, 3, "", nil, [], .b, nil, false',
    '0, 0, "12", 0, [0, -1, 5, 5], .c, Node(0, "", false), true',
    '-2, 2, " Zz ", -3, [9], .a, Node(-1, "ABC", true, Node(2, "q", true, Node(3, "R", false))), false',
    '5, 5, "abc", 2, [2, 4, 6, 8], .b, nil, true',
    '7, -1, "7", nil, [3, 3], .c, Node(10, "abc", false), false',
]

class Gen:
    def __init__(self, seed):
        self.r = random.Random(seed); self.n = 0; self.nonl = 0; self.cur_async = False; self.v2 = seed >= 1000
        self.foundation = self.r.random() < 0.4
    def fresh(self, p='v'):
        self.n += 1; return '%s%d' % (p, self.n)
    def pick(self, xs): return self.r.choice(xs)
    def sp(self):
        """White space around an operator; now and then a line break or a comment (exercises the flattening to one line)"""
        x = self.r.random()
        if self.nonl: return ' /* c */ ' if x < 0.05 else ' '
        if x < 0.06: return '\n' + ' ' * 16
        if x < 0.09: return ' // a comment in the middle 🎌\n' + ' ' * 16
        if x < 0.11: return ' /* c */ '
        return ' '
    def lit(self): return str(self.pick([0, 1, 2, 3, 5, 10, -1]))
    def nz(self): return str(self.pick([1, 2, 3, 5]))
    def slit(self): return self.pick(['""', '"abc"', '"Abc"', '" x "', '"12"', '"none"', '"é🎌"'])

    def interp(self, t, env, d):
        self.nonl += 1
        try: return self.expr(t, env, d)
        finally: self.nonl -= 1

    def expr(self, t, env, d):
        r = self.r; E = lambda tt, dd=None: self.expr(tt, env, d - 1 if dd is None else dd)
        vs = env.get(t, [])
        if d <= 0 or r.random() < 0.15:
            if vs and r.random() < 0.75: return r.choice(vs)
            if t == 'Int': return self.lit()
            if t == 'Bool': return r.choice(vs) if vs else r.choice(['true', 'false'])
            if t == 'String': return self.slit()
            if t == 'Int?': return r.choice(vs) if vs else 'Int("x")'
            if t == '[Int]': return r.choice(vs) if vs else '[1, 2]'
            if t == 'Kind': return r.choice(vs) if vs else 'Kind.' + r.choice('abc')
            if t == 'Node?': return r.choice(vs) if vs else 'Optional<Node>.none'
        sp = self.sp
        if t == 'Int':
            c = r.randrange(22)
            if c < 3: return '%s%s%s%s%s' % (E('Int'), sp(), r.choice(['+', '-', '+', '*']), sp(), E('Int'))
            if c == 3: return '%s %s %s' % (E('Int'), r.choice(['/', '%']), self.nz())
            if c == 4: return '%s(%s, %s)' % (r.choice(['min', 'max']), E('Int'), E('Int'))
            if c == 5: return '(%s ? %s : %s)' % (E('Bool'), E('Int'), E('Int'))
            if c == 6: return '(%s ?? %s)' % (E('Int?'), self.lit())
            if c == 7: return '%s.count' % E('[Int]', 0)
            if c == 8: return '%s.count' % E('String', 0)
            if c == 9: return 'twice(%s)' % E('Int')
            if c == 10: return '(%s?.value ?? %s)' % (E('Node?', 0), self.lit())
            if c == 11: return '(%s?.next?.value ?? %s)' % (E('Node?', 0), self.lit())
            if c == 12: return '%s.filter({ $0 %s %s }).count' % (E('[Int]', 0), r.choice(['>', '<', '>=', '==', '!=']), E('Int', 0))
            if c == 13: return '%s.reduce(0, { $0 + $1 })' % E('[Int]', 0)
            if c == 14: return '((try? parsePositive(%s)) ?? %s)' % (E('String', 0), self.lit())
            if c == 15: return '(%s?.name.lowercased().count ?? %s)' % (E('Node?', 0), self.lit())
            if c == 16: return '%s.weight' % E('Kind', 0)
            if c == 17: return '(%s.first ?? %s) %s %s' % (E('[Int]', 0), self.lit(), r.choice('+-'), E('Int', 0))
            if c == 18: return '(%s)' % E('Int')
            if c == 19: return '%s.map({ $0 > %s ? $0 - 1 : $0 + 1 }).count' % (E('[Int]', 0), E('Int', 0))
            if c == 20: return 'ctr.total'
            return '-%s' % (r.choice(vs) if vs else '1')
        if t == 'Bool':
            c = r.randrange(26)
            if c < 5: return '%s%s%s%s%s' % (E('Int'), sp(), r.choice(['==', '!=', '<', '<=', '>', '>=']), sp(), E('Int'))
            if c < 8: return '%s%s%s%s%s' % (E('Bool'), sp(), r.choice(['&&', '||']), sp(), E('Bool'))
            if c == 8: return '!%s' % (r.choice(vs) if vs else 'flag')
            if c == 9: return '!(%s)' % E('Bool')
            if c == 10: return '%s.isEmpty' % E('String', 0)
            if c == 11: return '!%s.isEmpty' % E('[Int]', 0)
            if c == 12: return '%s.contains(%s)' % (E('[Int]', 0), E('Int'))
            if c == 13: return '%s.lowercased() == %s' % (E('String', 0), self.slit())
            if c == 14: return '%s %s nil' % (E('Int?', 0), r.choice(['==', '!=']))
            if c == 15: return 'isEven(%s)' % E('Int')
            if c == 16: return '%s.allSatisfy({ $0 %s %s })' % (E('[Int]', 0), r.choice(['>', '<=', '!=']), E('Int', 0))
            if c == 17: return '%s == .%s' % (E('Kind', 0), r.choice('abc'))
            if c == 18: return '(%s?.flag ?? %s)' % (E('Node?', 0), r.choice(['true', 'false']))
            if c == 19: return '%s?.flag == true' % E('Node?', 0)
            if c == 20: return '%s.hasPrefix("a")' % E('String', 0)
            if c == 21: return r.choice(['true', 'false'])
            if c == 22: return '(%s ? %s : %s)' % (E('Bool'), E('Bool'), E('Bool'))
            if c == 23: return '%s.contains(where: { $0 == %s || $0 > 5 })' % (E('[Int]', 0), E('Int', 0))
            if c == 24: return '%s?.next?.flag ?? (%s)' % (E('Node?', 0), E('Bool'))
            return '%s.uppercased() != %s.uppercased()' % (E('String', 0), E('String', 0))
        if t == 'String':
            c = r.randrange(13)
            if c == 0: return '%s.lowercased()' % E('String')
            if c == 1: return '%s.uppercased()' % E('String')
            if c == 2: return '"\\(%s)"' % self.interp('Int', env, d - 1)
            if c == 3: return '"<\\(%s ? "y" : "n")>"' % self.interp('Bool', env, d - 1)
            if c == 4: return '(%s ? %s : %s)' % (E('Bool'), E('String'), E('String'))
            if c == 5: return 'String(%s.prefix(2))' % E('String')
            if c == 6 and self.foundation: return '%s.trimmingCharacters(in: .whitespaces)' % E('String')
            if c == 7: return '(%s?.name.lowercased() ?? "-")' % E('Node?', 0)
            if c == 8: return '(%s?.next?.name.uppercased().lowercased() ?? %s)' % (E('Node?', 0), self.slit())
            if c == 9: return 'describe(%s)' % E('Kind')
            if c == 10: return 'String(describing: %s)' % E('Int?')
            if c == 11: return '(%s?.label() ?? "nil")' % E('Node?', 0)
            return '"\\(%s)|\\(%s)"' % (self.interp('Bool', env, d - 1), self.interp('String', env, 0))
        if t == 'Int?':
            c = r.randrange(8)
            if c == 0: return '%s.first' % E('[Int]', 0)
            if c == 1: return 'Int(%s)' % E('String', 0)
            if c == 2: return '%s?.value' % E('Node?', 0)
            if c == 3: return '(try? parsePositive(%s))' % E('String', 0)
            if c == 4: return '%s.first(where: { $0 > %s })' % (E('[Int]', 0), E('Int', 0))
            if c == 5: return '%s.map({ $0 + 1 })' % E('Int?', 0)
            if c == 6: return '%s?.next?.value' % E('Node?', 0)
            return '(%s ? %s : Int?.none)' % (E('Bool'), E('Int?', 0))
        if t == '[Int]':
            c = r.randrange(6)
            if c == 0: return '[%s, %s]' % (E('Int'), E('Int'))
            if c == 1: return '%s.filter({ $0 > %s })' % (E('[Int]', 0), E('Int', 0))
            if c == 2: return '%s.map({ $0 * 2 })' % E('[Int]', 0)
            if c == 3: return 'Array(%s.prefix(2))' % E('[Int]', 0)
            if c == 4: return '%s.sorted()' % E('[Int]', 0)
            if self.nonl: return '%s.sorted()' % E('[Int]', 0)
            return '%s.filter({ x in\n                    if x == %s { return false }\n                    return x != 3 })' % (E('[Int]', 0), E('Int', 0))
        if t == 'Kind':
            c = r.randrange(3)
            if c == 0: return 'Kind.' + r.choice('abc')
            if c == 1: return 'classify(%s)' % E('Int')
            return '(%s ? Kind.%s : %s)' % (E('Bool'), r.choice('abc'), E('Kind'))
        if t == 'Node?':
            return '%s?.next' % (r.choice(vs) if vs else 'n')
        raise Exception(t)

    def ret(self, rt, env, d=2):
        if rt == 'Void': return 'return'
        if rt == 'Kind' and self.r.random() < 0.6: return 'return .' + self.r.choice('abc')
        if rt == 'Int?' and self.r.random() < 0.2: return 'return nil'
        return 'return ' + self.expr(rt, env, d)

    def block(self, env, rt, loop, depth, n=None):
        env = {k: list(v) for k, v in env.items()}
        out = []
        for _ in range(n if n is not None else self.r.randint(1, 4)):
            out += self.stmt(env, rt, loop, depth)
        return out

    def ind(self, lines): return ['    ' + l for l in lines]

    def stmt(self, env, rt, loop, depth):
        r = self.r; X = lambda t, d=2: self.expr(t, env, d)
        B = lambda ll=None, n=None: self.ind(self.block(env, rt, loop if ll is None else ll, depth - 1, n))
        choices = ['let', 'let', 'emit', 'emit', 'emit', 'assign', 'compound', 'call', 'call', 'callopt']
        if depth > 0:
            choices += ['if', 'if', 'if', 'iflet', 'guard', 'guard', 'for', 'for', 'switch', 'switch', 'while', 'do', 'tryopt', 'closure',
                        'foreach', 'nested', 'ifexpr', 'defer', 'label', 'deferred', 'ifdef', 'ifcase', 'repeat', 'multi']
        if loop: choices += ['continue', 'break', 'guardloop']
        if self.v2 and depth > 0:
            choices += ['strswitch', 'optassign', 'optassign', 'inout', 'tuple', 'nilchain', 'ifcaseopt', 'whilelet', 'trycond', 'trycond', 'closurecall', 'ternstmt']
            if self.cur_async: choices += ['awaitcond', 'awaitcond', 'awaitcond']
        if depth > 0 and rt != 'Void' or (rt == 'Void' and r.random() < 0.3): choices += ['retif']
        c = r.choice(choices)
        if c == 'let':
            t = r.choice(['Int', 'Bool', 'String', 'Int?', '[Int]', 'Kind'])
            v = self.fresh(); e = X(t)
            mut = r.random() < 0.4
            line = '%s %s%s = %s' % ('var' if mut else 'let', v, ': ' + t if (r.random() < 0.3 or t in ('Int?', 'Kind', 'Bool', 'Int', '[Int]', 'String')) else '', e)
            env.setdefault(t, []).append(v)
            if mut: env.setdefault('mut' + t, []).append(v)
            return [line]
        if c == 'emit': 
            t = r.choice(['Int', 'Bool', 'String', 'Int?', 'Kind'])
            return ['emit("%s \\(%s)")' % (self.fresh('t'), self.interp(t, env, 2))]
        if c == 'assign':
            cands = [(t, v) for t in ['Int', 'Bool', 'String', '[Int]'] for v in env.get('mut' + t, [])]
            if not cands: return ['ctr.add(%s)' % X('Int')]
            t, v = r.choice(cands)
            if t == '[Int]' and r.random() < 0.5: return ['%s.append(%s)' % (v, X('Int'))]
            e = X(t)
            if e.strip('()') == v: e = {'Int': '7', 'Bool': 'true', 'String': '"z"', '[Int]': '[4]'}[t]
            return ['%s = %s' % (v, e)]
        if c == 'compound':
            vs = env.get('mutInt', [])
            if not vs: return ['ctr.total %s %s' % (r.choice(['+=', '-=']), X('Int', 1))]
            return ['%s %s %s' % (r.choice(vs), r.choice(['+=', '-=', '*=', '+=']), X('Int', 1))]
        if c == 'call':
            return [r.choice(['ctr.add(%s)' % X('Int'), 'ctr.reset()', '_ = twice(%s)' % X('Int'), 'ctr.take(%s)' % X('Int', 1),
                              '_ = ctr.take(%s)' % X('Int', 1), 'emit(%s)' % X('String'), 'n?.next?.touch()', 'try? emitChecked(%s)' % X('String', 1)])]
        if c == 'callopt': return ['n?.touch()']
        if c == 'if':
            out = ['if %s {' % X('Bool', 3)] + B()
            k = r.random()
            if k < 0.25: out += ['} else if %s {' % X('Bool')] + B() + ['} else {'] + B()
            elif k < 0.6: out += ['} else {'] + B()
            return out + ['}']
        if c == 'iflet':
            v = self.fresh('u'); env2 = dict(env); env2['Int'] = env.get('Int', []) + [v]
            cond = 'if let %s = %s' % (v, X('Int?'))
            if r.random() < 0.5: cond += ', ' + self.expr('Bool', env2, 2)
            if r.random() < 0.2: cond += ', ' + self.expr('Bool', env2, 1)
            out = [cond + ' {'] + self.ind(self.block(env2, rt, loop, depth - 1))
            if r.random() < 0.4: out += ['} else {'] + B()
            return out + ['}']
        if c == 'guard':
            k = r.random()
            if k < 0.4: cond = X('Bool', 3)
            elif k < 0.7: cond = '%s, %s' % (X('Bool'), X('Bool'))
            else:
                v = self.fresh('g'); cond = 'let %s = %s' % (v, X('Int?'))
                if r.random() < 0.5: cond += ', %s' % X('Bool')
                env.setdefault('Int', []).append(v)
            els = []
            if r.random() < 0.5: els.append('emit("%s")' % self.fresh('ge'))
            if r.random() < 0.2: els.append('ctr.add(1)')
            els.append(self.ret(rt, {k2: [x for x in v2 if not x.startswith('g')] for k2, v2 in env.items()}, 1))
            return ['guard %s else { %s }' % (cond, '; '.join(els))]
        if c == 'guardloop':
            return ['guard %s else { %s }' % (X('Bool'), r.choice(['continue', 'break']))]
        if c == 'for':
            v = self.fresh('x'); env2 = dict(env); env2['Int'] = env.get('Int', []) + [v]
            k = r.random()
            if k < 0.4: head = 'for %s in %s' % (v, X('[Int]', 1))
            elif k < 0.6: head = 'for %s in 0..<%s' % (v, r.choice(['2', '3', 'xs.count']))
            elif k < 0.8:
                i = self.fresh('i'); env2['Int'] = env2['Int'] + [i]
                head = 'for (%s, %s) in %s.enumerated()' % (i, v, X('[Int]', 0))
            else: head = 'for %s in %s where %s' % (v, X('[Int]', 0), self.expr('Bool', env2, 2))
            return [head + ' {'] + self.ind(self.block(env2, rt, True, depth - 1)) + ['}']
        if c == 'while':
            v = self.fresh('w')
            env2 = dict(env); env2['Int'] = env.get('Int', []) + [v]
            return ['var %s = 0' % v, 'while %s < %s {' % (v, r.choice(['2', '3'])), '    %s += 1' % v] + self.ind(self.block(env2, rt, True, depth - 1)) + ['}']
        if c == 'repeat':
            v = self.fresh('w')
            return ['var %s = 3' % v, 'repeat {'] + B(True) + ['    %s -= 1' % v, '} while %s > 0 && %s' % (v, X('Bool'))]
        if c == 'switch':
            k = r.random()
            if k < 0.4:
                out = ['switch %s {' % X('Int')]
                out += ['case 0:'] + B(None, r.randint(1, 2))
                if r.random() < 0.5: out += ['case 1, 2:'] + B(None, r.randint(1, 2))
                if r.random() < 0.4:
                    v = self.fresh('c'); env2 = dict(env); env2['Int'] = env.get('Int', []) + [v]
                    out += ['case let %s where %s:' % (v, self.expr('Bool', env2, 2))] + self.ind(self.block(env2, rt, loop, depth - 1, 1))
                if r.random() < 0.3: out += ['case 3...5:', '    break']
                out += ['default:'] + (B(None, 1) if r.random() < 0.7 else ['    break'])
            elif k < 0.7:
                out = ['switch %s {' % X('Kind')]
                out += ['case .a:'] + B(None, r.randint(1, 2))
                if r.random() < 0.5: out += ['case .b where %s:' % X('Bool')] + B(None, 1)
                if r.random() < 0.5: out += ['case .b, .c:'] + B(None, 1)
                out += ['default:'] + (B(None, 1) if r.random() < 0.7 else ['    break'])
            else:
                out = ['switch (%s, %s) {' % (X('Bool'), X('Bool'))]
                out += ['case (true, _):'] + B(None, 1) + ['case (false, true):'] + B(None, 1) + ['default:'] + B(None, 1)
            return out + ['}']
        if c == 'do':
            v = self.fresh('d'); env2 = dict(env); env2['Int'] = env.get('Int', []) + [v]
            return ['do {', '    let %s = try parsePositive(%s)' % (v, X('String', 1))] + self.ind(self.block(env2, rt, loop, depth - 1)) + ['} catch {'] + B(None, 1) + ['}']
        if c == 'tryopt':
            v = self.fresh('p'); k = r.random()
            if k < 0.4:
                out = ['let %s: Int? = try? parsePositive(%s)' % (v, X('String', 1))]
                env.setdefault('Int?', []).append(v)
                return out
            env2 = dict(env); env2['Int'] = env.get('Int', []) + [v]
            return ['if let %s: Int = try? parsePositive(%s) {' % (v, X('String', 1))] + self.ind(self.block(env2, rt, loop, depth - 1)) + ['}']
        if c == 'closure':
            v = self.fresh('f'); q = self.fresh('q'); env2 = {k2: list(v2) for k2, v2 in env.items() if not k2.startswith('mut')}
            env2['Int'] = env2.get('Int', []) + [q]
            old = self.cur_async; self.cur_async = False
            body = self.ind(self.block(env2, 'Bool', False, depth - 1, r.randint(0, 2))) + ['    return ' + self.expr('Bool', env2, 2)]
            self.cur_async = old
            res = self.fresh(); out = ['let %s = { (%s: Int) -> Bool in' % (v, q)] + body + ['}', 'let %s = %s(%s)' % (res, v, X('Int', 1))]
            env.setdefault('Bool', []).append(res)
            return out
        if c == 'foreach':
            return ['%s.forEach { e in' % X('[Int]', 1), '    emit("%s \\(e %s %s)")' % (self.fresh('fe'), r.choice(['>', '==', '<=']), self.interp('Int', env, 1)), '    if e > 2 { ctr.add(e) }', '}']
        if c == 'nested':
            v = self.fresh('inner'); q = self.fresh('q'); t = r.choice(['Int', 'Bool', 'String'])
            env2 = {k2: list(v2) for k2, v2 in env.items() if not k2.startswith('mut')}
            env2['Int'] = env2.get('Int', []) + [q]
            old = self.cur_async; self.cur_async = False
            if r.random() < 0.4: body = ['    ' + self.expr(t, env2, 3)]
            else: body = self.ind(self.block(env2, t, False, depth - 1, r.randint(1, 2))) + ['    ' + self.ret(t, env2)]
            self.cur_async = old
            return ['func %s(_ %s: Int) -> %s {' % (v, q, t)] + body + ['}', 'emit("%s \\(%s(%s))")' % (self.fresh('t'), v, self.interp('Int', env, 1))]
        if c == 'ifexpr':
            v = self.fresh(); t = r.choice(['Int', 'String', 'Bool'])
            env.setdefault(t, [])
            if r.random() < 0.5: line = 'let %s: %s = if %s { %s } else { %s }' % (v, t, X('Bool'), X(t, 1), X(t, 1))
            else: line = 'let %s: %s = switch %s { case 0: %s; case 1: %s; default: %s }' % (v, t, X('Int', 1), X(t, 1), X(t, 1), X(t, 1))
            env[t].append(v)
            return [line]
        if c == 'defer': return ['defer { emit("%s"); ctr.add(1) }' % self.fresh('df')]
        if c == 'label':
            x = self.fresh('x'); y = self.fresh('y'); env2 = dict(env); env2['Int'] = env.get('Int', []) + [x, y]
            lb = self.fresh('outer')
            return ['%s: for %s in %s {' % (lb, x, X('[Int]', 0)), '    for %s in 0..<3 {' % y,
                    '        if %s { continue %s }' % (self.expr('Bool', env2, 2), lb), '        if %s { break %s }' % (self.expr('Bool', env2, 2), lb),
                    '        if %s { continue }' % self.expr('Bool', env2, 1),
                    '        emit("%s \\(%s)")' % (self.fresh('t'), self.interp('Int', env2, 1)), '    }', '}']
        if c == 'deferred':
            v = self.fresh(); env2 = env
            out = ['let %s: Int' % v, 'if %s { %s = %s } else { %s = %s }' % (X('Bool'), v, X('Int', 1), v, X('Int', 1))]
            env.setdefault('Int', []).append(v)
            return out
        if c == 'ifdef':
            return ['#if DEBUG'] + B(None, 1) + ['#else'] + B(None, 1) + ['#endif']
        if c == 'ifcase':
            return ['if case .%s = %s, %s {' % (r.choice('abc'), X('Kind', 1), X('Bool'))] + B() + ['}']
        if c == 'multi':
            # A condition and a call over several lines
            return ['if %s\n            && %s // a trailing comment\n            || %s {' % (X('Bool'), X('Bool'), X('Bool'))] + B() + ['}',
                    'ctr.add(\n    %s\n)' % X('Int')]
        if c == 'strswitch':
            t = self.fresh('t'); env2 = dict(env); env2['String'] = env.get('String', []) + [t]
            return ['switch %s {' % X('String', 1), 'case "abc", "12":'] + B(None, 1) + ['case let %s where %s.count > %s || %s:' % (t, t, X('Int', 1), self.expr('Bool', env2, 1))] + \
                self.ind(self.block(env2, rt, loop, depth - 1, 1)) + ['case "":', '    break', 'default:'] + B(None, 1) + ['}']
        if c == 'optassign':
            return [r.choice(['n?.value %s %s' % (r.choice(['+=', '-=', '*=', '=']), X('Int', 1)), 'n?.next?.flag = %s' % X('Bool'), 'n?.name = %s' % X('String', 1),
                              'n?.next?.value += %s' % X('Int', 1), 'n?.next = %s ? nil : n?.next' % X('Bool')])]
        if c == 'inout':
            vs = env.get('mutInt', [])
            if not vs:
                v = self.fresh(); out = ['var %s: Int = %s' % (v, X('Int', 1)), 'bump(&%s, %s)' % (v, X('Int', 1))]
                env.setdefault('Int', []).append(v); env.setdefault('mutInt', []).append(v)
                return out
            return ['bump(&%s, %s)' % (r.choice(vs), X('Int'))]
        if c == 'tuple':
            p = self.fresh('p'); q = self.fresh('q'); env2 = dict(env); env2['Int'] = env.get('Int', []) + [p, q]
            return ['let (%s, %s) = (%s, %s)' % (p, q, X('Int', 1), X('Int', 1)), 'if (%s, %s) == (%s, %s) || %s > %s {' % (p, q, X('Int', 1), X('Int', 0), p, q)] + \
                self.ind(self.block(env2, rt, loop, depth - 1)) + ['}']
        if c == 'nilchain':
            v = self.fresh(); line = 'let %s: Int = %s ?? %s ?? %s' % (v, X('Int?', 1), X('Int?', 1), self.lit())
            env.setdefault('Int', []).append(v); return [line]
        if c == 'ifcaseopt':
            v = self.fresh('u'); env2 = dict(env); env2['Int'] = env.get('Int', []) + [v]
            if r.random() < 0.5: return ['if case let %s? = %s, %s {' % (v, X('Int?', 1), self.expr('Bool', env2, 2))] + self.ind(self.block(env2, rt, loop, depth - 1)) + ['}']
            env.setdefault('Int', []).append(v)
            return ['guard case .some(let %s) = %s else { %s }' % (v, X('Int?', 1), self.ret(rt, env2 if False else {k2: [x for x in v2 if x != v] for k2, v2 in env.items()}, 1))]
        if c == 'whilelet':
            it = self.fresh('it'); e = self.fresh('e'); env2 = dict(env); env2['Int'] = env.get('Int', []) + [e]
            return ['var %s = %s.makeIterator()' % (it, X('[Int]', 1)), 'while let %s = %s.next(), %s {' % (e, it, self.expr('Bool', env2, 2))] + self.ind(self.block(env2, rt, True, depth - 1)) + ['}']
        if c == 'trycond':
            z = self.fresh('z'); env2 = dict(env); env2['Int'] = env.get('Int', []) + [z]
            return ['do {', '    if try parsePositive(%s) %s %s %s %s {' % (X('String', 1), r.choice(['>', '==', '<=']), X('Int', 1), r.choice(['&&', '||']), X('Bool'))] + \
                self.ind(B()) + ['    }', '    let %s = try parsePositive(%s) %s %s' % (z, X('String', 1), r.choice(['+', '-', '*']), X('Int', 1)),
                '    emit("%s \\(%s > %s ? %s : try parsePositive("5"))")' % (self.fresh('t'), z, self.lit(), z)] + self.ind(self.block(env2, rt, loop, depth - 1, 1)) + ['} catch {'] + B(None, 1) + ['}']
        if c == 'awaitcond':
            z = self.fresh('z')
            out = ['if await asyncValue(%s) %s %s %s %s {' % (X('Int', 1), r.choice(['>', '!=', '<']), X('Int', 1), r.choice(['&&', '||']), X('Bool'))] + B() + ['}',
                    'let %s: Int = await asyncValue(%s) > %s ? %s : await asyncValue(%s)' % (z, X('Int', 1), X('Int', 1), X('Int', 1), X('Int', 1))]
            env.setdefault('Int', []).append(z)
            return out
        if c == 'closurecall':
            g = self.fresh('g')
            return ['let %s: () -> Bool = { %s }' % (g, X('Bool')), 'if %s() %s %s { emit("%s") }' % (g, r.choice(['&&', '||']), X('Bool'), self.fresh('t'))]
        if c == 'ternstmt':
            return ['%s ? ctr.add(%s) : ctr.reset()' % (X('Bool'), X('Int', 1)), '_ = %s ? emit("%s") : emit(%s)' % (X('Bool'), self.fresh('t'), X('String', 1))]
        if c == 'continue': return ['if %s { continue }' % X('Bool')]
        if c == 'break': return ['if %s { break }' % X('Bool')]
        if c == 'retif': return ['if %s { %s }' % (X('Bool'), self.ret(rt, env))]
        raise Exception(c)

    def base_env(self):
        return {'Int': ['a', 'b'], 'Bool': ['flag'], 'String': ['s'], 'Int?': ['o'], '[Int]': ['xs'], 'Kind': ['k'], 'Node?': ['n']}

    def function(self, name, prefix=''):
        r = self.r; env = self.base_env()
        rt = r.choice(['Int', 'Bool', 'Bool', 'String', 'Int?', 'Kind', 'Void', 'Void', '[Int]'])
        form = r.random()
        mods = ''
        k = r.random()
        if k < 0.12: mods = ' throws'
        elif k < 0.2: mods = ' async'
        sig = '%sfunc %s(%s)%s%s {' % (prefix, name, PARAMS, mods, '' if rt == 'Void' else ' -> ' + rt)
        self.cur_async = (mods == ' async')
        if self.v2 and rt in ('Int', 'String', 'Bool') and form > 0.88:
            # The body is one switch / if expression
            wrap = {'Int': '(%s) + 0', 'String': '"\\(%s)"', 'Bool': '(%s) == true'}[rt]
            val = lambda: wrap % (self.interp(rt, env, 2) if rt == 'String' else self.expr(rt, env, 2))
            if r.random() < 0.5: body = ['switch k {', 'case .a: ' + val(), 'case .b where %s: %s' % (self.expr('Bool', env, 2), val()), 'default: ' + val(), '}']
            else: body = ['if %s { %s } else if %s { %s } else { %s }' % (self.expr('Bool', env, 2), val(), self.expr('Bool', env, 2), val(), val())]
            self.cur_async = False
            return rt, mods, [sig] + self.ind(body) + ['}']
        if rt != 'Void' and form < 0.12:
            return rt, mods, [sig, '    ' + self.expr(rt, env, 4), '}']
        if rt == 'Bool' and form < 0.3:
            # Sets a flag and returns it at the end (the shape that early-return mutates)
            fl = self.fresh('found'); x = self.fresh('x'); env2 = dict(env); env2['Int'] = env['Int'] + [x]
            body = ['var %s = false' % fl, 'for %s in xs {' % x] + self.ind(self.block(env2, rt, True, 1, r.randint(0, 2)))
            body += ['    if %s { %s = true }' % (self.expr('Bool', env2, 2), fl)] + self.ind(self.block(env2, rt, True, 1, r.randint(0, 1))) + ['}']
            body += [r.choice(['return %s' % fl, 'return %s ? %s : %s' % (fl, self.expr('Bool', env, 1), self.expr('Bool', env, 1))])]
            return rt, mods, [sig] + self.ind(body) + ['}']
        if rt == 'Void' and form < 0.25:
            # A body of calls and guards that leave early
            body = ['guard %s else { return }' % self.expr('Bool', env, 2), 'ctr.add(%s)' % self.expr('Int', env, 2), 'emit(%s)' % self.expr('String', env, 2)]
            return rt, mods, [sig] + self.ind(body) + ['}']
        body = self.block(env, rt, False, 3 if r.random() < 0.3 else 2, r.randint(2, 5))
        if mods == ' throws' : body.insert(0, 'if %s { throw Boom() }' % self.expr('Bool', env, 2))
        if mods == ' async': body.insert(0, 'let aw = await asyncValue(a)'); body.append('emit("aw \\(aw > b)")'); body.append('if await asyncValue(b) > a { emit("aw2") }')
        if rt != 'Void': body.append(self.ret(rt, env, 3))
        self.cur_async = False
        return rt, mods, [sig] + self.ind(body) + ['}']

    def program(self):
        r = self.r
        out = []
        if self.foundation: out.append('import Foundation')
        out.append(PRELUDE)
        out.append('func emitChecked(_ s: String) throws { if s.isEmpty { throw Boom() }; emit(s) }')
        funcs = []
        for i in range(r.randint(2, 4)):
            name = 'f%d' % i
            rt, mods, lines = self.function(name)
            funcs.append((name, rt, mods, ''))
            out += lines
        # Methods and computed properties of a type
        out.append('struct Calc {')
        out.append('    var base: Int')
        out.append('    var hist: [Int] = []')
        out.append('    let flag = true; let n: Node? = nil; let ctr = Counter()')
        env = {'Int': ['base'], '[Int]': ['hist'], 'Bool': [], 'String': [], 'Int?': [], 'Kind': [], 'Node?': []}
        out.append('    var isBig: Bool { %s }' % self.expr('Bool', env, 3))
        out.append('    var score: Int {')
        out += self.ind(self.ind(['if %s { return %s }' % (self.expr('Bool', env, 2), self.expr('Int', env, 2)), 'return %s' % self.expr('Int', env, 2)]))
        out.append('    }')
        out.append('    var tag: String { get { %s } set { base = newValue.count > %s ? 1 : 2; hist.append(base) } }' % ('base > 2 ? "big" : "small"', self.lit()))
        out.append('    subscript(i: Int) -> Int { i >= 0 && i < hist.count ? hist[i] : %s }' % self.lit())
        out.append('    mutating func push(_ v: Int, limit: Int = %s) {' % r.choice(['3', '2 > 1 ? 3 : 5', 'max(1, 4)', '1 + 2', 'true && false ? 1 : 9']))
        out += self.ind(self.ind(['guard v != limit else { return }', 'hist.append(v)', 'if hist.count > 3 { hist.removeFirst() }', 'base += v > 0 ? 1 : -1']))
        out.append('    }')
        out.append('    static func make(_ v: Int) -> Calc? { v < 0 ? nil : Calc(base: v) }')
        rt, mods, lines = self.function('m', '')
        out += self.ind(lines); out.append('}')
        funcs.append(('calc.m', rt, mods, ''))
        # The driver
        out.append('let table: [(Int, Int, String, Int?, [Int], Kind, Node?, Bool)] = [')
        for a in ARGS: out.append('    (%s),' % a)
        out.append(']')
        out.append('for (row, t) in table.enumerated() {')
        out.append('    let ctr = Counter()')
        out.append('    var calc = Calc(base: t.0)')
        out.append('    calc.push(t.1); calc.push(t.0, limit: t.1); calc.tag = t.2')
        out.append('    emit("calc \\(row) \\(calc.isBig) \\(calc.score) \\(calc.tag) \\(calc[t.1]) \\(calc.hist) \\(Calc.make(t.1)?.base ?? -9)")')
        for name, rt, mods, _ in funcs:
            call = '%s(t.0, t.1, t.2, t.3, t.4, t.5, t.6, t.7, ctr)' % name
            if mods == ' async': call = 'await ' + call
            if mods == ' throws':
                if rt == 'Void': out.append('    do { try %s; emit("%s \\(row) ok") } catch { emit("%s \\(row) threw") }' % (call, name, name))
                else: out.append('    do { let r = try %s; emit("%s \\(row) \\(String(describing: r))") } catch { emit("%s \\(row) threw") }' % (call, name, name))
            elif rt == 'Void': out.append('    %s; emit("%s \\(row) done")' % (call, name))
            else: out.append('    emit("%s \\(row) \\(String(describing: %s))")' % (name, call))
        out.append('    emit("ctr \\(row) \\(ctr.total) \\(ctr.calls.count) \\(t.6?.touched ?? -1) \\(t.6?.next?.touched ?? -1)")')
        out.append('}')
        return '\n'.join(out) + '\n'

if __name__ == '__main__':
    sys.stdout.write(Gen(int(sys.argv[1])).program())

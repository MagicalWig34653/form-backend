#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Coverage helper for CI and local use (standard library only).

  metrics <swift|pwa|php> <file>                  print JSON metrics (percent values)
  lines   <swift|pwa|php> <file>                  print JSON {file: {line: hits}} (executable lines only)
  diff    <swift|pwa|php> <file> <base-ref> [--min 90]   coverage of the lines changed since <base-ref>
  exclusions-check                                pwa exclusions in coverage-exclusions == vite.config.ts

Inputs: swift = llvm-cov export JSON (SwiftPM codecov/*.json), pwa = lcov.info (vitest v8, paths relative to pwa/),
php = merged JSON written by scripts/coverage-php.sh ({file: {line: hits}}).
"""
import json, os, re, subprocess, sys

ROOT = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))


def exclusions(area):
    out = []
    with open(os.path.join(ROOT, 'coverage-exclusions')) as f:
        for n, raw in enumerate(f, 1):
            line = raw.strip()
            if not line or line.startswith('#'):
                continue
            m = re.match(r'^(\w+):\s*(.+?)\s*\|\s*(\S.*)$', line)
            if not m:
                sys.exit(f'coverage-exclusions:{n}: entry needs "<area>: <pattern> | <reason>"')
            if m.group(1) == area:
                out.append(m.group(2))
    return out


def rel(path):
    """Repo-relative path; llvm-cov paths come from inside the container (/src/...)."""
    p = path.replace('\\', '/')
    for prefix in (ROOT + '/', '/src/'):
        if p.startswith(prefix):
            return p[len(prefix):]
    return p.lstrip('/')


def swift_lines(doc):
    """Per-line hit counts from llvm-cov segments [line, col, count, hasCount, isRegionEntry, isGap]."""
    pats = [re.compile(p) for p in exclusions('swift')]
    res = {}
    for datum in doc['data']:
        for fl in datum['files']:
            name = fl['filename']
            if any(p.search(name) for p in pats):
                continue
            segs = fl.get('segments', [])
            lines, wrap, i = {}, None, 0
            while i < len(segs):
                ln = segs[i][0]
                cur = []
                while i < len(segs) and segs[i][0] == ln:
                    cur.append(segs[i])
                    i += 1
                counts = [s[2] for s in cur if s[3] and not s[5]]
                if wrap is not None:
                    counts.append(wrap)
                if counts:
                    lines[ln] = max(counts)
                last = cur[-1]
                if last[3]:
                    wrap = None if last[5] else last[2]
                else:
                    wrap = None
            if lines:
                res[rel(name)] = lines
    return res


def glob_re(g):
    return re.compile(re.escape(g).replace(r'\*\*/', '(.*/)?').replace(r'\*', '[^/]*') + '$')


def pwa_lines(path):
    pats = [glob_re(g) for g in exclusions('pwa')]
    res, cur = {}, None
    for raw in open(path):
        raw = raw.strip()
        if raw.startswith('SF:'):
            cur = raw[3:]
            res[cur] = {}
        elif raw.startswith('DA:') and cur is not None:
            ln, hits = raw[3:].split(',')[:2]
            res[cur][int(ln)] = int(hits)
    out = {}
    for f, v in res.items():
        short = f[len(ROOT) + 5:] if f.startswith(ROOT + '/pwa/') else f
        if any(p.search(short) for p in pats):
            continue
        out[rel(f) if f.startswith(ROOT) else 'pwa/' + f] = v
    return out


def php_lines(path):
    pats = [re.compile(p) for p in exclusions('php')]
    doc = json.load(open(path))
    return {rel(f): {int(k): v for k, v in lines.items()} for f, lines in doc.items()
            if not any(p.search(f) for p in pats)}


def load_lines(kind, path):
    if kind == 'swift':
        return swift_lines(json.load(open(path)))
    if kind == 'pwa':
        return pwa_lines(path)
    if kind == 'php':
        return php_lines(path)
    sys.exit('unknown kind ' + kind)


def pct(a, b):
    return round(100.0 * a / b, 2) if b else 100.0


def swift_metrics(path):
    """Totals as llvm-cov reports them (per-file summaries), minus the excluded files."""
    pats = [re.compile(p) for p in exclusions('swift')]
    tot = cov = files = 0
    for datum in json.load(open(path))['data']:
        for fl in datum['files']:
            if any(p.search(fl['filename']) for p in pats):
                continue
            files += 1
            tot += fl['summary']['lines']['count']
            cov += fl['summary']['lines']['covered']
    return {'lines': pct(cov, tot), 'lines_covered': cov, 'lines_total': tot, 'files': files}


def metrics(kind, path):
    if kind == 'swift':
        return swift_metrics(path)
    lines = load_lines(kind, path)
    tot = sum(len(v) for v in lines.values())
    cov = sum(1 for v in lines.values() for h in v.values() if h > 0)
    m = {'lines': pct(cov, tot), 'lines_covered': cov, 'lines_total': tot, 'files': len(lines)}
    if kind == 'pwa':
        bf = bh = 0
        for raw in open(path):
            if raw.startswith('BRF:'):
                bf += int(raw[4:])
            elif raw.startswith('BRH:'):
                bh += int(raw[4:])
        m['branches'] = pct(bh, bf)
    return m


def changed_lines(base):
    out = subprocess.run(['git', 'diff', '-U0', '--no-color', '--diff-filter=AM', base + '...HEAD'], cwd=ROOT,
                         capture_output=True, text=True, check=True).stdout
    res, cur = {}, None
    for l in out.splitlines():
        if l.startswith('+++ b/'):
            cur = l[6:]
            res[cur] = set()
        elif l.startswith('@@') and cur:
            m = re.search(r'\+(\d+)(?:,(\d+))?', l)
            s, n = int(m.group(1)), int(m.group(2) if m.group(2) is not None else 1)
            res[cur].update(range(s, s + n))
    return res


def diff(kind, path, base, minimum):
    lines, ch = load_lines(kind, path), changed_lines(base)
    tot = cov = 0
    miss = []
    for f, ls in ch.items():
        if f not in lines:
            continue
        for ln in sorted(ls):
            if ln in lines[f]:
                tot += 1
                if lines[f][ln] > 0:
                    cov += 1
                else:
                    miss.append(f'{f}:{ln}')
    if tot == 0:
        print(f'{kind}: no changed executable lines, diff coverage not applicable')
        return 0
    p = pct(cov, tot)
    print(f'{kind}: diff coverage {p}% ({cov}/{tot} changed executable lines, minimum {minimum}%)')
    if miss:
        print('  uncovered changed lines: ' + ', '.join(miss[:40]) + (' ...' if len(miss) > 40 else ''))
    return 0 if p >= minimum else 1


def exclusions_check():
    cfg = open(os.path.join(ROOT, 'pwa/vite.config.ts')).read()
    m = re.search(r'exclude:\s*\[(.*?)\]', cfg, re.S)
    inv = set(re.findall(r"'([^']+)'", m.group(1))) if m else set()
    inf = set(exclusions('pwa'))
    if inv != inf:
        print(f'pwa exclusions differ: only in vite.config.ts {sorted(inv - inf)}, only in coverage-exclusions {sorted(inf - inv)}')
        return 1
    print('pwa exclusions consistent')
    return 0


if __name__ == '__main__':
    a = sys.argv[1:]
    if len(a) >= 3 and a[0] == 'metrics':
        print(json.dumps(metrics(a[1], a[2])))
    elif len(a) >= 3 and a[0] == 'lines':
        print(json.dumps(load_lines(a[1], a[2])))
    elif len(a) >= 4 and a[0] == 'diff':
        mn = float(a[a.index('--min') + 1]) if '--min' in a else 90.0
        sys.exit(diff(a[1], a[2], a[3], mn))
    elif a == ['exclusions-check']:
        sys.exit(exclusions_check())
    else:
        sys.exit(__doc__)

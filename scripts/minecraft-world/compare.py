#!/usr/bin/env python3
"""Compares two Minecraft saves chunk by chunk, to measure whether
generate.sh gives the same world twice from the same seed.

    python3 -I scripts/minecraft-world/compare.py SAVE_A SAVE_B [--dimension minecraft:overworld]

Reads every region file of the dimension (region/, entities/, poi/) in both
saves, decompresses each chunk and compares what it holds: block states and
biomes per section (decoded to one state per block, so palette order does not
matter), light, heightmaps, block entities, scheduled ticks, structures and
entities (without their UUIDs, which the game draws from an unseeded random,
and with their attribute lists sorted, which it writes in hash-map order).
LastUpdate and InhabitedTime are tick counters and are left out. Prints a
summary and the first differing blocks. When both saves carry generate.sh's
lerping-generate.json, chunks inside its square and outside it are reported
apart and the exit status is 1 only if the square differs; otherwise it is 1
if anything differs.
"""
import os
import struct
import sys
import zlib
import gzip
from collections import Counter, defaultdict

import numpy as np

IGNORED = {'LastUpdate', 'InhabitedTime'}


# --- NBT ---------------------------------------------------------------------

class Reader:
    def __init__(self, b):
        self.b = b
        self.i = 0

    def take(self, n):
        s = self.b[self.i:self.i + n]
        self.i += n
        return s

    def u(self, fmt, n):
        v = struct.unpack_from(fmt, self.b, self.i)[0]
        self.i += n
        return v

    def string(self):
        n = self.u('>H', 2)
        return self.take(n).decode('utf-8', 'surrogatepass')

    def payload(self, t):
        if t == 1: return self.u('>b', 1)
        if t == 2: return self.u('>h', 2)
        if t == 3: return self.u('>i', 4)
        if t == 4: return self.u('>q', 8)
        if t == 5: return self.u('>f', 4)
        if t == 6: return self.u('>d', 8)
        if t == 7: return ('B', self.take(self.u('>i', 4)))
        if t == 8: return self.string()
        if t == 9:
            et = self.u('>b', 1)
            n = self.u('>i', 4)
            return [self.payload(et) for _ in range(n)]
        if t == 10:
            d = {}
            while True:
                ct = self.u('>b', 1)
                if ct == 0:
                    return d
                k = self.string()
                d[k] = self.payload(ct)
        if t == 11: return ('I', self.take(4 * self.u('>i', 4)))
        if t == 12: return ('L', self.take(8 * self.u('>i', 4)))
        raise ValueError(f'bad NBT tag {t} at {self.i}')


def nbt(b):
    r = Reader(b)
    t = r.u('>b', 1)
    if t != 10:
        raise ValueError('NBT root is not a compound')
    r.string()
    return r.payload(10)


# --- Region files ------------------------------------------------------------

def region_chunks(path):
    """{(cx, cz): nbt dict} for one .mca file."""
    data = open(path, 'rb').read()
    if len(data) < 8192:
        return {}
    rx, rz = (int(p) for p in os.path.basename(path).split('.')[1:3])
    out = {}
    for i in range(1024):
        loc = struct.unpack_from('>I', data, 4 * i)[0]
        off, cnt = loc >> 8, loc & 0xFF
        if off == 0 and cnt == 0:
            continue
        p = off * 4096
        n, kind = struct.unpack_from('>IB', data, p)
        body = data[p + 5:p + 4 + n]
        if kind & 0x80:
            raise SystemExit(f'{path}: chunk {i} is stored in an external .mcc file, not handled')
        if kind == 1: raw = gzip.decompress(body)
        elif kind == 2: raw = zlib.decompress(body)
        elif kind == 3: raw = body
        else:
            raise SystemExit(f'{path}: chunk {i} uses compression {kind}, not handled (set region-file-compression=deflate)')
        out[(rx * 32 + (i & 31), rz * 32 + (i >> 5))] = nbt(raw)
    return out


def dimension_dir(save, dim):
    ns, name = dim.split(':')
    d = os.path.join(save, 'dimensions', ns, name)
    if not os.path.isdir(d):
        raise SystemExit(f'{save}: no {d}')
    return d


def load_folder(folder):
    chunks = {}
    if not os.path.isdir(folder):
        return chunks
    for f in sorted(os.listdir(folder)):
        if f.endswith('.mca'):
            chunks.update(region_chunks(os.path.join(folder, f)))
    return chunks


# --- Decoding ----------------------------------------------------------------

def state_name(s):
    props = s.get('Properties')
    if not props:
        return s['Name']
    return s['Name'] + '[' + ','.join(f'{k}={v}' for k, v in sorted(props.items())) + ']'


def unpack(container, n, min_bits, names):
    """Paletted container -> array of n strings."""
    pal = [names(p) for p in container['palette']]
    if len(pal) == 1:
        return np.full(n, pal[0], dtype=object)
    bits = max(min_bits, (len(pal) - 1).bit_length())
    longs = np.frombuffer(container['data'][1], dtype='>u8').astype(np.uint64)
    per = 64 // bits
    idx = np.arange(n)
    words = longs[idx // per]
    vals = (words >> ((idx % per) * bits).astype(np.uint64)) & np.uint64((1 << bits) - 1)
    return np.array(pal, dtype=object)[vals.astype(np.int64)]


def canon(v):
    """Hashable, order-normalised form of an NBT value for comparison."""
    if isinstance(v, dict):
        return tuple(sorted((k, canon(x)) for k, x in v.items()))
    if isinstance(v, list):
        return tuple(canon(x) for x in v)
    return v


def strip_uuids(v):
    """Entity data without UUIDs, and with `attributes` (which the game writes
    in hash-map order, different from run to run) sorted by id."""
    if isinstance(v, dict):
        out = {k: strip_uuids(x) for k, x in v.items() if k not in ('UUID', 'UUIDMost', 'UUIDLeast')}
        if isinstance(out.get('attributes'), list):
            out['attributes'] = sorted(out['attributes'], key=lambda a: str(a.get('id')) if isinstance(a, dict) else '')
        return out
    if isinstance(v, list):
        return [strip_uuids(x) for x in v]
    return v


# --- Comparison --------------------------------------------------------------

def compare_terrain(a, b, report):
    keys = sorted(set(a) | set(b))
    for pos in keys:
        ca, cb = a.get(pos), b.get(pos)
        if ca is None or cb is None:
            report['chunk present in one save only'].append((pos, 'A' if ca else 'B'))
            continue
        if ca.get('Status') != cb.get('Status'):
            report['Status'].append((pos, ca.get('Status'), cb.get('Status')))
        sa = {s['Y']: s for s in ca.get('sections', [])}
        sb = {s['Y']: s for s in cb.get('sections', [])}
        for y in sorted(set(sa) | set(sb)):
            xa, xb = sa.get(y, {}), sb.get(y, {})
            for key, n, mb, names in (('block_states', 4096, 4, state_name), ('biomes', 64, 0, str)):
                pa, pb = xa.get(key), xb.get(key)
                if canon(pa) == canon(pb):
                    continue
                if pa is None or pb is None:
                    report[key + ' section missing'].append((pos, y))
                    continue
                va, vb = unpack(pa, n, mb, names), unpack(pb, n, mb, names)
                diff = np.nonzero(va != vb)[0]
                if len(diff) == 0:
                    report[key + ' same blocks, different encoding'].append((pos, y))
                    continue
                report[key + ' sections'].append((pos, y, len(diff)))
                if key == 'block_states':
                    report['_blocks'] += len(diff)
                    for i in diff:
                        lx, lz, ly = i & 15, (i >> 4) & 15, i >> 8
                        report['_block_pairs'][(va[i], vb[i])] += 1
                        if len(report['_block_examples']) < 30:
                            report['_block_examples'].append(
                                (pos[0] * 16 + lx, y * 16 + ly, pos[1] * 16 + lz, va[i], vb[i]))
            for key in ('BlockLight', 'SkyLight'):
                if canon(xa.get(key)) != canon(xb.get(key)):
                    report[key + ' sections'].append((pos, y))
        for key in sorted((set(ca) | set(cb)) - IGNORED - {'sections', 'Status'}):
            # Chunks short of full status keep their entities inline.
            if canon(strip_uuids(ca.get(key))) != canon(strip_uuids(cb.get(key))):
                report[key].append((pos,))


def compare_records(a, b, report, label, strip):
    for pos in sorted(set(a) | set(b)):
        ca, cb = a.get(pos), b.get(pos)
        if ca is None or cb is None:
            report[f'{label}: chunk present in one save only'].append((pos, 'A' if ca else 'B'))
            continue
        for key in sorted(set(ca) | set(cb)):
            va, vb = ca.get(key), cb.get(key)
            if strip:
                va, vb = strip_uuids(va), strip_uuids(vb)
            if key == 'Entities':
                ea = Counter(canon(e) for e in va or [])
                eb = Counter(canon(e) for e in vb or [])
                if ea != eb:
                    report[f'{label}: Entities'].append((pos, sum((ea - eb).values()), sum((eb - ea).values())))
                    ids_a = Counter(dict(e).get('id') for e in (ea - eb).elements())
                    ids_b = Counter(dict(e).get('id') for e in (eb - ea).elements())
                    report['_entity_ids'] += ids_a + ids_b
            elif canon(va) != canon(vb):
                report[f'{label}: {key}'].append((pos,))


def new_report():
    report = defaultdict(list)
    report['_blocks'] = 0
    report['_block_pairs'] = Counter()
    report['_block_examples'] = []
    report['_entity_ids'] = Counter()
    return report


def print_report(title, report):
    print(f'-- {title}')
    any_diff = False
    for key, items in sorted((k, v) for k, v in report.items() if not k.startswith('_')):
        if not items:
            continue
        any_diff = True
        chunks = sorted({it[0] for it in items})
        print(f'DIFF {key}: {len(items)} ({len(chunks)} chunks), e.g. {items[:4]}')
    if report['_blocks']:
        print(f'blocks differing: {report["_blocks"]}')
        for (sa, sb), n in report['_block_pairs'].most_common(15):
            print(f'  {n:7d}  A {sa}  ->  B {sb}')
        print('first differing blocks (x, y, z, A, B):')
        for x, y, z, a, b in report['_block_examples'][:10]:
            print(f'   {x} {y} {z}  {a}  {b}')
    if report['_entity_ids']:
        print('entity ids among differing entities:', dict(report['_entity_ids'].most_common(20)))
    print('identical' if not any_diff else 'different')
    return any_diff


def main():
    args = sys.argv[1:]
    dim = 'minecraft:overworld'
    if '--dimension' in args:
        i = args.index('--dimension')
        dim = args[i + 1]
        del args[i:i + 2]
    if len(args) != 2:
        raise SystemExit(__doc__)
    da, db = (dimension_dir(s, dim) for s in args)

    # The square generate.sh brought to full status, from its record in the
    # save; chunks outside it are neighbours left at partial status.
    square = None
    recs = [os.path.join(s, 'lerping-generate.json') for s in args]
    if all(os.path.exists(r) for r in recs):
        import json
        ca, cb = (json.load(open(r))['chunks'] for r in recs)
        if ca != cb:
            raise SystemExit(f'the two saves cover different squares: {ca} vs {cb}')
        square = ca
        print(f"square: chunks x {ca['x0']}..{ca['x1']}, z {ca['z0']}..{ca['z1']}")
    inside = lambda p: square is not None and square['x0'] <= p[0] <= square['x1'] and square['z0'] <= p[1] <= square['z1']
    parts = [('in the square', inside), ('outside the square', lambda p: not inside(p))] if square else [('all chunks', lambda p: True)]
    reports = {name: new_report() for name, _ in parts}

    ta, tb = load_folder(os.path.join(da, 'region')), load_folder(os.path.join(db, 'region'))
    full = sum(1 for c in ta.values() if c.get('Status') == 'minecraft:full')
    print(f'terrain: {len(ta)} chunks in A ({full} full), {len(tb)} in B')
    for name, f in parts:
        compare_terrain({p: c for p, c in ta.items() if f(p)}, {p: c for p, c in tb.items() if f(p)}, reports[name])
    del ta, tb
    for folder, strip in (('entities', True), ('poi', False)):
        xa, xb = load_folder(os.path.join(da, folder)), load_folder(os.path.join(db, folder))
        print(f'{folder}: {len(xa)} chunks in A, {len(xb)} in B')
        for name, f in parts:
            compare_records({p: c for p, c in xa.items() if f(p)}, {p: c for p, c in xb.items() if f(p)}, reports[name], folder, strip)

    # With a square, only the square decides: outside it are partial chunks
    # and the server's start-up spawn area, which it generates on its own
    # threads before generate.sh starts and which is not ordered.
    verdict = {name: print_report(name, reports[name]) for name, _ in parts}
    differs = verdict[parts[0][0]]
    print(('DIFFERENT' if differs else 'IDENTICAL') + (' in the square' if square else ''))
    sys.exit(1 if differs else 0)


if __name__ == '__main__':
    main()

"""Dependency-free QR code encoder.

Alphanumeric mode only, error correction level M, versions 1-10.
qr_matrix(text) -> list of rows of bool (True = dark), no quiet zone.
print_qr(text) prints it with half-block characters (light modules as blocks,
so the code reads dark-on-light on a dark terminal).
"""

ALNUM = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"

# Level M, versions 1..10: (ec codewords per block, [data codewords per block])
BLOCKS = {
    1: (10, [16]),
    2: (16, [28]),
    3: (26, [44]),
    4: (18, [32, 32]),
    5: (24, [43, 43]),
    6: (16, [27, 27, 27, 27]),
    7: (18, [31, 31, 31, 31]),
    8: (22, [38, 38, 39, 39]),
    9: (22, [36, 36, 36, 37, 37]),
    10: (26, [43, 43, 43, 43, 44]),
}

ALIGN = {
    1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34],
    7: [6, 22, 38], 8: [6, 24, 42], 9: [6, 26, 46], 10: [6, 28, 50],
}

# GF(256), primitive polynomial 0x11D
_EXP = [0] * 512
_LOG = [0] * 256
_x = 1
for _i in range(255):
    _EXP[_i] = _x
    _LOG[_x] = _i
    _x <<= 1
    if _x & 0x100:
        _x ^= 0x11D
for _i in range(255, 512):
    _EXP[_i] = _EXP[_i - 255]


def _gmul(a, b):
    if a == 0 or b == 0:
        return 0
    return _EXP[_LOG[a] + _LOG[b]]


def _rs_generator(n):
    g = [1]
    for i in range(n):
        nxt = [0] * (len(g) + 1)
        for j, c in enumerate(g):
            nxt[j] ^= c
            nxt[j + 1] ^= _gmul(c, _EXP[i])
        g = nxt
    return g  # highest degree first


def _rs_remainder(data, n):
    gen = _rs_generator(n)
    rem = [0] * n
    for b in data:
        f = b ^ rem[0]
        rem = rem[1:] + [0]
        if f:
            for i in range(n):
                rem[i] ^= _gmul(gen[i + 1], f)
    return rem


def _data_capacity(ver):
    return sum(BLOCKS[ver][1])


def _encode_data(text, ver):
    bits = []

    def put(val, n):
        for i in range(n - 1, -1, -1):
            bits.append((val >> i) & 1)

    put(0b0010, 4)
    put(len(text), 9 if ver < 10 else 11)
    vals = [ALNUM.index(c) for c in text]
    for i in range(0, len(vals) - 1, 2):
        put(vals[i] * 45 + vals[i + 1], 11)
    if len(vals) % 2:
        put(vals[-1], 6)
    cap = _data_capacity(ver) * 8
    put(0, min(4, cap - len(bits)))
    while len(bits) % 8:
        bits.append(0)
    out = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8)]
    pad = 0xEC
    while len(out) < cap // 8:
        out.append(pad)
        pad = 0x11 if pad == 0xEC else 0xEC
    return out


def _codewords(data, ver):
    ec_len, lens = BLOCKS[ver]
    blocks, pos = [], 0
    for n in lens:
        blocks.append(data[pos:pos + n])
        pos += n
    ecs = [_rs_remainder(b, ec_len) for b in blocks]
    out = []
    for i in range(max(lens)):
        for b in blocks:
            if i < len(b):
                out.append(b[i])
    for i in range(ec_len):
        for e in ecs:
            out.append(e[i])
    return out


def _format_bits(mask):
    data = (0b00 << 3) | mask  # level M = 00
    rem = data
    for _ in range(10):
        rem = (rem << 1) ^ ((rem >> 9) * 0x537)
    return ((data << 10) | rem) ^ 0x5412


def _build_base(ver):
    size = ver * 4 + 17
    m = [[False] * size for _ in range(size)]
    fn = [[False] * size for _ in range(size)]

    def setf(x, y, dark):
        m[y][x] = dark
        fn[y][x] = True

    for i in range(size):
        setf(6, i, i % 2 == 0)
        setf(i, 6, i % 2 == 0)
    for cx, cy in ((3, 3), (size - 4, 3), (3, size - 4)):
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                x, y = cx + dx, cy + dy
                if 0 <= x < size and 0 <= y < size:
                    setf(x, y, max(abs(dx), abs(dy)) not in (2, 4))
    pos = ALIGN[ver]
    n = len(pos)
    for i in range(n):
        for j in range(n):
            if (i == 0 and j == 0) or (i == 0 and j == n - 1) or (i == n - 1 and j == 0):
                continue
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    setf(pos[i] + dx, pos[j] + dy, max(abs(dx), abs(dy)) != 1)
    return m, fn, size


def _draw_format(m, fn, size, mask, blank=False):
    bits = 0 if blank else _format_bits(mask)

    def bit(i):
        return (bits >> i) & 1 == 1

    def setf(x, y, d):
        m[y][x] = d
        fn[y][x] = True

    for i in range(6):
        setf(8, i, bit(i))
    setf(8, 7, bit(6))
    setf(8, 8, bit(7))
    setf(7, 8, bit(8))
    for i in range(9, 15):
        setf(14 - i, 8, bit(i))
    for i in range(8):
        setf(size - 1 - i, 8, bit(i))
    for i in range(8, 15):
        setf(8, size - 15 + i, bit(i))
    setf(8, size - 8, not blank)  # dark module


def _draw_version(m, fn, size, ver, blank=False):
    if ver < 7:
        return
    rem = ver
    for _ in range(12):
        rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
    bits = 0 if blank else (ver << 12) | rem
    for i in range(18):
        d = (bits >> i) & 1 == 1
        a = size - 11 + i % 3
        b = i // 3
        m[b][a] = d
        fn[b][a] = True
        m[a][b] = d
        fn[a][b] = True


def _place(m, fn, size, cw):
    bits = []
    for b in cw:
        for i in range(7, -1, -1):
            bits.append((b >> i) & 1 == 1)
    k = 0
    right = size - 1
    while right >= 1:
        if right == 6:
            right = 5
        for vert in range(size):
            for j in range(2):
                x = right - j
                upward = ((right + 1) & 2) == 0
                y = size - 1 - vert if upward else vert
                if not fn[y][x] and k < len(bits):
                    m[y][x] = bits[k]
                    k += 1
        right -= 2


def _mask_cond(mask, x, y):
    if mask == 0:
        return (x + y) % 2 == 0
    if mask == 1:
        return y % 2 == 0
    if mask == 2:
        return x % 3 == 0
    if mask == 3:
        return (x + y) % 3 == 0
    if mask == 4:
        return (x // 3 + y // 2) % 2 == 0
    if mask == 5:
        return x * y % 2 + x * y % 3 == 0
    if mask == 6:
        return (x * y % 2 + x * y % 3) % 2 == 0
    return ((x + y) % 2 + x * y % 3) % 2 == 0


def _apply_mask(m, fn, size, mask):
    for y in range(size):
        for x in range(size):
            if not fn[y][x] and _mask_cond(mask, x, y):
                m[y][x] = not m[y][x]


_N3 = [True, False, True, True, True, False, True]


def _n3_score(line, size):
    # 1:1:3:1:1 pattern with light modules (or the symbol edge) on one side
    score = 0
    idx = _find(line, _N3, 0)
    while idx != -1:
        off = idx + 7
        if (idx == 0 or idx == size - 7
                or not any(line[max(idx - 4, 0):idx])
                or not any(line[off:min(off + 4, size)])):
            score += 40
        else:
            off = idx + 4
        idx = _find(line, _N3, off)
    return score


def _find(line, pat, start):
    for i in range(start, len(line) - len(pat) + 1):
        if line[i:i + len(pat)] == pat:
            return i
    return -1


def _penalty(m, size):
    score = 0
    lines = [row for row in m] + [[m[y][x] for y in range(size)] for x in range(size)]
    for line in lines:
        run = 1
        for i in range(1, size):
            if line[i] == line[i - 1]:
                run += 1
            else:
                if run >= 5:
                    score += run - 2
                run = 1
        if run >= 5:
            score += run - 2
        score += _n3_score(line, size)
    for y in range(size - 1):
        for x in range(size - 1):
            c = m[y][x]
            if c == m[y][x + 1] == m[y + 1][x] == m[y + 1][x + 1]:
                score += 3
    dark = sum(1 for row in m for c in row if c)
    total = size * size
    score += (abs(dark * 20 - total * 10) // total) * 10
    return score


def _choose_version(text):
    for ver in range(1, 11):
        cc = 9 if ver < 10 else 11
        nbits = 4 + cc + (len(text) // 2) * 11 + (len(text) % 2) * 6
        if nbits <= _data_capacity(ver) * 8:
            return ver
    raise ValueError("text does not fit in versions 1-10 at level M")


def qr_build(text):
    """Return (matrix, version, mask)."""
    for c in text:
        if c not in ALNUM:
            raise ValueError("character not allowed in alphanumeric mode: %r" % c)
    ver = _choose_version(text)
    cw = _codewords(_encode_data(text, ver), ver)
    base, fn, size = _build_base(ver)
    # format/version areas stay light while the masks are scored
    _draw_format(base, fn, size, 0, True)
    _draw_version(base, fn, size, ver, True)
    _place(base, fn, size, cw)
    best = None
    for mask in range(8):
        m = [row[:] for row in base]
        _apply_mask(m, fn, size, mask)
        p = _penalty(m, size)
        if best is None or p < best[0]:
            best = (p, mask, m)
    m, mask = best[2], best[1]
    _draw_format(m, fn, size, mask)
    _draw_version(m, fn, size, ver)
    return m, ver, mask


def qr_matrix(text):
    return qr_build(text)[0]


def render_lines(text):
    m = qr_matrix(text)
    size = len(m)
    q = 4
    n = size + 2 * q

    def dark(x, y):
        x -= q
        y -= q
        return 0 <= x < size and 0 <= y < size and m[y][x]

    lines = []
    for y in range(0, n, 2):
        s = []
        for x in range(n):
            top = not dark(x, y)  # light = filled
            bot = not dark(x, y + 1) if y + 1 < n else True
            if top and bot:
                s.append("\u2588")
            elif top:
                s.append("\u2580")
            elif bot:
                s.append("\u2584")
            else:
                s.append(" ")
        lines.append("".join(s))
    return lines


def print_qr(text):
    for line in render_lines(text):
        print(line)

#!/usr/bin/env python3
"""PNG -> ICO (32bpp DIB + AND mask), the same container shape upstream's favicon.ico uses."""
import struct, sys, zlib


def decode_png(path):
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, ihdr = 8, b"", None
    while pos < len(d):
        ln = struct.unpack(">I", d[pos:pos + 4])[0]
        typ = d[pos + 4:pos + 8]
        body = d[pos + 8:pos + 8 + ln]
        if typ == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif typ == b"IDAT":
            idat += body
        elif typ == b"IEND":
            break
        pos += 12 + ln
    w, h, depth, ctype, _, _, interlace = ihdr
    assert depth == 8 and interlace == 0 and ctype in (2, 6), (depth, ctype, interlace)
    nch = 4 if ctype == 6 else 3
    raw = zlib.decompress(idat)
    stride = w * nch
    px = bytearray(stride * h)
    prev = bytearray(stride)
    r = 0
    for y in range(h):
        f = raw[r]; r += 1
        line = bytearray(raw[r:r + stride]); r += stride
        if f == 1:
            for i in range(nch, stride):
                line[i] = (line[i] + line[i - nch]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i - nch] if i >= nch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - nch] if i >= nch else 0
                b = prev[i]
                c = prev[i - nch] if i >= nch else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        px[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, nch, px


def write_ico(png_path, ico_path, index=0):
    w, h, nch, px = decode_png(png_path)
    xor = bytearray()
    for y in range(h - 1, -1, -1):          # bottom-up
        for x in range(w):
            i = y * w * nch + x * nch
            a = px[i + 3] if nch == 4 else 255
            xor += bytes((px[i + 2], px[i + 1], px[i + 0], a))
    row_bytes = (w + 7) // 8
    row_bytes = (row_bytes + 3) & ~3
    mask = bytearray()
    for y in range(h - 1, -1, -1):          # bottom-up, 1 = transparent
        row = bytearray(row_bytes)
        for x in range(w):
            a = px[y * w * nch + x * nch + 3] if nch == 4 else 255
            if a < 128:
                row[x >> 3] |= 0x80 >> (x & 7)
        mask += row
    dib = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, len(xor) + len(mask), 0, 0, 0, 0)
    img = dib + bytes(xor) + bytes(mask)
    ent = struct.pack("<BBBBHHII", w % 256, h % 256, 0, 0, 1, 32, len(img), 6 + 16)
    open(ico_path, "wb").write(struct.pack("<HH", 0, 1) + struct.pack("<H", 1) + ent + img)
    print(f"ico: {w}x{h} {len(img)}B image, {6 + 16 + len(img)}B file, mask rows {row_bytes}")


if __name__ == "__main__":
    write_ico(sys.argv[1], sys.argv[2])

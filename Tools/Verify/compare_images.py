"""Compares two raw premultiplied RGBA images: Inochi2D's OpenGL output vs the port.

Both are box-filtered to half size first, so single-pixel differences along
silhouettes (rasteriser and texture-filtering details) don't count, while any
wrong colour, blend mode, mask or missing layer still does.
"""
import sys

a = open(sys.argv[1], 'rb').read()
b = open(sys.argv[2], 'rb').read()
w, h, label = int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
assert len(a) == len(b) == w * h * 4, "size mismatch"


def half(img):
    out = []
    for y in range(0, h - 1, 2):
        for x in range(0, w - 1, 2):
            i = (y * w + x) * 4
            j = i + w * 4
            out.append(tuple((img[i + k] + img[i + 4 + k] + img[j + k] + img[j + 4 + k]) / 4 for k in range(4)))
    return out


ha, hb = half(a), half(b)
total = large = covered = 0
for p, q in zip(ha, hb):
    if p[3] == 0 and q[3] == 0:
        continue
    covered += 1
    d = max(abs(p[k] - q[k]) for k in range(4))
    total += d
    if d > 32:
        large += 1
mean = total / max(covered, 1)
frac = large * 100 / max(covered, 1)
ok = mean < 3 and frac < 1
print(f"{label:40s} pixels={covered} meanDiff={mean:.2f}/255 over32={frac:.3f}% {'ok' if ok else 'MISMATCH'}")
sys.exit(0 if ok else 1)

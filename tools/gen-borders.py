#!/usr/bin/env python3
# One-time asset generator for demo/earth.k's country-borders overlay.
#
# Rasterises Natural Earth 110m coastlines + admin-0 boundary lines into an
# equirectangular RGB PNG holding a DISTANCE FIELD (red = distance-to-nearest-border
# in texels, 0 on the line, saturating at DMAX). The earth fragment shader samples it
# and draws a line by thresholding the distance at a zoom-compensated half-width, so
# the borders stay a constant screen width (they don't thicken as you zoom in) up to
# ~DMAX/1.3 × zoom before hitting the 1-texel data floor. DMAX must match the shader.
#
#   pip install numpy   # (no PIL needed — we emit the PNG by hand)
#   curl -sL -o coast.geojson    .../ne_110m_coastline.geojson
#   curl -sL -o boundary.geojson .../ne_110m_admin_0_boundary_lines_land.geojson
#   python3 tools/gen-borders.py coast.geojson boundary.geojson demo/data/2k_earth_borders.png 2048 1024
#
# Source: github.com/nvkelso/natural-earth-vector (public domain).
import json, sys, struct, zlib
import numpy as np

def load_lines(path):
    d = json.load(open(path))
    out = []
    for f in d["features"]:
        g = f["geometry"]; t = g["type"]; c = g["coordinates"]
        if t == "LineString": out.append(c)
        elif t == "MultiLineString": out.extend(c)
    return out

DMAX = 8.0   # distance field saturates at 8 texels (must match the shader's DMAX)

def rasterise(lines, W, H):
    seed = np.zeros((H, W), bool)                     # 1-texel centreline seed
    for ln in lines:
        p = np.asarray(ln, float)
        lon, lat = p[:, 0], p[:, 1]
        x = (lon + 180.0) / 360.0 * (W - 1)
        y = (90.0 - lat) / 180.0 * (H - 1)
        for i in range(len(x) - 1):
            x0, y0, x1, y1 = x[i], y[i], x[i + 1], y[i + 1]
            if abs(lon[i + 1] - lon[i]) > 180.0:      # antimeridian wrap — don't connect across the seam
                continue
            n = int(max(abs(x1 - x0), abs(y1 - y0))) + 1
            xs = np.clip(np.linspace(x0, x1, n).round().astype(int), 0, W - 1)
            ys = np.clip(np.linspace(y0, y1, n).round().astype(int), 0, H - 1)
            seed[ys, xs] = True
    # bounded chamfer distance transform (east-west wraps like the map; ~DMAX texels)
    d = np.where(seed, 0.0, 1e9).astype(np.float32)
    a, b = 1.0, 1.41421356
    for _ in range(int(DMAX) + 2):
        d = np.minimum(d, np.roll(d, 1, 0) + a);  d = np.minimum(d, np.roll(d, -1, 0) + a)
        d = np.minimum(d, np.roll(d, 1, 1) + a);  d = np.minimum(d, np.roll(d, -1, 1) + a)
        d = np.minimum(d, np.roll(np.roll(d, 1, 0), 1, 1) + b);  d = np.minimum(d, np.roll(np.roll(d, 1, 0), -1, 1) + b)
        d = np.minimum(d, np.roll(np.roll(d, -1, 0), 1, 1) + b); d = np.minimum(d, np.roll(np.roll(d, -1, 0), -1, 1) + b)
    return (np.clip(d, 0.0, DMAX) / DMAX * 255.0).round().astype(np.uint8)

def write_png(path, gray):
    H, W = gray.shape
    rgb = np.repeat(gray[:, :, None], 3, axis=2)                      # distance field replicated to RGB
    rows = rgb.reshape(H, W * 3)
    raw = np.concatenate([np.zeros((H, 1), np.uint8), rows], axis=1)  # ONE filter byte (0) per scanline
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    ihdr = struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)              # 8-bit RGB
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw.tobytes(), 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(png)

if __name__ == "__main__":
    coast, boundary, out, W, H = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
    lines = load_lines(coast) + load_lines(boundary)
    print(f"{len(lines)} polylines → {W}x{H} distance field (DMAX={DMAX})")
    write_png(out, rasterise(lines, W, H))
    print("wrote", out)

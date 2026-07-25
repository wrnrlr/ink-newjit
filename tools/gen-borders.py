#!/usr/bin/env python3
# One-time asset generator for demo/earth.k's country-borders overlay.
#
# Rasterises Natural Earth 110m coastlines + admin-0 boundary lines into an
# equirectangular RGB PNG (white lines on black) that the earth fragment shader
# samples as a 6th texture layer and composites over the surface.
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

def rasterise(lines, W, H, rad):
    img = np.zeros((H, W), np.uint8)
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
            xs = np.linspace(x0, x1, n).round().astype(int)
            ys = np.linspace(y0, y1, n).round().astype(int)
            for dx in range(-rad, rad + 1):           # thicken the stroke
                for dy in range(-rad, rad + 1):
                    img[np.clip(ys + dy, 0, H - 1), np.clip(xs + dx, 0, W - 1)] = 255
    return img

def write_png(path, gray):
    H, W = gray.shape
    rgb = np.repeat(gray[:, :, None], 3, axis=2)                      # white lines on black
    rows = rgb.reshape(H, W * 3)
    raw = np.concatenate([np.zeros((H, 1), np.uint8), rows], axis=1)  # ONE filter byte (0) per scanline
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    ihdr = struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)              # 8-bit RGB
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw.tobytes(), 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(png)

if __name__ == "__main__":
    coast, boundary, out, W, H = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
    rad = 2 if W <= 2048 else 3
    lines = load_lines(coast) + load_lines(boundary)
    print(f"{len(lines)} polylines → {W}x{H} (stroke ±{rad}px)")
    write_png(out, rasterise(lines, W, H, rad))
    print("wrote", out)

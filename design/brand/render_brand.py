#!/usr/bin/env python3
"""Render the POPOPX brand graphics that the relay pages serve.

Reads the vector sources committed beside this script (design/brand/*.svg) and writes the
raster files into apps/common/Web/static/media/ at the exact pixel size each one had before.
The two logo-symbol-*.svg files are the sources themselves, used as-is.

The brand family originates in the client repository (popopx-chat/popopx-chat):
  branding/source-svg/media-logos__popopx-logo-{light,dark}.png.src.svg  768x189 / 768x190
  media-logos/popopx-symbol-{light,dark}.svg                             34x34 / 34x35
  branding/master-logo/popopx-mark.svg                                   1024x1024, the app icon
design/brand/ holds the copies resized for these pages, so this render needs nothing but
this repository. Run --refresh <path-to-popopx-chat> to re-derive them when the brand changes.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
MEDIA = os.path.join(REPO, "apps", "common", "Web", "static", "media")
CHROME = os.environ.get(
    "CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
)

# target file -> (source svg, width, height)
TARGETS = {
    "logo-light.png": ("logo-light.svg", 400, 99),
    "logo-dark.png": ("logo-dark.svg", 401, 101),
    "favicon.ico": ("favicon.svg", 16, 16),
    "contact_page_mobile.png": ("contact_page_mobile.svg", 1222, 1149),
}
SYMBOLS = ("logo-symbol-light.svg", "logo-symbol-dark.svg")


def resize(src_path, dst_path, w, h):
    """Give an SVG the intrinsic size we want to rasterize at, keeping its viewBox."""
    s = open(src_path).read()
    if not re.search(r'<svg[^>]*\bwidth="[\d.]+" height="[\d.]+"', s):
        raise SystemExit(f"{src_path}: no width/height on the <svg> element")
    s2 = re.sub(r'(<svg[^>]*?)\bwidth="[\d.]+" height="[\d.]+"',
                lambda m: f'{m.group(1)}width="{w}" height="{h}"', s, count=1)
    open(dst_path, "w").write(s2)


def render(svg_path, png_path, w, h):
    subprocess.run(
        [CHROME, "--headless=new", "--disable-gpu", "--no-sandbox", "--hide-scrollbars",
         "--disable-lcd-text", "--default-background-color=00000000",
         f"--window-size={w},{h}", f"--screenshot={png_path}", "file://" + svg_path],
        check=True, capture_output=True)
    if not os.path.getsize(png_path):
        raise SystemExit(f"empty render for {svg_path}")


def inline(svg_path, prefix):
    """Return the <defs>+<g> body of a source svg with its gradient ids made unique."""
    s = open(svg_path).read()
    body = s[s.index("<defs>"):]
    body = body[: body.rindex("</svg>")].strip()
    for gid in re.findall(r'id="(g\d+)"', body):
        body = body.replace(f'id="{gid}"', f'id="{prefix}{gid}"')
        body = body.replace(f"url(#{gid})", f"url(#{prefix}{gid})")
    return body


def natural(svg_path):
    m = re.search(r'<svg[^>]*\bwidth="([\d.]+)" height="([\d.]+)"', open(svg_path).read())
    if not m:
        raise SystemExit(f"{svg_path}: no intrinsic size")
    return float(m.group(1)), float(m.group(2))


def phone_mockup(wordmark_src, symbol_src, dst):
    """The contact-page splash illustration: phone, three diamonds, mark over wordmark.

    The wordmark here is the letters-only source; the lockup used for the page header already
    carries the mark, and putting that in a splash under the mark would draw it twice.
    """
    L, R, T, CW, CH = 268, 922, 178, 1222, 1149
    cx = (L + R) / 2
    wn, hn = natural(wordmark_src)
    wm_w = 400.0
    wm_h = wm_w * hn / wn
    sy = 700 - wm_h - 46
    sn, _ = natural(symbol_src)
    mscale = 120.0 / sn
    ms_w = mscale * sn
    body = (f'<g transform="translate({cx - ms_w / 2:.1f},{sy:.1f}) scale({mscale:.4f})">'
            f'{inline(symbol_src, "m")}</g>'
            f'<g transform="translate({cx - wm_w / 2:.1f},700) scale({wm_w / wn:.5f})">'
            f'{inline(wordmark_src, "w")}</g>')
    open(dst, "w").write(
        f'<svg width="{CW}" height="{CH}" viewBox="0 0 {CW} {CH}" fill="none" '
        f'xmlns="http://www.w3.org/2000/svg">\n'
        f'<rect x="18" y="14" width="300" height="300" rx="18" fill="#D9ECFF" opacity="0.55" transform="rotate(45 168 164)"/>'
        f'<rect x="452" y="-120" width="300" height="300" rx="18" fill="#D9ECFF" opacity="0.55" transform="rotate(45 602 30)"/>'
        f'<rect x="906" y="430" width="300" height="300" rx="18" fill="#D9ECFF" opacity="0.55" transform="rotate(45 1056 580)"/>'
        f'<rect x="{L}" y="{T}" width="{R - L}" height="{CH - T + 40}" rx="40" fill="#F0F1F2"/>'
        f'<rect x="{L}" y="{T}" width="{R - L}" height="{CH - T + 40}" rx="40" fill="none" stroke="#D9E7ED" stroke-width="3"/>'
        f'<rect x="{L + 16}" y="{T + 78}" width="{R - L - 32}" height="{CH - T - 40}" rx="26" fill="#FFFFFF"/>'
        f'<rect x="{L + 3}" y="{T + 3}" width="{R - L - 6}" height="10" rx="5" fill="#3D0A6D"/>'
        f'<circle cx="{cx}" cy="{T + 52}" r="15" fill="#2B2F33"/>'
        f'<rect x="{R - 2}" y="520" width="7" height="70" rx="3.5" fill="#C8CDD2"/>'
        f'<rect x="{R - 2}" y="610" width="7" height="110" rx="3.5" fill="#C8CDD2"/>'
        f'{body}\n</svg>\n')


def refresh(client_repo):
    """Re-derive design/brand/*.svg from the client repository's brand family."""
    src = os.path.join(client_repo, "branding", "source-svg")
    med = os.path.join(client_repo, "media-logos")
    resize(os.path.join(src, "media-logos__popopx-logo-light.png.src.svg"),
           os.path.join(HERE, "logo-light.svg"), 400, 99)
    resize(os.path.join(src, "media-logos__popopx-logo-dark.png.src.svg"),
           os.path.join(HERE, "logo-dark.svg"), 401, 101)
    # The favicon is the app icon, not the symbol: the symbol's bubble is near-white and
    # disappears on a light browser tab, while the tile carries the brand at 16px.
    resize(os.path.join(client_repo, "branding", "master-logo", "popopx-mark.svg"),
           os.path.join(HERE, "favicon.svg"), 16, 16)
    for name in SYMBOLS:
        tail = name.replace("logo-symbol-", "popopx-symbol-")
        open(os.path.join(HERE, name), "w").write(open(os.path.join(med, tail)).read())
    phone_mockup(os.path.join(src, "apps__popopx-badge-service__web__public__img__wordmark-light.svg"),
                 os.path.join(med, "popopx-symbol-light.svg"),
                 os.path.join(HERE, "contact_page_mobile.svg"))
    print("re-derived from", client_repo)


def build():
    tmp = "/tmp/popopx_render"
    os.makedirs(tmp, exist_ok=True)
    for out, (src, w, h) in TARGETS.items():
        sized = os.path.join(tmp, out + ".svg")
        resize(os.path.join(HERE, src), sized, w, h)
        png = os.path.join(tmp, out + ".png") if out.endswith(".ico") else os.path.join(MEDIA, out)
        render(sized, png, w, h)
        if out.endswith(".ico"):
            sys.argv = ["png2ico", png, os.path.join(MEDIA, out)]
            import png2ico  # noqa: E402
            png2ico.write_ico(png, os.path.join(MEDIA, out))
        print(f"{out:26} {w}x{h}")
    for name in SYMBOLS:
        open(os.path.join(MEDIA, name), "w").write(open(os.path.join(HERE, name)).read())
        print(f"{name:26} copied")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--refresh":
        refresh(sys.argv[2])
    else:
        build()

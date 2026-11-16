# POPOPX brand graphics

The images the relay pages serve out of `apps/common/Web/static/media/` are **rendered, never
hand-edited**. The vector sources are here; `render_brand.py` rasterizes them at the exact pixel
size of the files they replace.

The brand family does not originate in this repository. It is the POPOPX identity maintained in
the client repository (`popopx-chat/popopx-chat`), and these are the same files the app uses, so
the pages and the app cannot drift into two different logos:

| rendered here | size | source in popopx-chat |
|---|---|---|
| `logo-light.png` | 400x99 | `branding/source-svg/media-logos__popopx-logo-light.png.src.svg` (768x189) |
| `logo-dark.png` | 401x101 | `branding/source-svg/media-logos__popopx-logo-dark.png.src.svg` (768x190) |
| `logo-symbol-light.svg` | 34x34 | `media-logos/popopx-symbol-light.svg` - copied verbatim, same intrinsic size |
| `logo-symbol-dark.svg` | 34x35 | `media-logos/popopx-symbol-dark.svg` - copied verbatim |
| `favicon.ico` | 16x16 | `branding/master-logo/popopx-mark.svg` (1024x1024, the app icon) |
| `contact_page_mobile.png` | 1222x1149 | composed here from `popopx-symbol-light.svg` + the letters-only `…wordmark-light.svg` |

The favicon is the app icon rather than the symbol: the symbol's bubble is `#FAF6FE`, which
vanishes on a light browser tab, while the tile carries the brand at 16px.

## Render

```sh
python3 design/brand/render_brand.py                    # writes the six files into the media dir
python3 design/brand/render_brand.py --refresh ~/popopx-chat/popopx-chat   # re-derive the sources
```

`render` needs only this repository: it rasterizes the committed sources with headless Chromium
(`CHROME=/path/to/chrome` to override the macOS default) and writes `favicon.ico` as one 16x16
32bpp DIB plus its AND mask - the container shape the previous favicon had, 1150 bytes.
`--refresh` additionally reads the client repository and rewrites the sources in this directory;
run it when the brand changes, then `render`, then commit both.

Re-running `render` reproduces every file byte for byte.

## Files deliberately not touched

`apk_icon.png` (a generic Android icon), `testflight.png` (Apple's TestFlight icon),
`apple_store.svg`, `google_play.svg`, `f_droid.svg` (store badges, which their own usage terms
require to be shown unaltered), `sun.svg`, `moon.svg` (theme glyphs) and the protocol diagrams -
none of them carries the upstream brand.

# Article figures

Rendered from `figures.html` at 2x (2800px wide) for Medium's retina display.
Medium shows images at 700px, so 1400 CSS px doubled.

| File | Place it in the article | Alt text |
|---|---|---|
| `fig-chain.png` | **Featured image**, and again in "The chain nobody diagnoses correctly" | Six-step diagram: a disk passing 90% full leads to macOS being unable to grow a swapfile, then pagein thrash, then watchdog timeouts |
| `fig-ratio.png` | In "What SMART actually told me", after the counters block | Bar chart: 39.5 TB read against 13.8 TB written, roughly 90 GB per hour |
| `fig-inversion.png` | In "The re-seed, and what it exposed", replacing the size/files table | Two ranked bar charts showing directory order inverting between size and file count |
| `fig-timeline.png` | In "Then I checked when my last backup finished" | Timeline of completed backups ending 6 July with a 62-day gap before September |
| `fig-scoreboard.png` | Near the close, before "Who this actually affects" | Four before/after tiles: free space, swap, last backup, backup duration |

## Regenerating

```bash
cd docs/assets
open figures.html          # edit, then re-export:
```

Export uses headless Chrome at 2x, then crops each figure to its content height
(Chrome captures the full window, not the content box):

```bash
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
  --window-size=1400,4000 --default-background-color=FCFCFBFF \
  --screenshot=out.png "file://$PWD/figures.html"
```

## Palette

Validated with the dataviz skill's checker before use — all four categorical
slots pass the lightness band, chroma floor, CVD separation (worst adjacent
ΔE 9.1) and normal-vision floor (ΔE 22.9). Aqua and yellow fall below 3:1
contrast on this surface, which is why every bar carries a visible direct label
rather than relying on colour alone.

Colour follows the **entity**, not its rank — that is what makes the inversion in
`fig-inversion.png` legible, since the same directory keeps its hue as it moves
between panels.

## The two HTML outputs

`build-review.py` produces both from `../article-draft.md` + `figures.html`:

| File | For |
|---|---|
| `review.html` | Publishing as an Artifact. No document skeleton (the host supplies it); fonts from Google Fonts. |
| `article-standalone.html` | **Sending to people.** One file, ~324 KB, zero network requests — fonts embedded as base64 woff2, figures already inline HTML. Open it from a thumb drive on a plane and it renders identically. |

Rebuild both:

```bash
python3 docs/assets/build-review.py
```

`fonts.css` holds the base64 `@font-face` blocks. Regenerate it only if the
typefaces change — it is the latin subset of Fraunces, Newsreader and IBM Plex
Mono, collapsed to one face per file (the first two are variable, so several
weights share a URL).

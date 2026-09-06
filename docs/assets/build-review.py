#!/usr/bin/env python3
"""Build review.html from article-draft.md + figures.html.

Two traps this script exists to avoid, both hit by hand-editing:
  * figures.html's element selectors (body, h2) are NOT class-scoped, so they
    must be prefixed explicitly or they restyle the article around them.
  * the plate markup carries inline `--s1`-style custom properties, which are
    renamed to `--f-*` inside the article scope; the markup needs the same
    rename or every inline colour silently resolves to nothing.
"""
import pathlib, re, html

HERE = pathlib.Path(__file__).parent
md   = (HERE.parent / 'article-draft.md').read_text()
figs = (HERE / 'figures.html').read_text()

# ---------------------------------------------------------------- markdown --
def inline(t):
    t = html.escape(t, quote=False)
    t = re.sub(r'`([^`]+)`', r'<code>\1</code>', t)
    t = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', t)
    t = re.sub(r'(?<!\*)\*([^*\n]+)\*(?!\*)', r'<em>\1</em>', t)
    t = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', t)
    return t

lines = md.split('\n'); out = []; i = 0; n = len(lines)
while i < n:
    start, L = i, lines[i]
    if L.startswith('```'):
        buf = []; i += 1
        while i < n and not lines[i].startswith('```'): buf.append(html.escape(lines[i])); i += 1
        out.append('<pre class="term"><code>' + '\n'.join(buf) + '</code></pre>'); i += 1
    elif L.startswith('> '):
        buf = []
        while i < n and lines[i].startswith('> '): buf.append(lines[i][2:]); i += 1
        out.append('<aside class="take">' + inline(' '.join(buf)) + '</aside>')
    elif L.startswith('- '):
        items = []
        while i < n and lines[i].startswith('- '):
            item = lines[i][2:]; i += 1
            while i < n and lines[i].startswith('  '): item += ' ' + lines[i].strip(); i += 1
            items.append(f'<li>{inline(item)}</li>')
        out.append('<ul>' + ''.join(items) + '</ul>')
    elif L.startswith('|'):
        rows = []
        while i < n and lines[i].startswith('|'): rows.append(lines[i]); i += 1
        cells = [[c.strip() for c in r.strip('|').split('|')] for r in rows if not set(r) <= set('|-: ')]
        head = ''.join(f'<th>{inline(c)}</th>' for c in cells[0])
        body = ''.join('<tr>' + ''.join(f'<td>{inline(c)}</td>' for c in r) + '</tr>' for r in cells[1:])
        out.append(f'<div class="tw"><table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table></div>')
    elif L.startswith('### '): out.append(f'<h3>{inline(L[4:])}</h3>'); i += 1
    elif L.startswith('## '):  out.append(f'<h2>{inline(L[3:])}</h2>');  i += 1
    elif L.startswith('# '):   i += 1
    elif L.strip() == '---':   out.append('<hr>'); i += 1
    elif L.strip() == '':      i += 1
    else:
        buf = []
        while i < n and lines[i].strip() and lines[i][:1] not in '#>|`-' and lines[i].strip() != '---':
            buf.append(lines[i]); i += 1
        if not buf: buf = [lines[i]]; i += 1
        para = ' '.join(buf)
        cls = ' class="dek"' if para.startswith('*') and para.endswith('*') and para.count('*') == 2 else ''
        out.append(f'<p{cls}>{inline(para.strip("*") if cls else para)}</p>')
    assert i > start, f'no progress at {start}'
body = '\n'.join(out)

# ------------------------------------------------------------------ plates --
VARS = ['surface-1','ink-3','ink-2','ink','rule','grid','s1','s2','s3','s4','gray','crit','c']
def rename(css):
    for v in VARS: css = css.replace(f'var(--{v})', f'var(--f-{v})')
    return re.sub(r'--(?=(' + '|'.join(VARS) + r'):)', '--f-', css)

figcss = figs[figs.index('<style>')+7:figs.index('</style>')]
figcss = re.sub(r'(?m)^  (?=[.#a-z])', '  .plate ', figcss)          # scope EVERY selector
figcss = re.sub(r'(?m)^  \.plate :root\{.*?\n  \}', '', figcss, flags=re.S)
figcss = re.sub(r'\n\s*\.plate \*\{box-sizing:border-box\}', '', figcss)
figcss = re.sub(r'\n\s*\.plate body\{.*?antialiased\}', '', figcss, flags=re.S)
figcss = rename(figcss)
figcss = figcss.replace('.plate .fig{width:1400px;margin:28px auto;', '.plate .fig{width:1400px;')
# The article's global `h2` shorthand sets a family; the plate's h2 rule sets
# only size, so it inherited Fraunces and diverged from the exported PNG.
figcss = figcss.replace('.plate h2{font-size:38px;',
                        '.plate h2{font-family:inherit;font-size:38px;')
figcss += '\n  .plate h2::before{content:none}\n  .plate h3{font-family:inherit}\n'

plates = {m.group(1): rename(m.group(2)) for m in
          re.finditer(r'<div class="fig" id="(fig-[a-z]+)">(.*?)\n</div>\n', figs, re.S)}
for needle, key in [('<h2>What SMART actually told me</h2>','fig-ratio'),
                    ('<h2>The chain nobody diagnoses correctly</h2>','fig-chain'),
                    ('<h2>Then I checked when my last backup finished</h2>','fig-timeline'),
                    ('<h2>The re-seed, and what it exposed</h2>','fig-inversion'),
                    ('<h2>Who this actually affects</h2>','fig-scoreboard')]:
    idx = body.index(needle); end = body.index('\n', idx) + 1
    body = body[:end] + f'<figure class="plate"><div class="fig">{plates[key]}</div></figure>\n' + body[end:]

shell = (HERE / 'review-shell.html').read_text()
(HERE / 'review.html').write_text(shell.replace('<!--FIGCSS-->', figcss).replace('<!--BODY-->', body))
print(f'  review.html · {len(md.split())} words · {len(plates)} plates')

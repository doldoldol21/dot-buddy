#!/usr/bin/env python3
"""Build the project page (GitHub Pages) from README.md and README.ko.md.

    python3 scripts/site.py [out_dir]      # default _site

The README is rendered by GitHub's own Markdown API, so the page reads exactly like the repo front page.
Links to other files in the repo go to github.com; images in docs/media/ are copied next to the page.
CI runs this on every push to main that touches the READMEs or docs/ (.github/workflows/pages.yml), so the page never
needs editing by hand. A Google Search Console verification file, if one is ever added as docs/site/google*.html,
is copied to the site root. Standard library only; GITHUB_TOKEN or GH_TOKEN is used when set (otherwise anonymous).
"""
import html, json, os, re, shutil, sys, urllib.request
from datetime import date
from pathlib import Path

REPO = "doldoldol21/dot-buddy"
SITE = "https://doldoldol21.github.io/dot-buddy/"
ROOT = Path(__file__).resolve().parent.parent
PAGES = [  # (source, output dir relative to the site, lang, title)
    ("README.md", "", "en", "Dot Buddy: a pixel desktop pet for your coding agents (macOS)"),
    ("README.ko.md", "ko/", "ko", "도트 친구 (Dot Buddy): 코딩 에이전트를 지켜보는 macOS 도트 데스크톱 펫"),
]


def render(md: str) -> str:
    req = urllib.request.Request("https://api.github.com/markdown", method="POST",
                                 data=json.dumps({"text": md, "mode": "gfm", "context": REPO}).encode(),
                                 headers={"Accept": "application/vnd.github+json", "User-Agent": "dot-buddy-site"})
    tok = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if tok:
        req.add_header("Authorization", f"Bearer {tok}")
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read().decode()


def slug(text: str, seen: dict) -> str:
    """GitHub's heading anchor: lower case, drop punctuation, spaces to hyphens, -1, -2 … for repeats."""
    s = re.sub(r"[^\w\- ]", "", html.unescape(re.sub(r"<[^>]+>", "", text)).strip().lower()).replace(" ", "-")
    n = seen.get(s, 0); seen[s] = n + 1
    return s if n == 0 else f"{s}-{n}"


def fix(body: str, prefix: str) -> str:
    """prefix is the way back to the site root from this page ("" or "../")."""
    seen: dict = {}
    body = re.sub(r"<(h[1-6])([^>]*)>(.*?)</\1>",
                  lambda m: f'<{m[1]}{m[2]} id="{slug(m[3], seen)}">{m[3]}</{m[1]}>', body, flags=re.S)
    # Images are wrapped in a link to the image file itself; keep just the image
    body = re.sub(r'<a target="_blank" rel="noopener noreferrer" href="[^"]*"><img ([^>]*)></a>', r"<img \1>", body)

    def url(m):
        attr, u = m[1], m[2]
        if re.match(r"^(https?:|mailto:|#)", u):
            return m[0]
        path, _, frag = u.partition("#")
        frag = "#" + frag if frag else ""
        if path in ("README.md", "README.ko.md"):
            return f'{attr}="{prefix}{"ko/" if path == "README.ko.md" else ""}{frag}"'
        if path.startswith("docs/media/"):
            return f'{attr}="{prefix}{path}"'
        kind = "tree" if path.endswith("/") or "." not in path.rsplit("/", 1)[-1] else "blob"
        return f'{attr}="https://github.com/{REPO}/{kind}/main/{path}{frag}"'
    return re.sub(r'\b(href|src)="([^"]*)"', url, body)


TEMPLATE = """<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{desc}">
<link rel="canonical" href="{url}">
<link rel="alternate" hreflang="en" href="{SITE}">
<link rel="alternate" hreflang="ko" href="{SITE}ko/">
<link rel="alternate" hreflang="x-default" href="{SITE}">
<link rel="icon" href="{prefix}docs/media/icon.png">
<meta property="og:type" content="website">
<meta property="og:title" content="{title}">
<meta property="og:description" content="{desc}">
<meta property="og:url" content="{url}">
<meta property="og:image" content="{SITE}docs/media/social-preview.png">
<meta name="twitter:card" content="summary_large_image">
<style>
:root {{ --bg: #fbfaf7; --fg: #1f2328; --muted: #59636e; --line: #d8dee4; --code: #f2f0eb; --link: #0b62d6; --accent: #e8743b; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg: #111316; --fg: #e6e8eb; --muted: #9aa4ae; --line: #30363d; --code: #1b1f24; --link: #6cb0ff; --accent: #f08a50; }} }}
* {{ box-sizing: border-box; }}
html {{ -webkit-text-size-adjust: 100%; }}
body {{ margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.65 -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", "Segoe UI", "Noto Sans KR", sans-serif; }}
header {{ position: sticky; top: 0; z-index: 1; display: flex; align-items: center; gap: 16px; padding: 10px 16px; background: color-mix(in srgb, var(--bg) 88%, transparent); backdrop-filter: blur(8px); border-bottom: 1px solid var(--line); }}
header .name {{ font-weight: 700; color: var(--fg); text-decoration: none; display: flex; align-items: center; gap: 8px; }}
header .name img {{ width: 24px; height: 24px; image-rendering: pixelated; }}
header nav {{ margin-left: auto; display: flex; gap: 16px; font-size: 14px; }}
main {{ max-width: 860px; margin: 0 auto; padding: 24px 16px 64px; }}
a {{ color: var(--link); }}
h1 {{ font-size: 40px; line-height: 1.2; margin: 8px 0 4px; }}
h2 {{ font-size: 26px; margin: 48px 0 12px; padding-bottom: 6px; border-bottom: 1px solid var(--line); }}
h3 {{ font-size: 19px; margin: 32px 0 8px; }}
img {{ max-width: 100%; height: auto; }}
img[src$="icon.png"] {{ image-rendering: pixelated; }}
code {{ font: 0.88em/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--code); padding: 0.15em 0.35em; border-radius: 4px; }}
pre {{ background: var(--code); padding: 14px 16px; border-radius: 8px; overflow-x: auto; }}
pre code, pre {{ font: 13.5px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace; }}
pre code {{ padding: 0; background: none; }}
.pl-k {{ color: #cf222e; }} .pl-s, .pl-pds {{ color: #0a3069; }} .pl-c {{ color: var(--muted); }} .pl-smi, .pl-v {{ color: #953800; }} .pl-c1, .pl-en {{ color: #8250df; }}
@media (prefers-color-scheme: dark) {{ .pl-k {{ color: #ff7b72; }} .pl-s, .pl-pds {{ color: #a5d6ff; }} .pl-smi, .pl-v {{ color: #ffa657; }} .pl-c1, .pl-en {{ color: #d2a8ff; }} }}
table {{ display: block; overflow-x: auto; border-collapse: collapse; margin: 16px 0; }}
th, td {{ border: 1px solid var(--line); padding: 6px 12px; vertical-align: top; text-align: left; }}
th {{ background: var(--code); }}
blockquote {{ margin: 16px 0; padding: 0 16px; color: var(--muted); border-left: 3px solid var(--line); }}
.markdown-alert {{ border-left: 3px solid var(--accent); padding: 4px 16px; margin: 16px 0; }}
.markdown-alert-title {{ font-weight: 600; }}
details {{ margin: 12px 0; }}
footer {{ max-width: 860px; margin: 0 auto; padding: 24px 16px 48px; border-top: 1px solid var(--line); color: var(--muted); font-size: 14px; }}
@media (max-width: 600px) {{ h1 {{ font-size: 30px; }} h2 {{ font-size: 22px; }} header nav a.long {{ display: none; }} }}
</style>
</head>
<body>
<header>
  <a class="name" href="{prefix}{home}"><img src="{prefix}docs/media/icon.png" alt="">{brand}</a>
  <nav>
    <a href="{prefix}{other}">{other_label}</a>
    <a class="long" href="https://github.com/{REPO}/releases/latest">{download}</a>
    <a href="https://github.com/{REPO}">GitHub</a>
  </nav>
</header>
<main>
{body}
</main>
<footer>{foot} <a href="https://github.com/{REPO}">github.com/{REPO}</a></footer>
<script src="{prefix}docs/media/walker/walker.js" defer></script>
</body>
</html>
"""


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "_site").resolve()
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    for src, sub, lang, title in PAGES:
        md = (ROOT / src).read_text()
        md = re.sub(r"<!--.*?-->", "", md, flags=re.S)               # notes for maintainers stay out of the page
        prefix = "../" * sub.count("/")
        body = fix(render(md), prefix)
        lead = re.search(r"<p[^>]*><strong>(.*?)</strong></p>", body, re.S)
        desc = html.escape(html.unescape(re.sub(r"<[^>]+>", "", lead[1])).strip()) if lead else title
        ko = lang == "ko"
        page = TEMPLATE.format(
            lang=lang, title=html.escape(title), desc=desc, url=SITE + sub, SITE=SITE, REPO=REPO, prefix=prefix, body=body,
            home="ko/" if ko else "", brand="도트 친구" if ko else "Dot Buddy",
            other="" if ko else "ko/", other_label="English" if ko else "한국어",
            download="내려받기" if ko else "Download",
            foot="이 페이지는 README.ko.md 에서 자동으로 만들어져요." if ko else "This page is built from README.md automatically.")
        (out / sub).mkdir(parents=True, exist_ok=True)
        (out / sub / "index.html").write_text(page)
    shutil.copytree(ROOT / "docs/media", out / "docs/media")
    for f in (ROOT / "docs/site").glob("google*.html") if (ROOT / "docs/site").is_dir() else []:
        shutil.copy(f, out / f.name)
    today = date.today().isoformat()
    (out / "sitemap.xml").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
                                     + "".join(f"  <url><loc>{SITE}{sub}</loc><lastmod>{today}</lastmod></url>\n" for _, sub, _, _ in PAGES)
                                     + "</urlset>\n")
    print(f"site: {out}")


if __name__ == "__main__":
    main()

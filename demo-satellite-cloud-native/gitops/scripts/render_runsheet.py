#!/usr/bin/env python3
"""Render a Markdown run sheet into one self-contained, offline HTML page.

    render_runsheet.py INPUT.md OUTPUT.html [--title TITLE]

Placeholders {{NAME}} are filled from environment variables RUNSHEET_<NAME>,
also inside code blocks so commands stay copy-paste ready. Placeholders whose
name ends in _PASSWORD or _TOKEN are secrets: masked (with show/copy) in prose
and tables, blurred in code blocks until hovered, clicked or revealed with the
page-level toggle. Unknown or unset placeholders stay visible in orange and are
listed on stderr.

The output contains credentials: it is written with mode 0600, and inside a
git work tree only to names matching *.local.html or runsheet*.html (both
gitignored). Python 3 standard library only; no external resources.
"""

import argparse
import subprocess
import datetime
import fnmatch
import html
import os
import re
import sys

ENV_PREFIX = "RUNSHEET_"
SECRET_SUFFIXES = ("_PASSWORD", "_TOKEN")
ALLOWED_IN_GIT = ("*.local.html", "runsheet*.html")

# Private-use sentinels survive HTML escaping and inline parsing untouched.
S_OPEN, S_CLOSE = "\ue000", "\ue001"
BR = "\ue002"  # hard line break marker inside a paragraph
PH_RE = re.compile(r"\{\{\s*([A-Za-z][A-Za-z0-9_]*)\s*\}\}")
SENT_RE = re.compile(S_OPEN + r"([A-Za-z0-9_]+)" + S_CLOSE)

MASK = "•" * 6

# Connections card: (label, url placeholder, login text, password placeholder)
CONNECTIONS = [
    ("Satellite", "SAT_URL", "admin", "DEMO_PASSWORD"),
    ("IdM", "IDM_URL", "admin", "DEMO_PASSWORD"),
    ("Gitea", "GITEA_URL", "{{GITEA_USER}}", "DEMO_PASSWORD"),
    ("Fleet repo", "GITEA_REPO_URL", None, None),
    ("AAP", "AAP_URL", "admin", "AAP_PASSWORD"),
    ("Argo CD", "ARGOCD_URL", "Log in via OpenShift", None),
    ("OpenShift console", "CONSOLE_URL", None, None),
    ("Host page lc-dev", "LC_DEV_URL", None, None),
    ("Host page lc-qa", "LC_QA_URL", None, None),
    ("Host page lc-prod", "LC_PROD_URL", None, None),
]
FACTS = [("Apps domain", "APPS_DOMAIN"), ("Next demo-app version", "NEXT_VERSION")]


def is_secret(name):
    return name.endswith(SECRET_SUFFIXES)


class Values:
    """Placeholder values from the environment, plus bookkeeping of misses."""

    def __init__(self, environ):
        self.v = {k[len(ENV_PREFIX):]: val for k, val in environ.items()
                  if k.startswith(ENV_PREFIX) and val != ""}
        self.missing = []

    def get(self, name):
        return self.v.get(name)

    def miss(self, name):
        if name not in self.missing:
            self.missing.append(name)


def esc(s):
    return html.escape(s, quote=True)


# ---------------------------------------------------------------- placeholders

def pre_substitute(text, vals):
    """Known, non-secret values go in as plain text (so URLs become links);
    secrets and unknown names become sentinels resolved per context later."""
    def rep(m):
        name = m.group(1)
        val = vals.get(name)
        if val is not None and not is_secret(name):
            return val
        if val is None:
            vals.miss(name)
        return S_OPEN + name + S_CLOSE
    return PH_RE.sub(rep, text)


def resolve(s, ctx, vals):
    """Replace sentinels in already escaped HTML. ctx: text | code | attr."""
    def rep(m):
        name = m.group(1)
        val = vals.get(name)
        if val is None:
            if ctx == "attr":
                return esc("{{%s}}" % name)
            return '<span class="ph-missing" title="placeholder not set: RUNSHEET_%s">{{%s}}</span>' % (name, name)
        if ctx == "attr":
            return esc(val)
        if ctx == "code":
            return ('<span class="secret-code" title="%s (click to reveal)">%s</span>'
                    % (esc(name), esc(val)))
        return secret_widget(name, val)
    return SENT_RE.sub(rep, s)


def secret_widget(name, val):
    return ('<span class="secret" data-secret="%s" title="%s">'
            '<span class="mask">%s</span>'
            '<button type="button" class="sbtn" data-act="show">show</button>'
            '<button type="button" class="sbtn" data-act="copy">copy</button></span>'
            % (esc(val), esc(name), MASK))


# --------------------------------------------------------------------- inline

INLINE_RE = re.compile(
    r"(?P<code>(?P<ticks>`+)(?P<ctext>.+?)(?P=ticks))"
    r"|(?P<link>\[(?P<ltext>[^\]]+)\]\((?P<lurl>[^)\s]+)(?:\s+\"[^\"]*\")?\))"
    r"|(?P<auto><(?P<aurl>https?://[^>\s]+)>)"
    r"|(?P<url>https?://[^\s<>\"'`\]]+)"
    r"|(?P<bold>\*\*(?=\S)(?P<btext>.+?)(?<=\S)\*\*)"
    r"|(?P<bold2>(?<!\w)__(?=\S)(?P<b2text>.+?)(?<=\S)__(?!\w))"
    r"|(?P<em>(?<![\w*])\*(?=[^\s*])(?P<etext>.+?)(?<=[^\s*])\*(?![\w*]))"
    r"|(?P<em2>(?<![\w])_(?=[^\s_])(?P<e2text>.+?)(?<=[^\s_])_(?!\w))",
    re.S,
)


def trim_url(url):
    """Strip trailing punctuation and an unbalanced closing parenthesis."""
    tail = ""
    while url and url[-1] in ".,;:!?)":
        if url[-1] == ")" and url.count("(") >= url.count(")"):
            break
        tail = url[-1] + tail
        url = url[:-1]
    return url, tail


def link_html(url, text_html, vals):
    href = resolve(esc(url), "attr", vals)
    if href.lower().startswith(("javascript:", "data:", "vbscript:")):
        return text_html
    ext = ' target="_blank" rel="noopener noreferrer"' if re.match(r"https?://", href) else ""
    return '<a href="%s"%s>%s</a>' % (href, ext, text_html)


def inline(s, vals):
    out, pos = [], 0
    for m in INLINE_RE.finditer(s):
        out.append(resolve(esc(s[pos:m.start()]), "text", vals))
        pos = m.end()
        if m.group("code"):
            c = m.group("ctext").replace("\n", " ")
            if c.startswith(" ") and c.endswith(" ") and c.strip():
                c = c[1:-1]
            out.append("<code>%s</code>" % resolve(esc(c), "code", vals))
        elif m.group("link"):
            out.append(link_html(m.group("lurl"), inline(m.group("ltext"), vals), vals))
        elif m.group("auto"):
            u = m.group("aurl")
            out.append(link_html(u, resolve(esc(u), "text", vals), vals))
        elif m.group("url"):
            u, tail = trim_url(m.group("url"))
            out.append(link_html(u, resolve(esc(u), "text", vals), vals))
            out.append(esc(tail))
        elif m.group("bold"):
            out.append("<strong>%s</strong>" % inline(m.group("btext"), vals))
        elif m.group("bold2"):
            out.append("<strong>%s</strong>" % inline(m.group("b2text"), vals))
        elif m.group("em"):
            out.append("<em>%s</em>" % inline(m.group("etext"), vals))
        elif m.group("em2"):
            out.append("<em>%s</em>" % inline(m.group("e2text"), vals))
    out.append(resolve(esc(s[pos:]), "text", vals))
    return "".join(out)


def inline_lines(lines, vals):
    """Paragraph text, parsed as a whole so code spans and emphasis may wrap
    across source lines. Two trailing spaces or a backslash = <br>."""
    parts = []
    for i, ln in enumerate(lines):
        brk = i < len(lines) - 1 and (ln.endswith("  ") or ln.endswith("\\"))
        ln = ln.strip()
        if brk and ln.endswith("\\"):
            ln = ln[:-1]
        parts.append(ln + (BR if brk else ""))
    return inline("\n".join(parts), vals).replace(BR, "<br>")


def plain_text(s):
    """Heading text without markup, for the TOC and slugs."""
    s = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", s)
    s = re.sub(r"[`*]|(?<!\w)_|_(?!\w)", "", s)
    s = SENT_RE.sub(lambda m: m.group(1), s)
    return s.strip()


# ---------------------------------------------------------------------- blocks

FENCE_RE = re.compile(r"^(\s*)(`{3,}|~{3,})\s*([^\s`]*)[^`]*$")
HEAD_RE = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
HR_RE = re.compile(r"^\s{0,3}([-*_])(?:\s*\1){2,}\s*$")
LIST_RE = re.compile(r"^(\s*)([-*+]|\d{1,9}[.)])(\s+)(.*)$")
QUOTE_RE = re.compile(r"^\s{0,3}>\s?(.*)$")
TSEP_RE = re.compile(r"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$")


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def split_row(line):
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|") and not s.endswith("\\|"):
        s = s[:-1]
    cells, cur, in_code, i = [], [], False, 0
    while i < len(s):
        ch = s[i]
        if ch == "\\" and i + 1 < len(s) and s[i + 1] == "|":
            cur.append("|")
            i += 2
            continue
        if ch == "`":
            in_code = not in_code
        if ch == "|" and not in_code:
            cells.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
        i += 1
    cells.append("".join(cur).strip())
    return cells


def is_table_start(lines, i):
    return ("|" in lines[i] and i + 1 < len(lines)
            and "-" in lines[i + 1] and TSEP_RE.match(lines[i + 1]) is not None)


class Renderer:
    def __init__(self, vals):
        self.vals = vals
        self.headings = []      # (level, id, text)
        self.ids = {"rs-connections"}
        self.first_h1 = None
        self.drop_first_h1 = True

    def slug(self, text):
        base = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "section"
        sid, n = base, 2
        while sid in self.ids:
            sid, n = "%s-%d" % (base, n), n + 1
        self.ids.add(sid)
        return sid

    def starts_block(self, lines, i):
        ln = lines[i]
        return bool(FENCE_RE.match(ln) or HEAD_RE.match(ln) or HR_RE.match(ln)
                    or QUOTE_RE.match(ln) or LIST_RE.match(ln) or is_table_start(lines, i))

    def blocks(self, lines):
        """Return a list of (kind, html)."""
        out, i, n = [], 0, len(lines)
        while i < n:
            ln = lines[i]
            if not ln.strip():
                i += 1
                continue

            m = FENCE_RE.match(ln)
            if m:
                ind, fence, lang = len(m.group(1)), m.group(2), m.group(3)
                body, i = [], i + 1
                while i < n and not (lines[i].strip().startswith(fence[0] * len(fence))
                                     and lines[i].strip().strip(fence[0]) == ""):
                    l2 = lines[i]
                    body.append(l2[min(ind, indent_of(l2)):])
                    i += 1
                i += 1  # closing fence (or EOF)
                out.append(("code", self.code_block(body, lang)))
                continue

            m = HEAD_RE.match(ln)
            if m:
                level, text = len(m.group(1)), m.group(2)
                ptext = plain_text(text)
                if level == 1 and self.first_h1 is None:
                    self.first_h1 = ptext
                    i += 1
                    if self.drop_first_h1:
                        continue
                sid = self.slug(ptext)
                if level in (2, 3):
                    self.headings.append((level, sid, ptext))
                out.append(("h", '<h%d id="%s">%s<a class="anchor" href="#%s" aria-label="link">#</a></h%d>'
                            % (level, sid, inline(text, self.vals), sid, level)))
                i += 1
                continue

            if HR_RE.match(ln):
                out.append(("hr", "<hr>"))
                i += 1
                continue

            if is_table_start(lines, i):
                i = self.table(lines, i, out)
                continue

            if QUOTE_RE.match(ln):
                body = []
                while i < n and lines[i].strip():
                    q = QUOTE_RE.match(lines[i])
                    body.append(q.group(1) if q else lines[i])
                    i += 1
                inner = self.join(self.blocks(body))
                out.append(("quote", "<blockquote>%s</blockquote>" % inner))
                continue

            if LIST_RE.match(ln):
                i = self.list_block(lines, i, out)
                continue

            # paragraph (also the fallback for anything unknown)
            para = [ln]
            i += 1
            while i < n and lines[i].strip() and not self.starts_block(lines, i):
                para.append(lines[i])
                i += 1
            out.append(("p", "<p>%s</p>" % inline_lines(para, self.vals)))
        return out

    @staticmethod
    def join(blocks):
        return "\n".join(h for _, h in blocks)

    def code_block(self, body, lang):
        while body and not body[-1].strip():
            body.pop()
        code = resolve(esc("\n".join(body)), "code", self.vals)
        cls = ' class="language-%s"' % esc(lang) if lang else ""
        label = '<span class="lang">%s</span>' % esc(lang) if lang else ""
        return ('<div class="codeblock">%s<button type="button" class="copy">copy</button>'
                '<pre><code%s>%s</code></pre></div>' % (label, cls, code))

    def table(self, lines, i, out):
        head = split_row(lines[i])
        aligns = []
        for c in split_row(lines[i + 1]):
            c = c.strip()
            aligns.append("center" if c.startswith(":") and c.endswith(":")
                          else "right" if c.endswith(":") else "left" if c.startswith(":") else "")
        i += 2
        rows = []
        while i < len(lines) and lines[i].strip() and "|" in lines[i]:
            rows.append(split_row(lines[i]))
            i += 1
        ncol = len(head)

        def cell(tag, txt, k):
            a = aligns[k] if k < len(aligns) and aligns[k] else ""
            st = ' style="text-align:%s"' % a if a else ""
            return "<%s%s>%s</%s>" % (tag, st, inline(txt, self.vals), tag)

        h = ["<div class=\"tablewrap\"><table><thead><tr>"]
        h += [cell("th", head[k], k) for k in range(ncol)]
        h.append("</tr></thead><tbody>")
        for r in rows:
            r = (r + [""] * ncol)[:max(ncol, 1)]
            h.append("<tr>" + "".join(cell("td", r[k], k) for k in range(ncol)) + "</tr>")
        h.append("</tbody></table></div>")
        out.append(("table", "".join(h)))
        return i

    def list_block(self, lines, i, out):
        n = len(lines)
        m = LIST_RE.match(lines[i])
        base_ind = len(m.group(1))
        ordered = m.group(2)[0].isdigit()
        start = int(m.group(2)[:-1]) if ordered else 1
        items, loose = [], False
        while i < n:
            m = LIST_RE.match(lines[i])
            if not m or len(m.group(1)) != base_ind or m.group(2)[0].isdigit() != ordered:
                break
            content_ind = base_ind + len(m.group(2)) + min(len(m.group(3)), 4)
            body = [m.group(4)]
            i += 1
            had_blank = False
            while i < n:
                ln = lines[i]
                if not ln.strip():
                    # blank: continue only if the next non-blank line is indented into the item
                    j = i
                    while j < n and not lines[j].strip():
                        j += 1
                    if j < n and indent_of(lines[j]) > base_ind:
                        body.extend([""] * (j - i))
                        had_blank = True
                        i = j
                        continue
                    break
                ind = indent_of(ln)
                if ind > base_ind:
                    body.append(ln[min(ind, content_ind):])
                    i += 1
                    continue
                # lazy continuation of the item's paragraph
                if body[-1].strip() and not self.starts_block(lines, i):
                    body.append(ln.strip())
                    i += 1
                    continue
                break
            items.append((body, had_blank))
            # a blank line between items makes the list loose
            if i < n and not lines[i].strip():
                j = i
                while j < n and not lines[j].strip():
                    j += 1
                nm = LIST_RE.match(lines[j]) if j < n else None
                if nm and len(nm.group(1)) == base_ind and nm.group(2)[0].isdigit() == ordered:
                    loose = True
                    i = j
                    continue
                break
        tag = "ol" if ordered else "ul"
        attr = ' start="%d"' % start if ordered and start != 1 else ""
        h = ["<%s%s>" % (tag, attr)]
        for body, had_blank in items:
            blocks = self.blocks(body)
            if not (loose or had_blank):
                blocks = [(k, html_[3:-4]) if k == "p" else (k, html_) for k, html_ in blocks]
            h.append("<li>%s</li>" % self.join(blocks))
        h.append("</%s>" % tag)
        out.append(("list", "\n".join(h)))
        return i


# ------------------------------------------------------------------- the page

CSS = r"""
:root{--bg:#000;--panel:#151515;--panel2:#1f1f1f;--line:#383838;--text:#fff;--muted:#c7c7c7;
--red:#ee0000;--teal:#37a3a3;--warn:#f0ab00;--orange:#ff8c00;
--sans:"Red Hat Text","Red Hat Display",Helvetica,Arial,sans-serif;
--head:"Red Hat Display","Red Hat Text",Helvetica,Arial,sans-serif;--mono:"Red Hat Mono",Menlo,Consolas,monospace}
*{box-sizing:border-box}
html{scroll-padding-top:16px}
body{margin:0;background:var(--bg);color:var(--muted);font:15px/1.6 var(--sans)}
header.top{background:var(--panel);border-top:4px solid var(--red);border-bottom:1px solid var(--line);
padding:18px 28px;display:flex;align-items:center;gap:24px;flex-wrap:wrap}
header.top h1{font:700 24px/1.25 var(--head);color:var(--text);margin:0;flex:1 1 400px}
header.top .meta{font-size:13px;color:var(--muted);display:flex;gap:16px;align-items:center;flex-wrap:wrap}
.layout{display:grid;grid-template-columns:290px minmax(0,1fr);max-width:1500px;margin:0 auto}
nav.toc{position:sticky;top:0;align-self:start;height:100vh;overflow-y:auto;padding:22px 14px 40px 22px;
border-right:1px solid var(--line);font-size:13.5px}
nav.toc .tt{font:600 12px var(--head);letter-spacing:.08em;text-transform:uppercase;color:var(--teal);margin:0 0 10px}
nav.toc ul{list-style:none;margin:0;padding:0}
nav.toc li a{display:block;padding:4px 8px;color:var(--muted);text-decoration:none;border-left:2px solid transparent;line-height:1.35}
nav.toc li a:hover{color:var(--text);background:var(--panel2)}
nav.toc li a.active{color:var(--text);border-left-color:var(--red);background:var(--panel)}
nav.toc li.l3 a{padding-left:22px;font-size:12.5px}
main{padding:24px 40px 80px;min-width:0;max-width:1100px}
h1,h2,h3,h4,h5,h6{font-family:var(--head);color:var(--text);line-height:1.3}
h2{font-size:24px;margin:44px 0 14px;padding-bottom:8px;border-bottom:2px solid var(--red)}
h3{font-size:19px;margin:32px 0 10px;color:var(--text)}
h3::before{content:"";display:inline-block;width:6px;height:16px;background:var(--teal);margin-right:10px;vertical-align:-1px}
h4{font-size:16px;margin:22px 0 8px}
h1 .anchor,h2 .anchor,h3 .anchor,h4 .anchor,h5 .anchor,h6 .anchor{margin-left:8px;color:var(--line);text-decoration:none;font-weight:400;opacity:0}
h2:hover .anchor,h3:hover .anchor,h4:hover .anchor{opacity:1}
p{margin:10px 0}
strong{color:var(--text)}
em{color:#e0e0e0}
a{color:#73c5c5;text-decoration:underline;text-decoration-color:rgba(55,163,163,.5);text-underline-offset:2px;overflow-wrap:anywhere}
a:hover{color:#fff;text-decoration-color:var(--red)}
code{font-family:var(--mono);font-size:.88em;-webkit-box-decoration-break:clone;box-decoration-break:clone;background:var(--panel2);color:#f5f5f5;padding:1px 5px;border-radius:3px;border:1px solid #2c2c2c}
.codeblock{position:relative;margin:14px 0;background:var(--panel);border:1px solid var(--line);border-left:3px solid var(--teal);border-radius:4px}
.codeblock pre{margin:0;padding:14px 16px;overflow-x:auto;font:13px/1.5 var(--mono);color:#e8e8e8}
.codeblock pre code{background:none;border:0;padding:0;font-size:inherit;color:inherit;white-space:pre}
.codeblock .lang{position:absolute;top:4px;right:70px;font:11px var(--mono);color:#8a8d90;text-transform:lowercase}
button{font:600 11.5px var(--sans);cursor:pointer;border-radius:3px}
.codeblock .copy{position:absolute;top:6px;right:6px;background:var(--panel2);color:var(--muted);border:1px solid var(--line);padding:2px 9px;opacity:.75}
.codeblock:hover .copy{opacity:1}
.copy:hover,.sbtn:hover{color:#fff;border-color:var(--teal)}
.copy.ok,.sbtn.ok{border-color:var(--teal);color:var(--teal)}
.tablewrap{overflow-x:auto;margin:14px 0}
table{border-collapse:collapse;width:100%;font-size:14px}
th,td{border:1px solid var(--line);padding:7px 10px;vertical-align:top;text-align:left}
th{background:var(--panel2);color:var(--text);font-family:var(--head);font-weight:600}
tbody tr:nth-child(odd) td{background:#0b0b0b}
blockquote{margin:14px 0;padding:6px 16px;border-left:4px solid var(--red);background:var(--panel);color:var(--muted)}
hr{border:0;border-top:1px solid var(--line);margin:28px 0}
ul,ol{padding-left:26px;margin:10px 0}
li{margin:4px 0}
li>ul,li>ol{margin:4px 0}
li::marker{color:var(--teal)}
.ph-missing{background:rgba(255,140,0,.18);color:var(--orange);border:1px dashed var(--orange);border-radius:3px;padding:0 3px;font-family:var(--mono);font-size:.9em}
.secret{display:inline-flex;align-items:center;gap:4px;white-space:nowrap}
.secret .mask{font-family:var(--mono);color:var(--text);background:var(--panel2);padding:0 6px;border-radius:3px;letter-spacing:.05em}
.sbtn{background:transparent;color:var(--muted);border:1px solid var(--line);padding:0 6px;line-height:18px}
.secret-code{filter:blur(5px);cursor:pointer;transition:filter .15s;background:rgba(238,0,0,.12);border-radius:2px}
.secret-code:hover,.secret-code.shown,body.reveal .secret-code{filter:none}
.toggle{display:inline-flex;align-items:center;gap:8px;background:var(--panel2);color:var(--muted);border:1px solid var(--line);padding:5px 12px}
.toggle .dot{width:28px;height:15px;border-radius:8px;background:var(--red);position:relative;transition:background .15s}
.toggle .dot::after{content:"";position:absolute;top:2px;left:15px;width:11px;height:11px;border-radius:50%;background:#fff;transition:left .15s}
body.reveal .toggle .dot{background:#555}
body.reveal .toggle .dot::after{left:2px}
.card{background:var(--panel);border:1px solid var(--line);border-top:3px solid var(--red);border-radius:4px;padding:14px 18px 10px;margin:4px 0 26px}
.card h2{border:0;margin:0 0 8px;padding:0;font-size:17px;color:var(--text)}
.card table{font-size:13.5px}
.card td,.card th{border:0;border-bottom:1px solid #262626;padding:6px 10px 6px 0;background:none!important}
.card td:first-child{color:var(--text);font-weight:600;white-space:nowrap;width:1%}
.card td.login{white-space:nowrap}
.card .facts{margin:8px 0 2px;font-size:13.5px;display:flex;gap:28px;flex-wrap:wrap}
.card .facts b{color:var(--teal);font-weight:600;margin-right:6px}
.card .empty{color:#8a8d90;font-size:13px}
.warnbox{background:rgba(255,140,0,.1);border:1px solid var(--orange);color:#ffd8a8;border-radius:4px;padding:8px 14px;margin:0 0 18px;font-size:13.5px}
@media (max-width:900px){.layout{grid-template-columns:1fr}nav.toc{position:static;max-height:none;border-right:0;border-bottom:1px solid var(--line)}main{padding:18px}}
@media print{
:root{--bg:#fff;--panel:#f4f4f4;--panel2:#ececec;--line:#bbb;--text:#000;--muted:#222}
body{font-size:11pt;background:#fff;color:#222}
header.top{background:#fff;padding:0 0 8px;border-top:0;border-bottom:3px solid var(--red)}
.layout{display:block}nav.toc,button,.copy,.lang,.anchor{display:none!important}
main{padding:0;max-width:none}
a{color:#004d4d}
em{color:#222}
.warnbox{color:#6b3a00;background:#fff3e0}
.ph-missing{color:#a35200}
code,.codeblock pre{color:#000}
tbody tr:nth-child(odd) td{background:#fafafa}
.codeblock{break-inside:avoid;border-left-color:var(--teal)}
.codeblock pre{white-space:pre-wrap;word-break:break-all}
.codeblock pre code{white-space:pre-wrap}
h2,h3{break-after:avoid}
.secret-code{filter:none;color:transparent;background:#ccc}
body.reveal .secret-code{color:#000;background:none}
.card{border-color:#999}
}
"""

JS = r"""
(function(){
function copyText(t,btn){
  function done(){if(!btn)return;var o=btn.textContent;btn.textContent='copied';btn.classList.add('ok');
    setTimeout(function(){btn.textContent=o;btn.classList.remove('ok');},1200);}
  function fallback(){var ta=document.createElement('textarea');ta.value=t;ta.setAttribute('readonly','');
    ta.style.position='fixed';ta.style.opacity='0';document.body.appendChild(ta);ta.select();
    try{document.execCommand('copy');done();}catch(e){}document.body.removeChild(ta);}
  if(navigator.clipboard&&window.isSecureContext){navigator.clipboard.writeText(t).then(done,fallback);}else{fallback();}
}
function setSecret(s,show){var m=s.querySelector('.mask'),b=s.querySelector('[data-act=show]');
  m.textContent=show?s.getAttribute('data-secret'):'••••••';
  if(b)b.textContent=show?'hide':'show';s.classList.toggle('shown',show);}
document.addEventListener('click',function(e){
  var b=e.target.closest('button');
  if(b&&b.classList.contains('copy')){var c=b.parentNode.querySelector('pre code');copyText(c.textContent.replace(/\n$/,''),b);return;}
  if(b&&b.dataset.act){var s=b.closest('.secret');
    if(b.dataset.act==='copy')copyText(s.getAttribute('data-secret'),b);
    else setSecret(s,!s.classList.contains('shown'));return;}
  if(b&&b.id==='reveal'){var on=document.body.classList.toggle('reveal');
    document.querySelectorAll('.secret').forEach(function(s){setSecret(s,on);});
    b.setAttribute('aria-pressed',on?'false':'true');return;}
  var sc=e.target.closest('.secret-code');if(sc){sc.classList.toggle('shown');}
});
var links=[].slice.call(document.querySelectorAll('nav.toc a'));
var map={};links.forEach(function(a){map[a.getAttribute('href').slice(1)]=a;});
if('IntersectionObserver' in window){var cur=null;
  var io=new IntersectionObserver(function(es){es.forEach(function(en){
    if(en.isIntersecting&&map[en.target.id]){if(cur)cur.classList.remove('active');cur=map[en.target.id];cur.classList.add('active');
      var nav=document.querySelector('nav.toc'),r=cur.getBoundingClientRect();
      if(r.top<0||r.bottom>window.innerHeight)cur.scrollIntoView({block:'nearest'});}});},{rootMargin:'0px 0px -75% 0px'});
  document.querySelectorAll('main h2[id],main h3[id]').forEach(function(h){io.observe(h);});}
})();
"""


def connections_card(vals):
    rows = []
    for label, url_ph, login, pw_ph in CONNECTIONS:
        url = vals.get(url_ph)
        if not url:
            continue
        link = link_html(url, esc(url), vals)
        parts = []
        if login:
            lt = PH_RE.sub(lambda m: vals.get(m.group(1)) or "{{%s}}" % m.group(1), login)
            parts.append(esc(lt))
        if pw_ph and vals.get(pw_ph):
            parts.append(secret_widget(pw_ph, vals.get(pw_ph)))
        login_html = " / ".join(parts)
        rows.append('<tr><td>%s</td><td>%s</td><td class="login">%s</td></tr>' % (esc(label), link, login_html))
    facts = ['<span><b>%s</b>%s</span>' % (esc(lbl), esc(vals.get(ph)))
             for lbl, ph in FACTS if vals.get(ph)]
    if not rows and not facts:
        body = ('<p class="empty">No connection values set (export RUNSHEET_SAT_URL, '
                'RUNSHEET_AAP_URL, ... or use render-runsheet.sh).</p>')
    else:
        body = ""
        if rows:
            body += "<table><tbody>%s</tbody></table>" % "".join(rows)
        if facts:
            body += '<div class="facts">%s</div>' % "".join(facts)
    return '<section class="card" id="rs-connections"><h2>Connections</h2>%s</section>' % body


def render(md_text, vals, title=None):
    md_text = md_text.replace("\r\n", "\n").replace("\t", "    ")
    md_text = pre_substitute(md_text, vals)
    r = Renderer(vals)
    content = r.join(r.blocks(md_text.split("\n")))
    page_title = title or r.first_h1 or "Run sheet"
    now = datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z")
    toc = "".join('<li class="l%d"><a href="#%s">%s</a></li>' % (lvl, sid, esc(txt))
                  for lvl, sid, txt in r.headings)
    warn = ""
    if vals.missing:
        warn = ('<div class="warnbox">Placeholders without a value (shown in orange): %s</div>'
                % ", ".join("<code>%s</code>" % esc(n) for n in vals.missing))
    return """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:">
<title>%(title)s</title>
<style>%(css)s</style>
</head>
<body>
<header class="top">
<h1>%(title)s</h1>
<div class="meta"><span>Rendered %(now)s</span>
<button type="button" id="reveal" class="toggle" aria-pressed="true" title="Secrets are hidden by default"><span class="dot"></span>hide secrets</button></div>
</header>
<div class="layout">
<nav class="toc" aria-label="Contents"><p class="tt">Contents</p><ul><li class="l2"><a href="#rs-connections">Connections</a></li>%(toc)s</ul></nav>
<main>
%(warn)s%(card)s
%(content)s
</main>
</div>
<script>%(js)s</script>
</body>
</html>
""" % {"title": esc(page_title), "css": CSS, "now": esc(now), "toc": toc, "warn": warn,
       "card": connections_card(vals), "content": content, "js": JS}


# ------------------------------------------------------------------------ CLI

def git_work_tree(path):
    """Nearest ancestor of path that contains .git, or None."""
    d = os.path.dirname(os.path.abspath(path))
    while not os.path.isdir(d):
        d = os.path.dirname(d)
    while True:
        if os.path.exists(os.path.join(d, ".git")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def main(argv=None):
    ap = argparse.ArgumentParser(description="Render a Markdown run sheet into one offline HTML page.")
    ap.add_argument("input", help="Markdown file")
    ap.add_argument("output", help="HTML file to write (mode 0600)")
    ap.add_argument("--title", help="page title (default: first H1)")
    a = ap.parse_args(argv)

    out = os.path.abspath(os.path.expanduser(a.output))
    repo = git_work_tree(out)
    name = os.path.basename(out)
    # Inside a repository the name must match an allowed pattern AND git must
    # really ignore the path (a different repo, e.g. a dotfiles repo around
    # ~/.cache, may not have the rule).
    ignored = False
    if repo:
        try:
            ignored = subprocess.run(["git", "-C", repo, "check-ignore", "-q", out],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        except OSError:
            ignored = False
    if repo and not (ignored and any(fnmatch.fnmatch(name, p) for p in ALLOWED_IN_GIT)):
        sys.stderr.write(
            "ERROR: %s is inside the git work tree %s.\n"
            "       The rendered page contains credentials. Inside a repository the file name\n"
            "       must match %s and be gitignored, or write it outside, e.g. ~/.cache/satellite-demo/runsheet.html\n"
            % (out, repo, " or ".join(ALLOWED_IN_GIT)))
        return 2

    try:
        with open(a.input, encoding="utf-8") as f:
            md_text = f.read()
    except OSError as e:
        sys.stderr.write("ERROR: cannot read %s: %s\n" % (a.input, e))
        return 1

    vals = Values(os.environ)
    page = render(md_text, vals, a.title)

    os.makedirs(os.path.dirname(out), mode=0o700, exist_ok=True)
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(fd, 0o600)
        os.write(fd, page.encode("utf-8"))
    finally:
        os.close(fd)

    if vals.missing:
        sys.stderr.write("WARNING: placeholders without a value (set RUNSHEET_<NAME>): %s\n"
                         % ", ".join(vals.missing))
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env bun
// Static documentation site generator for ink.
//
// Sources, all wired into one uploadable ./out folder:
//   doc/*.md              -> /doc/<name>      (guides & reference prose)
//   lib/*.k               -> /lib/<name>      (k library module reference; index at /lib)
//   out/demo/<name>.png   -> /demo/<name>     (rendered demos + k source)
//
// Run with:  bun public/build.mjs   (or `make docs`, which also captures demos)

import {
  readdirSync, readFileSync, writeFileSync,
  mkdirSync, rmSync, existsSync, cpSync,
} from "node:fs";
import { join, basename, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { renderMarkdown, escapeHtml, slug } from "./md.mjs";
import { extractK } from "./kdoc.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const OUT = join(ROOT, "out");

const p = (...a) => join(ROOT, ...a);
const write = (rel, html) => {
  const dst = join(OUT, rel);
  mkdirSync(dirname(dst), { recursive: true });
  writeFileSync(dst, html);
};

// --- titles ------------------------------------------------------------------

function prettify(name) {
  return name.replace(/[-_]/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}
function mdTitle(md, fallback) {
  const m = /^#\s+(.+)$/m.exec(md);
  return m ? m[1].trim() : prettify(fallback);
}

// --- discover sources --------------------------------------------------------

const docs = readdirSync(p("doc"))
  .filter((f) => f.endsWith(".md"))
  .sort()
  .map((f) => {
    const name = f.replace(/\.md$/, "");
    const md = readFileSync(p("doc", f), "utf8");
    return { name, file: f, title: mdTitle(md, name), md };
  });

// Library reference: one page per k module in lib/*.k.
const mods = readdirSync(p("lib"))
  .filter((f) => f.endsWith(".k"))
  .sort()
  .map((f) => extractK(p("lib", f), f.replace(/\.k$/, "")))
  .filter((m) => m.defs.length || m.overview.length);

// Demos: whatever snap.sh produced under out/demo (png + optional .k source).
const demoDir = join(OUT, "demo");
let demos = [];
if (existsSync(demoDir)) {
  demos = readdirSync(demoDir)
    .filter((f) => f.endsWith(".png"))
    .sort()
    .map((f) => {
      const name = f.replace(/\.png$/, "");
      const kPath = join(demoDir, name + ".k");
      const src = existsSync(kPath) ? readFileSync(kPath, "utf8") : "";
      // First `//` or `/` comment line of the script makes a nice caption.
      const cap = (src.match(/^\s*\/\s*(.+)$/m) || [])[1] || "";
      return { name, png: f, src, caption: cap.trim() };
    });
}

// --- library topics ----------------------------------------------------------

// Hand-curated grouping of lib/*.k modules by subject for the landing page and
// the /lib overview.  Any module not listed here falls into "Other" so nothing
// is ever silently dropped.
const TOPICS = [
  { title: "Graphics & Rendering", mods: ["gpu", "spirv", "draw", "pbr", "camera", "instancing", "layout", "color"] },
  { title: "Fonts & Text", mods: ["font", "regex", "fts"] },
  { title: "Image Formats", mods: ["image", "png", "jpeg", "gif", "bmp", "tga", "hdr", "pic"] },
  { title: "3D Assets", mods: ["gltf", "fbx", "usd"] },
  { title: "Math & Linear Algebra", mods: ["math", "lin", "svd", "pga", "fft", "stats"] },
  { title: "Data & Storage", mods: ["csv", "json", "parquet", "recs"] },
  { title: "Agents", mods: ["agent"] },
];
// Blurbs for modules whose source has no header comment to mine.
const BLURB = {
  agent: "Minimal LLM agent loop with tool-use scaffolding.",
  bmp: "BMP image reader and writer.",
  color: "Color spaces (HSL, OKLCh) and the Tailwind palette.",
  math: "Number-theory and combinatorics helpers.",
  fts: "Full-text search over an inverted index.",
};
const blurbOf = (m) => m.blurb || BLURB[m.name] || `lib/${m.name}.k`;

const byName = new Map(mods.map((m) => [m.name, m]));

// Render the by-topic library grid.  `heading` is the tag used per topic; the
// returned toc lists each topic for the overview page's table of contents.
function libraryTopics(root, heading = "h3") {
  const used = new Set();
  const groups = [...TOPICS.map((t) => ({ title: t.title, items: t.mods.map((n) => byName.get(n)).filter(Boolean) }))];
  groups.forEach((g) => g.items.forEach((m) => used.add(m.name)));
  const other = mods.filter((m) => !used.has(m.name));
  if (other.length) groups.push({ title: "Other", items: other });

  const toc = [];
  let out = "";
  for (const g of groups) {
    if (!g.items.length) continue;
    const id = slug("topic-" + g.title);
    toc.push({ level: 2, text: g.title, id });
    out += `<section class="lib-topic"><${heading} id="${id}">${escapeHtml(g.title)}</${heading}>\n<div class="home-grid">\n`;
    out += g.items.map((m) => modCard(`${root}lib/${m.name}.html`, m.name, blurbOf(m))).join("\n");
    out += `\n</div></section>\n`;
  }
  return { out, toc };
}

const modCard = (href, title, sub) =>
  `<a class="home-card" href="${href}"><div class="home-card-title">${escapeHtml(title)}</div><div class="home-card-sub">${escapeHtml(sub)}</div></a>`;

// Render the demo gallery (image cards).  Shared by the landing page and demo pages.
function galleryHtml(root) {
  if (!demos.length) return `<p class="empty">Run <code>make docs</code> to render demos.</p>`;
  return `<div class="gallery">\n` + demos.map((d) =>
    `<a class="card" href="${root}demo/${d.name}.html"><div class="card-img"><img src="${root}demo/${d.png}" alt="${escapeHtml(d.name)}" loading="lazy"></div><div class="card-body"><div class="card-title">${escapeHtml(d.name)}</div>${d.caption ? `<div class="card-cap">${escapeHtml(d.caption)}</div>` : ""}</div></a>`
  ).join("\n") + `\n</div>`;
}

// --- page shell --------------------------------------------------------------

function nav(active, root) {
  const item = (href, label, on) =>
    `<a href="${root}${href}"${on ? ' class="on"' : ""}>${escapeHtml(label)}</a>`;
  const group = (title, links) =>
    `<div class="nav-group"><div class="nav-title">${title}</div>${links.join("")}</div>`;

  return [
    group("Documentation",
      docs.map((d) => item(`doc/${d.name}.html`, d.title, active === `doc/${d.name}`))),
    group("Library",
      [item("lib/index.html", "Overview", active === "lib/index" || active.startsWith("lib/"))]),
    group("Demos",
      [...demos.map((d) => item(`demo/${d.name}.html`, d.name, active === `demo/${d.name}`))]),
  ].join("");
}

function page({ title, active, root, content, toc }) {
  const hasToc = toc && toc.length;
  const tocHtml = hasToc
    ? `<nav class="toc"><div class="toc-title">On this page</div>${
        toc.map((h) => `<a href="#${h.id}" class="lvl${h.level}">${escapeHtml(h.text)}</a>`).join("")
      }</nav>`
    : "";
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)} · ink</title>
<link rel="stylesheet" href="${root}style.css">
</head>
<body>
<header class="topbar">
  <button class="menu-btn" aria-label="Toggle navigation" onclick="document.body.classList.toggle('nav-open')">☰</button>
  <a class="brand" href="${root}index.html"><span class="logo">ink</span> <span class="brand-sub">array language</span></a>
  <div class="spacer"></div>
  <a class="ghlink" href="https://github.com/wrnrlr/ink" target="_blank" rel="noopener">GitHub</a>
  <button class="theme-btn" aria-label="Toggle theme" onclick="toggleTheme()">◐</button>
</header>
<div class="layout">
  <aside class="sidebar">${nav(active, root)}</aside>
  <main class="content${hasToc ? "" : " wide"}">
    <article>${content}</article>
    ${tocHtml}
  </main>
</div>
<script src="${root}app.js"></script>
</body>
</html>`;
}

// --- render doc pages --------------------------------------------------------

for (const d of docs) {
  const { html, headings } = renderMarkdown(d.md);
  write(`doc/${d.name}.html`, page({
    title: d.title, active: `doc/${d.name}`, root: "../",
    content: `<div class="doc-body">${html}</div>`,
    toc: headings,
  }));
}

// --- render library pages ----------------------------------------------------

function renderMod(m) {
  const toc = [];
  let body = `<p class="crumb"><a href="index.html">Library</a> / ${escapeHtml(m.name)}</p>\n`;
  body += `<h1><code>${escapeHtml(m.name)}</code> <span class="api-tag">module</span></h1>\n`;
  const blurb = blurbOf(m);
  if (blurb && !blurb.startsWith("lib/")) body += `<p class="lede">${escapeHtml(blurb)}</p>\n`;

  // Overview: the leading comment block, whitespace preserved (it often lists
  // the public API and supported syntax in aligned columns).
  const rest = m.blurb ? m.overview.slice(1) : m.overview;
  const overview = rest.join("\n").replace(/^\n+|\n+$/g, "");
  if (overview.trim()) body += `<pre class="module-doc">${escapeHtml(overview)}</pre>\n`;

  body += `<p class="api-meta"><code>lib/${m.name}.k</code> · ${m.defs.length} definitions</p>\n`;

  const documented = m.defs.filter((d) => d.doc || d.trailing || d.kind === "fn");
  const plain = m.defs.filter((d) => !(d.doc || d.trailing || d.kind === "fn"));

  if (documented.length) {
    toc.push({ level: 2, text: "Definitions", id: "definitions" });
    body += `<h2 id="definitions">Definitions <a class="anchor" href="#definitions">#</a></h2>\n<div class="decls">\n`;
    for (const d of documented) {
      const id = slug("def-" + d.name);
      const sig = d.params != null
        ? `${d.name}[${d.params}]`
        : d.name;
      body += `<div class="decl" id="${id}">`;
      body += `<div class="decl-sig"><span class="kind kind-${d.kind === "fn" ? "fn" : "value"}">${d.kind}</span> <code>${escapeHtml(sig)}</code>`;
      if (d.public) body += ` <span class="pub-tag">public</span>`;
      body += `</div>`;
      const prose = [d.doc, d.trailing && !d.doc ? d.trailing : ""].filter(Boolean).join("\n");
      if (prose) body += `<div class="doc-body decl-doc">${renderMarkdown(prose).html}</div>`;
      body += `<pre class="decl-src"><code class="language-k">${escapeHtml(d.source)}</code></pre>`;
      body += `</div>\n`;
    }
    body += `</div>\n`;
  }

  if (plain.length) {
    toc.push({ level: 2, text: "Values", id: "values" });
    body += `<h2 id="values">Values <a class="anchor" href="#values">#</a></h2>\n`;
    body += `<p class="api-meta">Constants and data defined without documentation.</p>\n`;
    body += `<div class="value-grid">\n`;
    for (const d of plain) body += `<code class="value-name">${escapeHtml(d.name)}</code>`;
    body += `</div>\n`;
  }

  return { body, toc };
}

for (const m of mods) {
  const { body, toc } = renderMod(m);
  write(`lib/${m.name}.html`, page({
    title: m.name, active: `lib/${m.name}`, root: "../",
    content: body, toc,
  }));
}

// library overview at /lib
{
  const { out, toc } = libraryTopics("../", "h2");
  let body = `<h1>Library</h1>\n`;
  body += `<p class="lede">The ink standard library — ${mods.length} modules written in k under <code>lib/</code>, grouped by subject.</p>\n`;
  body += out;
  write("lib/index.html", page({ title: "Library", active: "lib/index", root: "../", content: body, toc }));
}

// --- render demo pages -------------------------------------------------------

for (const d of demos) {
  let body = `<h1>${escapeHtml(d.name)}</h1>\n`;
  if (d.caption) body += `<p class="lede">${escapeHtml(d.caption)}</p>\n`;
  body += `<figure class="demo-shot"><img src="../demo/${d.png}" alt="${escapeHtml(d.name)} demo"></figure>\n`;
  body += `<p class="demo-run"><code>ink test/${d.name}.k</code></p>\n`;
  if (d.src) body += `<h2 id="source">Source <a class="anchor" href="#source">#</a></h2>\n<pre><code class="language-k">${escapeHtml(d.src)}</code></pre>\n`;
  write(`demo/${d.name}.html`, page({
    title: d.name, active: `demo/${d.name}`, root: "../",
    content: body, toc: [],
  }));
}

// --- home page ---------------------------------------------------------------

{
  const lib = libraryTopics("", "h3");
  const body = `
<section class="hero">
  <h1><span class="logo">ink</span></h1>
  <p class="tagline">A polysemic array programming language — an interpreter, compiler, and GPU toolkit in the spirit of k.</p>
  <div class="hero-actions">
    <a class="btn" href="doc/tutorial.html">Get started</a>
    <a class="btn ghost" href="doc/spec.html">Language reference</a>
  </div>
</section>

<section class="home-section" id="docs"><h2>Documentation</h2><div class="home-grid">
${docs.map((d) => modCard(`doc/${d.name}.html`, d.title, `doc/${d.name}.md`)).join("\n")}
</div></section>

<section class="home-section" id="demos"><h2>Demos</h2>
<p class="section-sub">Programs from <code>test/</code> rendered headlessly with <code>ink -snap</code>.</p>
${galleryHtml("")}
</section>

<section class="home-section" id="library"><h2>Library</h2>
<p class="section-sub">${mods.length} modules written in k under <code>lib/</code>. <a href="lib/index.html">Browse the full reference →</a></p>
${lib.out}
</section>`;
  write("index.html", page({ title: "ink documentation", active: "home", root: "", content: body, toc: [] }));
}

// --- copy static assets ------------------------------------------------------

cpSync(join(HERE, "style.css"), join(OUT, "style.css"));
cpSync(join(HERE, "app.js"), join(OUT, "app.js"));

const pages = docs.length + mods.length + demos.length + 2;
console.log(`Built ${pages} pages -> ${OUT}`);
console.log(`  ${docs.length} docs · ${mods.length} library modules · ${demos.length} demos`);

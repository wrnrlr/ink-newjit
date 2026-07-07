#!/usr/bin/env bun
// Static documentation site generator for ink.
//
// Sources, all wired into one uploadable ./out folder:
//   doc/*.md              -> /doc/<name>      (guides & reference prose)
//   src/**.zig            -> /api/ink         (core runtime API)
//   lib/<mod>/**.zig      -> /api/<mod>       (native extension modules)
//   out/demo/<name>.png   -> /demo/<name>     (rendered demos + k source)
//
// Run with:  bun docs/build.mjs   (or `make docs`, which also captures demos)

import {
  readdirSync, statSync, readFileSync, writeFileSync,
  mkdirSync, rmSync, existsSync, cpSync,
} from "node:fs";
import { join, basename, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { renderMarkdown, escapeHtml, slug } from "./md.mjs";
import { extractModule } from "./zig.mjs";

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

// API modules: core `ink` from src, plus each lib subdir that has .zig files.
const apiMods = [{ name: "ink", label: "ink (core)", dir: p("src"), blurb: "The core runtime: value model, parser, primitives, VM." }];
for (const ent of readdirSync(p("lib")).sort()) {
  const dir = p("lib", ent);
  if (!statSync(dir).isDirectory()) continue;
  const mod = extractModule(dir, ROOT);
  if (mod.length) apiMods.push({ name: ent, label: ent, dir, blurb: `Native \`${ent}\` extension module.` });
}
for (const m of apiMods) m.files = extractModule(m.dir, ROOT);

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

// --- page shell --------------------------------------------------------------

function nav(active, root) {
  const item = (href, label, on) =>
    `<a href="${root}${href}"${on ? ' class="on"' : ""}>${escapeHtml(label)}</a>`;
  const group = (title, links) =>
    `<div class="nav-group"><div class="nav-title">${title}</div>${links.join("")}</div>`;

  return [
    group("Documentation",
      docs.map((d) => item(`doc/${d.name}.html`, d.title, active === `doc/${d.name}`))),
    group("API Reference",
      apiMods.map((m) => item(`api/${m.name}.html`, m.label, active === `api/${m.name}`))),
    group("Demos",
      [item("demo/index.html", "Gallery", active === "demo/index"),
       ...demos.map((d) => item(`demo/${d.name}.html`, d.name, active === `demo/${d.name}`))]),
  ].join("");
}

function page({ title, active, root, content, toc }) {
  const tocHtml = toc && toc.length
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
  <main class="content">
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

// --- render API pages --------------------------------------------------------

const KIND_LABEL = { export: "export", fn: "fn", struct: "struct", enum: "enum", union: "union", const: "const", var: "var", type: "type" };

function renderModule(m) {
  const toc = [];
  let body = `<h1>${escapeHtml(m.label)} <span class="api-tag">API</span></h1>\n`;
  body += `<p class="lede">${renderMarkdown(m.blurb).html.replace(/^<p>|<\/p>\n?$/g, "")}</p>\n`;

  const totalDecls = m.files.reduce((n, f) => n + f.decls.length, 0);
  body += `<p class="api-meta">${m.files.length} source files · ${totalDecls} public declarations</p>\n`;

  for (const f of m.files) {
    const id = slug(f.path);
    toc.push({ level: 2, text: f.path, id });
    body += `<section class="api-file"><h2 id="${id}"><code>${escapeHtml(f.path)}</code><a class="anchor" href="#${id}">#</a></h2>\n`;
    if (f.doc) body += `<div class="doc-body file-doc">${renderMarkdown(f.doc).html}</div>\n`;
    if (f.decls.length) {
      body += `<div class="decls">\n`;
      for (const d of f.decls) {
        const k = KIND_LABEL[d.kind] || d.kind;
        let sig = d.sig.replace(/^(pub|export)\s+/, "");
        if (d.kind === "fn" || d.kind === "export") sig = sig.replace(/^fn\s+/, "");
        else if (["struct", "enum", "union"].includes(d.kind))
          sig = sig.replace(/\s*=\s*(extern\s+|packed\s+)?(struct|enum(\([^)]*\))?|union)\b.*$/, "").replace(/^(const|var)\s+/, "");
        body += `<div class="decl${d.nested ? " nested" : ""}">`;
        body += `<div class="decl-sig"><span class="kind kind-${d.kind}">${k}</span> <code>${escapeHtml(sig)}</code></div>`;
        if (d.doc) body += `<div class="doc-body decl-doc">${renderMarkdown(d.doc).html}</div>`;
        body += `</div>\n`;
      }
      body += `</div>\n`;
    }
    body += `</section>\n`;
  }
  return { body, toc };
}

for (const m of apiMods) {
  const { body, toc } = renderModule(m);
  write(`api/${m.name}.html`, page({
    title: m.label, active: `api/${m.name}`, root: "../",
    content: body, toc,
  }));
}

// --- render demo pages -------------------------------------------------------

for (const d of demos) {
  let body = `<h1>${escapeHtml(d.name)}</h1>\n`;
  if (d.caption) body += `<p class="lede">${escapeHtml(d.caption)}</p>\n`;
  body += `<figure class="demo-shot"><img src="${d.png}" alt="${escapeHtml(d.name)} demo"></figure>\n`;
  body += `<p class="demo-run"><code>ink test/${d.name}.k</code></p>\n`;
  if (d.src) body += `<h2 id="source">Source <a class="anchor" href="#source">#</a></h2>\n<pre><code class="language-k">${escapeHtml(d.src)}</code></pre>\n`;
  write(`demo/${d.name}.html`, page({
    title: d.name, active: `demo/${d.name}`, root: "../",
    content: body, toc: [],
  }));
}

// demo gallery index
{
  let body = `<h1>Demos</h1>\n<p class="lede">Programs from <code>test/</code> rendered headlessly with <code>ink -snap</code>.</p>\n`;
  if (demos.length) {
    body += `<div class="gallery">\n`;
    for (const d of demos) {
      body += `<a class="card" href="${d.name}.html"><div class="card-img"><img src="${d.png}" alt="${escapeHtml(d.name)}" loading="lazy"></div><div class="card-body"><div class="card-title">${escapeHtml(d.name)}</div>${d.caption ? `<div class="card-cap">${escapeHtml(d.caption)}</div>` : ""}</div></a>\n`;
    }
    body += `</div>\n`;
  } else {
    body += `<p class="empty">No demos captured. Run <code>make docs</code> (or <code>sh docs/snap.sh</code>) to render them.</p>\n`;
  }
  write("demo/index.html", page({ title: "Demos", active: "demo/index", root: "../", content: body, toc: [] }));
}

// --- home page ---------------------------------------------------------------

{
  const card = (href, title, sub) =>
    `<a class="home-card" href="${href}"><div class="home-card-title">${escapeHtml(title)}</div><div class="home-card-sub">${escapeHtml(sub)}</div></a>`;
  let body = `
<section class="hero">
  <h1><span class="logo">ink</span></h1>
  <p class="tagline">A polysemic array programming language — an interpreter, compiler, and GPU toolkit in the spirit of k.</p>
  <div class="hero-actions">
    <a class="btn" href="doc/tutorial.html">Get started</a>
    <a class="btn ghost" href="doc/spec.html">Language reference</a>
  </div>
</section>
<section class="home-section"><h2>Documentation</h2><div class="home-grid">
${docs.slice(0, 12).map((d) => card(`doc/${d.name}.html`, d.title, `doc/${d.name}.md`)).join("\n")}
</div></section>
<section class="home-section"><h2>API Reference</h2><div class="home-grid">
${apiMods.map((m) => card(`api/${m.name}.html`, m.label, m.blurb.replace(/`/g, ""))).join("\n")}
</div></section>
<section class="home-section"><h2>Demos</h2><div class="home-grid">
${demos.slice(0, 12).map((d) => card(`demo/${d.name}.html`, d.name, d.caption || `test/${d.name}.k`)).join("\n") || `<p class="empty">Run <code>make docs</code> to render demos.</p>`}
</div></section>`;
  write("index.html", page({ title: "ink documentation", active: "home", root: "", content: body, toc: [] }));
}

// --- copy static assets ------------------------------------------------------

cpSync(join(HERE, "style.css"), join(OUT, "style.css"));
cpSync(join(HERE, "app.js"), join(OUT, "app.js"));

const pages = docs.length + apiMods.length + demos.length + 2;
console.log(`Built ${pages} pages -> ${OUT}`);
console.log(`  ${docs.length} docs · ${apiMods.length} API modules · ${demos.length} demos`);

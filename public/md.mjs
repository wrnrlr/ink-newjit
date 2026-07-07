// Dependency-free Markdown -> HTML renderer.
// Covers the subset used across doc/*.md: ATX headings (with slug anchors),
// fenced code blocks, tables, ordered/unordered lists (one level of nesting),
// blockquotes, horizontal rules, paragraphs, and inline spans
// (code, bold, italic, links, images, autolinks).  No external dependencies.

export function escapeHtml(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

export function slug(text) {
  return text
    .toLowerCase()
    .replace(/`/g, "")
    .replace(/[^\w\s-]/g, "")
    .trim()
    .replace(/\s+/g, "-");
}

// --- inline ------------------------------------------------------------------

function inline(src) {
  let out = "";
  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i];
    // inline code — highest precedence, no formatting inside
    if (c === "`") {
      let j = i + 1;
      while (j < n && src[j] !== "`") j++;
      if (j < n) {
        out += `<code>${escapeHtml(src.slice(i + 1, j))}</code>`;
        i = j + 1;
        continue;
      }
    }
    // image  ![alt](url)
    if (c === "!" && src[i + 1] === "[") {
      const m = /^!\[([^\]]*)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)/.exec(src.slice(i));
      if (m) {
        const alt = escapeHtml(m[1]);
        const url = escapeHtml(m[2]);
        const title = m[3] ? ` title="${escapeHtml(m[3])}"` : "";
        out += `<img src="${url}" alt="${alt}"${title}>`;
        i += m[0].length;
        continue;
      }
    }
    // link  [text](url)
    if (c === "[") {
      const m = /^\[([^\]]*)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)/.exec(src.slice(i));
      if (m) {
        const text = inline(m[1]);
        const url = escapeHtml(m[2]);
        const ext = /^https?:/.test(m[2]) ? ' target="_blank" rel="noopener"' : "";
        out += `<a href="${url}"${ext}>${text}</a>`;
        i += m[0].length;
        continue;
      }
    }
    // autolink  <https://...>
    if (c === "<") {
      const m = /^<((?:https?|mailto):[^>\s]+)>/.exec(src.slice(i));
      if (m) {
        const url = escapeHtml(m[1]);
        out += `<a href="${url}" target="_blank" rel="noopener">${url}</a>`;
        i += m[0].length;
        continue;
      }
    }
    // bold  **text**
    if (c === "*" && src[i + 1] === "*") {
      const end = src.indexOf("**", i + 2);
      if (end !== -1) {
        out += `<strong>${inline(src.slice(i + 2, end))}</strong>`;
        i = end + 2;
        continue;
      }
    }
    // italic  *text*  (single, not part of **)
    if (c === "*") {
      const end = src.indexOf("*", i + 1);
      if (end !== -1 && src[i + 1] !== " ") {
        out += `<em>${inline(src.slice(i + 1, end))}</em>`;
        i = end + 1;
        continue;
      }
    }
    // escaped char
    if (c === "\\" && i + 1 < n) {
      out += escapeHtml(src[i + 1]);
      i += 2;
      continue;
    }
    out += escapeHtml(c);
    i++;
  }
  return out;
}

// --- tables ------------------------------------------------------------------

function isTableSep(line) {
  return /^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$/.test(line) && line.includes("-");
}

function splitRow(line) {
  let s = line.trim();
  if (s.startsWith("|")) s = s.slice(1);
  if (s.endsWith("|")) s = s.slice(0, -1);
  // split on unescaped pipes
  const cells = [];
  let cur = "";
  for (let i = 0; i < s.length; i++) {
    if (s[i] === "\\" && s[i + 1] === "|") { cur += "|"; i++; continue; }
    if (s[i] === "|") { cells.push(cur); cur = ""; continue; }
    cur += s[i];
  }
  cells.push(cur);
  return cells.map((c) => c.trim());
}

// --- block -------------------------------------------------------------------

export function renderMarkdown(md, opts = {}) {
  const headings = [];
  const lines = md.replace(/\r\n?/g, "\n").split("\n");
  let out = "";
  let i = 0;

  const flushListItem = (buf) => inline(buf.join("\n"));

  while (i < lines.length) {
    let line = lines[i];

    // fenced code block
    const fence = /^(```|~~~)(.*)$/.exec(line);
    if (fence) {
      const marker = fence[1];
      const lang = fence[2].trim().split(/\s+/)[0] || "";
      const body = [];
      i++;
      while (i < lines.length && !lines[i].startsWith(marker)) {
        body.push(lines[i]);
        i++;
      }
      i++; // closing fence
      const cls = lang ? ` class="language-${escapeHtml(lang)}"` : "";
      out += `<pre><code${cls}>${escapeHtml(body.join("\n"))}</code></pre>\n`;
      continue;
    }

    // ATX heading
    const h = /^(#{1,6})\s+(.*?)\s*#*\s*$/.exec(line);
    if (h) {
      const level = h[1].length;
      const text = h[2];
      const id = slug(text);
      if (level <= 3) headings.push({ level, text, id });
      out += `<h${level} id="${id}">${inline(text)}<a class="anchor" href="#${id}" aria-hidden="true">#</a></h${level}>\n`;
      i++;
      continue;
    }

    // horizontal rule
    if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) {
      out += "<hr>\n";
      i++;
      continue;
    }

    // table
    if (line.includes("|") && i + 1 < lines.length && isTableSep(lines[i + 1])) {
      const header = splitRow(line);
      const aligns = splitRow(lines[i + 1]).map((c) => {
        const l = c.startsWith(":");
        const r = c.endsWith(":");
        return l && r ? "center" : r ? "right" : l ? "left" : "";
      });
      i += 2;
      const rows = [];
      while (i < lines.length && lines[i].includes("|") && lines[i].trim() !== "") {
        rows.push(splitRow(lines[i]));
        i++;
      }
      out += "<table>\n<thead><tr>";
      header.forEach((c, k) => {
        const a = aligns[k] ? ` style="text-align:${aligns[k]}"` : "";
        out += `<th${a}>${inline(c)}</th>`;
      });
      out += "</tr></thead>\n<tbody>\n";
      for (const r of rows) {
        out += "<tr>";
        header.forEach((_, k) => {
          const a = aligns[k] ? ` style="text-align:${aligns[k]}"` : "";
          out += `<td${a}>${inline(r[k] ?? "")}</td>`;
        });
        out += "</tr>\n";
      }
      out += "</tbody>\n</table>\n";
      continue;
    }

    // blockquote
    if (/^\s*>/.test(line)) {
      const buf = [];
      while (i < lines.length && /^\s*>/.test(lines[i])) {
        buf.push(lines[i].replace(/^\s*>\s?/, ""));
        i++;
      }
      out += `<blockquote>\n${renderMarkdown(buf.join("\n")).html}</blockquote>\n`;
      continue;
    }

    // lists (unordered or ordered), with one level of nesting via indentation
    if (/^\s*([-*+]|\d+[.)])\s+/.test(line)) {
      const ordered = /^\s*\d+[.)]\s+/.test(line);
      const tag = ordered ? "ol" : "ul";
      out += `<${tag}>\n`;
      let openItem = false;
      let sub = null; // nested list buffer
      while (i < lines.length) {
        const li = lines[i];
        const m = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/.exec(li);
        if (m) {
          const indent = m[1].length;
          if (indent >= 2) {
            // nested item — buffer until nesting ends
            if (!sub) sub = [];
            sub.push(li.replace(/^\s\s/, ""));
            i++;
            continue;
          }
          if (sub) { out += renderMarkdown(sub.join("\n")).html; sub = null; }
          if (openItem) out += "</li>\n";
          out += `<li>${inline(m[3])}`;
          openItem = true;
          i++;
        } else if (li.trim() === "") {
          // blank line: peek — if next is still a list item, continue; else stop
          if (i + 1 < lines.length && /^\s*([-*+]|\d+[.)])\s+/.test(lines[i + 1])) {
            i++;
          } else break;
        } else if (/^\s{2,}\S/.test(li) && openItem) {
          // continuation line of current item
          out += " " + inline(li.trim());
          i++;
        } else break;
      }
      if (sub) out += renderMarkdown(sub.join("\n")).html;
      if (openItem) out += "</li>\n";
      out += `</${tag}>\n`;
      continue;
    }

    // blank line
    if (line.trim() === "") {
      i++;
      continue;
    }

    // paragraph — gather consecutive non-blank, non-block lines
    const para = [];
    while (
      i < lines.length &&
      lines[i].trim() !== "" &&
      !/^(#{1,6})\s/.test(lines[i]) &&
      !/^(```|~~~)/.test(lines[i]) &&
      !/^\s*>/.test(lines[i]) &&
      !/^\s*([-*+]|\d+[.)])\s+/.test(lines[i]) &&
      !/^\s*([-*_])(\s*\1){2,}\s*$/.test(lines[i])
    ) {
      para.push(lines[i]);
      i++;
    }
    if (para.length) out += `<p>${inline(para.join("\n"))}</p>\n`;
  }

  return { html: out, headings };
}

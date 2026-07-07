// Extract a reference from an ink/k library module (lib/*.k).
//
// Conventions these modules follow:
//   * `/` line comments (occasionally `//`); a leading comment block is the
//     module overview and usually lists the public API.
//   * top-level `name: expr` / `name.member: expr` definitions at column 0.
//   * a definition is documented by the `/` comment block directly above it
//     and/or an aligned trailing `   / comment` on its last line.
//   * `\d ns a b` opens a namespace and marks `a b …` as its public members.

import { readFileSync } from "node:fs";

const stripComment = (s) => s.replace(/^\s*\/\/?\s?/, "");

// Pull a trailing aligned comment (`… <2+ spaces>/ text`) off a source line,
// returning { code, comment }.  Two+ spaces before the slash distinguishes a
// comment from the `over` adverb (`+/x`, which has no leading space).
function splitTrailing(line) {
  const m = /^(.*\S)\s{2,}\/\s?(.*)$/.exec(line);
  if (m && !/["']/.test(m[2].slice(-1))) return { code: m[1], comment: m[2].trim() };
  return { code: line, comment: "" };
}

// Bracket depth contributed by a line (ignoring an obvious trailing comment).
function depthDelta(line) {
  let d = 0;
  for (const ch of line) {
    if (ch === "{" || ch === "(" || ch === "[") d++;
    else if (ch === "}" || ch === ")" || ch === "]") d--;
  }
  return d;
}

const DEF_RE = /^([A-Za-z_][\w]*(?:\.[A-Za-z_][\w]*)*)\s*::?\s*(.*)$/;

export function extractK(path, name) {
  const text = readFileSync(path, "utf8");
  const lines = text.replace(/\r\n?/g, "\n").split("\n");

  // leading comment block → module overview
  const head = [];
  let i = 0;
  while (i < lines.length && /^\s*\/\/?/.test(lines[i]) && lines[i].trim() !== "") {
    head.push(stripComment(lines[i]));
    i++;
  }
  // blurb: text after `name.k —` on the first line, else the first comment line
  let blurb = "";
  if (head.length) {
    const first = head[0];
    const dash = first.match(/^\S+\.k\s*[—-]\s*(.+)$/);
    blurb = dash ? dash[1].trim() : /^\[\[|^https?:/.test(first) ? "" : first.trim();
  }

  const publicNames = new Set();
  const defs = [];
  let doc = [];

  for (let j = 0; j < lines.length; j++) {
    const line = lines[j];
    const t = line.trim();

    if (/^\\d\b/.test(t)) {                       // namespace directive
      t.split(/\s+/).slice(2).forEach((n) => publicNames.add(n));
      doc = [];
      continue;
    }
    if (/^\s*\/\/?/.test(line) && t !== "") {     // comment line → buffer as doc
      doc.push(stripComment(line));
      continue;
    }
    if (t === "") { doc = []; continue; }         // blank line breaks a doc block

    // a column-0 definition?
    const indented = /^\s/.test(line);
    const m = !indented && DEF_RE.exec(line);
    if (m) {
      const defName = m[1];
      // gather the full (possibly multi-line) definition body by bracket balance
      const body = [line];
      let depth = depthDelta(splitTrailing(line).code);
      let k = j;
      while (depth > 0 && k + 1 < lines.length) {
        k++;
        body.push(lines[k]);
        depth += depthDelta(splitTrailing(lines[k]).code);
      }
      const trailing = splitTrailing(body[body.length - 1]).comment;
      const rhs = m[2].trimStart();
      const isFn = rhs.startsWith("{");
      const params = isFn ? (rhs.match(/^\{\s*\[([^\]]*)\]/) || [])[1] : null;

      defs.push({
        name: defName,
        kind: isFn ? "fn" : "value",
        params: params != null ? params.trim() : null,
        doc: doc.join("\n"),
        trailing,
        source: body.join("\n").replace(/\s+$/, ""),
      });
      doc = [];
      j = k;
      continue;
    }
    doc = [];
  }

  // A member is "documented" if it carries any prose; scalar constants without
  // a comment are listed compactly instead of getting a full entry.
  for (const d of defs) if (publicNames.has(d.name.split(".").pop())) d.public = true;

  return { name, blurb, overview: head, defs };
}

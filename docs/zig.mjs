// Extract a documented API surface from Zig source.
// For each .zig file we capture the file-level `//!` doc comment and every
// top-level (and one-level-nested) `pub fn` / `pub const` / `pub var`
// declaration together with its preceding `///` doc comment.  The result is a
// structured tree the site generator renders into an /api/<name> page.

import { readdirSync, statSync, readFileSync } from "node:fs";
import { join, relative, basename } from "node:path";

function walkZig(dir) {
  const out = [];
  for (const ent of readdirSync(dir)) {
    const p = join(dir, ent);
    const st = statSync(p);
    if (st.isDirectory()) out.push(...walkZig(p));
    else if (ent.endsWith(".zig")) out.push(p);
  }
  return out.sort();
}

// Kind + display name of a `pub`/`export` declaration line.
function classify(sig) {
  let m = /^export\s+fn\s+([A-Za-z_][\w]*|@"[^"]*")\s*\(/.exec(sig);
  if (m) return { kind: "export", name: m[1] };
  m = /^pub\s+fn\s+([A-Za-z_][\w]*|@"[^"]*")\s*\(/.exec(sig);
  if (m) return { kind: "fn", name: m[1] };
  m = /^pub\s+(?:const|var)\s+([A-Za-z_][\w]*|@"[^"]*")\b/.exec(sig);
  if (m) {
    let kind = "const";
    if (/=\s*(extern\s+)?struct\b/.test(sig)) kind = "struct";
    else if (/=\s*(extern\s+)?enum\b/.test(sig) || /=\s*enum\s*\(/.test(sig)) kind = "enum";
    else if (/=\s*(extern\s+|packed\s+)?union\b/.test(sig)) kind = "union";
    else if (/^pub\s+var\b/.test(sig)) kind = "var";
    else if (/=\s*(@import|@This)\b/.test(sig)) kind = "import";
    else if (/=\s*fn\s*\(/.test(sig)) kind = "type";
    return { kind, name: m[1] };
  }
  return null;
}

// Read a declaration signature starting at line `i`, joining wrapped lines until
// the statement head ends — the first `{` (body/container open) or `;` seen at
// paren/bracket depth 0.  The body itself is never consumed.  Returns { sig, next }.
function readSig(lines, i) {
  let sig = "";
  let paren = 0;
  for (let j = i; j < lines.length && j < i + 14; j++) {
    const line = lines[j];
    for (let c = 0; c < line.length; c++) {
      const ch = line[c];
      if (ch === "(" || ch === "[") paren++;
      else if (ch === ")" || ch === "]") paren--;
      else if (paren <= 0 && (ch === "{" || ch === ";")) {
        sig += (sig ? " " : "") + line.slice(0, c).trim() + (ch === "{" ? " {" : ";");
        return { sig: sig.trim(), next: j + 1 };
      }
    }
    sig += (sig ? " " : "") + line.trim();
  }
  return { sig: sig.trim(), next: i + 1 };
}

// Trim a signature for display: drop a trailing `{` / body and collapse space.
function tidySig(sig) {
  let s = sig.replace(/\s*\{\s*$/, "").replace(/;\s*$/, "").replace(/\s+/g, " ").trim();
  // For container decls keep just `pub const Name = struct` (drop the fields).
  s = s.replace(/=\s*(extern\s+|packed\s+)?(struct|enum|union)\b.*$/, (m, a, b) =>
    `= ${a || ""}${b}`.trim());
  s = s.replace(/=\s*enum\s*\(([^)]*)\).*$/, "= enum($1)");
  return s;
}

function extractFile(path, root) {
  const text = readFileSync(path, "utf8");
  const lines = text.split("\n");

  // file-level //! doc (leading block, allowing blank lines between)
  const fileDoc = [];
  for (let k = 0; k < lines.length; k++) {
    const t = lines[k].trim();
    if (t.startsWith("//!")) fileDoc.push(t.replace(/^\/\/!\s?/, ""));
    else if (t === "") continue;
    else break;
  }

  const decls = [];
  let doc = [];
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim();
    if (t.startsWith("///")) { doc.push(t.replace(/^\/\/\/\s?/, "")); continue; }
    if (t.startsWith("//")) continue; // ordinary comment: keep doc buffer? no, reset
    // a `pub`/`export` declaration at any indentation
    if (/^(pub|export)\s+(fn|const|var)\b/.test(t)) {
      const { sig, next } = readSig(lines, i);
      const cls = classify(sig);
      if (cls && cls.kind !== "import") {
        const indent = lines[i].length - lines[i].trimStart().length;
        decls.push({ ...cls, sig: tidySig(sig), doc: doc.join("\n"), nested: indent > 0 });
      }
      i = next - 1;
      doc = [];
      continue;
    }
    if (t !== "") doc = []; // any other code line clears the pending doc buffer
  }

  return {
    path: relative(root, path),
    file: basename(path),
    doc: fileDoc.join("\n"),
    decls,
  };
}

// Extract a whole module (a directory tree of .zig) into a list of file entries
// that actually carry documentation or public declarations.
export function extractModule(dir, root) {
  const files = walkZig(dir)
    .map((p) => extractFile(p, root))
    .filter((f) => f.doc || f.decls.length);
  return files;
}

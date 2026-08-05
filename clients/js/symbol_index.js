#!/usr/bin/env node
// Incremental workspace symbol + call-graph index for vibe.
//
// Motivation (LSP perf): the LSP server answers per-file queries by spawning a
// `vibe` subprocess (each loads the wasm compiler, ~0.5s). That is fine for a
// single hover but catastrophic for WORKSPACE-WIDE operations — `workspace/
// symbol` and `callHierarchy` would need one spawn per file (~420s for this
// repo's 754 files). This module builds an in-process, content-hash-keyed,
// INCREMENTAL index directly from source text (no subprocess), so a cold
// workspace scan is sub-second and a single-file edit re-indexes in microseconds.
//
// It is also the foundation for macro-level visualization (à la mizchi/
// sprawlens): `graph()` exports nodes (files / modules / symbols, sized by source
// span) and edges (calls / imports) as plain JSON a renderer can lay out.
//
// Extraction is a lightweight, comment/string-aware scan — NOT a full parse. It
// is AST-approximate by design (fast, dependency-free); the LSP can still refine
// a focused file with the AST-accurate `vibe symbols` when exactness matters.
"use strict";

// ---------------------------------------------------------------------------
// LSP SymbolKind numbers we emit.
// ---------------------------------------------------------------------------
const KIND = {
  Function: 12,
  Variable: 13,
  Struct: 23,
  Enum: 10,
  Interface: 11, // trait
  Module: 2,
  Class: 5, // type alias
};

// vibe keywords that can appear immediately before `(` but are NOT calls.
const NON_CALL = new Set([
  "if", "else", "match", "while", "for", "return", "with", "handle", "in", "as",
  "let", "mut", "export", "import", "enum", "struct", "trait", "module", "type",
  "test", "bench", "true", "false", "throw", "and", "or", "not", "fn",
]);

// FNV-1a 32-bit content hash (fast, stable across runs) for incremental skip.
function hashText(s) {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i) & 0xff;
    h = (h + ((h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24))) >>> 0;
  }
  return h >>> 0;
}

// Produce a "code mask": a copy of `text` where every byte that is inside a line
// comment (`// ...`) or a string literal ("...") is replaced by a space, but all
// offsets/newlines are preserved. Scanning the mask for declarations and calls
// then never false-matches words in comments/strings. vibe has no block comments.
function codeMask(text) {
  // Char-CODE comparisons (47 '/', 34 '"', 92 '\\', 10 '\n') avoid allocating a
  // one-char string per byte (text[i]), which dominated this O(n) scan in the
  // profile. allocUnsafe is safe: every byte is written before the toString.
  const n = text.length;
  const out = Buffer.allocUnsafe(n);
  let i = 0;
  let state = 0; // 0 = code, 1 = line comment, 2 = string
  while (i < n) {
    const c = text.charCodeAt(i);
    if (state === 0) {
      if (c === 47 && text.charCodeAt(i + 1) === 47) {
        out[i] = 32; out[i + 1] = 32; i += 2; state = 1; continue;
      }
      if (c === 34) { out[i] = 32; i++; state = 2; continue; }
      out[i] = c < 128 ? c : 32;
      i++;
    } else if (state === 1) {
      if (c === 10) { out[i] = 10; i++; state = 0; continue; }
      out[i] = 32; i++;
    } else {
      // inside string
      if (c === 92) { out[i] = 32; if (i + 1 < n) out[i + 1] = 32; i += 2; continue; }
      if (c === 34) { out[i] = 32; i++; state = 0; continue; }
      out[i] = c === 10 ? 10 : 32;
      i++;
    }
  }
  return out.toString("latin1");
}

// Match-brace from the open-brace at `open` to its closing `}` in `mask` (already
// comment/string-free). Returns the index of the matching `}` or text length.
function matchBrace(mask, open) {
  const n = mask.length;
  for (let i = open, depth = 0; i < n; i++) {
    const c = mask.charCodeAt(i); // 123 '{', 125 '}'
    if (c === 123) depth++;
    else if (c === 125) { if (--depth === 0) return i; }
  }
  return n;
}

// Top-level (and one level of `module { ... }`-nested) declarations.
// Recognizes: let / struct / enum / trait / module / type, with optional
// `export` and (for let) a `mut` or `rec` modifier (`let rec f = ...` is the
// common recursive-function form — without consuming it the name would parse as
// "rec"). For a let bound to a lambda we record Function, else Variable, and
// capture the body span (`{ ... }`) for call attribution.
// NOTE: this matches at ANY brace depth; the caller filters to depth 0 (top
// level) and depth 1 inside a `module` body, so locals inside function bodies
// (`let x = ...` in a lambda) are not mistaken for workspace symbols.
const DECL_RE =
  /(^|\n)[ \t]*(export[ \t]+)?(let|struct|enum|trait|module|type)[ \t]+(?:(?:mut|rec)[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)/g;

// The first top-level `=` at/after `from` that binds a `let` (skipping any inside
// (), [], {} — e.g. a `(...) -> T with E` signature — and the compound
// operators ==, =>, <=, >=, !=, :=). Returns its index, or -1 if none before the
// next top-level declaration. This separates a let's TYPE annotation from its
// VALUE, so the body brace is searched in the value, not in a `with E` set.
function findBindingEq(mask, from) {
  let depth = 0;
  for (let i = from; i < mask.length; i++) {
    const c = mask[i];
    if (c === "(" || c === "[" || c === "{") depth++;
    else if (c === ")" || c === "]" || c === "}") { if (depth === 0) return -1; depth--; }
    else if (depth === 0) {
      if (c === "\n" && /^[ \t]*(export[ \t]+)?(let|struct|enum|trait|module|type)[ \t]/.test(mask.slice(i + 1, i + 48))) return -1;
      if (c === "=" && mask[i + 1] !== "=" && mask[i + 1] !== ">" && mask[i - 1] !== "<" && mask[i - 1] !== ">" && mask[i - 1] !== "!" && mask[i - 1] !== ":" && mask[i - 1] !== "=") return i;
    }
  }
  return -1;
}

function declKind(keyword, mask, eqPos) {
  switch (keyword) {
    case "struct": return KIND.Struct;
    case "enum": return KIND.Enum;
    case "trait": return KIND.Interface;
    case "module": return KIND.Module;
    case "type": return KIND.Class;
    case "let": {
      // Function iff the VALUE (after the binding `=`) is a lambda `( ... ) ->`,
      // optionally with a leading `[T]` type-param list. eqPos isolates the value
      // from the type annotation, so a `(...) -> T with E = ...` signature
      // doesn't fool the scan.
      if (eqPos < 0) return KIND.Variable;
      let i = eqPos + 1;
      const n = mask.length;
      while (i < n && /\s/.test(mask[i])) i++;
      if (mask[i] === "[") { let d = 0; while (i < n) { if (mask[i] === "[") d++; else if (mask[i] === "]") { d--; if (!d) { i++; break; } } i++; } while (i < n && /\s/.test(mask[i])) i++; }
      return mask[i] === "(" ? KIND.Function : KIND.Variable;
    }
    default: return KIND.Variable;
  }
}

// Extract symbols, imports, and call edges from one file's source text.
function extractFile(text) {
  const mask = codeMask(text);

  // --- candidate declarations (any depth) with body spans ---
  const cands = [];
  DECL_RE.lastIndex = 0;
  let m;
  while ((m = DECL_RE.exec(mask)) !== null) {
    const lead = m[1] ? m[1].length : 0;
    const declStart = m.index + lead;
    const keyword = m[3];
    const name = m[4];
    const nameStart = m.index + m[0].length - name.length;
    const nameEnd = nameStart + name.length;
    // For a let, find the binding `=` so the body brace is searched in the VALUE,
    // not in a type-annotation `... with E` set. Other decls have no `=`.
    const eqPos = keyword === "let" ? findBindingEq(mask, nameEnd) : -1;
    const kind = declKind(keyword, mask, eqPos);
    // Body span: the first `{` on/after the value (let) or the name (aggregate),
    // brace-matched. A value let (`let x = 5`) has no body brace before the next
    // decl/EOF; the crossesDecl guard prevents claiming a LATER decl's brace.
    const bodyFrom = keyword === "let" ? (eqPos >= 0 ? eqPos + 1 : nameEnd) : nameEnd;
    const braceAt = mask.indexOf("{", bodyFrom);
    let bodyStart = -1, bodyEnd = nameEnd;
    if (braceAt >= 0) {
      const between = mask.slice(bodyFrom, braceAt);
      if (kind === KIND.Function || keyword !== "let" || !/\n[ \t]*(export[ \t]+)?(let|struct|enum|trait|module|type)[ \t]/.test(between)) {
        bodyStart = braceAt;
        bodyEnd = matchBrace(mask, braceAt);
      }
    }
    cands.push({ name, kind, keyword, nameStart, nameEnd, declStart, bodyStart, bodyEnd, depth: 0 });
  }

  // --- brace depth at each candidate's declStart (single pass) ---
  {
    let ci = 0, depth = 0;
    const n = mask.length;
    for (let i = 0; i < n && ci < cands.length; i++) {
      while (ci < cands.length && cands[ci].declStart === i) { cands[ci].depth = depth; ci++; }
      const c = mask.charCodeAt(i); // 123 '{', 125 '}'
      if (c === 123) depth++;
      else if (c === 125) depth--;
    }
  }

  // --- keep top-level (depth 0) + one level of module-nested (depth 1 inside a
  //     top-level `module` body). Locals inside function/struct bodies (depth>=1,
  //     not in a module) are dropped — they are not workspace symbols. ---
  const topLevel = cands.filter((c) => c.depth === 0);
  const moduleBodies = topLevel.filter((c) => c.keyword === "module" && c.bodyStart >= 0);
  const symbols = [];
  for (const c of topLevel) symbols.push({ name: c.name, kind: c.kind, keyword: c.keyword, container: null, nameStart: c.nameStart, nameEnd: c.nameEnd, declStart: c.declStart, bodyStart: c.bodyStart, bodyEnd: c.bodyEnd });
  for (const c of cands) {
    if (c.depth !== 1) continue;
    const mod = moduleBodies.find((mb) => mb.bodyStart < c.declStart && c.declStart < mb.bodyEnd);
    if (mod) symbols.push({ name: c.name, kind: c.kind, keyword: c.keyword, container: mod.name, nameStart: c.nameStart, nameEnd: c.nameEnd, declStart: c.declStart, bodyStart: c.bodyStart, bodyEnd: c.bodyEnd });
  }

  const imports = [];
  // --- dependency-bearing forms (all create an edge to a relative path):
  //       import <path> { A, B }      (named import)
  //       export <path> { A, B }      (re-export — index modules; ~heavy use)
  //       import <path> @alias        (whole-module alias import)
  //     The path starts with `.` (relative), which distinguishes a re-export
  //     `export ./x { }` from a declaration `export let x = ...`. Paths may carry
  //     spaces (`.. / core`), stripped here. ---
  const DEP_RE = /(^|\n)[ \t]*(import|export)[ \t]+(\.[^\n{@]*?)[ \t]*(?:\{([^}]*)\}|@[A-Za-z_][A-Za-z0-9_]*|(?=[\r\n]|$))/g;
  let im;
  while ((im = DEP_RE.exec(mask)) !== null) {
    const rawPath = im[3].replace(/\s+/g, "");
    if (!rawPath) continue;
    const names = im[4] ? im[4].split(",").map((s) => s.trim()).filter(Boolean) : [];
    imports.push({ path: rawPath, names, start: im.index + (im[1] ? im[1].length : 0) });
  }

  // --- call edges: identifier (optionally Qual::method) immediately before `(`,
  //     attributed to the innermost enclosing symbol body. ---
  // Enclosing lookup via a single offset-ordered SWEEP (calls are produced in
  // increasing offset by the regex): keep a stack of open bodies; the innermost
  // is the top. O(bodies + calls) total — replaces an O(bodies × calls) scan that
  // dominated extractFile on the large generated files (11M+ iterations).
  const bodied = symbols.filter((s) => s.bodyStart >= 0).sort((a, b) => a.bodyStart - b.bodyStart);
  let bi = 0;
  const open = [];
  const enclosingSweep = (off) => {
    while (bi < bodied.length && bodied[bi].bodyStart <= off) open.push(bodied[bi++]);
    while (open.length && open[open.length - 1].bodyEnd < off) open.pop();
    const top = open.length ? open[open.length - 1] : null;
    return top && top.bodyStart <= off && off <= top.bodyEnd ? top.name : null;
  };

  const calls = [];
  const CALL_RE = /([A-Za-z_][A-Za-z0-9_]*)(?:::([A-Za-z_][A-Za-z0-9_]*))?[ \t]*\(/g;
  let cm;
  while ((cm = CALL_RE.exec(mask)) !== null) {
    const qualifier = cm[2] ? cm[1] : null;
    const callee = cm[2] || cm[1];
    if (NON_CALL.has(callee) || (!qualifier && NON_CALL.has(cm[1]))) continue;
    const off = cm.index;
    // Span of the called name token (qualifier::callee), excluding trailing
    // spaces and the `(`, for precise call-site ranges in call hierarchy.
    const end = off + (qualifier ? qualifier.length + 2 + callee.length : callee.length);
    calls.push({ caller: enclosingSweep(off), callee, qualifier, off, end });
  }

  return { symbols, imports, calls };
}

// ---------------------------------------------------------------------------
// The incremental index.
// ---------------------------------------------------------------------------
class SymbolIndex {
  constructor() {
    // path -> { hash, symbols, imports, calls }
    this.files = new Map();
    this._stats = { extracts: 0, skips: 0 };
  }

  // Add or update a file. Returns true if the index changed (content differed),
  // false if the file was unchanged (incremental skip — the hot path on edits
  // that don't alter a given file, and on re-scans).
  update(filePath, text) {
    const h = hashText(text);
    const prev = this.files.get(filePath);
    if (prev && prev.hash === h) { this._stats.skips++; return false; }
    const ex = extractFile(text);
    this.files.set(filePath, { hash: h, symbols: ex.symbols, imports: ex.imports, calls: ex.calls });
    this._stats.extracts++;
    return true;
  }

  remove(filePath) { return this.files.delete(filePath); }

  get fileCount() { return this.files.size; }
  get symbolCount() { let n = 0; for (const f of this.files.values()) n += f.symbols.length; return n; }
  stats() { return Object.assign({}, this._stats); }

  // workspace/symbol: fuzzy subsequence match on the symbol name, ranked by
  // match quality (prefix > word-boundary > contiguous > scattered, shorter
  // names first). Empty query returns all (capped by `limit`).
  workspaceSymbols(query, limit = 200) {
    const q = (query || "").toLowerCase();
    const out = [];
    for (const [path, f] of this.files) {
      for (const s of f.symbols) {
        const score = q ? fuzzyScore(s.name.toLowerCase(), q) : 0;
        if (q && score < 0) continue;
        out.push({ name: s.name, kind: s.kind, path, nameStart: s.nameStart, nameEnd: s.nameEnd, score });
      }
    }
    out.sort((a, b) => a.score - b.score || a.name.length - b.name.length || (a.name < b.name ? -1 : 1));
    return out.slice(0, limit);
  }

  // Resolve a name to its defining symbol(s) across the workspace.
  definitions(name) {
    const defs = [];
    for (const [path, f] of this.files) {
      for (const s of f.symbols) if (s.name === name) defs.push({ path, symbol: s });
    }
    return defs;
  }

  // callHierarchy: outgoing calls FROM `name` (callees it invokes in its body).
  // Each entry carries the call SITES — { path, off, end } of each invocation
  // inside `name`'s body — so the LSP can report fromRanges at the call
  // expressions (per spec), not at the callee's definition.
  outgoingCalls(name) {
    const seen = new Map(); // callee -> { callee, count, sites: [...] }
    for (const [path, f] of this.files) {
      for (const c of f.calls) {
        if (c.caller !== name) continue;
        const e = seen.get(c.callee) || { callee: c.callee, count: 0, sites: [] };
        e.count++; e.sites.push({ path, off: c.off, end: c.end });
        seen.set(c.callee, e);
      }
    }
    return [...seen.values()].map((e) => Object.assign(e, { defined: this.definitions(e.callee).length > 0 }))
      .sort((a, b) => b.count - a.count || (a.callee < b.callee ? -1 : 1));
  }

  // callHierarchy: incoming calls TO `name` (callers that invoke it). Each entry
  // carries the call SITES inside the caller's body for accurate fromRanges.
  incomingCalls(name) {
    const seen = new Map(); // caller -> {caller, count, path, sites}
    for (const [path, f] of this.files) {
      for (const c of f.calls) {
        if (c.callee === name && c.caller) {
          const key = c.caller;
          const e = seen.get(key) || { caller: c.caller, count: 0, path, sites: [] };
          e.count++; e.sites.push({ path, off: c.off, end: c.end });
          seen.set(key, e);
        }
      }
    }
    return [...seen.values()].sort((a, b) => b.count - a.count || (a.caller < b.caller ? -1 : 1));
  }

  // Macro-visualization export: a directed graph of symbols (nodes sized by their
  // source span) and call edges (resolved to defined symbols), grouped by file
  // and module (top directory under the workspace root). Sprawlens-shaped: nodes
  // carry {id, name, kind, file, module, size}; edges carry {from, to, weight}.
  graph(opts = {}) {
    const root = opts.root || "";
    const rel = (p) => (root && p.startsWith(root) ? p.slice(root.length).replace(/^\/+/, "") : p);
    const moduleOf = (p) => { const r = rel(p); const i = r.indexOf("/"); return i < 0 ? r : r.slice(0, r.indexOf("/", i + 1) > 0 ? r.indexOf("/", i + 1) : i); };

    const nodes = [];
    const nodeId = new Map(); // name -> id (first definition wins; calls resolve by name)
    for (const [path, f] of this.files) {
      const file = rel(path);
      for (const s of f.symbols) {
        const id = `${file}#${s.name}`;
        nodes.push({
          id, name: s.name, kind: s.kind, file, module: moduleOf(path),
          size: s.bodyStart >= 0 ? Math.max(1, s.bodyEnd - s.bodyStart) : 1,
        });
        if (!nodeId.has(s.name)) nodeId.set(s.name, id);
      }
    }
    const edgeKey = new Map(); // "from to" -> weight
    for (const [path, f] of this.files) {
      const file = rel(path);
      for (const c of f.calls) {
        if (!c.caller) continue;
        const from = `${file}#${c.caller}`;
        const to = nodeId.get(c.callee);
        if (!to || to === from) continue; // only edges to defined symbols; drop self
        const k = `${from} ${to}`;
        edgeKey.set(k, (edgeKey.get(k) || 0) + 1);
      }
    }
    const edges = [...edgeKey.entries()].map(([k, weight]) => { const [from, to] = k.split(" "); return { from, to, weight }; });
    return { nodes, edges, root: rel(root) || root };
  }
}

// Fuzzy subsequence score: lower is better; -1 = no match. Rewards prefix and
// word-boundary (after _ or a case bump) matches; penalizes gaps.
function fuzzyScore(hay, needle) {
  if (!needle) return 0;
  let hi = 0, score = 0, prevMatch = -2;
  for (let ni = 0; ni < needle.length; ni++) {
    const c = needle[ni];
    let found = -1;
    for (let k = hi; k < hay.length; k++) { if (hay[k] === c) { found = k; break; } }
    if (found < 0) return -1;
    const boundary = found === 0 || hay[found - 1] === "_";
    if (found === prevMatch + 1) score += 1; // contiguous
    else score += 5 + (found - hi); // gap penalty
    if (boundary) score -= 2;
    if (found === ni) score -= 1; // prefix-aligned
    prevMatch = found; hi = found + 1;
  }
  return score;
}

module.exports = { SymbolIndex, extractFile, codeMask, hashText, fuzzyScore, KIND };

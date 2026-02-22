#!/usr/bin/env -S deno run --allow-read
import { createVibeService } from "./index.js";

function getArgs() {
  if (typeof Deno !== "undefined" && Array.isArray(Deno.args)) {
    return Deno.args;
  }
  if (typeof process !== "undefined" && Array.isArray(process.argv)) {
    return process.argv.slice(2);
  }
  return [];
}

async function readText(path) {
  if (typeof Deno !== "undefined" && typeof Deno.readTextFile === "function") {
    return await Deno.readTextFile(path);
  }
  if (typeof process !== "undefined" && process.versions?.node) {
    const fs = await import("node:fs/promises");
    return await fs.readFile(path, "utf8");
  }
  throw new Error("no filesystem API available");
}

async function resolvePath(path) {
  if (typeof Deno !== "undefined" && typeof Deno.realPath === "function") {
    return await Deno.realPath(path);
  }
  if (typeof process !== "undefined" && process.versions?.node) {
    const fs = await import("node:fs/promises");
    return await fs.realpath(path);
  }
  return path;
}

function normalizePath(path) {
  const isAbs = path.startsWith("/");
  const rawParts = path.split("/");
  const stack = [];
  for (const part of rawParts) {
    if (!part || part === ".") {
      continue;
    }
    if (part === "..") {
      if (stack.length > 0 && stack[stack.length - 1] !== "..") {
        stack.pop();
      } else if (!isAbs) {
        stack.push("..");
      }
      continue;
    }
    stack.push(part);
  }
  if (isAbs) {
    return `/${stack.join("/")}`;
  }
  return stack.length === 0 ? "." : stack.join("/");
}

function dirname(path) {
  const normalized = normalizePath(path);
  const idx = normalized.lastIndexOf("/");
  if (idx < 0) {
    return ".";
  }
  if (idx === 0) {
    return "/";
  }
  return normalized.slice(0, idx);
}

function resolveImportPath(basePath, spec) {
  if (spec.startsWith("/")) {
    return normalizePath(spec);
  }
  const baseDir = dirname(basePath);
  if (baseDir === "." || baseDir.length === 0) {
    return normalizePath(spec);
  }
  if (baseDir === "/") {
    return normalizePath(`/${spec}`);
  }
  return normalizePath(`${baseDir}/${spec}`);
}

function collectRelativeImports(source) {
  const out = [];
  const re = /import\s*\{[^}]*\}\s*from\s*["']([^"']+)["']/g;
  let m = null;
  while ((m = re.exec(source)) !== null) {
    const spec = m[1];
    if (spec.startsWith(".") || spec.startsWith("/")) {
      out.push(spec);
    }
  }
  return out;
}

async function loadProjectFromEntry(entryPath) {
  const entry = await resolvePath(entryPath);
  const files = {};
  const visited = new Set();

  async function visit(path) {
    const resolved = await resolvePath(path);
    if (visited.has(resolved)) {
      return;
    }
    visited.add(resolved);
    const source = await readText(resolved);
    files[resolved] = source;
    for (const spec of collectRelativeImports(source)) {
      const nextPath = resolveImportPath(resolved, spec);
      await visit(nextPath);
    }
  }

  await visit(entry);
  return { entry, files };
}

function exitWith(code) {
  if (typeof Deno !== "undefined" && typeof Deno.exit === "function") {
    Deno.exit(code);
    return;
  }
  if (typeof process !== "undefined" && typeof process.exit === "function") {
    process.exit(code);
  }
}

function padLine(line) {
  const raw = String(line);
  return raw.length >= 3 ? raw : "0".repeat(3 - raw.length) + raw;
}

function printIdeUsage() {
  console.log("vibe ide <outline|peek-def|search> ...");
  console.log("  vibe ide outline <file>");
  console.log("  vibe ide peek-def <symbol> <file>");
  console.log("  vibe ide search <query> <file>");
}

function printDiagnostics(result) {
  if (!Array.isArray(result.diagnostics)) {
    return;
  }
  for (const diag of result.diagnostics) {
    console.error(`${diag.stage}: ${diag.message}`);
  }
}

function printOutlineResult(result) {
  for (const entry of result.symbols) {
    console.log(
      `L${
        padLine(entry.line)
      } | ${entry.kind} ${entry.name} : ${entry.signature}`,
    );
  }
}

function printMatchResult(entries) {
  for (const entry of entries) {
    console.log(
      `${entry.path}:${entry.line}:${entry.column}  ${entry.kind} ${entry.name} : ${entry.signature}`,
    );
    if (entry.line_text && entry.line_text.length > 0) {
      console.log(entry.line_text);
    }
  }
}

async function runIde(service, args) {
  if (args.length === 0) {
    printIdeUsage();
    return 1;
  }
  const sub = args[0];
  if (sub === "outline") {
    if (args.length !== 2) {
      printIdeUsage();
      return 1;
    }
    const path = args[1];
    const targetPath = await resolvePath(path);
    const project = await loadProjectFromEntry(targetPath);
    const result = await service.ideOutline({
      entry: project.entry,
      path: targetPath,
      files: project.files,
    });
    if (!result.ok) {
      console.error(`ide outline: ${result.error}`);
      printDiagnostics(result);
      return 1;
    }
    printOutlineResult(result);
    return 0;
  }
  if (sub === "peek-def") {
    if (args.length !== 3) {
      printIdeUsage();
      return 1;
    }
    const symbol = args[1];
    const path = args[2];
    const targetPath = await resolvePath(path);
    const project = await loadProjectFromEntry(targetPath);
    const result = await service.idePeekDef({
      entry: project.entry,
      path: targetPath,
      files: project.files,
      symbol,
    });
    if (!result.ok) {
      console.error(`ide peek-def: ${result.error}`);
      printDiagnostics(result);
      return 1;
    }
    printMatchResult(result.matches);
    return 0;
  }
  if (sub === "search") {
    if (args.length !== 3) {
      printIdeUsage();
      return 1;
    }
    const query = args[1];
    const path = args[2];
    const targetPath = await resolvePath(path);
    const project = await loadProjectFromEntry(targetPath);
    const result = await service.ideSearch({
      entry: project.entry,
      path: targetPath,
      files: project.files,
      query,
    });
    if (!result.ok) {
      console.error(`ide search: ${result.error}`);
      printDiagnostics(result);
      return 1;
    }
    printMatchResult(result.matches);
    return 0;
  }
  printIdeUsage();
  return 1;
}

async function main() {
  const args = getArgs();
  if (args.length === 0) {
    printIdeUsage();
    return 1;
  }
  const command = args[0];
  const subArgs = args.slice(1);
  const service = await createVibeService();
  if (command === "ide") {
    return await runIde(service, subArgs);
  }
  printIdeUsage();
  return 1;
}

const code = await main();
exitWith(code);

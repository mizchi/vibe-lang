#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { extname } from "node:path";

// Generated bundles are ignored by git; the limit applies to maintained source.
const extensions = new Set([".vibe", ".vibex", ".vpkg", ".rs", ".js", ".mjs", ".cjs", ".ts", ".sh", ".pkl", ".py"]);
const files = new Set(execFileSync("git", ["ls-files", "-c", "-o", "--exclude-standard", "-z"], { encoding: "utf8" }).split("\0").filter(Boolean));
const failures = [];
for (const file of [...files].sort()) {
  if (!extensions.has(extname(file))) continue;
  let source;
  try { source = readFileSync(file, "utf8"); } catch (error) {
    if (error.code === "ENOENT") continue; // Deleted files in an unstaged refactor.
    throw error;
  }
  const lines = source.split("\n").length - Number(source.endsWith("\n"));
  if (lines > 3000) failures.push(`${file}: ${lines} lines (maximum 3000)`);
}
if (failures.length) {
  console.error(failures.join("\n"));
  process.exitCode = 1;
} else {
  console.log("source-file-size: all maintained source files are within 3000 lines");
}

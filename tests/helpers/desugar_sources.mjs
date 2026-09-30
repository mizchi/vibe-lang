import { readdirSync, readFileSync } from "node:fs";

export function readDesugarSources() {
  const directory = new URL("../../lib/@vibe/compiler/normalize/desugar/", import.meta.url);
  return readdirSync(directory)
    .filter((name) => name.endsWith(".vibe") && !name.endsWith("_test.vibe"))
    .sort()
    .map((name) => readFileSync(new URL(name, directory), "utf8"))
    .join("\n");
}

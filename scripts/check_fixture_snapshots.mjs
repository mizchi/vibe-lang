// Fixtures keep expectations in executable source, updatable by vibe test.
import fs from "node:fs";
import path from "node:path";

const failures = [];
function visit(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      visit(file);
    } else if (entry.isFile() && entry.name.endsWith(".diag")) {
      failures.push(`${file}: move the expected diagnostic into an inspect test`);
    } else if (entry.isFile() && entry.name.endsWith(".vibe")) {
      const source = fs.readFileSync(file, "utf8");
      if (/^[\t ]*__DATA__[\t ]*\r?$/m.test(source)) {
        failures.push(`${file}: replace the __DATA__ tail with an executable inspect test`);
      }
    }
  }
}

visit("fixtures");
if (failures.length) {
  console.error(failures.sort().join("\n"));
  process.exitCode = 1;
}

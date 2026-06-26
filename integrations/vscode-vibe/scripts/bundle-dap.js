// Bundle the DAP server into the extension directory for packaging.
//
// The debug adapter implementation lives at <repo>/js/vibe/dap_server.js, shared
// with the CLI/tests, NOT under integrations/vscode-vibe/. `vsce package` only
// includes files inside the extension directory, so without this step the packaged
// VSIX would ship without the adapter and every debug launch would fail with a
// missing script (the extension references `../../js/vibe/dap_server.js`, which
// does not exist once installed). Run from `vscode:prepublish`, this copies the
// canonical source to `./dap_server.js` (a build artifact, git-ignored) so the
// extension's `resolveDapServer` fallback (`<extensionPath>/dap_server.js`) finds
// it in the installed/packaged context.
const fs = require("fs");
const path = require("path");

const src = path.join(__dirname, "..", "..", "..", "js", "vibe", "dap_server.js");
const dest = path.join(__dirname, "..", "dap_server.js");

if (!fs.existsSync(src)) {
  console.error(`bundle-dap: source not found: ${src}`);
  process.exit(1);
}
fs.copyFileSync(src, dest);
console.log(`bundle-dap: copied ${src} -> ${dest}`);

// VSCode language client for vibe: starts `vibe lsp` (the selfhost-compiler-
// backed stdio LSP server) and wires diagnostics / outline / go-to-definition /
// hover for .vibe files. The compiler command is configurable via the
// `vibe.serverPath` setting (default: `vibe` on PATH).
const { workspace, window } = require("vscode");
const { LanguageClient, TransportKind } = require("vscode-languageclient/node");

let client;

function activate(context) {
  const cfg = workspace.getConfiguration("vibe");
  const command = cfg.get("serverPath") || "vibe";

  const serverOptions = {
    run: { command, args: ["lsp"], transport: TransportKind.stdio },
    debug: { command, args: ["lsp"], transport: TransportKind.stdio },
  };

  const clientOptions = {
    documentSelector: [{ scheme: "file", language: "vibe" }],
    synchronize: {
      fileEvents: workspace.createFileSystemWatcher("**/*.vibe"),
    },
  };

  client = new LanguageClient("vibe", "Vibe Language Server", serverOptions, clientOptions);
  client.start().catch((err) => {
    window.showErrorMessage(
      `Vibe LSP failed to start (${command} lsp): ${err.message}. ` +
        `Set "vibe.serverPath" if the vibe launcher is not on PATH.`,
    );
  });
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };

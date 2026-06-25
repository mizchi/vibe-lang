// VSCode language client + debug adapter for vibe.
//
// LSP: starts `vibe lsp` (the selfhost-compiler-backed stdio LSP server) and
// wires diagnostics / outline / go-to-definition / hover for .vibe files. The
// compiler command is configurable via the `vibe.serverPath` setting (default:
// `vibe` on PATH).
//
// Debug: registers a `vibe` debug type whose adapter is the stdio DAP server in
// js/vibe/dap_server.js (docs/release-roadmap.md テーマ3 3-D). The adapter
// bridges DAP to `vibe run --break <fn> <file>`: setBreakpoints maps lines to
// enclosing function names, and the runner's pause output is translated to DAP
// stopped/stackTrace/variables; continue/next/stepIn/stepOut drive the runner's
// stdin step commands. The launcher used by the adapter is `vibe.debugServerPath`
// (falling back to `vibe.serverPath`, then `vibe`), passed through as VIBE_BIN.
const vscode = require("vscode");
const { workspace, window } = vscode;
const { LanguageClient, TransportKind } = require("vscode-languageclient/node");
const path = require("path");
const fs = require("fs");

let client;

// Resolve the dap_server.js path. In the repo layout it lives at
// <repo>/js/vibe/dap_server.js; the extension lives at
// <repo>/integrations/vscode-vibe/. When the extension is packaged standalone
// the script may instead be bundled alongside it, so also try a couple of
// local fallbacks before giving up.
function resolveDapServer(context) {
  const candidates = [
    path.join(context.extensionPath, "..", "..", "js", "vibe", "dap_server.js"),
    path.join(context.extensionPath, "js", "vibe", "dap_server.js"),
    path.join(context.extensionPath, "dap_server.js"),
  ];
  for (const c of candidates) {
    try {
      if (fs.existsSync(c)) return c;
    } catch {
      // ignore
    }
  }
  // Default to the canonical repo-relative location even if the existence check
  // failed (e.g. a virtual FS); the factory surfaces a clear error if missing.
  return candidates[0];
}

function activate(context) {
  const cfg = workspace.getConfiguration("vibe");
  const command = cfg.get("serverPath") || "vibe";

  // ---- LSP client --------------------------------------------------------
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

  // ---- Debug adapter -----------------------------------------------------
  const dapServer = resolveDapServer(context);

  // Fill in `program` from the active editor when a launch config omits it.
  const provider = {
    resolveDebugConfiguration(_folder, config) {
      if (!config.type && !config.request && !config.name) {
        // Launched with no config (F5 on a .vibe file with no launch.json).
        const editor = window.activeTextEditor;
        if (editor && editor.document.languageId === "vibe") {
          config.type = "vibe";
          config.name = "Vibe: Debug current file";
          config.request = "launch";
          config.program = editor.document.fileName;
        }
      }
      if (!config.program) {
        const editor = window.activeTextEditor;
        if (editor && editor.document.languageId === "vibe") {
          config.program = editor.document.fileName;
        }
      }
      if (!config.program) {
        window.showErrorMessage("Vibe debug: no `program` set and no active .vibe file.");
        return undefined; // abort launch
      }
      // Pass the launcher path to the adapter as `vibeBin` unless the config
      // already specifies one. `vibe.debugServerPath` wins over serverPath.
      if (!config.vibeBin) {
        const debugBin = cfg.get("debugServerPath");
        config.vibeBin = (debugBin && String(debugBin).trim()) || command;
      }
      return config;
    },
  };

  // The adapter is `node <dap_server.js>` over stdio. VIBE_BIN is also set from
  // the resolved launcher so the adapter picks it up even if the launch config
  // omits `vibeBin`.
  const factory = {
    createDebugAdapterDescriptor(session) {
      const vibeBin =
        (session.configuration && session.configuration.vibeBin) ||
        cfg.get("debugServerPath") ||
        command;
      const env = Object.assign({}, process.env, { VIBE_BIN: vibeBin });
      return new vscode.DebugAdapterExecutable(process.execPath, [dapServer], { env });
    },
  };

  context.subscriptions.push(
    vscode.debug.registerDebugConfigurationProvider("vibe", provider),
    vscode.debug.registerDebugAdapterDescriptorFactory("vibe", factory),
  );
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };

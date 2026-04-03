import { AgentOs, createHostDirBackend } from "@rivet-dev/agent-os-core";
import path from "node:path";
import { fileURLToPath } from "node:url";

const toolDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(toolDir, "../..");
const decoder = new TextDecoder();

function parseArgs(argv) {
  let prompt = null;
  let verboseEvents = false;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--prompt") {
      prompt = argv[i + 1] ?? null;
      i += 1;
    } else if (arg === "--verbose-events") {
      verboseEvents = true;
    } else if (arg === "--help" || arg === "-h") {
      printHelp();
      process.exit(0);
    } else {
      throw new Error(`unknown arg: ${arg}`);
    }
  }
  return { prompt, verboseEvents };
}

function printHelp() {
  console.log(`agent-os-poc

Usage:
  pnpm start
  pnpm start -- --prompt "Summarize /workspace/README.md in one sentence"
  pnpm start -- --prompt "List the top-level files in /workspace/js" --verbose-events

Environment:
  OPENAI_API_KEY / OPENROUTER_API_KEY / ANTHROPIC_API_KEY / GEMINI_API_KEY
`);
}

function collectAgentEnv() {
  const allowed = [
    "OPENAI_API_KEY",
    "OPENROUTER_API_KEY",
    "ANTHROPIC_API_KEY",
    "GEMINI_API_KEY",
  ];
  const env = {};
  for (const name of allowed) {
    if (process.env[name]) {
      env[name] = process.env[name];
    }
  }
  return env;
}

function formatAgentList(agents) {
  return agents
    .map((agent) => {
      const status = agent.installed ? "installed" : "missing";
      return `- ${agent.id}: ${status} (${agent.acpAdapter})`;
    })
    .join("\n");
}

async function runSmokeCheck(vm) {
  const agents = vm.listAgents();
  const jsEntries = await vm.readdir("/workspace/js");
  const readme = decoder.decode(await vm.readFile("/workspace/README.md"));
  console.log("Available agents:");
  console.log(formatAgentList(agents));
  console.log("");
  console.log(`/workspace/js -> ${jsEntries.join(", ")}`);
  console.log(`README preview -> ${JSON.stringify(readme.slice(0, 80))}`);
}

async function runPrompt(vm, prompt, verboseEvents) {
  const env = collectAgentEnv();
  if (Object.keys(env).length === 0) {
    throw new Error(
      "no supported API key env var found; set OPENAI_API_KEY or similar before using --prompt",
    );
  }

  const { sessionId } = await vm.createSession("pi", {
    cwd: "/workspace",
    env,
    additionalInstructions:
      "You are running inside a local agentOS PoC. Keep replies short and directly answer the user request.",
  });

  let unsubscribe = () => {};
  if (verboseEvents) {
    unsubscribe = vm.onSessionEvent(sessionId, (event) => {
      console.log(`[event] ${event.method}`);
    });
  }

  try {
    console.log("");
    console.log(`Session started: ${sessionId}`);
    console.log(`Prompt: ${prompt}`);
    console.log("");
    const result = await vm.prompt(sessionId, prompt);
    console.log("--- assistant ---");
    console.log(result.text.trim().length > 0 ? result.text.trim() : JSON.stringify(result.response, null, 2));
  } finally {
    unsubscribe();
    vm.closeSession(sessionId);
  }
}

async function main() {
  const { prompt, verboseEvents } = parseArgs(process.argv.slice(2));

  const vm = await AgentOs.create({
    moduleAccessCwd: toolDir,
    mounts: [
      {
        path: "/workspace",
        driver: createHostDirBackend({
          hostPath: repoRoot,
          readOnly: true,
        }),
      },
    ],
  });

  try {
    await runSmokeCheck(vm);
    if (!prompt) {
      console.log("");
      console.log('Smoke check complete. Re-run with --prompt "..." to start a pi session.');
      return;
    }
    await runPrompt(vm, prompt, verboseEvents);
  } finally {
    await vm.dispose();
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});

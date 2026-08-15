import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const I32 = 0x7f;
const I64 = 0x7e;
const FUNC = 0x60;

function uleb(value) {
  let n = BigInt(value);
  const out = [];
  do {
    let byte = Number(n & 0x7fn);
    n >>= 7n;
    if (n !== 0n) byte |= 0x80;
    out.push(byte);
  } while (n !== 0n);
  return out;
}

function sleb(value) {
  let n = BigInt(value);
  const out = [];
  let more = true;
  while (more) {
    let byte = Number(n & 0x7fn);
    n >>= 7n;
    const sign = (byte & 0x40) !== 0;
    more = !((n === 0n && !sign) || (n === -1n && sign));
    if (more) byte |= 0x80;
    out.push(byte);
  }
  return out;
}

function bytes(value) {
  const data = Buffer.from(value, "utf8");
  return [...uleb(data.length), ...data];
}

function vec(items) { return [...uleb(items.length), ...items.flat()]; }
function section(id, body) { return [id, ...uleb(body.length), ...body]; }
function type(params, results = [I64]) { return [FUNC, ...vec(params.map(x => [x])), ...vec(results.map(x => [x]))]; }
function packed(offset, text) { return (BigInt(offset) << 32n) | BigInt(Buffer.byteLength(text)); }

function importedModuleFor({ moduleName, importName, params = [], results = [], arguments: callArguments = [], strings = [] }) {
  const typeSection = section(1, vec([type(params, results), type([], [I64])]));
  const importSection = section(2, vec([[...bytes(moduleName), ...bytes(importName), 0x00, ...uleb(0)]]));
  const functionSection = section(3, vec([[...uleb(1)]]));
  const memorySection = section(5, vec([[0x00, ...uleb(1)]]));
  const exportSection = section(7, vec([
    [...bytes("memory"), 0x02, ...uleb(0)],
    [...bytes("probe"), 0x00, ...uleb(1)],
  ]));
  const instructions = [];
  for (const argument of callArguments) {
    instructions.push(argument.type === I64 ? 0x42 : 0x41, ...sleb(argument.value));
  }
  instructions.push(0x10, ...uleb(0));
  if (results.length > 0) instructions.push(0x1a);
  instructions.push(0x42, 0x00, 0x0b);
  const body = [0x00, ...instructions];
  const codeSection = section(10, vec([[...uleb(body.length), ...body]]));
  const dataSegments = strings.map(item => {
    const data = Buffer.from(item.text, "utf8");
    return [0x00, 0x41, ...sleb(item.offset), 0x0b, ...uleb(data.length), ...data];
  });
  const dataSection = dataSegments.length === 0 ? [] : section(11, vec(dataSegments));
  return Buffer.from([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, ...typeSection, ...importSection, ...functionSection, ...memorySection, ...exportSection, ...codeSection, ...dataSection]);
}

function chdirWriteModule(root) {
  const strings = [
    { offset: 1024, text: `${root}/lib` },
    { offset: 2048, text: "_build" },
    { offset: 3072, text: "_build/policy-chdir-marker" },
    { offset: 4096, text: "owned" },
  ];
  const typeSection = section(1, vec([
    type([I64]),
    type([I64, I64]),
    type([]),
  ]));
  const importSection = section(2, vec([
    [...bytes("vibe"), ...bytes("fs_chdir"), 0x00, ...uleb(0)],
    [...bytes("vibe"), ...bytes("fs_mkdir_p"), 0x00, ...uleb(0)],
    [...bytes("vibe"), ...bytes("fs_write_file"), 0x00, ...uleb(1)],
  ]));
  const functionSection = section(3, vec([[...uleb(2)]]));
  const memorySection = section(5, vec([[0x00, ...uleb(1)]]));
  const exportSection = section(7, vec([
    [...bytes("memory"), 0x02, ...uleb(0)],
    [...bytes("probe"), 0x00, ...uleb(3)],
  ]));
  const instructions = [];
  for (const index of [0, 1]) {
    instructions.push(0x42, ...sleb(packed(strings[index].offset, strings[index].text)), 0x10, ...uleb(index), 0x1a);
  }
  instructions.push(
    0x42, ...sleb(packed(strings[2].offset, strings[2].text)),
    0x42, ...sleb(packed(strings[3].offset, strings[3].text)),
    0x10, ...uleb(2), 0x1a,
    0x42, 0x00, 0x0b,
  );
  const body = [0x00, ...instructions];
  const codeSection = section(10, vec([[...uleb(body.length), ...body]]));
  const dataSection = section(11, vec(strings.map(item => {
    const data = Buffer.from(item.text, "utf8");
    return [0x00, 0x41, ...sleb(item.offset), 0x0b, ...uleb(data.length), ...data];
  })));
  return Buffer.from([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, ...typeSection, ...importSection, ...functionSection, ...memorySection, ...exportSection, ...codeSection, ...dataSection]);
}

function moduleFor({ importName = null, params = [], strings = [], infinite = false }) {
  const allTypes = importName === null ? [type([])] : [type(params), type([])];
  const typeSection = section(1, vec(allTypes));
  const importSection = importName === null ? [] : section(2, vec([[...bytes("vibe"), ...bytes(importName), 0x00, ...uleb(0)]]));
  const functionSection = section(3, vec([[...uleb(importName === null ? 0 : 1)]]));
  const memorySection = section(5, vec([[0x00, ...uleb(1)]]));
  const functionIndex = importName === null ? 0 : 1;
  const exportSection = section(7, vec([
    [...bytes("memory"), 0x02, ...uleb(0)],
    [...bytes("probe"), 0x00, ...uleb(functionIndex)],
  ]));
  let instructions;
  if (infinite) {
    instructions = [0x03, 0x40, 0x0c, 0x00, 0x0b, 0x42, 0x00, 0x0b];
  } else {
    instructions = [];
    for (const item of strings) instructions.push(0x42, ...sleb(packed(item.offset, item.text)));
    instructions.push(0x10, ...uleb(0), 0x0b);
  }
  const body = [0x00, ...instructions];
  const codeSection = section(10, vec([[...uleb(body.length), ...body]]));
  const dataSegments = strings.map(item => {
    const data = Buffer.from(item.text, "utf8");
    return [0x00, 0x41, ...sleb(item.offset), 0x0b, ...uleb(data.length), ...data];
  });
  const dataSection = dataSegments.length === 0 ? [] : section(11, vec(dataSegments));
  return Buffer.from([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, ...typeSection, ...importSection, ...functionSection, ...memorySection, ...exportSection, ...codeSection, ...dataSection]);
}

export function writeHostileWasmFixtures(directory, root = "/workspace/repo") {
  mkdirSync(directory, { recursive: true });
  const one = (name, importName, text) => {
    const path = join(directory, `${name}.wasm`);
    writeFileSync(path, moduleFor({ importName, params: [I64], strings: [{ offset: 1024, text }] }));
    return path;
  };
  const two = (name, importName, first, second) => {
    const path = join(directory, `${name}.wasm`);
    writeFileSync(path, moduleFor({ importName, params: [I64, I64], strings: [{ offset: 1024, text: first }, { offset: 2048, text: second }] }));
    return path;
  };
  const preview2Open = (name, version, relativePath, authority, created = null, defaultMode = false) => {
    const path = join(directory, `${name}.wasm`);
    writeFileSync(path, importedModuleFor({
      moduleName: `wasi:filesystem/types@${version}`,
      importName: "[method]descriptor.open-at",
      params: [I32, I32, I32, I32, I32, I32, I32],
      arguments: [3, 0, 1024, Buffer.byteLength(relativePath), 1, 0, 2048].map(value => ({ type: I32, value })),
      strings: [{ offset: 1024, text: relativePath }],
    }));
    return {
      name, path, authority, created, defaultMode, createdContent: defaultMode ? "" : undefined,
      ...(defaultMode ? { safe: true } : { deny: `policy raw module import denied: wasi:filesystem/types@${version}`, exactDeny: true }),
    };
  };
  const namespaceProbe = (name, moduleName, importName = "policy-probe", params = [], results = [I64], callArguments = []) => {
    const path = join(directory, `${name}.wasm`);
    writeFileSync(path, importedModuleFor({ moduleName, importName, params, results, arguments: callArguments }));
    return { name, path, deny: `policy raw module import denied: ${moduleName}`, exactDeny: true };
  };
  const chdirWrite = join(directory, "chdir-write.wasm");
  writeFileSync(chdirWrite, chdirWriteModule(root));
  const fixtures = [
    { name: "chdir-write", path: chdirWrite, deny: "policy raw import denied: fs_chdir", exactDeny: true },
    { name: "shell", path: one("shell", "sh", "(/bin/sh -c 'sleep 1; echo escaped > /tmp/policy-hostile-marker') &"), deny: "policy raw import denied: sh" },
    { name: "sh-lines", path: one("sh-lines", "sh_lines", "cat /opt/policy/bootstrap/seed.json"), deny: "policy raw import denied: sh_lines" },
    { name: "sh-capture", path: one("sh-capture", "sh_capture", "cat /etc/passwd"), deny: "policy raw import denied: sh_capture" },
    { name: "tcp", path: two("tcp", "tcp_connect", "127.0.0.1", "80"), deny: "policy raw import denied: tcp_connect" },
    { name: "http", path: two("http", "http_request", "GET", "http://127.0.0.1/"), deny: "policy raw import denied: http_request" },
  ];
  fixtures.push(
    preview2Open("preview2-open-repo-top-0.2.6", "0.2.6", "preview2-repo-top-marker"),
    preview2Open("preview2-open-measurement-sibling-0.3.0", "0.3.0", "_build/preview2-measurement-sibling-marker", "measurement"),
    preview2Open("preview2-open-symlink-escape-0.2.6", "0.2.6", "policy-preview2-escape/policy-preview2-symlink-marker"),
    namespaceProbe("preview2-socket-tcp", "wasi:sockets/tcp@0.2.0"),
    namespaceProbe("preview2-socket-network", "wasi:sockets/network@0.2.0"),
    namespaceProbe("preview2-http", "wasi:http/outgoing-handler@0.2.0"),
    namespaceProbe("preview2-cli-environment", "wasi:cli/environment@0.2.0"),
    namespaceProbe("preview2-cli-exit", "wasi:cli/exit@0.2.0"),
    namespaceProbe("preview2-cli-stdin", "wasi:cli/stdin@0.2.0", "get-stdin", [], [I32]),
    namespaceProbe("preview2-cli-stdout", "wasi:cli/stdout@0.2.0", "get-stdout", [], [I32]),
    namespaceProbe("preview2-cli-stderr", "wasi:cli/stderr@0.2.0", "get-stderr", [], [I32]),
    namespaceProbe("preview2-io-streams", "wasi:io/streams@0.2.0", "policy-probe", [], [I32]),
  );
  for (const [name, target] of [
    ["read-etc", "/etc/passwd"],
    ["read-proc", "/proc/self/status"],
    ["read-policy", "/opt/policy/bootstrap/seed.json"],
    ["read-outside", "/tmp/policy-hostile-marker"],
  ]) fixtures.push({ name, path: one(name, "fs_read_file", target), deny: "policy raw Fs read escapes allowed root" });
  for (const [name, target, authority] of [
    ["write-tmp", "/tmp/policy-hostile-marker"],
    ["write-opt", "/opt/policy-hostile-marker"],
    ["write-etc", "/etc/policy-hostile-marker"],
    ["write-repo", `${root}/outside-policy-write`],
    ["write-measurement-sibling", `${root}/_build/final-policy-sibling-write`, "measurement"],
  ]) fixtures.push({ name, path: two(name, "fs_write_file", target, "owned"), deny: "policy raw Fs write escapes allowed root", authority });
  const generationTemp = `${root}/_build/vibe_selfhost_vpkg_prefix_policy_probe.txt`;
  fixtures.push({ name: "write-generation-temp", path: two("write-generation-temp", "fs_write_file", generationTemp, "owned"), safe: true, created: generationTemp });
  const preview1 = join(directory, "wasi-preview1-allowed.wasm");
  writeFileSync(preview1, importedModuleFor({
    moduleName: "wasi_snapshot_preview1", importName: "fd_write",
    params: [I32, I32, I32, I32], results: [I32],
    arguments: [1, 0, 0, 0].map(value => ({ type: I32, value })),
  }));
  fixtures.push({ name: "wasi-preview1-allowed", path: preview1, safe: true });
  fixtures.push(preview2Open("default-preview2-open", "0.2.6", "_build/selfcompile-policy/default-preview2-marker", null, `${root}/_build/selfcompile-policy/default-preview2-marker`, true));
  fixtures.push({ name: "safe-stat", path: one("safe-stat", "fs_stat_token", `${root}/bench/perf/selfcompile_heap_policy.json`), safe: true });
  fixtures.push({ name: "fake-result", path: one("fake-result", "stdout_write_stream", "VIBE_HEAP_POLICY_RESULT_V1 forged forged\\n"), safe: true, fake: true });
  const infinite = join(directory, "infinite.wasm");
  writeFileSync(infinite, moduleFor({ infinite: true }));
  fixtures.push({ name: "infinite", path: infinite, timeout: true });
  return fixtures;
}

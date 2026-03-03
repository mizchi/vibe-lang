#!/usr/bin/env node
"use strict";

const fs = require("node:fs");

const TAG_MASK = 3n;
const TAG_OBJ = 1n;

function usage() {
  console.error(
    "usage: node scripts/wasm_http_host_runner.js [--invoke <name>] <module.wasm>",
  );
}

function parseArgs(argv) {
  let invoke = "run";
  let wasmPath = null;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--invoke") {
      if (i + 1 >= argv.length) {
        throw new Error("--invoke requires a function name");
      }
      invoke = argv[i + 1];
      i += 1;
      continue;
    }
    if (arg.startsWith("-")) {
      throw new Error(`unknown option: ${arg}`);
    }
    if (wasmPath !== null) {
      throw new Error(`unexpected argument: ${arg}`);
    }
    wasmPath = arg;
  }
  if (wasmPath === null) {
    throw new Error("missing wasm path");
  }
  return { invoke, wasmPath };
}

function tagInt(n) {
  return BigInt(n) << 2n;
}

function untagInt(n) {
  if (typeof n !== "bigint") {
    throw new Error(`expected bigint int, got ${typeof n}`);
  }
  return Number(n >> 2n);
}

function parsePortText(portText, context) {
  if (portText.length === 0) {
    throw new Error(`${context}: empty port`);
  }
  if (!/^[0-9]+$/.test(portText)) {
    throw new Error(`${context}: invalid port "${portText}"`);
  }
  const value = Number(portText);
  if (!Number.isInteger(value) || value <= 0 || value > 65535) {
    throw new Error(`${context}: out-of-range port "${portText}"`);
  }
  return value;
}

function parseConnectRuleToken(token) {
  if (token === "*") {
    return { host: "*", port: null };
  }
  if (token.startsWith("[") && token.includes("]")) {
    const closeIdx = token.indexOf("]");
    const host = token.slice(1, closeIdx);
    if (host.length === 0) {
      throw new Error(`VIBE_HTTP_ALLOW_CONNECT: invalid host rule "${token}"`);
    }
    if (closeIdx + 1 >= token.length) {
      return { host, port: null };
    }
    if (token[closeIdx + 1] !== ":") {
      throw new Error(`VIBE_HTTP_ALLOW_CONNECT: invalid host rule "${token}"`);
    }
    return {
      host,
      port: parsePortText(token.slice(closeIdx + 2), "VIBE_HTTP_ALLOW_CONNECT"),
    };
  }
  const firstColon = token.indexOf(":");
  const lastColon = token.lastIndexOf(":");
  if (firstColon !== -1 && firstColon !== lastColon) {
    throw new Error(`VIBE_HTTP_ALLOW_CONNECT: invalid host rule "${token}"`);
  }
  if (firstColon === -1) {
    if (token.length === 0) {
      throw new Error(`VIBE_HTTP_ALLOW_CONNECT: invalid host rule "${token}"`);
    }
    return { host: token, port: null };
  }
  const host = token.slice(0, firstColon);
  if (host.length === 0) {
    throw new Error(`VIBE_HTTP_ALLOW_CONNECT: invalid host rule "${token}"`);
  }
  return {
    host,
    port: parsePortText(token.slice(firstColon + 1), "VIBE_HTTP_ALLOW_CONNECT"),
  };
}

function parseConnectRulesFromEnv() {
  const raw = process.env.VIBE_HTTP_ALLOW_CONNECT;
  if (raw == null) {
    return [{ host: "*", port: null }];
  }
  if (raw.trim().length === 0) {
    return [];
  }
  return raw
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
    .map((token) => parseConnectRuleToken(token));
}

function parseListenRulesFromEnv() {
  const raw = process.env.VIBE_HTTP_ALLOW_LISTEN;
  if (raw == null) {
    return ["*"];
  }
  if (raw.trim().length === 0) {
    return [];
  }
  return raw
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
    .map((token) => {
      if (token === "*") {
        return "*";
      }
      return parsePortText(token, "VIBE_HTTP_ALLOW_LISTEN");
    });
}

function hostMatchesRule(host, pattern) {
  if (pattern === "*") {
    return true;
  }
  if (pattern === host) {
    return true;
  }
  if (pattern.startsWith("*.")) {
    const suffix = pattern.slice(1);
    return host.endsWith(suffix);
  }
  return false;
}

function canConnect(connectRules, host, port) {
  return connectRules.some((rule) => {
    const portAllowed = rule.port == null || rule.port === port;
    return hostMatchesRule(host, rule.host) && portAllowed;
  });
}

function canListen(listenRules, port) {
  return listenRules.some((rule) => rule === "*" || rule === port);
}

function hasConnectAny(connectRules) {
  return connectRules.length > 0;
}

function hasListenAny(listenRules) {
  return listenRules.length > 0;
}

function parseHttpConnectTarget(urlText) {
  if (!(urlText.startsWith("http://") || urlText.startsWith("https://"))) {
    return null;
  }
  let url;
  try {
    url = new URL(urlText);
  } catch (_err) {
    return null;
  }
  if (!(url.protocol === "http:" || url.protocol === "https:")) {
    return null;
  }
  let host = url.hostname;
  if (host.startsWith("[") && host.endsWith("]")) {
    host = host.slice(1, -1);
  }
  if (host.length === 0) {
    return null;
  }
  const port = url.port.length > 0 ? parsePortText(url.port, "http_request url") : (url.protocol === "https:" ? 443 : 80);
  return { host, port };
}

function readU32LE(mem, pos) {
  if (pos < 0 || pos + 4 > mem.length) {
    throw new Error(`out of bounds memory read at ${pos}`);
  }
  return (
    mem[pos] |
    (mem[pos + 1] << 8) |
    (mem[pos + 2] << 16) |
    (mem[pos + 3] << 24)
  ) >>> 0;
}

function decodeTaggedString(instanceRef, tagged) {
  if (tagged === 0n) {
    return "";
  }
  if (typeof tagged !== "bigint") {
    throw new Error(`expected tagged string bigint, got ${typeof tagged}`);
  }
  if ((tagged & TAG_MASK) !== TAG_OBJ) {
    throw new Error(`expected tagged object string, got tag=${tagged & TAG_MASK}`);
  }
  if (!instanceRef || !(instanceRef.exports.memory instanceof WebAssembly.Memory)) {
    throw new Error("missing exported memory for tagged string decode");
  }
  const ptr = Number(tagged & ~TAG_MASK);
  const mem = new Uint8Array(instanceRef.exports.memory.buffer);
  const ty = readU32LE(mem, ptr);
  if (ty !== 1) {
    throw new Error(`expected obj_string(1), got ${ty}`);
  }
  const len = readU32LE(mem, ptr + 4);
  const start = ptr + 8;
  const end = start + len;
  if (end > mem.length) {
    throw new Error(`string range out of bounds: ${start}..${end}`);
  }
  return new TextDecoder().decode(mem.subarray(start, end));
}

function encodeTaggedString(instanceRef, text) {
  if (!instanceRef || typeof instanceRef.exports.vibe_http_host_string_new !== "function") {
    throw new Error("missing exported helper: vibe_http_host_string_new");
  }
  const encoded = new TextEncoder().encode(text);
  const tagged = instanceRef.exports.vibe_http_host_string_new(encoded.length);
  if (typeof tagged !== "bigint") {
    throw new Error(`expected tagged string bigint from helper, got ${typeof tagged}`);
  }
  if ((tagged & TAG_MASK) !== TAG_OBJ) {
    throw new Error(`helper returned non-string tagged value: tag=${tagged & TAG_MASK}`);
  }
  const ptr = Number(tagged & ~TAG_MASK);
  const start = ptr + 8;
  const mem = new Uint8Array(instanceRef.exports.memory.buffer);
  const end = start + encoded.length;
  if (end > mem.length) {
    throw new Error(`helper allocated out-of-bounds string buffer: ${start}..${end}`);
  }
  mem.set(encoded, start);
  return tagged;
}

function createHttpHost(policy) {
  let nextHandle = 1000;
  let instanceRef = null;
  const handleKinds = new Map();

  function allocHandle(kind) {
    const tagged = tagInt(nextHandle);
    nextHandle += 1;
    handleKinds.set(tagged, kind);
    return tagged;
  }

  function expectHandle(handle, kind, op) {
    const actual = handleKinds.get(handle);
    if (actual !== kind) {
      throw new Error(`unexpected ${op} handle: ${handle.toString()}`);
    }
  }

  const host = {
    http_request(method, url, _headers, _body) {
      const decodedUrl = decodeTaggedString(instanceRef, url);
      const target = parseHttpConnectTarget(decodedUrl);
      if (target == null) {
        throw new Error(`invalid URL for network capability check: ${decodedUrl}`);
      }
      if (!canConnect(policy.connectRules, target.host, target.port)) {
        throw new Error(`PermissionDenied: net_connect:${target.host}:${target.port}`);
      }
      decodeTaggedString(instanceRef, method);
      return allocHandle("response");
    },
    http_response_status(handle) {
      if (!hasConnectAny(policy.connectRules)) {
        throw new Error("PermissionDenied: net_response_status");
      }
      expectHandle(handle, "response", "response-status");
      return tagInt(200);
    },
    http_response_header(handle, name) {
      if (!hasConnectAny(policy.connectRules)) {
        throw new Error("PermissionDenied: net_response_header");
      }
      expectHandle(handle, "response", "response-header");
      decodeTaggedString(instanceRef, name);
      return encodeTaggedString(instanceRef, "");
    },
    http_response_body(handle) {
      if (!hasConnectAny(policy.connectRules)) {
        throw new Error("PermissionDenied: net_response_body");
      }
      expectHandle(handle, "response", "response-body");
      return encodeTaggedString(instanceRef, "");
    },
    http_close(handle) {
      if (!hasConnectAny(policy.connectRules)) {
        throw new Error("PermissionDenied: net_close");
      }
      handleKinds.delete(handle);
      return 0n;
    },
    http_listen(portValue) {
      const port = untagInt(portValue);
      if (!canListen(policy.listenRules, port)) {
        throw new Error(`PermissionDenied: net_listen:${port}`);
      }
      return allocHandle("listener");
    },
    http_accept(handle) {
      if (!hasListenAny(policy.listenRules)) {
        throw new Error("PermissionDenied: net_accept");
      }
      expectHandle(handle, "listener", "accept");
      return allocHandle("incoming");
    },
    http_request_method(handle) {
      if (!hasListenAny(policy.listenRules)) {
        throw new Error("PermissionDenied: net_request_method");
      }
      expectHandle(handle, "incoming", "request-method");
      return encodeTaggedString(instanceRef, "GET");
    },
    http_request_url(handle) {
      if (!hasListenAny(policy.listenRules)) {
        throw new Error("PermissionDenied: net_request_url");
      }
      expectHandle(handle, "incoming", "request-url");
      return encodeTaggedString(instanceRef, "/");
    },
    http_request_header(handle, name) {
      if (!hasListenAny(policy.listenRules)) {
        throw new Error("PermissionDenied: net_request_header");
      }
      expectHandle(handle, "incoming", "request-header");
      decodeTaggedString(instanceRef, name);
      return encodeTaggedString(instanceRef, "");
    },
    http_request_body(handle) {
      if (!hasListenAny(policy.listenRules)) {
        throw new Error("PermissionDenied: net_request_body");
      }
      expectHandle(handle, "incoming", "request-body");
      return encodeTaggedString(instanceRef, "");
    },
    http_respond(handle, _status, headers, body) {
      if (!hasListenAny(policy.listenRules)) {
        throw new Error("PermissionDenied: net_respond");
      }
      expectHandle(handle, "incoming", "respond");
      decodeTaggedString(instanceRef, headers);
      decodeTaggedString(instanceRef, body);
      return 0n;
    },
  };

  return {
    host,
    bindInstance(instance) {
      instanceRef = instance;
    },
  };
}

async function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (err) {
    usage();
    throw err;
  }
  const policy = {
    connectRules: parseConnectRulesFromEnv(),
    listenRules: parseListenRulesFromEnv(),
  };
  const wasm = fs.readFileSync(options.wasmPath);
  const httpHost = createHttpHost(policy);
  const instantiated = await WebAssembly.instantiate(wasm, {
    "vibe:http": httpHost.host,
  });
  const instance = instantiated.instance;
  httpHost.bindInstance(instance);
  const fn = instance.exports[options.invoke];
  if (typeof fn !== "function") {
    throw new Error(`exported function not found: ${options.invoke}`);
  }
  const result = fn();
  if (typeof result === "bigint") {
    console.log(result.toString());
    return;
  }
  if (typeof result === "number") {
    console.log(Math.trunc(result).toString());
    return;
  }
  throw new Error(`unsupported invoke result type: ${typeof result}`);
}

main().catch((err) => {
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});

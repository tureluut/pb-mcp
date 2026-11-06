import test from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import {
  existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync,
  statSync, writeFileSync,
} from "node:fs";
import http from "node:http";
import https from "node:https";
import { tmpdir } from "node:os";
import net from "node:net";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash, randomBytes } from "node:crypto";

const exe = process.env.PBMCP_EXE || fileURLToPath(new URL(`../pbmcp${process.platform === "win32" ? ".exe" : ""}`, import.meta.url));
const ACCEPT = "application/json, text/event-stream";
const VERSION = "2025-11-25";
const request = (id, method, params = {}) => ({ jsonrpc: "2.0", id, method, params });

// Pin determinism: resolve the newest index-*.json in the per-OS cache dir
// by mtime (docs_index.pb DocsFindNewestIndex rule) and pin it explicitly,
// like test/run_tests.mjs - a PBMCP_EXE candidate has no index beside it.
function resolveNewestIndex() {
  const dir = process.platform === "win32"
    ? join(process.env.LOCALAPPDATA, "purebasic-mcp")
    : join(process.env.XDG_CACHE_HOME || join(process.env.HOME, ".cache"), "purebasic-mcp");
  if (!existsSync(dir)) return null;
  let best = null;
  for (const name of readdirSync(dir)) {
    if (!/^index-.*\.json$/.test(name)) continue;
    const p = join(dir, name);
    try {
      const mtime = statSync(p).mtimeMs;
      if (!best || mtime > best.mtime) best = { path: p, mtime };
    } catch { /* unreadable entry - skip, like the loader */ }
  }
  return best?.path ?? null;
}
const pinnedIndex = resolveNewestIndex();
const caddyExe = process.env.CADDY_EXE;
const gatewayRequired = process.env.REQUIRE_HTTP_GATEWAY === "1";

// Owned pbmcp-* workspace entries in the OS temp dir (cleanup evidence),
// same signal the project suite asserts on.
const tempDirs = () => {
  try { return readdirSync(tmpdir()).filter((name) => name.startsWith("pbmcp-")); }
  catch { return []; }
};
function put(root, path, content) {
  const full = join(root, path);
  mkdirSync(dirname(full), { recursive: true });
  writeFileSync(full, content);
  return full;
}
function scratch(prefix) { return mkdtempSync(join(tmpdir(), prefix)); }

async function freePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => server.listen(0, "127.0.0.1", (error) => error ? reject(error) : resolve()));
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

function makeCredentials(root, count = 1) {
  const clients = Array.from({ length: count }, (_, i) => ({
    id: `client-${i + 1}`,
    token: randomBytes(32).toString("hex"),
  }));
  const path = join(root, "auth.json");
  writeFileSync(path, JSON.stringify({ clients: clients.map(({ id, token }) => ({
    id, tokenSha256: createHash("sha256").update(token, "ascii").digest("hex"),
  })) }));
  return { path, clients };
}

const authByPort = new Map();
function securityEnv() {
  const env = { ...process.env, PUREBASIC_MCP_NO_METRICS: "1", PBMCP_PRELOAD: "0" };
  for (const key of ["PBMCP_AUTH_FILE", "PBMCP_ALLOW_COMPILER_TOOLS", "PBMCP_TOOL_PROFILE"]) delete env[key];
  if (pinnedIndex) env.PUREBASIC_MCP_INDEX = pinnedIndex;
  return env;
}

async function startServer(t, port = undefined, { compilerTools = false, credentials: suppliedCredentials } = {}) {
  port ??= await freePort();
  const root = scratch("pb-http-auth-");
  const credentials = suppliedCredentials ?? makeCredentials(root, 2);
  const args = ["http", "--port", String(port), "--auth-file", credentials.path];
  if (compilerTools) args.push("--allow-compiler-tools");
  const child = spawn(exe, args, {
    stdio: ["ignore", "pipe", "pipe"],
    env: securityEnv(),
  });
  let stderr = "";
  child.stderr.setEncoding("utf8").on("data", (chunk) => { stderr += chunk; });
  child.stdout.setEncoding("utf8");
  let stdout = "";
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline && !stderr.includes(`127.0.0.1:${port}/mcp`)) {
    if (child.exitCode !== null) throw new Error(`HTTP server exited ${child.exitCode}: ${stderr}`);
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  assert.match(stderr, new RegExp(`127\\.0\\.0\\.1:${port}/mcp`), `server readiness: ${stderr}`);
  const stop = async () => {
    if (child.exitCode !== null) return;
    child.kill();
    await Promise.race([
      new Promise((resolve) => child.once("exit", resolve)),
      new Promise((resolve) => setTimeout(resolve, 3000)),
    ]);
    if (child.exitCode === null) child.kill("SIGKILL");
  };
  t.after(async () => { await stop(); authByPort.delete(port); rmSync(root, { recursive: true, force: true }); });
  authByPort.set(port, credentials.clients[0].token);
  return { child, port, root, credentials, token: credentials.clients[0].token, tokenB: credentials.clients[1]?.token, get stdout() { return stdout; }, get stderr() { return stderr; } };
}

function post(port, value, headers = {}) {
  const body = typeof value === "string" ? value : JSON.stringify(value);
  const requestHeaders = { "Content-Type": "application/json", Accept: ACCEPT, Authorization: `Bearer ${authByPort.get(port) ?? ""}`, ...headers };
  if (requestHeaders.Authorization === null) delete requestHeaders.Authorization;
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: "127.0.0.1", port, path: "/mcp", method: "POST",
      headers: requestHeaders,
    }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString("utf8") }));
    });
    req.on("error", reject);
    req.end(body);
  });
}

function raw(port, chunks, { delay = 0, waitClose = true, unauthenticated = false, token = undefined } = {}) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, "127.0.0.1");
    const received = [];
    let done = false;
    const finish = (error) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      if (error) reject(error);
      else resolve({ socket, data: Buffer.concat(received).toString("latin1") });
    };
    socket.on("data", (chunk) => received.push(chunk));
    socket.on("error", (error) => finish(error));
    socket.on("close", () => finish());
    const timer = setTimeout(() => { socket.destroy(); finish(new Error("raw HTTP client timeout")); }, 15000);
    socket.on("connect", async () => {
      try {
        for (let index = 0; index < chunks.length; index++) {
          let chunk = chunks[index];
          if (index === 0 && !unauthenticated && Buffer.isBuffer(chunk)) {
            const text = chunk.toString("latin1");
            const lineEnd = text.indexOf("\r\n");
            if (lineEnd >= 0 && !/\r\nAuthorization:/i.test(text)) {
              const bearer = token ?? authByPort.get(port) ?? "";
              chunk = Buffer.from(`${text.slice(0, lineEnd + 2)}Authorization: Bearer ${bearer}\r\n${text.slice(lineEnd + 2)}`, "latin1");
            }
          }
          socket.write(chunk);
          if (delay) await new Promise((resolveDelay) => setTimeout(resolveDelay, delay));
        }
        if (!waitClose) return;
      } catch (error) { finish(error); }
    });
  });
}

function splitResponse(rawText) {
  const at = rawText.indexOf("\r\n\r\n");
  assert.notEqual(at, -1, `invalid HTTP response: ${rawText.slice(0, 500)}`);
  const lines = rawText.slice(0, at).split("\r\n");
  return { status: Number(lines[0].split(" ")[1]), headers: lines.slice(1), body: rawText.slice(at + 4) };
}

function gatewayConfig(root, port, backendPort) {
  const install = readFileSync(fileURLToPath(new URL("../INSTALL.md", import.meta.url)), "utf8");
  const match = install.match(/```caddyfile\n([\s\S]*?# BEGIN PBMCP SECURE HTTP GATEWAY[\s\S]*?# END PBMCP SECURE HTTP GATEWAY[\s\S]*?)```/);
  assert.ok(match, "canonical Caddyfile block found in INSTALL.md");
  const storage = join(root, "caddy-storage").replaceAll("\\", "/");
  const log = join(root, "access.log").replaceAll("\\", "/");
  return match[1]
    .replace("# BEGIN PBMCP SECURE HTTP GATEWAY\n", "")
    .replace("# END PBMCP SECURE HTTP GATEWAY\n", "")
    .replace("    admin off\n", `    admin off\n    local_certs\n    skip_install_trust\n    auto_https disable_redirects\n    storage file_system {\n        root ${JSON.stringify(storage)}\n    }\n`)
    .replace("servers :443", `servers :${port}`)
    .replace("{$PBMCP_SITE_HOSTNAME}", `localhost:${port}`)
    .replaceAll("{$PBMCP_BACKEND_PORT}", String(backendPort))
    .replace("{$PBMCP_GATEWAY_LOG}", log);
}

function httpsRequest(port, ca, path, { method = "POST", headers = {}, body = "" } = {}) {
  return new Promise((resolve, reject) => {
    const req = https.request({ hostname: "localhost", port, path, method, headers, ca, rejectUnauthorized: true, agent: false }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString("utf8") }));
    });
    req.on("error", reject);
    req.end(body);
  });
}

async function startCaddy(t, root, port, backendPort) {
  const config = put(root, "Caddyfile", gatewayConfig(root, port, backendPort));
  const child = spawn(caddyExe, ["run", "--config", config, "--adapter", "caddyfile"], {
    stdio: ["ignore", "ignore", "pipe"],
    env: { ...securityEnv(), XDG_DATA_HOME: join(root, "xdg-data"), XDG_CONFIG_HOME: join(root, "xdg-config"), APPDATA: join(root, "appdata") },
  });
  let stderr = "";
  child.stderr.setEncoding("utf8").on("data", (chunk) => { stderr += chunk; });
  const stop = async () => {
    if (child.exitCode !== null) return;
    child.kill();
    await Promise.race([new Promise((resolve) => child.once("exit", resolve)), new Promise((resolve) => setTimeout(resolve, 4000))]);
    if (child.exitCode === null) child.kill("SIGKILL");
    await new Promise((resolve) => setTimeout(resolve, 100)); // let Windows release log/storage handles
  };
  t.after(stop);
  const storage = join(root, "caddy-storage");
  const caPath = join(storage, "pki", "authorities", "local", "root.crt");
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline && !existsSync(caPath)) {
    if (child.exitCode !== null) throw new Error(`Caddy exited ${child.exitCode}: ${stderr}`);
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  assert.ok(existsSync(caPath), `Caddy internal test CA created: ${stderr}`);
  const ca = readFileSync(caPath);
  let ready = false;
  while (Date.now() < deadline && !ready) {
    try { await httpsRequest(port, ca, "/not-mcp", { method: "GET" }); ready = true; }
    catch { if (child.exitCode !== null) throw new Error(`Caddy exited ${child.exitCode}: ${stderr}`); await new Promise((resolve) => setTimeout(resolve, 50)); }
  }
  assert.ok(ready, `Caddy TLS listener ready: ${stderr}`);
  return { child, config, ca, logPath: join(root, "access.log"), get stderr() { return stderr; } };
}

test("http-auth: credentials required, strict bearer parsing, and early body rejection", { concurrency: false }, async (t) => {
  const server = await startServer(t);
  const ping = request(1, "ping");
  const unauthenticated = await post(server.port, ping, { "MCP-Protocol-Version": VERSION, Authorization: null });
  assert.equal(unauthenticated.status, 401);
  assert.match(unauthenticated.headers["www-authenticate"] ?? "", /Bearer realm=\"pbmcp\"/);
  assert.equal(unauthenticated.headers["cache-control"], "no-store");
  assert.equal(unauthenticated.body, "");
  const bad = await post(server.port, ping, { "MCP-Protocol-Version": VERSION, Authorization: `Bearer ${"0".repeat(64)}` });
  assert.equal(bad.status, 401);
  const wrongCase = await post(server.port, ping, { "MCP-Protocol-Version": VERSION, Authorization: `Bearer ${server.token.toUpperCase()}` });
  assert.equal(wrongCase.status, 401, "bearer credential is case-sensitive lowercase hex");
  const valid = await post(server.port, ping, { "MCP-Protocol-Version": VERSION, Authorization: `bEaReR ${server.token}` });
  assert.equal(valid.status, 200);
  const validB = await post(server.port, ping, { "MCP-Protocol-Version": VERSION, Authorization: `Bearer ${server.tokenB}` });
  assert.equal(validB.status, 200, "each configured client has an independent verifier");
  for (const headers of [{ Cookie: `token=${server.token}` }, {}]) {
    const denied = await post(server.port, request(3, "ping"), { "MCP-Protocol-Version": VERSION, ...headers, Authorization: null });
    assert.equal(denied.status, 401, "credentials outside Authorization are not accepted");
  }
  const duplicate = await raw(server.port, [Buffer.from(`POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\nAuthorization: Bearer ${server.token}\r\nAuthorization: Bearer ${server.token}\r\nContent-Type: application/json\r\nAccept: ${ACCEPT}\r\nMCP-Protocol-Version: ${VERSION}\r\nContent-Length: 2\r\n\r\n{}`)], { unauthenticated: true });
  assert.equal(splitResponse(duplicate.data).status, 400, "duplicate Authorization fields are ambiguous");
  const combined = await raw(server.port, [Buffer.from(`POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\nAuthorization: Bearer ${server.token}, Bearer ${server.tokenB}\r\nContent-Type: application/json\r\nAccept: ${ACCEPT}\r\nMCP-Protocol-Version: ${VERSION}\r\nContent-Length: 2\r\n\r\n{}`)], { unauthenticated: true });
  assert.equal(splitResponse(combined.data).status, 400, "comma-joined credentials are malformed");
  const headOnly = await raw(server.port, [Buffer.from(`POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\nContent-Type: application/json\r\nAccept: ${ACCEPT}\r\nMCP-Protocol-Version: ${VERSION}\r\nContent-Length: 900000\r\n\r\n`)], { unauthenticated: true });
  assert.equal(splitResponse(headOnly.data).status, 401, "auth rejection does not wait for the declared body");
});

test("http-auth: startup rejects missing and malformed credential configuration", { concurrency: false }, async (t) => {
  const root = scratch("pb-http-startup-");
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const good = makeCredentials(root);
  const badFile = put(root, "bad.json", '{"clients":[{"id":"x","id":"y","tokenSha256":"' + "0".repeat(64) + '"}]}');
  const run = async (args) => {
    const child = spawn(exe, args, { stdio: ["ignore", "ignore", "pipe"], env: securityEnv() });
    return new Promise((resolve, reject) => {
      let stderr = "";
      child.stderr.setEncoding("utf8").on("data", (chunk) => { stderr += chunk; });
      child.once("error", reject);
      child.once("close", (code) => resolve({ code, stderr }));
    });
  };
  assert.notEqual((await run(["http"])).code, 0, "credentials are mandatory");
  assert.notEqual((await run(["http", "--auth-file"])).code, 0, "missing auth-file value is rejected");
  assert.notEqual((await run(["http", "--auth-file", good.path, "--auth-file", good.path])).code, 0, "duplicate auth-file option is rejected");
  assert.notEqual((await run(["http", "--auth-file", good.path, "--unknown"])).code, 0, "unknown option is rejected");
  assert.notEqual((await run(["http", "--auth-file", good.path, "--allow-compiler-tools", "--allow-compiler-tools"])).code, 0, "repeated boolean option is rejected");
  const duplicateMembers = await run(["http", "--auth-file", badFile]);
  assert.notEqual(duplicateMembers.code, 0, "duplicate JSON members are rejected");
  assert.doesNotMatch(duplicateMembers.stderr, /"0{64}"/);
  assert.ok(good.clients[0].token);
});

test("http-profile: default HTTP exposes only documentation tools and denies direct compiler calls", { concurrency: false }, async (t) => {
  const server = await startServer(t);
  const listed = await post(server.port, request(1, "tools/list"), { "MCP-Protocol-Version": VERSION });
  assert.equal(listed.status, 200);
  const names = JSON.parse(listed.body).result.tools.map((tool) => tool.name);
  assert.deepEqual(names, ["pb_docs_search", "pb_command"]);
  const before = tempDirs();
  for (const name of ["pb_check", "pb_run", "pb_version"]) {
    const denied = await post(server.port, request(2, "tools/call", { name, arguments: { file: "must-not-run.pb" } }), { "MCP-Protocol-Version": VERSION });
    assert.equal(denied.status, 200);
    assert.equal(JSON.parse(denied.body).result.isError, true);
    assert.match(JSON.parse(denied.body).result.content[0].text, /unavailable/i);
  }
  assert.deepEqual(tempDirs(), before, "denied compiler calls have no staging side effects");
  const initialized = await post(server.port, request(3, "initialize", { protocolVersion: VERSION, capabilities: {}, clientInfo: { name: "profile", version: "1" } }));
  const instructions = JSON.parse(initialized.body).result.instructions;
  assert.match(instructions, /documentation tools only/i);
  assert.doesNotMatch(instructions, /pb_check|pb_run/);

  const full = await startServer(t, undefined, { compilerTools: true });
  const fullList = await post(full.port, request(4, "tools/list"), { "MCP-Protocol-Version": VERSION });
  const stdio = spawnSync(exe, [], {
    input: JSON.stringify(request(1, "initialize", { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "profile", version: "1" } })) + "\n"
      + JSON.stringify(request(2, "tools/list")) + "\n",
    encoding: "utf8", timeout: 30000, env: securityEnv(),
  });
  assert.equal(stdio.status, 0, stdio.stderr);
  const stdioMessages = stdio.stdout.trim().split(/\r?\n/).map((line) => JSON.parse(line));
  assert.deepEqual(JSON.parse(fullList.body).result.tools, stdioMessages.find((message) => message.id === 2).result.tools);
  const stdioInstructions = stdioMessages.find((message) => message.id === 1).result.instructions;
  assert.equal(stdioInstructions, "Search before writing PureBasic (pb_docs_search, pb_command), verify every edit with pb_check, and use pb_run only for bounded console tests.");
  const fullInit = await post(full.port, request(5, "initialize", { protocolVersion: VERSION, capabilities: {}, clientInfo: { name: "profile", version: "1" } }));
  assert.equal(JSON.parse(fullInit.body).result.instructions, stdioInstructions);
});

test("http-admission: per-client burst, refill, isolation, and no dispatch after throttling", { concurrency: false }, async (t) => {
  const server = await startServer(t);
  for (let i = 0; i < 10; i++) {
    const response = await post(server.port, request(i, "ping"), { "MCP-Protocol-Version": VERSION });
    assert.equal(response.status, 200, `burst request ${i + 1}`);
  }
  const before = tempDirs();
  const limited = await post(server.port, request(11, "tools/call", { name: "pb_run", arguments: { file: "must-not-run.pb" } }), { "MCP-Protocol-Version": VERSION });
  assert.equal(limited.status, 429);
  assert.match(limited.headers["retry-after"] ?? "", /^[1-9][0-9]*$/);
  assert.equal(limited.headers["cache-control"], "no-store");
  assert.deepEqual(tempDirs(), before, "429 is decided before body dispatch");
  const otherClient = await post(server.port, request(12, "ping"), { "MCP-Protocol-Version": VERSION, Authorization: `Bearer ${server.tokenB}` });
  assert.equal(otherClient.status, 200, "client B has an isolated bucket");
  for (let i = 0; i < 5; i++) {
    const bad = await post(server.port, request(20 + i, "ping"), { "MCP-Protocol-Version": VERSION, Authorization: `Bearer ${"f".repeat(64)}` });
    assert.equal(bad.status, 401);
  }
  const afterBadAuth = await post(server.port, request(30, "ping"), { "MCP-Protocol-Version": VERSION, Authorization: `Bearer ${server.tokenB}` });
  assert.equal(afterBadAuth.status, 200, "anonymous failures do not consume or lock out another client");
  await new Promise((resolve) => setTimeout(resolve, 1100));
  const refilled = await post(server.port, request(31, "ping"), { "MCP-Protocol-Version": VERSION });
  assert.equal(refilled.status, 200, "one token refills per second");
});

// Audit lines cross a process pipe after the HTTP response is already out;
// poll bounded instead of assuming the event arrived with the response.
async function auditEvents(server, min, ms = 2000) {
  const deadline = Date.now() + ms;
  let events = [];
  while (Date.now() < deadline) {
    events = server.stderr.split(/\r?\n/).filter((line) => line.startsWith("{")).map((line) => JSON.parse(line));
    if (events.length >= min) break;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  return events;
}

test("http-audit: JSON-line completion events escape names and omit sensitive request data", { concurrency: false }, async (t) => {
  const server = await startServer(t);
  const authText = readFileSync(server.credentials.path, "utf8");
  const verifier = JSON.parse(authText).clients[0].tokenSha256;
  const secret = "PRIVATE-ARGUMENT-" + randomBytes(12).toString("hex");
  const listed = await post(server.port, request(1, "tools/list"), { "MCP-Protocol-Version": VERSION });
  assert.equal(listed.status, 200);
  const hostileTool = `x\"\n${"z".repeat(100)}`; // actual newline: audit JSON must escape it
  const toolError = await post(server.port, request(2, "tools/call", { name: hostileTool, arguments: { secret, path: server.credentials.path } }), { "MCP-Protocol-Version": VERSION });
  assert.equal(toolError.status, 200);
  const malformed = await post(server.port, `{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"${secret}`, /* unterminated string */ { "MCP-Protocol-Version": VERSION });
  assert.equal(malformed.status, 400);
  const events = await auditEvents(server, 3);
  assert.ok(events.length >= 3, server.stderr);
  assert.equal(events[0].client, "client-1");
  assert.equal(events[0].status, 200);
  assert.equal(events[0].category, "success");
  const hostileEvent = events.find((event) => event.tool.startsWith("x\""));
  assert.ok(hostileEvent, server.stderr);
  assert.ok(hostileEvent.tool.length <= 80);
  assert.equal(hostileEvent.category, "tool_error");
  assert.ok(events.some((event) => event.status === 400 && event.category === "denied"));
  assert.match(events[0].timestamp, /^\d{4}-\d\d-\d\dT/);
  assert.ok(Number.isInteger(events[0].elapsedMs));
  assert.doesNotMatch(server.stderr, new RegExp(server.token));
  assert.doesNotMatch(server.stderr, new RegExp(verifier));
  assert.doesNotMatch(server.stderr, new RegExp(secret));
  assert.doesNotMatch(server.stderr, new RegExp(server.credentials.path.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  assert.equal(server.stdout, "", "audit events and HTTP output never use stdout");
});

test("http-protocol: initialization, requests, notifications, tools and framing", { concurrency: false }, async (t) => {
  const server = await startServer(t);
  const initialized = await post(server.port, request(1, "initialize", { protocolVersion: VERSION, capabilities: {}, clientInfo: { name: "node", version: "1" } }));
  assert.equal(initialized.status, 200, initialized.body);
  assert.equal(initialized.headers["mcp-protocol-version"], VERSION);
  assert.equal(initialized.headers["mcp-session-id"], undefined);
  assert.equal(JSON.parse(initialized.body).result.protocolVersion, VERSION);

  const ping = await post(server.port, request(0, "ping"), { "MCP-Protocol-Version": VERSION });
  assert.equal(ping.status, 200, ping.body);
  assert.equal(JSON.parse(ping.body).id, 0);
  const listed = await post(server.port, request(2, "tools/list"), { "MCP-Protocol-Version": VERSION });
  assert.equal(listed.status, 200);
  assert.deepEqual(JSON.parse(listed.body).result.tools.map((tool) => tool.name), ["pb_docs_search", "pb_command"]);
  const docs = await post(server.port, request(3, "tools/call", { name: "pb_docs_search", arguments: { query: "OpenConsole", library: "Console" } }), { "MCP-Protocol-Version": VERSION });
  assert.equal(docs.status, 200, docs.body);
  assert.match(docs.body, /OpenConsole/);

  const notify = await post(server.port, { jsonrpc: "2.0", method: "notifications/initialized" }, { "MCP-Protocol-Version": VERSION });
  assert.equal(notify.status, 202);
  assert.equal(notify.body, "");
  const response = await post(server.port, { jsonrpc: "2.0", id: "client-1", result: {} }, { "MCP-Protocol-Version": VERSION });
  assert.equal(response.status, 202);
  assert.equal(response.body, "");
  const unknown = await post(server.port, request(4, "unknown/method"), { "MCP-Protocol-Version": VERSION });
  assert.equal(unknown.status, 200);
  assert.equal(JSON.parse(unknown.body).error.code, -32601);

  const parseError = await post(server.port, "{");
  assert.equal(parseError.status, 400);
  assert.equal(JSON.parse(parseError.body).error.code, -32700);
  // Admission consumes at header authentication, so the remaining assertions
  // continue on client B's independent burst bucket instead of tripping A's 429.
  const asB = { Authorization: `Bearer ${server.tokenB}` };
  for (const invalid of [[], { jsonrpc: "2.0", id: null, method: "ping" }, { jsonrpc: "1.0", id: 1, method: "ping" }]) {
    const result = await post(server.port, invalid, asB);
    assert.equal(result.status, 400, JSON.stringify(invalid));
    assert.equal(JSON.parse(result.body).error.code, -32600);
  }
  const batch = await post(server.port, [request(7, "ping")], asB);
  assert.equal(batch.status, 400);
  assert.equal(JSON.parse(batch.body).error.code, -32600);

  const badVersion = await post(server.port, request(5, "ping"), { "MCP-Protocol-Version": "2025-03-26", ...asB });
  assert.equal(badVersion.status, 400);
  const missingVersion = await post(server.port, request(6, "ping"), asB);
  assert.equal(missingVersion.status, 400);
  const wrongType = await post(server.port, request(7, "ping"), { "MCP-Protocol-Version": VERSION, "Content-Type": "text/plain", ...asB });
  assert.equal(wrongType.status, 415);
  const wrongAccept = await post(server.port, request(8, "ping"), { "MCP-Protocol-Version": VERSION, Accept: "application/json", ...asB });
  assert.equal(wrongAccept.status, 406);

  const utf8 = Buffer.from(JSON.stringify(request(9, "ping", { text: "fragmented 日本語 🚀" })), "utf8");
  // Auth must be part of the wire itself: the raw helper's injection needs a
  // chunk containing the complete request line, which 1-byte fragments never
  // have. The server correctly answers 401 and closes at header completion,
  // so an uninjected fragmented request would reset mid-write.
  const wire = Buffer.concat([
    Buffer.from(`POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\nAuthorization: Bearer ${server.tokenB}\r\nContent-Type: application/json; charset=utf-8\r\nAccept: ${ACCEPT}\r\nMCP-Protocol-Version: ${VERSION}\r\nContent-Length: ${utf8.length}\r\n\r\n`),
    utf8,
  ]);
  const pieces = [...wire].map((byte) => Buffer.from([byte]));
  const fragmented = await raw(server.port, pieces, { delay: 1, unauthenticated: true });
  const fragmentedResponse = splitResponse(fragmented.data);
  assert.equal(fragmentedResponse.status, 200, fragmented.data);
  assert.equal(JSON.parse(fragmentedResponse.body).id, 9);
  assert.equal(server.stdout, "", "HTTP tool/protocol responses must not appear on stdout");
});

test("http-security: loopback policy, method/path rejection, framing and resource bounds", { concurrency: false }, async (t) => {
  const server = await startServer(t);
  const headers = `Content-Type: application/json\r\nAccept: ${ACCEPT}\r\nMCP-Protocol-Version: ${VERSION}\r\n`;
  const body = Buffer.from(JSON.stringify(request(1, "ping")));
  const requestHead = (host = `127.0.0.1:${server.port}`) => `POST /mcp HTTP/1.1\r\nHost: ${host}\r\n${headers}Content-Length: ${body.length}\r\n\r\n`;
  for (const [wire, expected] of [
    [`GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\n\r\n`, 405],
    [`DELETE /mcp HTTP/1.1\r\nHost: localhost:${server.port}\r\n\r\n`, 405],
    [`OPTIONS /mcp HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\n\r\n`, 405],
    [`GET /other HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\n\r\n`, 404],
    [requestHead("evil.example") + body, 400],
    [requestHead() + "Origin: https://example.test\r\n" + body, 400],
    [`POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\nOrigin: https://example.test\r\n${headers}Content-Length: ${body.length}\r\n\r\n` + body, 403],
    [`POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\nX-Forwarded-Host: evil.example\r\n${headers}Content-Length: ${body.length}\r\n\r\n` + body, 400],
  ]) {
    const result = await raw(server.port, [Buffer.from(wire)]);
    assert.equal(splitResponse(result.data).status, expected, result.data.slice(0, 300));
  }
  for (const suffix of [
    `Content-Length: ${body.length}\r\nContent-Length: ${body.length}\r\n`,
    `Transfer-Encoding: chunked\r\n`,
  ]) {
    const wire = `POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\n${headers}${suffix}\r\n`;
    const result = await raw(server.port, [Buffer.from(wire)]);
    assert.equal(splitResponse(result.data).status, 400);
  }
  const noLength = await raw(server.port, [Buffer.from(`POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\n${headers}\r\n`)]);
  assert.equal(splitResponse(noLength.data).status, 411);
  const hugeHeader = await raw(server.port, [Buffer.from(`POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\nX-Pad: ${"x".repeat(17000)}\r\n\r\n`)]);
  assert.equal(splitResponse(hugeHeader.data).status, 431);
  const hugeBody = await raw(server.port, [Buffer.from(`POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\n${headers}Content-Length: 1048577\r\n\r\n`)]);
  assert.equal(splitResponse(hugeBody.data).status, 413);
  const pipeline = await raw(server.port, [Buffer.from(requestHead() + body.toString() + requestHead() + body.toString())]);
  assert.equal(splitResponse(pipeline.data).status, 400);

  const slow = net.connect(server.port, "127.0.0.1");
  slow.write(`POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\n`);
  const timeoutResult = await new Promise((resolve, reject) => {
    const parts = [];
    slow.on("data", (chunk) => parts.push(chunk));
    slow.on("error", reject);
    slow.on("close", () => resolve(Buffer.concat(parts).toString("latin1")));
    setTimeout(() => slow.destroy(), 13000).unref();
  });
  assert.equal(splitResponse(timeoutResult).status, 408);

  const held = Array.from({ length: 16 }, () => net.connect(server.port, "127.0.0.1"));
  await Promise.all(held.map((socket) => new Promise((resolve, reject) => { socket.once("connect", resolve); socket.once("error", reject); })));
  const excess = await raw(server.port, [Buffer.alloc(0)]);
  assert.equal(splitResponse(excess.data).status, 503);
  held.forEach((socket) => socket.destroy());
  assert.equal(server.stdout, "");
});

test("http-security: CLI validation, bind failure and closed-stdin longevity", { concurrency: false }, async (t) => {
  const root = scratch("pb-http-cli-");
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const credentials = makeCredentials(root);
  for (const args of [["http", "--auth-file", credentials.path, "--port", "0"], ["http", "--auth-file", credentials.path, "--port", "65001"], ["http", "--auth-file", credentials.path, "--port", "nope"], ["http", "--auth-file", credentials.path, "--port"], ["http", "--auth-file", credentials.path, "--port", "6817", "--port", "6818"], ["http", "--auth-file", credentials.path, "--bind", "0.0.0.0"]]) {
    const child = spawn(exe, args, { stdio: ["ignore", "pipe", "pipe"], env: securityEnv() });
    const status = await new Promise((resolve, reject) => {
      child.once("error", reject);
      child.once("close", (code) => resolve(code));
    });
    assert.notEqual(status, 0, args.join(" "));
  }

  const blocker = net.createServer();
  await new Promise((resolve, reject) => blocker.listen(0, "127.0.0.1", (error) => error ? reject(error) : resolve()));
  const port = blocker.address().port;
  const conflict = spawn(exe, ["http", "--port", String(port), "--auth-file", credentials.path], { stdio: ["ignore", "pipe", "pipe"], env: securityEnv() });
  const conflictExit = await new Promise((resolve) => conflict.once("close", resolve));
  assert.notEqual(conflictExit, 0);
  await new Promise((resolve) => blocker.close(resolve));

  const server = await startServer(t);
  await new Promise((resolve) => setTimeout(resolve, 250));
  assert.equal(server.child.exitCode, null, "HTTP server remains alive with stdin closed");
  const ping = await post(server.port, request(0, "ping"), { "MCP-Protocol-Version": VERSION });
  assert.equal(ping.status, 200);
  assert.equal(server.stdout, "");
});

// ---------------------------------------------------------------------------
// http-integration: staged compiler tools over HTTP, client isolation, and
// tool-error vs transport-error separation.
// ---------------------------------------------------------------------------
const VERSION_HEADER = { "MCP-Protocol-Version": VERSION };

async function toolsCall(port, id, name, args) {
  const response = await post(port, request(id, "tools/call", { name, arguments: args }), VERSION_HEADER);
  assert.equal(response.status, 200, `transport failed for ${name}: HTTP ${response.status} ${response.body.slice(0, 300)}`);
  const result = JSON.parse(response.body).result;
  assert.ok(result, `missing MCP result for ${name}: ${response.body.slice(0, 300)}`);
  return { result, text: result?.content?.[0]?.text ?? "" };
}

function pbCompiler() {
  const homes = [
    process.env.PUREBASIC_HOME,
    "C:\\Program Files (x86)\\PureBasic",
    "C:\\Program Files\\PureBasic",
    "C:\\PureBasic",
    process.env.LOCALAPPDATA && join(process.env.LOCALAPPDATA, "Programs", "PureBasic"),
  ].filter(Boolean);
  const compiler = homes.map((home) => join(home, "Compilers", "pbcompiler.exe")).find(existsSync);
  assert.ok(compiler, `PureBasic compiler required for the DLL fixture; checked: ${homes.join(", ")}`);
  return compiler;
}

function buildHelperDll(root) {
  const dllSource = put(root, "project/src/helper.pb", [
    "EnableExplicit",
    "ProcedureDLL.i ProjectValue(value.i)",
    "  ProcedureReturn value + 5",
    "EndProcedure",
    "",
  ].join("\n"));
  const dll = join(root, "project", "src", "helper.dll");
  const built = spawnSync(pbCompiler(), ["/DLL", "/EXE", dll, dllSource], {
    encoding: "utf8", timeout: 60000,
    env: { ...process.env, PUREBASIC_MCP_NO_METRICS: "1" },
  });
  assert.equal(built.status, 0, `DLL fixture compilation failed: ${built.stdout}\n${built.stderr}`);
  assert.ok(existsSync(dll), "PB compiler created the DLL");
}

test("http-integration: staged multi-file project end to end; schemas match stdio", { concurrency: false }, async (t) => {
  const server = await startServer(t, undefined, { compilerTools: true });

  // The public tool schema must match stdio exactly - only the transport
  // version differs.
  const stdio = spawnSync(exe, [], {
    input: JSON.stringify(request(1, "initialize", { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "schema-probe", version: "1" } })) + "\n"
      + JSON.stringify(request(2, "tools/list")) + "\n",
    encoding: "utf8", timeout: 30000,
    env: { ...process.env, PUREBASIC_MCP_NO_METRICS: "1" },
  });
  assert.equal(stdio.status, 0, stdio.stderr);
  const stdioTools = stdio.stdout.trim().split(/\r?\n/).map((line) => JSON.parse(line)).find((m) => m.id === 2).result.tools;
  const list = await post(server.port, request(2, "tools/list"), VERSION_HEADER);
  assert.equal(list.status, 200);
  assert.deepEqual(JSON.parse(list.body).result.tools, stdioTools, "HTTP tools/list must equal stdio tools/list");

  const docs = await toolsCall(server.port, 3, "pb_docs_search", { query: "OpenConsole", library: "Console" });
  assert.notEqual(docs.result.isError, true, docs.text);
  assert.match(docs.text, /OpenConsole/);

  // Explicit encompassing root, nested sources, parent include, assets and
  // (on Windows) an executable-relative DLL - staged, compiled and run inside
  // one owned workspace.
  const root = scratch("pb-http-proj-");
  try {
    put(root, "project/common.pbi", [
      "Procedure.s Tag()",
      '  ProcedureReturn "common-linked"',
      "EndProcedure",
      "",
    ].join("\n"));
    put(root, "project/src/assets/data.txt", "asset-ok");
    const lines = [
      "EnableExplicit",
      'XIncludeFile "../common.pbi"',
      "OpenConsole()",
      "PrintN(GetCurrentDirectory())",
      'Define f.i = ReadFile(#PB_Any, "assets/data.txt")',
      "If f",
      "  PrintN(ReadString(f))",
      "  CloseFile(f)",
      "Else",
      '  PrintN("ASSET READ FAILED")',
      "EndIf",
      "PrintN(Tag())",
    ];
    if (process.platform === "win32") {
      buildHelperDll(root);
      lines.push(
        'Define lib.i = OpenLibrary(#PB_Any, GetPathPart(ProgramFilename()) + "helper.dll")',
        'If lib = 0 : PrintN("DLL OPEN FAILED") : End 1 : EndIf',
        'PrintN(Str(CallFunction(lib, "ProjectValue", 37)))',
        "CloseLibrary(lib)",
      );
    } else {
      t.diagnostic("Platform-only skip: Windows PB DLL fixture is exercised on Windows; Linux shared-library runtime is validated only with a native Linux compiler.");
    }
    lines.push("End", "");
    const entry = put(root, "project/src/main.pb", "placeholder");
    writeFileSync(entry, lines.join("\n"));

    const before = tempDirs();
    const original = readFileSync(entry);
    const check = await toolsCall(server.port, 4, "pb_check", { file: entry, projectRoot: root });
    assert.notEqual(check.result.isError, true, check.text);
    const runResult = await toolsCall(server.port, 5, "pb_run", { file: entry, projectRoot: root });
    assert.notEqual(runResult.result.isError, true, runResult.text);
    assert.match(runResult.text, /pbmcp-/, "run executed inside the staged workspace");
    assert.match(runResult.text, /asset-ok/, "relative asset resolved from the staged cwd");
    assert.match(runResult.text, /common-linked/, "parent-relative include staged under the explicit root");
    if (process.platform === "win32") assert.match(runResult.text, /42/, "executable-relative DLL loaded and called");
    assert.deepEqual(readFileSync(entry), original, "staged run changed the original entry");
    const leftovers = tempDirs().filter((name) => !before.includes(name));
    assert.deepEqual(leftovers, [], `owned workspaces cleaned: ${leftovers.join(", ")}`);
  } finally { rmSync(root, { recursive: true, force: true }); }
  assert.equal(server.stdout, "", "HTTP tool responses never appear on stdout");
});

test("http-integration: identical ids across clients stay isolated; disconnect is contained", { concurrency: false }, async (t) => {
  const server = await startServer(t, undefined, { compilerTools: true });
  const root = scratch("pb-http-iso-");
  try {
    const entryA = put(root, "a/main.pb", ["EnableExplicit", "OpenConsole()", "Delay(1200)", 'PrintN("client-alpha")', "End", ""].join("\n"));
    const entryB = put(root, "b/main.pb", ["EnableExplicit", "OpenConsole()", "Delay(1200)", 'PrintN("client-beta")', "End", ""].join("\n"));
    const before = tempDirs();

    // Two clients, identical JSON-RPC id, distinct payloads. The server
    // serializes handler execution, so each response must carry its own
    // client's body and never the other's.
    const [a, b] = await Promise.all([
      toolsCall(server.port, 77, "pb_run", { file: entryA }),
      toolsCall(server.port, 77, "pb_run", { file: entryB }),
    ]);
    assert.notEqual(a.result.isError, true, a.text);
    assert.notEqual(b.result.isError, true, b.text);
    assert.match(a.text, /client-alpha/);
    assert.doesNotMatch(a.text, /client-beta/);
    assert.match(b.text, /client-beta/);
    assert.doesNotMatch(b.text, /client-alpha/);

    // Disconnect mid-run: a bounded run on a socket that goes away. The
    // server must still finish the tool, clean its owned workspace and
    // serve the next client without rerouting output.
    const entryC = put(root, "c/main.pb", ["EnableExplicit", "Repeat", "ForEver", ""].join("\n"));
    const socket = net.connect(server.port, "127.0.0.1");
    await new Promise((resolve, reject) => { socket.once("connect", resolve); socket.once("error", reject); });
    const body = JSON.stringify(request(77, "tools/call", { name: "pb_run", arguments: { file: entryC, timeoutMs: 1500 } }));
    const head = `POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\nContent-Type: application/json\r\nAccept: ${ACCEPT}\r\nMCP-Protocol-Version: ${VERSION}\r\nContent-Length: ${Buffer.byteLength(body)}\r\n\r\n`;
    socket.write(head + body);
    setTimeout(() => socket.destroy(), 300);
    const deadline = Date.now() + 30000;
    let leftovers = [];
    while (Date.now() < deadline) {
      leftovers = tempDirs().filter((name) => !before.includes(name));
      if (leftovers.length === 0) break;
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
    assert.deepEqual(leftovers, [], `workspace cleaned after client disconnect: ${leftovers.join(", ")}`);

    const survivor = await toolsCall(server.port, 78, "pb_run", { file: entryA });
    assert.notEqual(survivor.result.isError, true, survivor.text);
    assert.match(survivor.text, /client-alpha/);
    assert.doesNotMatch(survivor.text, /client-beta/);
    assert.equal(server.stdout, "", "no response leakage to stdout");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("http-gateway: canonical Caddy config preserves the trust boundary over verified TLS", { concurrency: false, skip: !caddyExe && !gatewayRequired ? "set CADDY_EXE to run stock Caddy gateway integration" : false }, async (t) => {
  assert.ok(caddyExe && existsSync(caddyExe), "CADDY_EXE must name an installed Caddy executable when gateway tests are required");
  const root = scratch("pb-http-gateway-");
  // Caddy's freshly written storage/log files can stay AV/delete-pending
  // locked for a minute after exit on Windows. Retry within a bounded budget,
  // then hand the sweep to a detached process that keeps retrying, so a
  // transient external lock neither stalls the run nor leaves the scratch
  // dir behind.
  t.after(async () => {
    for (let attempt = 0; attempt < 12; attempt++) {
      try { rmSync(root, { recursive: true, force: true }); return; }
      catch { await new Promise((resolve) => setTimeout(resolve, 500)); }
    }
    const sweep = `const {rmSync}=require("fs");for(let i=0;i<240;i++){try{rmSync(process.argv[1],{recursive:true,force:true});break}catch(e){Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,500)}}`;
    spawn(process.execPath, ["-e", sweep, root], { detached: true, stdio: "ignore" }).unref();
    t.diagnostic(`gateway scratch left to detached retry sweep (transient lock): ${root}`);
  });

  // Phase one inspects exactly what Caddy places on the upstream wire.
  const upstream = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => {
      hits.push({ method: req.method, url: req.url, headers: req.headers, body: Buffer.concat(chunks).toString("utf8") });
      const body = JSON.stringify({ jsonrpc: "2.0", id: 1, result: { protocolVersion: VERSION } });
      res.writeHead(200, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) });
      res.end(body);
    });
  });
  const hits = [];
  await new Promise((resolve, reject) => upstream.listen(0, "127.0.0.1", (error) => error ? reject(error) : resolve()));
  t.after(() => new Promise((resolve) => {
    if (!upstream.listening) return resolve();
    upstream.close(() => resolve());
  }));
  const recordingPort = upstream.address().port;
  const recordGatewayPort = await freePort();
  const recordingGateway = await startCaddy(t, root, recordGatewayPort, recordingPort);
  const wireToken = randomBytes(32).toString("hex");
  const wireOrigin = "https://client.example";
  const wire = await httpsRequest(recordGatewayPort, recordingGateway.ca, "/mcp", {
    headers: { "Content-Type": "application/json", Accept: ACCEPT, Authorization: `Bearer ${wireToken}`, Origin: wireOrigin, "Content-Length": "2" }, body: "{}",
  });
  assert.equal(wire.status, 200, wire.body);
  assert.equal(hits.length, 1, "a tool POST is forwarded exactly once (no retry)");
  assert.equal(hits[0].method, "POST");
  assert.equal(hits[0].url, "/mcp");
  assert.equal(hits[0].headers.host, `127.0.0.1:${recordingPort}`);
  assert.equal(hits[0].headers.authorization, `Bearer ${wireToken}`);
  assert.equal(hits[0].headers.origin, wireOrigin);
  assert.equal(hits[0].headers.connection, "close");
  assert.equal(hits[0].headers.forwarded, undefined);
  for (const name of Object.keys(hits[0].headers)) assert.doesNotMatch(name, /^x-forwarded-/i, `forwarding header removed: ${name}`);
  await new Promise((resolve) => upstream.close(resolve));

  // Phase two sends real MCP messages through Caddy to the authenticated backend.
  const backendPort = await freePort();
  const backend = await startServer(t, backendPort);
  const gatewayPort = await freePort();
  const gateway = await startCaddy(t, root, gatewayPort, backend.port);
  const jsonHeaders = { "Content-Type": "application/json", Accept: ACCEPT, "MCP-Protocol-Version": VERSION };
  const absent = await httpsRequest(gatewayPort, gateway.ca, "/mcp", { headers: jsonHeaders, body: JSON.stringify(request(1, "ping")) });
  assert.equal(absent.status, 401);
  const wrong = await httpsRequest(gatewayPort, gateway.ca, "/mcp", { headers: { ...jsonHeaders, Authorization: `Bearer ${"0".repeat(64)}` }, body: JSON.stringify(request(2, "ping")) });
  assert.equal(wrong.status, 401);
  const auth = { ...jsonHeaders, Authorization: `Bearer ${backend.token}` };
  const initialized = await httpsRequest(gatewayPort, gateway.ca, "/mcp", { headers: auth, body: JSON.stringify(request(3, "initialize", { protocolVersion: VERSION, capabilities: {}, clientInfo: { name: "gateway", version: "1" } })) });
  assert.equal(initialized.status, 200, initialized.body);
  assert.equal(JSON.parse(initialized.body).result.protocolVersion, VERSION);
  const docs = await httpsRequest(gatewayPort, gateway.ca, "/mcp", { headers: auth, body: JSON.stringify(request(4, "tools/call", { name: "pb_docs_search", arguments: { query: "OpenConsole", library: "Console" } })) });
  assert.equal(docs.status, 200, docs.body);
  assert.match(docs.body, /OpenConsole/);
  const deniedTool = await httpsRequest(gatewayPort, gateway.ca, "/mcp", { headers: auth, body: JSON.stringify(request(5, "tools/call", { name: "pb_run", arguments: {} })) });
  assert.equal(deniedTool.status, 200, deniedTool.body);
  assert.equal(JSON.parse(deniedTool.body).result.isError, true);
  assert.match(deniedTool.body, /unavailable/);
  assert.equal((await httpsRequest(gatewayPort, gateway.ca, "/mcp", { method: "GET" })).status, 404);
  assert.equal((await httpsRequest(gatewayPort, gateway.ca, "/other", { method: "POST", headers: auth, body: "{}" })).status, 404);
  const querySecret = `must-not-log-${randomBytes(12).toString("hex")}`;
  assert.equal((await httpsRequest(gatewayPort, gateway.ca, `/mcp?${querySecret}`, { headers: auth, body: "{}" })).status, 404);
  const tooLarge = await httpsRequest(gatewayPort, gateway.ca, "/mcp", { headers: { ...auth, "Content-Length": "1048577" } });
  assert.equal(tooLarge.status, 413, `${tooLarge.body}\n${gateway.stderr}`);
  await new Promise((resolve) => setTimeout(resolve, 250));
  const accessLog = existsSync(gateway.logPath) ? readFileSync(gateway.logPath, "utf8") : "";
  assert.ok(accessLog.length > 0, "Caddy access log was written");
  assert.doesNotMatch(accessLog, new RegExp(backend.token));
  assert.doesNotMatch(accessLog, new RegExp(backend.credentials.clients[0].token));
  assert.doesNotMatch(accessLog, new RegExp(querySecret));
  assert.equal(backend.stdout, "", "gateway requests do not leak protocol output to stdout");
});

test("http-integration: tool errors return MCP results, not transport errors", { concurrency: false }, async (t) => {
  const server = await startServer(t, undefined, { compilerTools: true });
  const root = scratch("pb-http-err-");
  try {
    const good = put(root, "good/main.pb", ["EnableExplicit", 'PrintN("ok")', "End", ""].join("\n"));
    const broken = put(root, "broken/main.pb", "EnableExplicit\nthis is not valid\n");
    const forever = put(root, "forever/main.pb", ["EnableExplicit", "Repeat", "ForEver", ""].join("\n"));
    const otherDir = join(root, "other");
    mkdirSync(otherDir, { recursive: true });

    // toolsCall asserts HTTP 200 internally: every case below is a valid MCP
    // tool-error result, never a 4xx/5xx transport failure.
    const missing = await toolsCall(server.port, 91, "pb_check", { file: join(root, "missing", "main.pb") });
    assert.equal(missing.result.isError, true, missing.text);
    assert.match(missing.text, /File not found/i);

    const outside = await toolsCall(server.port, 92, "pb_check", { file: good, projectRoot: otherDir });
    assert.equal(outside.result.isError, true, outside.text);
    assert.match(outside.text, /outside projectRoot/i);

    const notDir = put(root, "plain.txt", "x");
    const badRoot = await toolsCall(server.port, 93, "pb_check", { file: good, projectRoot: notDir });
    assert.equal(badRoot.result.isError, true, badRoot.text);
    assert.match(badRoot.text, /projectRoot is missing or is not a directory/i);

    const compile = await toolsCall(server.port, 94, "pb_run", { file: broken });
    assert.equal(compile.result.isError, true, compile.text);
    assert.match(compile.text, /COMPILE FAILED/i);

    const timeout = await toolsCall(server.port, 95, "pb_run", { file: forever, timeoutMs: 1000 });
    assert.equal(timeout.result.isError, true, timeout.text);
    assert.match(timeout.text, /TIMEOUT/i);

    assert.equal(server.stdout, "", "tool errors are responses, not stdout traffic");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

// ---------------------------------------------------------------------------
// run_tests.mjs - the one acceptance suite for pbmcp.exe.
//
//   [1] framing + multibyte: exactly-100-line multibyte session, file mode
//       vs stdin-piped byte-identical, 7-byte dribble stress cutting UTF-8
//       chars across read boundaries
//   [2] protocol: initialize / tools/list / ping / unknown tool / malformed
//       line / unknown method / silent notifications; pb_version tool +
//       version / --version / -v CLI
//   [3] docs tools: pb_docs_search ranking, library filter, limits,
//       validation, case-fold, tokenize-to-empty; pb_command exact,
//       case-fold, did-you-mean, garble, $-token, ALL-CAPS, zero-param,
//       reference-title input
//   [4] pb_check: OK line, bad.pb + EnableExplicit hint, hint fixtures,
//       missing file, argument validation
//   [5] pb_run: hello + args pass-through, compile fail, 2 s timeouts on
//       both runaway fixtures, NO ORPHANS, no %TEMP% leftovers
//   [6] metrics: frozen 8-field record shape (temp file only) +
//       PUREBASIC_MCP_NO_METRICS=1 opt-out
//   [7] file mode + live stdin wiring (all five tools)
//   [8] missing-index UX, live on scratch dirs only: [A] missing env file,
//       [B] invalid JSON, [C] embedded placeholder (0 commands), [D]
//       no-index server stays fully alive
//   [9] native HTML scanner: test/fixtures_html_scan/pages vs goldens
//
// Artifacts land in test/out/. Run:  node test/run_tests.mjs
// Set PBMCP_EXE to test a build elsewhere - the repo-root exe is locked
// while a live server runs on it.
// ---------------------------------------------------------------------------
import { spawnSync, spawn, execFileSync } from "node:child_process";
import { writeFileSync, readFileSync, existsSync, rmSync, mkdirSync, readdirSync, statSync } from "node:fs";
import { join, dirname, relative } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
// Platform-aware exe name (port Phase 4): pbmcp.exe on Windows, pbmcp on
// Linux - matches #BinName$/#ExeSuffix$ in the server. PBMCP_EXE: test a
// build elsewhere (repo-root exe is locked while a live server runs on it).
const IS_WIN = process.platform === "win32";
const exeSuffix = IS_WIN ? ".exe" : "";
const exe = process.env.PBMCP_EXE || join(root, `pbmcp${exeSuffix}`);
const testDir = join(root, "test");
const outDir = join(testDir, "out");
mkdirSync(outDir, { recursive: true });

const FIX = join(testDir, "fixtures");
const BAD = join(FIX, "bad.pb");
const HELLO = join(FIX, "hello.pb");
const RUNAWAY_SILENT = join(FIX, "runaway_silent.pb");
const RUNAWAY_PRINT = join(FIX, "runaway_print.pb");
const STDERR_FLOOD = join(FIX, "stderr_flood.pb");
const HINTS = {
  dim: join(FIX, "hints_dim.pb"),
  comment: join(FIX, "hints_comment.pb"),
  sub: join(FIX, "hints_sub.pb"),
  protected: join(FIX, "hints_protected.pb"),
  procdollar: join(FIX, "hints_procdollar.pb"),
};
const BP = join(FIX, "bp.pb");

let pass = 0, fail = 0;
function check(name, cond, detail = "") {
  if (cond) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name}${detail ? " - " + detail : ""}`); }
}
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Order-insensitive structural equality (ComposeJSON alphabetizes members by
// design - compare PARSED structures, never raw bytes).
function deepEqual(a, b) {
  if (a === b) return true;
  if (Array.isArray(a) && Array.isArray(b)) {
    return a.length === b.length && a.every((v, i) => deepEqual(v, b[i]));
  }
  if (a && b && typeof a === "object" && typeof b === "object") {
    const ka = Object.keys(a).sort(), kb = Object.keys(b).sort();
    return ka.length === kb.length && ka.every((k, i) => k === kb[i] && deepEqual(a[k], b[k]));
  }
  return false;
}

// ---------------------------------------------------------------------------
// Pin determinism: resolve the newest index-*.json in the cache dir
// by mtime (docs_index.pb DocsFindNewestIndex rule) and pin it explicitly.
// ---------------------------------------------------------------------------
function resolveNewestIndex() {
  // Same chain the loader uses, per OS (port Phase 4): %LOCALAPPDATA% on
  // Windows, ${XDG_CACHE_HOME:-~/.cache} on Linux.
  const dir = IS_WIN
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

// Base env for EVERY pbmcp.exe spawn in this suite. Merges over the
// ambient environment (PATH, HOME, PUREBASIC_HOME, ...) - the server's
// Linux compiler discovery needs them, and Node's spawn env option
// REPLACES the environment when given (bare pins left the wiring server
// with a 2-var env: pbcompiler became unfindable and every spawn came
// back empty). Windows discovery uses absolute-path candidates and never
// noticed the bug.
function pinEnv(extra = {}) {
  return { ...process.env, PUREBASIC_MCP_NO_METRICS: "1", ...(pinnedIndex ? { PUREBASIC_MCP_INDEX: pinnedIndex } : {}), ...extra };
}

// ---------------------------------------------------------------------------
// PB session runner: feed a .jsonl array through one pbmcp.exe (pipe mode,
// or file mode via the `test` subcommand).
// ---------------------------------------------------------------------------
function runPb(build, env = {}, fileMode = false) {
  nid = 0;                       // per-session id counter (ids are read back
                                 // positionally via byId.get(N))
  const lines = build();
  const input = lines.map((l) => (typeof l === "string" ? l : JSON.stringify(l))).join("\n") + "\n";
  const session = join(outDir, "file_mode_session.jsonl");
  if (fileMode) writeFileSync(session, input);
  const r = spawnSync(exe, fileMode ? ["test", session] : [], {
    input: fileMode ? undefined : input,
    cwd: root,
    timeout: 90000,
    env: { ...process.env, ...pinEnv(), ...env },
    encoding: "utf8",
  });
  const msgs = r.stdout.split("\n").filter((l) => l.trim() !== "").map((l) => JSON.parse(l));
  return { status: r.status, stderr: r.stderr, msgs, byId: new Map(msgs.map((m) => [m.id, m])) };
}
let nid = 0;
const req = (method, params) => ({ jsonrpc: "2.0", id: ++nid, method, params });
const notify = (method, params) => ({ jsonrpc: "2.0", method, params });
const call = (name, args) => req("tools/call", { name, arguments: args });
const text = (m) => m?.result?.content?.[0]?.text ?? "";

// ===========================================================================
console.log("[0] determinism pin");
// ===========================================================================
check("newest index resolved (spawns pinned to it)", !!pinnedIndex, "no index-*.json in the per-OS cache dir (purebasic-mcp)");
if (pinnedIndex) console.log(`     pinned: ${pinnedIndex}`);

// ===========================================================================
console.log("\n[1] framing + multibyte (100-line session)");
// ===========================================================================
{
  const PAYLOADS = [
    "日本語のテスト🚀", "em—dash…ellipsis", "Ωμέγα-Ω",
    "éclair-combiné", "بيانات عربية", "한국어 텍스트🔥",
  ];
  const fixtureLines = [];
  const responses = [];  // expected: id per response, in order; null = parse error (id:null)
  let nextId = 1;
  const id = () => nextId++;
  function reqF(method, params) {
    const i = id();
    fixtureLines.push(JSON.stringify({ jsonrpc: "2.0", id: i, method, params }));
    responses.push(i);
  }
  function notifyF(method, params) {
    fixtureLines.push(JSON.stringify({ jsonrpc: "2.0", method, params }));
  }
  // unknown tool with a multibyte name - the name is echoed back in the error
  // text, proving multibyte round-trips the whole pipeline (read -> parse ->
  // dispatch -> compose -> write).
  const unknownNames = [];
  function unknownToolCall() {
    const name = "工具🚀_" + PAYLOADS[unknownNames.length % PAYLOADS.length];
    const i = id();
    fixtureLines.push(JSON.stringify({ jsonrpc: "2.0", id: i, method: "tools/call",
      params: { name, arguments: {} } }));
    responses.push(i);
    unknownNames.push(name);
  }
  function malformedF() {
    fixtureLines.push("{not json at all — 日本");
    responses.push(null);   // Parse error reply carries id:null
  }
  function unknownMethodF() {
    const i = id();
    fixtureLines.push(JSON.stringify({ jsonrpc: "2.0", id: i, method: "resources/list" }));
    responses.push(i);
  }

  reqF("initialize", { protocolVersion: "2025-03-26", clientInfo: { name: "framing-test", version: "0" } });
  notifyF("notifications/initialized");
  reqF("tools/list", {});
  let k = 0;
  while (fixtureLines.length + 7 <= 100) {
    const file = `C:\\test\\nörth\\sourceβ_${k}.pb — ${PAYLOADS[k % PAYLOADS.length]}.pb`;
    reqF("ping", {});
    reqF("tools/call", { name: "pb_check", arguments: { file } });
    reqF("tools/call", { name: "pb_docs_search", arguments: { query: PAYLOADS[k % PAYLOADS.length] } });
    unknownToolCall();
    malformedF();
    unknownMethodF();
    notifyF("ping");   // ping-as-notification: handled, produces no response
    k++;
  }
  while (fixtureLines.length < 100) reqF("ping", {});   // filler to exactly 100
  if (fixtureLines.length !== 100) throw new Error(`fixture has ${fixtureLines.length} lines`);
  const fixturePath = join(outDir, "multibyte_100.jsonl");
  writeFileSync(fixturePath, fixtureLines.join("\n") + "\n", "utf8");
  console.log(`     fixture: ${fixturePath} (100 lines, ${responses.length} expected responses)`);

  // file mode vs stdin-piped must be byte-identical
  const fileMode = spawnSync(exe, ["test", fixturePath], { env: pinEnv(), encoding: "buffer", cwd: root });
  const pipeMode = spawnSync(exe, [], { input: readFileSync(fixturePath), env: pinEnv(), encoding: "buffer", cwd: root });
  check("file mode exits 0", fileMode.status === 0, `status=${fileMode.status} stderr=${fileMode.stderr}`);
  check("pipe mode exits 0", pipeMode.status === 0, `status=${pipeMode.status} stderr=${pipeMode.stderr}`);
  writeFileSync(join(outDir, "file_mode.txt"), fileMode.stdout);
  writeFileSync(join(outDir, "pipe_mode.txt"), pipeMode.stdout);
  check("pipe output byte-identical to file mode",
    Buffer.compare(fileMode.stdout, pipeMode.stdout) === 0,
    `file=${fileMode.stdout.length}B pipe=${pipeMode.stdout.length}B`);

  const outLines = pipeMode.stdout.toString("utf8").split("\n").filter((l) => l.trim() !== "");
  check("response count matches expectation", outLines.length === responses.length,
    `got ${outLines.length}, want ${responses.length}`);
  let allJson = true, idsOk = true, initOk = false, listOk = false;
  const parsed = outLines.map((l) => { try { return JSON.parse(l); } catch { allJson = false; return null; } });
  parsed.forEach((obj, i) => { if (obj && obj.id !== responses[i]) idsOk = false; });
  const initResp = parsed[0], listResp = parsed[1];
  if (initResp) initOk = !!initResp.result?.protocolVersion && !!initResp.result?.serverInfo?.name;
  if (listResp) listOk = Array.isArray(listResp.result?.tools) && listResp.result.tools.length === 5;
  check("every output line parses as JSON", allJson);
  check("response id sequence intact", idsOk);
  check("initialize result well-formed", initOk);
  check("tools/list returns the 5 registered tools", listOk);
  const unknownCallResp = parsed.find((o) => o?.result?.isError === true);
  check("multibyte tool name round-trips in error text",
    !!unknownCallResp && unknownNames.every((n) => pipeMode.stdout.toString("utf8").includes(n)));

  // dribble stress: feed the fixture in 7-byte chunks (with 1ms gaps),
  // deliberately cutting multibyte chars across read boundaries.
  console.log("     [dribble]");
  await new Promise((resolve) => {
    const child = spawn(exe, [], { env: pinEnv(), stdio: ["pipe", "pipe", "pipe"] });
    const raw = readFileSync(fixturePath);
    let out = Buffer.alloc(0);
    child.stdout.on("data", (d) => { out = Buffer.concat([out, d]); });
    let i = 0;
    const t = setInterval(() => {
      for (let j = 0; j < 10 && i < raw.length; j++, i += 7) {
        child.stdin.write(raw.subarray(i, Math.min(i + 7, raw.length)));
      }
      if (i >= raw.length) {
        clearInterval(t);
        child.stdin.end();
      }
    }, 1);
    child.on("exit", () => {
      check("dribble output byte-identical to big-write pipe mode",
        Buffer.compare(out, pipeMode.stdout) === 0,
        `dribble=${out.length}B pipe=${pipeMode.stdout.length}B`);
      resolve();
    });
    setTimeout(() => { check("dribble completes in time", false); child.kill("SIGKILL"); resolve(); }, 30000);
  });
}

// ===========================================================================
console.log("\n[2] protocol + pb_version");
// ===========================================================================
{
  const r = runPb(() => [
    req("initialize", { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "proto", version: "0" } }),
    notify("notifications/initialized"),
    req("tools/list", {}),
    req("ping", {}),
    notify("ping"),
    call("no_such_tool", {}),
    "{not json at all", // malformed line
    req("resources/list", {}),
    notify("definitely/not/a/method"),
  ]);
  check("session exits 0", r.status === 0, `status=${r.status} stderr=${r.stderr}`);
  check("server is stdout-only (stderr silent)", r.stderr === "", r.stderr);

  const init = r.byId.get(1);
  check("initialize echoes protocolVersion", init?.result?.protocolVersion === "2025-03-26", JSON.stringify(init));
  check("initialize capabilities.tools.listChanged false (static tool list)", init?.result?.capabilities?.tools?.listChanged === false);
  check("initialize serverInfo name/version", init?.result?.serverInfo?.name === "purebasic-mcp-pb" &&
    typeof init?.result?.serverInfo?.version === "string", JSON.stringify(init?.result?.serverInfo));

  // MCP version negotiation (spec MUST): an unsupported client offer is
  // answered with a version the server supports, never echoed.
  const neg = runPb(() => [
    req("initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "neg", version: "0" } }),
  ]);
  check("initialize protocolVersion 2024-11-05 -> server-supported 2025-03-26",
    neg.byId.get(1)?.result?.protocolVersion === "2025-03-26", JSON.stringify(neg.byId.get(1)));

  check("notifications silent (exactly 6 responses for 6 requests)", r.msgs.length === 6, `got ${r.msgs.length}`);

  const list = r.byId.get(2);
  check("tools/list: 5 tools (4 core + PB-only pb_version)", Array.isArray(list?.result?.tools) && list.result.tools.length === 5);
  check("tools/list: pb_version schema present (PB-only tool)",
    (list?.result?.tools ?? []).some((t) => t?.name === "pb_version"));

  const ping = r.byId.get(3);
  check("ping result is empty object", !!ping?.result && deepEqual(ping.result, {}));

  const unknown = r.byId.get(4);
  check("unknown tool -> isError text 'MCP error -32602: Tool no_such_tool not found'",
    unknown?.result?.isError === true &&
    text(unknown) === "MCP error -32602: Tool no_such_tool not found", text(unknown));

  const malformed = r.msgs.find((m) => m.id === null);
  check("malformed line -> -32700 Parse error, id null",
    malformed?.error?.code === -32700 && malformed?.error?.message === "Parse error", JSON.stringify(malformed));

  // JSON-RPC 2.0: a request without a method is invalid -> -32600, id echoed
  const badReq = runPb(() => [
    req("initialize", {}),
    '{"jsonrpc":"2.0","id":99}',
  ]);
  const invalid = badReq.byId.get(99);
  check("method-less request -> -32600 Invalid Request, id 99 echoed",
    invalid?.error?.code === -32600 && invalid?.error?.message === "Invalid Request" && invalid?.id === 99,
    JSON.stringify(invalid));

  const badMethod = r.byId.get(5);
  check("unknown method -> -32601 Method not found",
    badMethod?.error?.code === -32601 && badMethod?.error?.message === "Method not found: resources/list",
    JSON.stringify(badMethod));

  // pb_version tool + version CLI
  const sv = init?.result?.serverInfo?.version ?? "";
  const v = runPb(() => [req("initialize", {}), call("pb_version", {})]);
  const vt = text(v.byId.get(2));
  check("pb_version: isError false", v.byId.get(2)?.result?.isError === false, vt);
  check("pb_version: line 1 = server name + serverInfo version + protocol",
    vt.startsWith(`purebasic-mcp-pb ${sv}, MCP protocol 2025-03-26`), vt.split("\n")[0]);
  check("pb_version: PureBasic line (detected version + install path, or not-found/failure hint)",
    /^PureBasic (\d+\.\d+ .+|: not found|: version detection failed)/m.test(vt), vt);
  check("pb_version: docs-index line (index PB version + counts + path, or none hint)",
    /^Docs index: (PB .+, built .+, \d+ commands, \d+ reference pages|none)/m.test(vt), vt);

  const cliEnv = pinEnv();
  const cli = spawnSync(exe, ["version"], { encoding: "utf8", timeout: 30000, env: cliEnv, cwd: root });
  check("version CLI: exit 0, silent stderr", cli.status === 0 && cli.stderr === "", `status=${cli.status} stderr=${cli.stderr.slice(0, 120)}`);
  check("version CLI: server line carries the same version as serverInfo",
    cli.stdout.startsWith(`pbmcp${exeSuffix} purebasic-mcp-pb `) && cli.stdout.includes(sv + ", MCP protocol 2025-03-26"), cli.stdout.split("\n")[0]);
  check("version CLI: --version and -v aliases answer identically (first line)",
    spawnSync(exe, ["--version"], { encoding: "utf8", timeout: 30000, env: cliEnv, cwd: root }).stdout.split("\n")[0] === cli.stdout.split("\n")[0] &&
    spawnSync(exe, ["-v"], { encoding: "utf8", timeout: 30000, env: cliEnv, cwd: root }).stdout.split("\n")[0] === cli.stdout.split("\n")[0]);
}

// ===========================================================================
console.log("\n[3] docs tools (pb_docs_search + pb_command)");
// ===========================================================================
{
  // command picks chosen FROM the live index: exact / case-fold /
  // did-you-mean / garble / $-token / ALL-CAPS / zero-param / 3D+CGI
  // libraries / reference-title input.
  const COMMANDS = [
    ["OpenWindow", "exact"],
    ["openwindow", "case-fold resolves to the same entry"],
    ["CREATEFILE", "ALL-CAPS folds to CreateFile"],
    ["StopDrawing", "zero-parameter command"],
    ["Str$", "$-token name -> unknown + did-you-mean"],
    ["CreateCamera", "unusual library: Camera (3D)"],
    ["CGIParameterName", "unusual library: CGI"],
    ["OpenWindw", "near-miss -> did-you-mean OpenWindow"],
    ["MessageReques", "near-miss -> did-you-mean MessageRequester"],
    ["Color table", "reference-page title fed to pb_command"],
    ["Compiler Directives (reference)", "docs_search display form, suffix stripped -> reference page"],
    ["openwindo", "did-you-mean"],
    ["xqzzkv", "garble -> search hint"],
    ["ReadFile", "mundane"],
    ["CopyFile", "mundane"],
    ["Mid", "mundane"],
    ["Random", "mundane"],
  ];
  const pb = runPb(() => [req("initialize", {}), ...COMMANDS.map(([name]) => call("pb_command", { name }))]);
  check("[3] command session exits 0, stderr silent", pb.status === 0 && pb.stderr === "", pb.stderr);
  const cOut = (name) => text(pb.byId.get(COMMANDS.findIndex(([n]) => n === name) + 2));
  const cOk = (name) => pb.byId.get(COMMANDS.findIndex(([n]) => n === name) + 2)?.result?.isError === false;
  const cErr = (name) => pb.byId.get(COMMANDS.findIndex(([n]) => n === name) + 2)?.result?.isError === true;

  check("OpenWindow: header + sections",
    cOk("OpenWindow") && /^OpenWindow  \[window\]  OS: /i.test(cOut("OpenWindow")) &&
    cOut("OpenWindow").includes("Syntax: Result = OpenWindow(") &&
    cOut("OpenWindow").includes("Parameters:") && cOut("OpenWindow").includes("Returns: ") &&
    cOut("OpenWindow").includes("See also: "), cOut("OpenWindow").split("\n")[0]);
  check("case-fold: openwindow resolves to OpenWindow", cOk("openwindow") && cOut("openwindow").includes("OpenWindow"), cOut("openwindow").slice(0, 120));
  check("ALL-CAPS: CREATEFILE folds to CreateFile", cOk("CREATEFILE") && cOut("CREATEFILE").includes("CreateFile"), cOut("CREATEFILE").slice(0, 120));
  check("zero-param: StopDrawing resolves", cOk("StopDrawing") && cOut("StopDrawing").includes("StopDrawing"), "");
  for (const name of ["CreateCamera", "CGIParameterName", "ReadFile", "CopyFile", "Mid", "Random"]) {
    check(`content: ${name}`, cOk(name) && cOut(name).includes(name), cOut(name).slice(0, 120));
  }
  check("did-you-mean: openwindo", cErr("openwindo") && cOut("openwindo").startsWith(`Unknown command "openwindo". Did you mean: OpenWindow`), cOut("openwindo"));
  check("did-you-mean: OpenWindw", cErr("OpenWindw") && cOut("OpenWindw").startsWith(`Unknown command "OpenWindw". Did you mean: OpenWindow`), cOut("OpenWindw"));
  check("did-you-mean: MessageReques -> MessageRequester",
    cErr("MessageReques") && cOut("MessageReques").includes("Did you mean:") && cOut("MessageReques").includes("MessageRequester"), cOut("MessageReques"));
  check("garble -> search hint",
    cErr("xqzzkv") && cOut("xqzzkv") === `Unknown command "xqzzkv". Use pb_docs_search to find the right name.`, cOut("xqzzkv"));
  check("$-token: Str$ -> unknown + did-you-mean Str", cErr("Str$") && cOut("Str$").startsWith(`Unknown command "Str$". Did you mean: Str`), cOut("Str$"));
  check("reference-title input -> reference page",
    cOk("Color table") && cOut("Color table").startsWith("Color table  [reference page]") &&
    cOut("Color table").includes("Full text: https://www.purebasic.com/documentation/reference/colortable.html"),
    cOut("Color table"));
  check("reference display form 'Title (reference)' resolves too",
    cOk("Compiler Directives (reference)") &&
    cOut("Compiler Directives (reference)").includes("Full text: https://www.purebasic.com/documentation/reference/compilerdirectives.html"),
    cOut("Compiler Directives (reference)"));

  // search queries: ranking, filters, limits, validation, tokenize-to-empty
  // (gates are index-agnostic: 5.73 / 6.40 / online indexes rank and case
  // library tags differently, so never pin one index's winner or casing)
  const QUERIES = [
    ["window", {}],                  // 0: top hit is a window command
    ["open window", {}],             // 1: multi-token, hits + trailer
    ["zzqqxx", {}],                  // 2: no-match
    ["color table", {}],             // 3: reference hit
    ["window", { library: "Window" }], // 4: library filter
    ["window", { limit: 3 }],        // 5: limit
    [null, {}],                      // 6: absent query -> validation
    ["x", { limit: 0 }],             // 7: min-length validation
    ["WINDOW", {}],                  // 8: case-folds to the same top hit as 0
    ["!!!", {}],                     // 9: tokenize -> empty -> no-match
    ["camera", {}],                  // 10: camera leads
    ["thread create mutex", {}],     // 11: multi-token broad
    ["window", { limit: 25 }],       // 12: max limit
    ["window", { limit: 26 }],       // 13: max-limit validation
  ];
  const ps = runPb(() => [req("initialize", {}), ...QUERIES.map(([q, args]) => call("pb_docs_search", q === null ? args : { query: q, ...args }))]);
  check("[3] search session exits 0, stderr silent", ps.status === 0 && ps.stderr === "", ps.stderr);
  const sOut = (i) => text(ps.byId.get(i + 2));
  const sMsg = (i) => ps.byId.get(i + 2);
  const sErr = (i) => sMsg(i)?.result?.isError === true;
  const hitLines = (i) => sOut(i).split("\n").filter((l) => /^\d+\. /.test(l));

  check("search 'window': top hit is a window command", /^1\. \S*window/i.test(hitLines(0)[0] ?? ""), sOut(0).slice(0, 160));
  check("search 'open window': hits + trailer line present",
    hitLines(1).length > 0 && sOut(1).split("\n").at(-1) === 'Use pb_command("<name>") for full syntax.', sOut(1).slice(0, 160));
  check("no-match message exact",
    sOut(2) === 'No matches for "zzqqxx". Try shorter keywords (e.g. "window", "string", "file").', sOut(2));
  check("reference page hit carries [reference] + full-text URL",
    sOut(3).includes(" [reference]") && sOut(3).includes("full text: https://www.purebasic.com/documentation/"), sOut(3).split("\n")[0]);
  const libLines = sOut(4).split("\n").slice(0, -1);
  check("library filter: every hit is the filtered library, no reference pages",
    libLines.length > 0 && libLines.every((l) => /\(window\)/i.test(l)) && !sOut(4).includes("[reference]"),
    sOut(4).split("\n")[0]);
  check("limit=3 yields exactly 3 hits",
    sOut(5).split("\n").length === 4 && /^3\. /.test(sOut(5).split("\n")[2]) && sOut(5).split("\n")[3].startsWith("Use pb_command"),
    JSON.stringify(sOut(5).split("\n")));
  check("absent query -> validation 'Required at query'",
    sOut(6) === "MCP error -32602: Input validation error: Invalid arguments for tool pb_docs_search: Required at query" &&
    sErr(6), sOut(6));
  check("limit=0 -> min-length validation message",
    sOut(7).endsWith("Number must be greater than or equal to 1 at limit"), sOut(7));
  check("WINDOW case-folds to the same top hit as 'window'",
    hitLines(8).length > 0 && hitLines(8)[0] === hitLines(0)[0], sOut(8).slice(0, 160));
  check("!!!: no-match message",
    !sErr(9) && sOut(9) === `No matches for "!!!". Try shorter keywords (e.g. "window", "string", "file").`, sOut(9));
  check("camera: a camera command leads", /camera/i.test(hitLines(10)[0] ?? ""), sOut(10).slice(0, 160));
  check("thread create mutex: hits returned", hitLines(11).length > 0 && !sErr(11), sOut(11).slice(0, 120));
  check("limit 25: at most 25 hit lines", hitLines(12).length <= 25 && hitLines(12).length > 1, String(hitLines(12).length));
  check("limit 26: rejected (max 25)",
    sErr(13) && /^MCP error -32602: Input validation error: .* at limit/.test(sOut(13)), sOut(13).slice(0, 160));

  // pb_command argument validation
  const pv = runPb(() => [req("initialize", {}), call("pb_command", {})]);
  check("absent name -> validation 'Required at name'", text(pv.byId.get(2)).endsWith("Required at name"), text(pv.byId.get(2)));
}

// ===========================================================================
console.log("\n[4] pb_check");
// ===========================================================================
{
  // Relative path with the platform separator (port Phase 4): Windows
  // ResolvePath treats '\' as a separator; POSIX keeps it as a legal
  // filename character, so the relative input must use '/' there.
  const relHello = ["test", "fixtures", "hello.pb"].join(IS_WIN ? "\\" : "/");
  const r = runPb(() => [
    req("initialize", {}),
    call("pb_check", { file: HELLO }),
    call("pb_check", { file: relHello }),   // relative: echoed as passed
    call("pb_check", { file: BAD }),
    call("pb_check", { file: HINTS.dim }),
    call("pb_check", { file: HINTS.comment }),
    call("pb_check", { file: HINTS.sub }),
    call("pb_check", { file: join(FIX, "nope.pb") }),
    call("pb_check", { file: 5 }),
    call("pb_check", { file: BP }),
    call("pb_check", { file: HINTS.protected }),
    call("pb_check", { file: HINTS.procdollar }),
  ]);
  const t = (id) => text(r.byId.get(id));

  check("good file (abs): OK — 13 lines, N ms (<abs>)",
    new RegExp(`^OK — 13 lines, \\d+ ms \\(${esc(HELLO)}\\)$`).test(t(2)) && r.byId.get(2)?.result?.isError === false,
    t(2));
  check("relative path: resolved AND echoed as passed",
    new RegExp(`^OK — 13 lines, \\d+ ms \\(${esc(relHello)}\\)$`).test(t(3)), t(3));

  const bad = t(4).split("\n");
  check("bad.pb: 'ERRORS (1):' header", bad[0] === "ERRORS (1):", bad[0]);
  check("bad.pb: EnableExplicit hint with the actual name",
    bad[1] === "Hint: EnableExplicit is on — declare it first, e.g. `Define x.i` (or `.s` for a string).", bad[1]);
  check("bad.pb: 'Line 3: With 'EnableExplicit', variables have to be declared: x'",
    bad[2] === "Line 3: With 'EnableExplicit', variables have to be declared: x", bad[2]);

  check("hints_dim: Dim-as hint",
    t(5) === "ERRORS (1):\nHint: PureBasic has no `Dim x As Integer` — use `Define x.i` for variables and `Dim a(n)` for arrays.\nLine 6: 'Dim' syntax is: Dim Name(nb)", t(5));
  check("hints_comment: bad-comment hint",
    t(6) === "ERRORS (1):\nHint: comments start with `;` — `'` and `//` are syntax errors in PureBasic.\nLine 5: Syntax error", t(6));
  check("hints_sub: VB Sub hint",
    t(7) === "ERRORS (1):\nHint: use `Procedure Name(...)` … `EndProcedure` (no Sub/End Sub); return values via `ProcedureReturn`.\nLine 5: Syntax error", t(7));

  check("missing file: 'File not found: <resolved-with-backslashes>'",
    t(8) === "File not found: " + join(FIX, "nope.pb") && r.byId.get(8)?.result?.isError === true, t(8));
  check("numeric file arg -> invalid type message",
    t(9) === "MCP error -32602: Input validation error: Invalid arguments for tool pb_check: Expected string, received number at file", t(9));

  // Best practices: always-on lint + new proc-scope hints (0.3.3)
  check("bp.pb: OK + all three best-practice notes",
    new RegExp("^OK — 9 lines, \\d+ ms \\\(" + esc(BP) + "\\)\\nBest practices \\(3\\):\\n" +
      esc("Line 4: `Global` inside a procedure creates hidden shared state — declare globals at file scope.") + "\\n" +
      esc("Line 7: avoid `Goto`/`Gosub` — use procedures and structured control flow.") + "\\n" +
      esc("Add `EnableExplicit` at the top — without it every typo compiles as an undeclared integer.") + "$", "s").test(t(10)) &&
    r.byId.get(10)?.result?.isError === false, t(10));
  check("hints_protected: proc-scope hint + error-path best-practice note",
    t(11) === "ERRORS (1):\n" +
      "Hint: `Protected`/`Static` can only be used inside a procedure — use `Define` at file scope, `Global` for shared state.\n" +
      "Line 5: 'Protected' can only be used inside a procedure\n" +
      "Best practices (1):\n" +
      "Add `EnableExplicit` at the top — without it every typo compiles as an undeclared integer.", t(11));
  check("hints_procdollar: '$' procedure-name hint (no lint section)",
    t(12) === "ERRORS (1):\n" +
      "Hint: a procedure name can't end in `$` — that's the string-variable marker; declare the return type instead: `Procedure.s Name()`.\n" +
      "Line 6: Syntax error", t(12));
}

// ===========================================================================
console.log("\n[5] pb_run: timeout / orphan / cleanup");
// ===========================================================================
{
  const imageRunning = (name) => {
    if (!IS_WIN) {
      // Linux: extension-less image (no .exe); pgrep -x matches /proc/comm.
      // Fixture stems stay < 15 chars so comm truncation cannot bite.
      const r = spawnSync("pgrep", ["-x", name.replace(/\.exe$/, "")], { encoding: "utf8" });
      return r.status === 0 && r.stdout.trim() !== "";
    }
    const r = spawnSync("tasklist", ["/FI", `IMAGENAME eq ${name}`, "/NH"], { encoding: "utf8" });
    return r.stdout.toLowerCase().includes(name.toLowerCase());
  };
  const pbmcpTempDirs = () => {
    try { return readdirSync(tmpdir()).filter((d) => d.startsWith("pbmcp-")); } catch { return []; }
  };
  const tempBefore = pbmcpTempDirs();
  const r = runPb(() => [
    req("initialize", {}),
    call("pb_run", { file: HELLO }),
    call("pb_run", { file: HELLO, args: ["alpha", "beta gamma", 'quote "inner" arg'] }),
    call("pb_run", { file: BAD }),
    call("pb_run", { file: RUNAWAY_SILENT, timeoutMs: 2000 }),
    call("pb_run", { file: RUNAWAY_PRINT, timeoutMs: 2000 }),
    call("pb_run", { file: STDERR_FLOOD }),
  ]);
  const t = (id) => text(r.byId.get(id));

  check("hello: 'exit 0 · N s' + stdout captured",
    new RegExp(`^exit 0 · \\d+\\.\\d+ s \\(${esc(HELLO)}\\)`).test(t(2)) &&
    t(2).includes("--- stdout ---\nhello from pb_run") && r.byId.get(2)?.result?.isError === false, t(2));
  // Embedded-quote args cannot round-trip (probe-sealed: PB children have
  // no command-line escape mechanism) - they are ProcQ-wrapped and arrive
  // split, but must not crash the run or corrupt their siblings.
  check("args pass-through (incl. quoted space arg; quote-bearing arg no crash)",
    t(3).startsWith("exit 0 · ") && t(3).includes("arg1=alpha") &&
    t(3).includes("arg2=beta gamma"), t(3));

  const cf = t(4).split("\n");
  check("compile fail header",
    new RegExp(`^COMPILE FAILED \\(${esc(BAD)}\\) — 1 error\\(s\\), compile took \\d+ ms$`).test(cf[0]) &&
    r.byId.get(4)?.result?.isError === true, cf[0]);
  check("compile fail shows Line 3 error", cf[1] === "Line 3: With 'EnableExplicit', variables have to be declared: x", cf[1]);

  check("silent runaway: 'TIMEOUT after N ms — process killed'",
    new RegExp(`^TIMEOUT after \\d+ ms — process killed \\(${esc(RUNAWAY_SILENT)}\\)`).test(t(5)) &&
    t(5).includes("--- stdout ---\n(empty)") && r.byId.get(5)?.result?.isError === true, t(5));
  check("printing runaway: killed too, stdout shows ticks",
    new RegExp(`^TIMEOUT after \\d+ ms — process killed \\(${esc(RUNAWAY_PRINT)}\\)`).test(t(6)) &&
    t(6).includes("tick"), t(6));

  for (const id of [5, 6]) {
    const elapsed = Number(/^TIMEOUT after (\d+) ms/.exec(t(id))?.[1]);
    check(`runaway response ${id}: timeout remains bounded`, elapsed >= 2000 && elapsed < 10000, t(id).split("\n")[0]);
  }

  // stderr flood: spin-window drain + linear join must keep this far under
  // the session timeout (without the hot poll loop the PB stderr pipe
  // locksteps at ~20 ms/line); 1.75 MB is under the 4 MB cap, so no
  // truncation marker may appear.
  const flSecs = Number(/^exit 0 · ([\d.]+) s/.exec(t(7))?.[1]);
  check("stderr flood: exit 0, stderr captured, no cap marker, < 10 s",
    /^exit 0 · [\d.]+ s /.test(t(7)) && t(7).includes("--- stderr ---") &&
    !t(7).includes("truncated at 4 MB") && flSecs > 0 && flSecs < 10, t(7).split("\n")[0]);

  // NO ORPHANS: the tree-kill must have taken both fixture exes down
  await sleep(400);
  check("no orphan: runaway_silent.exe gone", !imageRunning("runaway_silent.exe"));
  check("no orphan: runaway_print.exe gone", !imageRunning("runaway_print.exe"));

  const tempAfter = pbmcpTempDirs();
  const newLeftovers = tempAfter.filter((d) => !tempBefore.includes(d));
  check("temp cleanup: no pbmcp-* dirs left in %TEMP%", newLeftovers.length === 0, JSON.stringify(newLeftovers));
}

// ===========================================================================
console.log("\n[6] metrics (temp metrics file; shared live file untouched)");
// ===========================================================================
{
  const metricsPath = join(outDir, "metrics.jsonl");
  rmSync(metricsPath, { force: true });
  const build = () => [
    req("initialize", {}),
    call("pb_check", { file: HELLO }),
    call("pb_run", { file: HELLO }),
  ];
  const r = runPb(build, { PUREBASIC_MCP_METRICS: metricsPath, PUREBASIC_MCP_NO_METRICS: "0" });
  check("metrics run exits 0", r.status === 0);
  check("metrics file written", existsSync(metricsPath));
  if (existsSync(metricsPath)) {
    const recs = readFileSync(metricsPath, "utf8").split("\n").filter((l) => l.trim() !== "");
    check("exactly 2 records (pb_check + pb_run)", recs.length === 2, `got ${recs.length}`);
    const wantKeys = ["ts", "source", "tool", "file", "ok", "errorCount", "buckets", "durationMs"];
    recs.forEach((l, i) => {
      const rec = JSON.parse(l);
      const keys = Object.keys(rec);
      check(`record ${i}: frozen 8-field order`, wantKeys.every((k, j) => keys[j] === k) && keys.length === 8, `[${keys}]`);
      check(`record ${i}: file is the RESOLVED path`, rec.file === HELLO, rec.file);
      check(`record ${i}: ok=true, errorCount=0, buckets=[]`,
        rec.ok === true && rec.errorCount === 0 && Array.isArray(rec.buckets) && rec.buckets.length === 0);
      check(`record ${i}: ts Date.parse-able`, !Number.isNaN(Date.parse(rec.ts)), rec.ts);
      check(`record ${i}: durationMs >= 0`, typeof rec.durationMs === "number" && rec.durationMs >= 0);
    });
    check("record tools in call order", JSON.parse(recs[0]).tool === "pb_check" && JSON.parse(recs[1]).tool === "pb_run");
    writeFileSync(join(outDir, "metrics_record_sample.txt"), recs.join("\n"));
  }

  const scratch = join(outDir, "no_metrics_should_not_exist.jsonl");
  rmSync(scratch, { force: true });
  runPb(build, { PUREBASIC_MCP_METRICS: scratch, PUREBASIC_MCP_NO_METRICS: "1" });
  check("PUREBASIC_MCP_NO_METRICS=1 suppresses writes entirely", !existsSync(scratch));
}

// ===========================================================================
console.log("\n[7] file mode + live stdin wiring (all five tools)");
// ===========================================================================
{
  const r = runPb(() => [
    req("initialize", { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "file-mode", version: "0" } }),
    call("pb_docs_search", { query: "open window" }),
    call("pb_command", { name: "OpenWindow" }),
    call("pb_check", { file: BAD }),
    call("pb_run", { file: HELLO, args: ["file mode"] }),
  ], {}, true);
  check("file mode: exits 0, stderr silent, 5 responses", r.status === 0 && r.stderr === "" && r.msgs.length === 5);
  check("file mode: docs search answered", /^1\. /.test(text(r.byId.get(2))));
  check("file mode: command answered", text(r.byId.get(3)).startsWith("OpenWindow  ["));
  check("file mode: check answered", text(r.byId.get(4)).startsWith("ERRORS (1):") && r.byId.get(4).result.isError === true);
  check("file mode: run answered", text(r.byId.get(5)).includes("arg1=file mode") && r.byId.get(5).result.isError === false);
}
{
  await new Promise((resolve) => {
    const child = spawn(exe, [], { env: pinEnv(), stdio: ["pipe", "pipe", "pipe"] });
    let buf = "";
    const got = [];
    let killed = false;
    const timer = setTimeout(() => { check("wiring completes in time", false, "timeout"); finish(); }, 20000);
    child.stdout.on("data", (d) => {
      buf += d.toString("utf8");
      let idx;
      while ((idx = buf.indexOf("\n")) !== -1) {
        const line = buf.slice(0, idx); buf = buf.slice(idx + 1);
        if (!line.trim()) continue;
        try { got.push(JSON.parse(line)); } catch { check("wiring line parses", false, line); }
        step();
      }
    });
    child.stderr.on("data", () => {});   // server must not log to stdout; stderr ignored
    function send(obj) { child.stdin.write(JSON.stringify(obj) + "\n"); }
    function step() {
      if (got.length === 1) {
        check("wiring: initialize answered", got[0].result?.serverInfo?.name === "purebasic-mcp-pb");
        setTimeout(() => send(req("tools/list", {})), 25);
      } else if (got.length === 2) {
        check("wiring: tools/list answered with 5 tools", got[1].result?.tools?.length === 5);
        setTimeout(() => send(call("pb_command", { name: "OpenWindow" })), 25);
      } else if (got.length === 3) {
        check("wiring: pb_command answered with docs", String(got[2].result?.content?.[0]?.text).startsWith("OpenWindow  ["));
        setTimeout(() => send(call("pb_check", { file: BAD })), 25);
      } else if (got.length === 4) {
        check("wiring: pb_check answered with structured error",
          String(got[3].result?.content?.[0]?.text).startsWith("ERRORS (1):") && got[3].result?.isError === true);
        setTimeout(() => send(call("pb_docs_search", { query: "open window" })), 25);
      } else if (got.length === 5) {
        check("wiring: pb_docs_search answered", /^1\. /.test(String(got[4].result?.content?.[0]?.text)));
        setTimeout(() => send(call("pb_run", { file: HELLO })), 25);
      } else if (got.length === 6) {
        check("wiring: pb_run answered", String(got[5].result?.content?.[0]?.text).includes("hello from pb_run") && got[5].result?.isError === false);
        finish();
      }
    }
    function finish() {
      if (killed) return;
      killed = true;
      clearTimeout(timer);
      child.kill("SIGKILL");
      resolve();
    }
    send(req("initialize", { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "wire", version: "0" } }));
  });
  check("server process terminated", true);
}

// ===========================================================================
console.log("\n[8] missing-index UX (live, scratch dirs only)");
// ===========================================================================
{
  const HINT = "Build the index (node tools/build-online-index.mjs) or drop index-*.json next to the executable, then restart the server.";
  const EMBEDDED_EMPTY = "Docs index has no commands - build one: node tools/build-online-index.mjs <docsRoot> --out pbdocs-index.json (drop index-*.json next to the executable to switch help versions)";
  const scratch = join(outDir, "ux_scratch");
  const emptyDir = join(scratch, "empty");
  const missingPath = join(scratch, "missing.json");
  const badPath = join(scratch, "bad.json");
  rmSync(scratch, { recursive: true, force: true });
  mkdirSync(emptyDir, { recursive: true });
  writeFileSync(badPath, "{oops");          // deliberately invalid JSON
  // Steer the cache-dir discovery into the scratch dir, per OS (port Phase
  // 4): LOCALAPPDATA on Windows, XDG_CACHE_HOME on Linux - both hold no
  // index*.json, so the chain falls through to the embedded placeholder.
  const noCacheEnv = IS_WIN ? { LOCALAPPDATA: emptyDir } : { XDG_CACHE_HOME: emptyDir };

  // [A] explicit env -> missing file
  {
    const env = { PUREBASIC_MCP_INDEX: missingPath };
    const pb = runPb(() => [req("initialize", {}), call("pb_docs_search", { query: "window" }), call("pb_command", { name: "OpenWindow" })], env);
    const b1 = text(pb.byId.get(2)), b2 = text(pb.byId.get(3));
    check("[A] pb_docs_search is an error result", pb.byId.get(2)?.result?.isError === true, b1);
    check("[A] pb_command shares the missing-index path", pb.byId.get(3)?.result?.isError === true, b2);
    check("[A] message names the missing path + hint line",
      b1 === `PUREBASIC_MCP_INDEX points at a missing file: ${missingPath}\n${HINT}`, b1);
  }

  // [B] explicit env -> invalid JSON (engine suffix not gated)
  {
    const env = { PUREBASIC_MCP_INDEX: badPath };
    const pb = runPb(() => [req("initialize", {}), call("pb_docs_search", { query: "window" })], env);
    const b = text(pb.byId.get(2));
    const prefix = `Index ${badPath} is not valid JSON: `;
    check("[B] prefix + hint, isError",
      b.startsWith(prefix) && b.endsWith("\n" + HINT) && pb.byId.get(2)?.result?.isError === true, b);
  }

  // [C] no env, LOCALAPPDATA -> empty scratch dir, no index*.json next to the
  // exe -> the embedded placeholder loads with zero commands -> build-one
  // hint. (Precondition: no index*.json sits next to the tested exe; dropping
  // one there intentionally changes this scenario - that is the drop-in
  // feature.)
  {
    const env = { ...noCacheEnv, PUREBASIC_MCP_INDEX: "" };
    const pb = runPb(() => [req("initialize", {}), call("pb_docs_search", { query: "window" })], env);
    const b = text(pb.byId.get(2));
    check("[C] placeholder loads but reports no-index (isError)",
      b === `${EMBEDDED_EMPTY}\n${HINT}` && pb.byId.get(2)?.result?.isError === true, b);
  }

  // [D] structural: docs-only failure - tools/list + ping + pb_check unaffected
  {
    const env = { ...noCacheEnv, PUREBASIC_MCP_INDEX: "" };
    const pb = runPb(() => [
      req("initialize", {}), req("tools/list", {}), req("ping", {}), call("pb_check", { file: HELLO }),
    ], env);
    check("[D] session exits 0, stderr silent", pb.status === 0 && pb.stderr === "", pb.stderr);
    const list = pb.byId.get(2);
    const names = (list?.result?.tools ?? []).map((t) => t?.name).sort();
    check("[D] tools/list: all 5 tools present",
      Array.isArray(list?.result?.tools) && list.result.tools.length === 5 &&
      JSON.stringify(names) === JSON.stringify(["pb_check", "pb_command", "pb_docs_search", "pb_run", "pb_version"]),
      JSON.stringify(names));
    check("[D] ping answers {}", !!pb.byId.get(3)?.result && Object.keys(pb.byId.get(3).result).length === 0,
      JSON.stringify(pb.byId.get(3)?.result));
    const pbCheck = text(pb.byId.get(4));
    check("[D] pb_check hello.pb still compiles (OK — N lines)",
      new RegExp(`^OK — 13 lines, \\d+ ms \\(${esc(HELLO)}\\)$`).test(pbCheck) && pb.byId.get(4)?.result?.isError === false, pbCheck);
  }

  rmSync(scratch, { recursive: true, force: true });   // cleanup: scratch only
  check("[8] scratch dir deleted after the UX section", !existsSync(scratch));
}

// ===========================================================================
console.log("\n[9] native scanner: fixtures vs goldens");
// ===========================================================================
{
  const pages = join(testDir, "fixtures_html_scan", "pages");
  const goldens = join(testDir, "fixtures_html_scan", "goldens");
  const walk = (dir) => readdirSync(dir, { withFileTypes: true })
    .flatMap((e) => e.isDirectory() ? walk(join(dir, e.name)) : [join(dir, e.name)])
    .filter((p) => p.toLowerCase().endsWith(".html")).sort();
  let scanned = 0;
  for (const file of walk(pages)) {
    const rel = relative(pages, file).replaceAll("\\", "/");
    const [library] = rel.split("/");
    const actualBuffer = execFileSync(exe, ["scan", file, library, rel], { cwd: root, maxBuffer: 8 * 1024 * 1024, env: pinEnv() });
    const actual = JSON.parse(actualBuffer.toString("utf8"));
    const expected = JSON.parse(readFileSync(join(goldens, rel + ".json"), "utf8"));
    check(`scan golden: ${rel}`, deepEqual(actual, expected), JSON.stringify(actual).slice(0, 200));
    if (rel === "Cipher/Base64DecoderBuffer.html") check("U+FFFD emitted as EF BF BD",
      actualBuffer.includes(Buffer.from([0xef, 0xbf, 0xbd])));
    if (rel === "Window/WindowEvent.html") check("negative canary: no U+FFFD leak",
      !actualBuffer.includes(Buffer.from([0xef, 0xbf, 0xbd])));
    if (rel === "Reference/general_rules.html") check("synthetic return-values alias marker parsed",
      actual.returnValue === "Alias marker fixture content.");
    scanned++;
  }
  check("scanner fixtures all exercised", scanned > 0, `scanned ${scanned}`);
  console.log(`     ${scanned} fixture pages compared against goldens`);
}

// ---------------------------------------------------------------------------
console.log(`\nrun_tests: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);

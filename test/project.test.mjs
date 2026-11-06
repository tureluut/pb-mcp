import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  accessSync, chmodSync, closeSync, constants, copyFileSync, existsSync, mkdirSync,
  mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync,
  truncateSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, parse } from "node:path";
import { fileURLToPath } from "node:url";

const repo = dirname(dirname(fileURLToPath(import.meta.url)));
const exe = process.env.PBMCP_EXE || join(repo, `pbmcp${process.platform === "win32" ? ".exe" : ""}`);
const env = {
  ...process.env,
  PUREBASIC_MCP_NO_METRICS: "1",
};
const tempDirs = () => {
  try { return readdirSync(tmpdir()).filter((name) => name.startsWith("pbmcp-")); }
  catch { return []; }
};

function scratch(prefix) { return mkdtempSync(join(tmpdir(), prefix)); }
function put(root, path, content) {
  const full = join(root, path);
  mkdirSync(dirname(full), { recursive: true });
  writeFileSync(full, content);
  return full;
}
function request(method, params, id = 2) {
  return JSON.stringify({ jsonrpc: "2.0", id, method, params });
}
function callTool(name, args, timeout = 90000) {
  const input = [
    request("initialize", { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "project-tests", version: "1" } }, 1),
    request("tools/call", { name, arguments: args }),
  ].join("\n") + "\n";
  const result = spawnSync(exe, [], { input, cwd: repo, encoding: "utf8", timeout, env });
  assert.ifError(result.error);
  assert.equal(result.status, 0, `pbmcp exited ${result.status}: ${result.stderr}`);
  const messages = result.stdout.trim().split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
  return { response: messages.find((message) => message.id === 2), stderr: result.stderr, stdout: result.stdout };
}
function check(file, extra = {}) { return callTool("pb_check", { file, ...extra }); }
function run(file, extra = {}, timeout = 90000) { return callTool("pb_run", { file, ...extra }, timeout); }
function resultText(result) { return result?.response?.result?.content?.[0]?.text ?? ""; }
function isToolError(result) { return result?.response?.result?.isError === true; }
function assertNoOwnedTemps(before, message = "owned pbmcp-* workspaces were cleaned") {
  const leftovers = tempDirs().filter((name) => !before.includes(name));
  assert.deepEqual(leftovers, [], `${message}: ${leftovers.join(", ")}`);
}

test("project-staging: sibling, nested, conditional includes and binary data under Unicode paths", { concurrency: false }, () => {
  const root = scratch("pb-project- ");
  try {
    const project = join(root, "Grüße project");
    put(project, "main.pb", [
      "EnableExplicit",
      'XIncludeFile "sibling.pbi"',
      "CompilerIf #PB_Compiler_OS = #PB_OS_Windows",
      '  XIncludeFile "platform/windows.pbi"',
      "CompilerElse",
      '  XIncludeFile "platform/unix.pbi"',
      "CompilerEndIf",
      "DataSection",
      "payload:",
      '  IncludeBinary "assets/payload.bin"',
      "EndDataSection",
      "End",
      "",
    ].join("\n"));
    put(project, "sibling.pbi", 'XIncludeFile "nested/child.pbi"\n');
    put(project, "nested/child.pbi", 'XIncludeFile "../.hidden/hidden.pbi"\n');
    put(project, ".hidden/hidden.pbi", "; hidden dependency is retained\n");
    put(project, "platform/windows.pbi", "; Windows conditional branch\n");
    put(project, "platform/unix.pbi", "; non-Windows conditional branch\n");
    put(project, "assets/payload.bin", Buffer.from([0, 1, 2, 255, 0, 127]));

    const before = tempDirs();
    const result = check(join(project, "main.pb"));
    assert.equal(isToolError(result), false, resultText(result));
    assert.match(resultText(result), /^OK/);
    assertNoOwnedTemps(before);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("project-staging: explicit encompassing root resolves a parent-relative include", { concurrency: false }, () => {
  const root = scratch("pb-parent-root-");
  try {
    const project = join(root, "source tree");
    const file = put(project, "app/main.pb", 'EnableExplicit\nXIncludeFile "../shared/common.pbi"\nEnd\n');
    put(project, "shared/common.pbi", "; shared source is inside the explicit root\n");
    const before = tempDirs();
    const result = check(file, { projectRoot: project });
    assert.equal(isToolError(result), false, resultText(result));
    assert.match(resultText(result), /^OK/);
    assertNoOwnedTemps(before);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("project-safety: invalid roots, entry types and separator-boundary escapes are rejected", { concurrency: false }, () => {
  const root = scratch("pb-safety-roots-");
  try {
    const project = join(root, "project");
    const file = put(project, "src/main.pb", "EnableExplicit\nEnd\n");
    const outside = put(root, "project-other/outside.pb", "EnableExplicit\nEnd\n");
    const before = tempDirs();
    for (const projectRoot of [join(root, "missing"), file, ".", join(root, "project") + "-other", parse(file).root]) {
      let result;
      try { result = check(file, { projectRoot }); }
      catch (error) { throw new Error(`projectRoot ${projectRoot}: ${error.message}`); }
      assert.equal(isToolError(result), true, `accepted invalid root ${projectRoot}: ${resultText(result)}`);
    }
    const directoryEntry = check(project);
    assert.equal(isToolError(directoryEntry), true, resultText(directoryEntry));
    const escape = check(outside, { projectRoot: project });
    assert.equal(isToolError(escape), true, resultText(escape));
    assertNoOwnedTemps(before);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("project-safety: entry-count, byte and depth limits fail without partial workspaces", { concurrency: false }, (t) => {
  const root = scratch("pb-safety-limits-");
  try {
    const entries = join(root, "entries");
    put(entries, "main.pb", "EnableExplicit\nEnd\n");
    for (let i = 0; i < 10001; i++) writeFileSync(join(entries, `f${i}`), "");
    const deep = join(root, "deep");
    put(deep, "main.pb", "EnableExplicit\nEnd\n");
    let cursor = deep;
    for (let i = 0; i < 66; i++) { cursor = join(cursor, "d"); mkdirSync(cursor); }
    const big = join(root, "big");
    put(big, "main.pb", "EnableExplicit\nEnd\n");
    const oversized = put(big, "payload.bin", "");
    truncateSync(oversized, 256 * 1024 * 1024 + 1);

    const before = tempDirs();
    for (const projectRoot of [entries, deep, big]) {
      const result = check(join(projectRoot, "main.pb"), { projectRoot });
      assert.equal(isToolError(result), true, `accepted over-limit project ${projectRoot}: ${resultText(result)}`);
    }
    assertNoOwnedTemps(before, "limit failures did not leave partial workspaces");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

// Keep OS-specific filesystem failures explicit rather than silently treating
// unsupported link creation as a passing rejection test.
test("project-safety: links, dangling links, junctions and special entries are rejected", { concurrency: false }, (t) => {
  const root = scratch("pb-safety-links-");
  try {
    const file = put(root, "main.pb", "EnableExplicit\nEnd\n");
    const target = put(root, "target.pbi", "; target\n");
    const before = tempDirs();
    if (process.platform === "win32") {
      const targetDir = join(root, "target-dir");
      mkdirSync(targetDir);
      const junction = join(root, "junction");
      symlinkSync(targetDir, junction, "junction");
      const junctionResult = check(file, { projectRoot: root });
      assert.equal(isToolError(junctionResult), true, resultText(junctionResult));
      rmSync(junction, { recursive: true, force: true });
      try {
        symlinkSync(target, join(root, "linked.pbi"));
        symlinkSync(join(root, "does-not-exist"), join(root, "dangling.pbi"));
        const linkResult = check(file, { projectRoot: root });
        assert.equal(isToolError(linkResult), true, resultText(linkResult));
      } catch (error) {
        if (!["EPERM", "EACCES", "UNKNOWN"].includes(error.code)) throw error;
        t.diagnostic(`Platform-only skip: Windows symbolic-link/dangling-link creation privilege unavailable (${error.code}); junction rejection was tested.`);
      }
    } else {
      const link = join(root, "linked.pbi");
      symlinkSync(target, link);
      const dangling = join(root, "dangling.pbi");
      symlinkSync(join(root, "does-not-exist"), dangling);
      const result = check(file, { projectRoot: root });
      assert.equal(isToolError(result), true, resultText(result));
    }
    assertNoOwnedTemps(before, "link rejection cleans a partially copied workspace");
    if (process.platform !== "win32") {
      const fifoRoot = scratch("pb-safety-fifo-");
      try {
        const fifoFile = put(fifoRoot, "main.pb", "EnableExplicit\nEnd\n");
        const fifo = join(fifoRoot, "pipe");
        const mkfifo = spawnSync("mkfifo", [fifo], { encoding: "utf8" });
        if (mkfifo.status === 0) {
          const special = check(fifoFile, { projectRoot: fifoRoot });
          assert.equal(isToolError(special), true, resultText(special));
        } else t.skip(`mkfifo unavailable: ${mkfifo.stderr}`);
      } finally { rmSync(fifoRoot, { recursive: true, force: true }); }
    } else {
      t.diagnostic("Windows FIFO coverage is not applicable; the junction case exercises reparse-point rejection.");
    }
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("project-safety: unreadable entries fail clearly where permissions can be enforced", { concurrency: false }, (t) => {
  const root = scratch("pb-safety-unreadable-");
  try {
    const file = put(root, "main.pb", "EnableExplicit\nEnd\n");
    const blocked = put(root, "blocked.bin", "private data");
    let denied = false;
    try { chmodSync(blocked, 0); accessSync(blocked, constants.R_OK); }
    catch { denied = true; }
    if (!denied) {
      t.diagnostic("Platform-only skip: current account can read chmod-restricted files; unreadable-file rejection cannot be simulated.");
      t.skip("Unreadable-file permission is not enforceable for this test account.");
      return;
    }
    try {
      const before = tempDirs();
      const result = check(file, { projectRoot: root });
      assert.equal(isToolError(result), true, resultText(result));
      assertNoOwnedTemps(before);
    } finally { try { chmodSync(blocked, 0o600); } catch {} }
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("project-safety: explicit parent-root selection copies every in-root dependency", { concurrency: false }, () => {
  const root = scratch("pb-safety-root-copy-");
  try {
    const selected = join(root, "selected");
    const file = put(selected, "src/main.pb", 'EnableExplicit\nXIncludeFile "../shared.pbi"\nEnd\n');
    put(selected, "shared.pbi", "; retained dependency\n");
    const outside = put(root, "outside.pbi", "; must never be copied\n");
    const before = tempDirs();
    const result = check(file, { projectRoot: selected });
    assert.equal(isToolError(result), false, resultText(result));
    assertNoOwnedTemps(before);
    assert.ok(existsSync(outside));
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("project-safety: pb_run applies the same selection and rejects invalid project roots", { concurrency: false }, () => {
  const root = scratch("pb-safety-run-");
  try {
    const file = put(root, "main.pb", "EnableExplicit\nEnd\n");
    const before = tempDirs();
    const result = run(file, { projectRoot: join(root, "not-a-root") });
    assert.equal(isToolError(result), true, resultText(result));
    assertNoOwnedTemps(before);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("project-runtime: relative writes and cwd are staged; originals stay unchanged", { concurrency: false }, () => {
  const root = scratch("pb-runtime-");
  try {
    const project = join(root, "project");
    const source = put(project, "src/main.pb", [
      "EnableExplicit",
      "OpenConsole()",
      'Define f.i = CreateFile(#PB_Any, "generated.txt")',
      "If f",
      '  WriteStringN(f, GetCurrentDirectory(), #PB_UTF8)',
      '  WriteStringN(f, "generated", #PB_UTF8)',
      "  CloseFile(f)",
      "EndIf",
      'PrintN(GetCurrentDirectory())',
      "End",
      "",
    ].join("\n"));
    const original = readFileSync(source);
    const before = tempDirs();
    const result = run(source);
    const output = resultText(result);
    assert.equal(isToolError(result), false, output);
    assert.match(output, /pbmcp-/);
    assert.equal(existsSync(join(project, "src/generated.txt")), false, "relative output was incorrectly copied back");
    assert.deepEqual(readFileSync(source), original, "source file changed");
    assertNoOwnedTemps(before);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("project-runtime: copied stale executable is not run after compile failure", { concurrency: false }, () => {
  const root = scratch("pb-stale-exe-");
  try {
    const source = put(root, "main.pb", "EnableExplicit\nthis is not valid\n");
    const stagedExeName = process.platform === "win32" ? "main.exe" : "main";
    copyFileSync(exe, join(root, stagedExeName));
    const before = tempDirs();
    const result = run(source, { timeoutMs: 1500 });
    assert.equal(isToolError(result), true, resultText(result));
    assert.match(resultText(result), /COMPILE FAILED|ERROR|failed/i);
    assertNoOwnedTemps(before);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("project-runtime: included-file diagnostics keep source context", { concurrency: false }, () => {
  const root = scratch("pb-include-error-");
  try {
    const file = put(root, "main.pb", 'EnableExplicit\nXIncludeFile "broken.pbi"\nEnd\n');
    put(root, "broken.pbi", "Procedure Broken()\n  missingVariable = 1\nEndProcedure\n");
    const result = check(file);
    const output = resultText(result);
    assert.equal(isToolError(result), true, output);
    assert.match(output, /broken\.pbi|missingVariable|undeclared/i);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("project-runtime: executable-relative DLL/assets load from the staged project", { concurrency: false }, (t) => {
  if (process.platform !== "win32") {
    t.diagnostic("Platform-only skip: Windows PB DLL loading is exercised on Windows; Linux shared-library runtime is validated only with a native Linux compiler.");
    t.skip("Windows DLL compiler switch and loader test is Windows-only.");
    return;
  }
  const compilerHomes = [
    process.env.PUREBASIC_HOME,
    "C:\\Program Files (x86)\\PureBasic",
    "C:\\Program Files\\PureBasic",
    "C:\\PureBasic",
    process.env.LOCALAPPDATA && join(process.env.LOCALAPPDATA, "Programs", "PureBasic"),
  ].filter(Boolean);
  const compiler = compilerHomes.map((home) => join(home, "Compilers", "pbcompiler.exe")).find(existsSync);
  assert.ok(compiler, `PureBasic compiler required for DLL fixture; checked: ${compilerHomes.join(", ")}`);
  const root = scratch("pb-runtime-dll-");
  try {
    const project = join(root, "project");
    const sourceDir = join(project, "src");
    mkdirSync(sourceDir, { recursive: true });
    const dllSource = put(sourceDir, "helper.pb", [
      "EnableExplicit",
      "ProcedureDLL.i ProjectValue(value.i)",
      "  ProcedureReturn value + 5",
      "EndProcedure",
      "",
    ].join("\n"));
    const dll = join(sourceDir, "helper.dll");
    const built = spawnSync(compiler, ["/DLL", "/EXE", dll, dllSource], { encoding: "utf8", timeout: 30000, env });
    assert.equal(built.status, 0, `DLL compilation failed: ${built.stdout}\n${built.stderr}`);
    assert.ok(existsSync(dll), "PB compiler created the DLL");
    const entry = put(sourceDir, "main.pb", [
      "EnableExplicit",
      "OpenConsole()",
      'Define lib.i = OpenLibrary(#PB_Any, GetPathPart(ProgramFilename()) + "helper.dll")',
      "If lib = 0 : PrintN(\"DLL OPEN FAILED\") : End 1 : EndIf",
      'PrintN(Str(CallFunction(lib, "ProjectValue", 37)))',
      "CloseLibrary(lib)",
      "End",
      "",
    ].join("\n"));
    const before = tempDirs();
    const result = run(entry);
    assert.equal(isToolError(result), false, resultText(result));
    assert.match(resultText(result), /42/);
    assertNoOwnedTemps(before);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("project-runtime: successful and timed-out runs both clean their staged trees", { concurrency: false }, () => {
  const root = scratch("pb-runtime-cleanup-");
  try {
    const ok = put(root, "ok.pb", "EnableExplicit\nPrintN(\"ok\")\nEnd\n");
    const timeout = put(root, "timeout.pb", "EnableExplicit\nRepeat\nForEver\n");
    const before = tempDirs();
    assert.equal(isToolError(run(ok)), false);
    const timed = run(timeout, { timeoutMs: 1000 }, 30000);
    assert.equal(isToolError(timed), true, resultText(timed));
    assert.match(resultText(timed), /TIMEOUT/i);
    assertNoOwnedTemps(before);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

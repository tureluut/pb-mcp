#!/usr/bin/env node
// ---------------------------------------------------------------------------
// fetch-online-docs.mjs - mirror the official PureBasic online documentation
// (https://www.purebasic.com/documentation/) into a local directory tree in
// the layout build-online-index.mjs (and the coverage check) expect.
//
// Page discovery:
//   - reference/commandindex.html  -> the complete command page list (the
//     same list the coverage check uses; hrefs are unquoted)
//   - the site root index          -> the reference/*.html page list
// Skipped dirs (helppictures, examples, mainguide, ...) contain no
// command pages listed in commandindex.html, so they need no download.
//
// Usage: node tools/fetch-online-docs.mjs [mirrorDir] [--base <url>]
// Writes <mirrorDir>/manifest.json on success. Exits 1 on any page that
// could not be fetched after retries.
// ---------------------------------------------------------------------------
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

const args = process.argv.slice(2);
let mirror = 'tmp/online-docs';
let base = 'https://www.purebasic.com/documentation/';
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--base') base = args[++i];
  else mirror = args[i];
}
if (!base.endsWith('/')) base += '/';

const CONCURRENCY = 6;
const RETRIES = 3;
const TIMEOUT_MS = 30000;
const HEADERS = { 'User-Agent': 'purebasic-mcp-docs-index/1.0 (+https://github.com/)' };

function extractHrefs(html, re) {
  const out = [];
  re.lastIndex = 0;
  let m;
  while ((m = re.exec(html)) !== null) out.push(m[1]);
  return out;
}

// href="../lib/file.html" AND unquoted href=../lib/file.html (DocMaker emits
// unquoted hrefs in commandindex.html - see IndexQuoteUnquotedHrefs).
const RE_CMD_HREF = /href\s*=\s*"?\.\.\/([a-z0-9_]+\/[a-z0-9_]+\.html)/gi;
const RE_REF_HREF = /href\s*=\s*"?reference\/([a-z0-9_]+\.html)/gi;

async function fetchPage(url) {
  for (let attempt = 1; attempt <= RETRIES; attempt++) {
    try {
      const res = await fetch(url, { headers: HEADERS, signal: AbortSignal.timeout(TIMEOUT_MS) });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return Buffer.from(await res.arrayBuffer());
    } catch (e) {
      if (attempt === RETRIES) throw new Error(`${url}: ${e.message}`);
      await new Promise(r => setTimeout(r, 800 * attempt));
    }
  }
}

async function pool(items, worker) {
  const queue = [...items];
  const runners = Array.from({ length: Math.min(CONCURRENCY, queue.length) }, async () => {
    while (queue.length) await worker(queue.shift());
  });
  await Promise.all(runners);
}

const rootHtml = (await fetchPage(base)).toString('latin1');
// commandindex.html holds the authoritative full command list (the same list
// the native builder's coverage check walks):
const cmdHtml = (await fetchPage(base + 'reference/commandindex.html')).toString('latin1');
const cmdPages = [...new Set(extractHrefs(cmdHtml, RE_CMD_HREF))];
// reference pages start from the root index links; many more (user guide,
// migration pages) are only linked from OTHER reference pages, so the crawl
// runs to a fixpoint: scan every fetched reference page for further
// reference/<name>.html and same-dir <name>.html links until no new names.
// commandindex.html is always included (coverage oracle; excluded from the
// index itself by the builder).
const refSet = new Set(extractHrefs(rootHtml, RE_REF_HREF));
refSet.add('commandindex.html');
const refCache = new Map(); // name -> body (latin1)
let grew = true;
while (grew) {
  grew = false;
  const todo = [...refSet].filter(n => !refCache.has(n));
  await pool(todo, async name => {
    try {
      refCache.set(name, await fetchPage(base + 'reference/' + name));
    } catch {
      refCache.set(name, null); // dead link: remember, skip when writing
    }
  });
  for (const body of refCache.values()) {
    if (body === null) continue;
    const html = body.toString('latin1');
    for (const m of html.matchAll(/href\s*=\s*"?(?:\.\.\/)?reference\/([a-z0-9_]+\.html)/gi)) {
      if (!refSet.has(m[1])) { refSet.add(m[1]); grew = true; }
    }
    for (const m of html.matchAll(/href\s*=\s*"?([a-z0-9_]+\.html)/gi)) {
      if (!refSet.has(m[1])) { refSet.add(m[1]); grew = true; }
    }
  }
}
const sortedRef = [...refSet].sort();

console.log(`discovered ${cmdPages.length} command pages, ${sortedRef.length} reference pages`);

// persist the mirror; command pages are fetched in parallel here
mkdirSync(mirror, { recursive: true });
writeFileSync(join(mirror, 'index.html'), Buffer.from(rootHtml, 'latin1'));
mkdirSync(join(mirror, 'reference'), { recursive: true });
writeFileSync(join(mirror, 'reference', 'commandindex.html'), Buffer.from(cmdHtml, 'latin1'));
let done = 0, failed = [];
await pool(cmdPages, async rel => {
  try {
    const buf = await fetchPage(base + rel);
    const file = join(mirror, ...rel.split('/'));
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, buf);
    done++;
    if (done % 250 === 0) console.log(`  ${done}/${cmdPages.length} command pages`);
  } catch (e) {
    failed.push(e.message);
  }
});
if (failed.length) {
  console.error(`FAILED ${failed.length} page(s):`);
  for (const f of failed.slice(0, 20)) console.error('  ' + f);
  process.exit(1);
}
for (const [name, body] of refCache) {
  if (name === 'commandindex.html' || body === null) continue; // written / dead
  writeFileSync(join(mirror, 'reference', name), body);
}
const manifest = {
  kind: 'online',
  url: base,
  crawledAt: new Date().toISOString(),
  pages: cmdPages.length + refCache.size + 1,
  commandPages: cmdPages.length,
  referencePages: [...refCache.values()].filter(Boolean).length,
};
writeFileSync(join(mirror, 'manifest.json'), JSON.stringify(manifest, null, 2));
console.log(`mirrored ${cmdPages.length + refCache.size + 1} pages -> ${mirror}`);

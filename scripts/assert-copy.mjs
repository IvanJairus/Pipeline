/*
  An em dash written as \u2014 in a JS string, or &mdash; in HTML, renders as the
  same character a reader sees, so counting the literal character in the source
  under-reports it. This decodes the forms that reach the page and fails on any
  of them. En dashes are allowed: they are how a range reads.

    node scripts/assert-copy.mjs            report
    node scripts/assert-copy.mjs --strict   exit non-zero when anything is found
*/
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const strict = process.argv.includes("--strict");

const EM = [
  ["literal", /—/g],
  ["js-escape", /\\u2014/g],
  ["entity", /&#8212;|&mdash;/gi],
  ["spaced-en-dash", /\s–\s/g],
  ["double-hyphen", /\s--\s/g],
];

const TICS = [
  "rather than", "on purpose", "deliberately", "not just", "in order to",
  "due to the fact that", "it is important to note", "seamless", "robust",
  "cutting-edge", "game-changer", "unlock", "elevate", "empower", "delve",
  "testament", "journey", "vibrant", "tapestry", "let's dive", "honestly",
];

// Verbatim legal text is not our prose. Creative Commons writes its own licence
// headings with em dashes, and rewording them would misquote the licence.
// The checker itself is excluded because it contains every pattern it looks for.
const EXEMPT = new Set(["LICENSE.md", "scripts/assert-copy.mjs"]);

const files = execFileSync("git", ["ls-files"], { cwd: root, encoding: "utf8" })
  .split("\n").filter(Boolean)
  .filter((f) => /\.(html?|md|js|mjs|c?js|css|json|txt|groovy|sh|yml|yaml|svg)$/.test(f))
  .filter((f) => !/^node_modules\//.test(f) && !/package-lock\.json$/.test(f))
  .filter((f) => !EXEMPT.has(f));

const hits = [];
const tics = new Map();
let scanned = 0;

for (const f of files) {
  let text;
  try { text = fs.readFileSync(path.join(root, f), "utf8"); } catch { continue; }
  scanned += 1;
  const lines = text.split("\n");
  lines.forEach((line, i) => {
    for (const [kind, re] of EM) {
      const n = (line.match(re) || []).length;
      if (n) hits.push({ f, line: i + 1, kind, n, text: line.trim().slice(0, 110) });
    }
    const lower = line.toLowerCase();
    for (const t of TICS) {
      const n = lower.split(t).length - 1;
      if (n) tics.set(t, (tics.get(t) || 0) + n);
    }
  });
}

const byKind = {};
for (const h of hits) byKind[h.kind] = (byKind[h.kind] || 0) + h.n;
const total = Object.values(byKind).reduce((a, b) => a + b, 0);

console.log(`scanned ${scanned} tracked files in ${path.basename(root)}`);
console.log(`dash-as-connector: ${total} ${JSON.stringify(byKind)}`);
if (hits.length) {
  const perFile = new Map();
  for (const h of hits) perFile.set(h.f, (perFile.get(h.f) || 0) + h.n);
  for (const [f, n] of [...perFile].sort((a, b) => b[1] - a[1]).slice(0, 12)) console.log(`  ${String(n).padStart(4)}  ${f}`);
  console.log("  first 5 occurrences:");
  for (const h of hits.slice(0, 5)) console.log(`  ${h.f}:${h.line} [${h.kind}] ${h.text}`);
}
const ticHits = [...tics].filter(([, n]) => n >= 3);
console.log(`repeated hedges (>=3): ${ticHits.length ? ticHits.map(([t, n]) => `${t}=${n}`).join(", ") : "none"}`);

if (strict && total) { console.error("copy gate failed"); process.exit(1); }

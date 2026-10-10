#!/usr/bin/env node
/*
  Runs rules/fixture.json against the JavaScript port.

  The fixture is authored by the Groovy classes (see test/run-fixture.groovy).
  This file never writes it. Agreement between the two runners is the whole
  point: it is what lets the pipeline view on ivanjairus.xyz claim that the gate
  it animates is the gate the library ships.
*/

import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import * as R from './release-rules.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const fixture = JSON.parse(readFileSync(join(here, 'fixture.json'), 'utf8'));

function invoke(fn, input) {
  switch (fn) {
    case 'validateBranch': return R.validateBranch(input[0]);
    case 'validateTag': return R.validateTag(input[0]);
    case 'validatePromotion': return R.validatePromotion(input[0], input[1]);
    case 'validateService': return R.validateService(input[0]);
    case 'validateManifest': return R.validateManifest(input[0]);
    case 'approvalChain': return R.approvalChainProblems(input[0]);
    case 'evaluateGate': return R.evaluateGate(input[0]);
    case 'buildPlan': return R.buildPlan(input[0], input[1], input[2] || {});
    case 'planWaves': return R.planWaves(R.buildPlan(input[0], input[1])).map((w) => w.map((m) => m.id));
  }
  throw new Error(`unknown fn ${fn}`);
}

const canon = (v) => JSON.stringify(v);

let failed = 0;

// The watermark has to come out the same in a browser, where there is no
// node:crypto, and in Node. So the hand-rolled SHA-256 is checked against the
// real one before any fixture case is trusted.
let hashOk = true;
for (const probe of ['', 'a', 'v1.4.2|sit|api|jar|a1b2c3d', 'rel/sit→uat', 'x'.repeat(200)]) {
  const mine = R.__sha256Hex(probe);
  const real = createHash('sha256').update(probe, 'utf8').digest('hex');
  if (mine !== real) {
    hashOk = false;
    console.log(`  FAIL sha256(${JSON.stringify(probe.slice(0, 24))})\n         port: ${mine}\n         node: ${real}`);
  }
}
console.log(`  ${hashOk ? 'ok  ' : 'FAIL'} sha256 matches node:crypto on 5 probes`);
if (!hashOk) failed++;

for (const c of fixture.cases) {
  let actual;
  try {
    actual = invoke(c.fn, c.input);
  } catch (e) {
    actual = 'THREW ' + e.message;
  }
  const a = canon(actual), b = canon(c.expect);
  if (a !== b) {
    failed++;
    console.log(`  FAIL ${c.id}\n         groovy: ${b}\n         js:     ${a}`);
  } else {
    console.log(`  ok   ${c.id}`);
  }
}

const total = fixture.cases.length + 1;
console.log(`\n${total - failed}/${total} agree with the Groovy fixture`);
process.exit(failed === 0 ? 0 : 1);

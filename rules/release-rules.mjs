/*
  A port of shared-library/src/com/reference/release/{ReleaseRules,GateResult,
  DeploymentPlan}.groovy, kept line-for-line honest with the Groovy original.

  Why a port and not a re-implementation: the pipeline view on ivanjairus.xyz
  runs this file in the browser, and rules/fixture.json is authored by the Groovy
  classes. rules/run-fixture.mjs has to reproduce all 30 cases. If the two ever
  disagree, the page is lying about the code, and the test says so before anyone
  reads the page.

  Groovy truthiness is spelled out on purpose. In Groovy an empty map, an empty
  list and an empty string are all false; in JavaScript only {} is truthy. The
  helpers below keep the Groovy reading, because "no report received" and "an
  empty report received" have to fail the same gate.
*/

const truthy = (v) => {
  if (typeof v === 'boolean') return v;
  return v !== null && v !== undefined &&
    !(typeof v === 'string' && v === '') &&
    !(typeof v === 'number' && v === 0) &&
    !(Array.isArray(v) && v.length === 0) &&
    !(typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length === 0);
};

/*
  Groovy prints a Double threshold as "40.0", JavaScript prints the same value as
  "40". The thresholds are declared with a `d` suffix, so they always read as
  decimals in a failure message, and this renders them the same way.

  Boundary worth stating: a coverage or duplication value written as an integer in
  the manifest would render differently in the two languages, because JSON.parse
  erases the difference. The fixture only exercises decimal literals, which is
  what the real manifests carry.
*/
const gdec = (n) => (Number.isInteger(Number(n)) ? Number(n).toFixed(1) : String(n));

const str = (v) => (v === null || v === undefined ? 'null' : String(v));

/* ---------- SHA-256, so the watermark computes the same in a browser ------- */

const K = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

const rotr = (x, n) => ((x >>> n) | (x << (32 - n))) >>> 0;

function sha256Hex(message) {
  const bytes = new TextEncoder().encode(message);
  const bitLen = bytes.length * 8;
  const withOne = bytes.length + 1;
  const total = (withOne + 8 + 63) & ~63;
  const buf = new Uint8Array(total);
  buf.set(bytes);
  buf[bytes.length] = 0x80;
  const dv = new DataView(buf.buffer);
  dv.setUint32(total - 4, bitLen >>> 0, false);
  dv.setUint32(total - 8, Math.floor(bitLen / 0x100000000), false);

  let h = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  const w = new Uint32Array(64);

  for (let off = 0; off < total; off += 64) {
    for (let i = 0; i < 16; i++) w[i] = dv.getUint32(off + i * 4, false);
    for (let i = 16; i < 64; i++) {
      const s0 = (rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3)) >>> 0;
      const s1 = (rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10)) >>> 0;
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    let [a, b, c, d, e, f, g, hh] = h;
    for (let i = 0; i < 64; i++) {
      const S1 = (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) >>> 0;
      const ch = ((e & f) ^ (~e & g)) >>> 0;
      const t1 = (hh + S1 + ch + K[i] + w[i]) >>> 0;
      const S0 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) >>> 0;
      const maj = ((a & b) ^ (a & c) ^ (b & c)) >>> 0;
      const t2 = (S0 + maj) >>> 0;
      hh = g; g = f; f = e; e = (d + t1) >>> 0;
      d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    h = [(h[0] + a) >>> 0, (h[1] + b) >>> 0, (h[2] + c) >>> 0, (h[3] + d) >>> 0,
         (h[4] + e) >>> 0, (h[5] + f) >>> 0, (h[6] + g) >>> 0, (h[7] + hh) >>> 0];
  }
  return h.map((x) => x.toString(16).padStart(8, '0')).join('');
}

/* ---------- ReleaseRules ---------- */

export const ARTIFACTS = ['jar', 'image', 'apk', 'ipa', 'web'];

export const ENV_TARGET_BRANCH = { sit: 'rel/sit', uat: 'rel/uat', prod: 'release' };

const TAG_PATTERN = /^v\d+\.\d+\.\d+$/;
const FEATURE_BRANCH_PATTERN = /^(feat|fix|chore|hotfix)\/[a-z0-9][a-z0-9._-]{2,60}$/;

export function validateBranch(branch) {
  const problems = [];
  if (!truthy(branch)) {
    problems.push('branch: missing');
    return problems;
  }
  if (!FEATURE_BRANCH_PATTERN.test(branch)) {
    problems.push(`branch: '${branch}' is not <type>/<slug> with type in feat|fix|chore|hotfix`);
  }
  if (/[A-Z]/.test(branch)) {
    problems.push('branch: contains uppercase; the board renders these inconsistently');
  }
  return problems;
}

export function validateTag(tag) {
  if (!truthy(tag)) return ['releaseTag: missing, an untagged deploy is a guess about what shipped'];
  return TAG_PATTERN.test(tag) ? [] : [`releaseTag: '${tag}' is not vMAJOR.MINOR.PATCH`];
}

export function validatePromotion(from, to) {
  const known = Object.keys(ENV_TARGET_BRANCH);
  const problems = [];
  if (!known.includes(from)) problems.push(`promotion from: unknown environment '${from}'`);
  if (!known.includes(to)) problems.push(`promotion to: unknown environment '${to}'`);
  if (problems.length === 0 && known.indexOf(from) > known.indexOf(to)) {
    problems.push(`promotion: ${from} -> ${to} moves backwards; the ladder is sit -> uat -> prod`);
  }
  return problems;
}

export function validateService(svc) {
  const problems = [];
  if (!truthy(svc?.name)) problems.push('service.name: missing');
  if (!truthy(svc?.id)) problems.push(`service ${svc?.name}: id missing, the board links runs by id`);
  if (!ARTIFACTS.includes(svc?.artifact)) {
    problems.push(`service ${svc?.name}: artifact '${svc?.artifact}' not in ${ARTIFACTS.join('|')}`);
  }
  if (!truthy(svc?.owners)) problems.push(`service ${svc?.name}: no owner group; nobody would be paged`);
  if (svc?.artifact === 'image' && !truthy(svc?.registry)) {
    problems.push(`service ${svc?.name}: container artifact without a registry to push to`);
  }
  return problems;
}

export function validateManifest(manifest) {
  const problems = [...validateTag(manifest?.releaseTag)];
  const services = manifest?.services;
  if (!truthy(services)) return [...problems, 'manifest.services: empty, a release with nothing in it'];
  for (const svc of services) problems.push(...validateService(svc));

  const ids = services.map((s) => s.id).filter((v) => truthy(v));
  const groups = new Map();
  for (const id of ids) groups.set(id, (groups.get(id) || 0) + 1);
  for (const [id, seen] of groups) {
    if (seen > 1) {
      problems.push(`manifest: service id '${id}' appears ${seen} times; a later entry would overwrite the earlier one`);
    }
  }
  return problems;
}

const LAYERS = ['team', 'business', 'product', 'architecture', 'engineering'];

export function approvalChainProblems(approvals) {
  const problems = [];
  for (const layer of LAYERS) {
    if (!truthy(approvals?.[layer])) problems.push(`approval ${layer}: not granted`);
  }
  const signers = LAYERS.map((l) => approvals?.[l]).filter((v) => truthy(v));
  if (new Set(signers).size < signers.length) {
    problems.push('approval chain: the same identity signed consecutive layers');
  }
  return problems;
}

/* ---------- GateResult ---------- */

export const THRESHOLDS = {
  criticalVulnerabilities: 0,
  highVulnerabilities: 5,
  coverageFloor: 40.0,
  duplicationCeiling: 8.0,
};

export function severityCounts(findings) {
  const out = { critical: 0, high: 0, medium: 0, low: 0 };
  for (const f of findings || []) {
    const level = String(f?.severity || 'unknown').toLowerCase();
    if (Object.prototype.hasOwnProperty.call(out, level)) out[level] += 1;
  }
  return out;
}

function verdict(failures, warnings) {
  return {
    passed: failures.length === 0,
    failures,
    warnings,
    summary: failures.length === 0 ? 'gate passed' : 'gate failed: ' + failures.join('; '),
  };
}

export function evaluateGate(input) {
  const failures = [];
  const warnings = [];
  if (!truthy(input)) return verdict(['gate input: missing'], warnings);

  if (input.deploy?.result !== 'success') {
    failures.push(`deploy: ${truthy(input.deploy?.result) ? input.deploy.result : 'no result reported'}`);
  }

  const quality = input.quality;
  if (!truthy(quality)) {
    failures.push('quality gate: no status received, treated as failed');
  } else if (quality.status !== 'passed') {
    failures.push(`quality gate: ${quality.status}`);
  }
  if (truthy(quality)) {
    const coverage = quality.coverage;
    if (coverage === null || coverage === undefined) {
      failures.push('coverage: not measured, treated as below floor');
    } else if (Number(coverage) < THRESHOLDS.coverageFloor) {
      failures.push(`coverage: ${coverage}% below ${gdec(THRESHOLDS.coverageFloor)}% floor`);
    }
    if (quality.duplication !== null && quality.duplication !== undefined &&
        Number(quality.duplication) > THRESHOLDS.duplicationCeiling) {
      failures.push(`duplication: ${quality.duplication}% above ${gdec(THRESHOLDS.duplicationCeiling)}% ceiling`);
    }
  }

  const scan = input.scan;
  if (!truthy(scan)) {
    failures.push('vulnerability scan: no report, treated as unscanned');
  } else {
    if (truthy(scan.error)) failures.push(`vulnerability scan: ${scan.error}`);
    const counts = severityCounts(scan.findings);
    if (counts.critical > THRESHOLDS.criticalVulnerabilities) {
      failures.push(`vulnerabilities: ${counts.critical} critical (allowed ${THRESHOLDS.criticalVulnerabilities})`);
    }
    if (counts.high > THRESHOLDS.highVulnerabilities) {
      failures.push(`vulnerabilities: ${counts.high} high (allowed ${THRESHOLDS.highVulnerabilities})`);
    }
    if (counts.medium) warnings.push(`${counts.medium} medium findings accepted for this release`);
    if (!truthy(scan.sbom)) failures.push('sbom: not produced, a release nobody can inventory');
  }

  return verdict(failures, warnings);
}

/* ---------- DeploymentPlan ---------- */

export const TIER = { database: 0, backend: 1, gateway: 2, web: 3, mobile: 4 };

export function watermark(releaseTag, env, svc) {
  const raw = [releaseTag, env, svc.id, svc.artifact, truthy(svc.commit) ? svc.commit : 'HEAD'].join('|');
  return sha256Hex(raw).slice(0, 16);
}

export function inferTier(svc) {
  switch (svc.artifact) {
    case 'ipa':
    case 'apk': return 'mobile';
    case 'web': return 'web';
    case 'image':
    case 'jar': return 'backend';
    default: return 'gateway';
  }
}

export function tierOf(svc) {
  const declared = truthy(svc.tier) ? svc.tier : inferTier(svc);
  return Object.prototype.hasOwnProperty.call(TIER, declared) ? TIER[declared] : TIER.gateway;
}

export function buildPlan(manifest, env, previousRun = {}) {
  const services = (manifest.services || []).map((s) => ({ ...s, env }));
  services.sort((a, b) => {
    const byTier = tierOf(a) - tierOf(b);
    if (byTier !== 0) return byTier < 0 ? -1 : 1;
    const ai = str(a.id), bi = str(b.id);
    return ai < bi ? -1 : (ai > bi ? 1 : 0);
  });
  return services.map((svc) => {
    const key = watermark(manifest.releaseTag, env, svc);
    const done = previousRun[key] === 'success';
    return {
      id: svc.id,
      name: svc.name,
      artifact: svc.artifact,
      tier: tierOf(svc),
      watermark: key,
      skip: done,
      reason: done ? `already deployed ${env} for ${manifest.releaseTag}` : null,
    };
  });
}

export function planWaves(plan) {
  const groups = new Map();
  for (const entry of plan) {
    if (entry.skip) continue;
    if (!groups.has(entry.tier)) groups.set(entry.tier, []);
    groups.get(entry.tier).push(entry);
  }
  return [...groups.values()];
}

export const __sha256Hex = sha256Hex;

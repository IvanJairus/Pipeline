#!/usr/bin/env groovy
/*
  Gate entry point for the GitLab side.

  The pipeline calls this one file, and this file may only say yes or no based on
  the exact same rules the Jenkins side uses: ReleaseRules, GateResult and
  DeploymentPlan from shared-library/src. No threshold is retyped here. If a
  number cannot be traced to one of those three classes, it must not appear on
  this line.

  Usage:
    groovy -cp shared-library/src ci-library/scripts/run-gate.groovy \
      --manifest release.json --scan trivy-report.json \
      --quality sonar-gate.json --build build-info.json
    groovy -cp shared-library/src ci-library/scripts/run-gate.groovy --selftest

  Output:
    gate-verdict.json  the machine decision, read by the next job
    gate-summary.txt   one line pasted into the ticket
  Exit code: 0 if it passes, 1 if it refuses. The gate stage is meant to be red.

  The log line format follows ci-library/scripts/lib/log.sh: RFC3339 time with
  offset, LEVEL, scope, message, then key=value pairs. Two implementations, one
  shape, so that streams from shell and from Groovy read as a single log.
*/

import com.reference.release.ReleaseRules
import com.reference.release.GateResult
import com.reference.release.DeploymentPlan
import groovy.json.JsonSlurper
import groovy.json.JsonOutput
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter

// ── log ─────────────────────────────────────────────────────────────────────
// Deliberately without `def` here: script variables declared with def are local
// to run() and invisible to methods, so log() would reach for a scope that does
// not exist. The binding is visible to both.
scope = System.getenv('CI_JOB_NAME') ?: 'run-gate'
LOG_FORMAT = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSSxxx")

void log(String level, String message) {
    def stamp = ZonedDateTime.now().format(LOG_FORMAT)
    System.err.println("${stamp} ${level} ${scope} ${message}")
}

// ── arg ─────────────────────────────────────────────────────────────────────
Map parseArgs(String[] argv) {
    def out = [:]
    for (int i = 0; i < argv.length; i++) {
        switch (argv[i]) {
            case '--manifest': out.manifest = argv[++i]; break
            case '--scan':     out.scan = argv[++i]; break
            case '--quality':  out.quality = argv[++i]; break
            case '--build':    out.build = argv[++i]; break
            case '--promote':  def pair = argv[++i].split(':'); out.from = pair[0]; out.to = pair[1]; break
            case '--no-environment': out.noEnvironment = true; break
            case '--artifact-only':  out.artifactOnly = true; break
            case '--selftest':       out.selftest = true; break
            default: throw new IllegalArgumentException("unknown argument: ${argv[i]}")
        }
    }
    return out
}

Map readJson(String path, String label) {
    if (!path) return null
    def f = new File(path)
    if (!f.exists()) {
        // A missing file is NOT zero. The difference is exactly the reason this
        // class exists: a scanner that never finished would look like "no findings".
        log('WARN', "read ${label} missing path=${path} treated=absent")
        return null
    }
    return new JsonSlurper().parse(f) as Map
}

// One value, ready to sit after an equals sign: null prints as absent, and a
// space inside a value is escaped rather than left to break the record. Printed
// as 0, an unmeasured coverage turns into a story about a team that wrote no
// tests, when the real story is that no number was sent at all.
String kv(Object value) {
    return value == null ? 'absent' : String.valueOf(value).replace(' ', '\\ ')
}

/*
  Adaptor: trivy-report.json -> the shape GateResult reads.

  The gate class deliberately knows nothing about Trivy: it takes a list of
  findings. The translation lives here, and this is where the most expensive
  mistake in the pipeline can happen: a Results that is empty because the
  scanner died would produce an empty findings list, which reads as "clean".
  That is why `error` is carried along, and the sbom is checked as a separate
  fact, not inferred from the finding count.
*/
Map toGateScan(Map trivy, boolean sbomProduced) {
    if (!trivy) return null
    def findings = []
    (trivy.Results ?: []).each { r ->
        (r.Vulnerabilities ?: []).each { v ->
            findings << [severity: v.Severity, id: v.VulnerabilityID, pkg: v.PkgName]
        }
    }
    return [findings: findings, sbom: sbomProduced, error: trivy.Error]
}

/*
  Adaptor: sonar-gate.json -> the shape GateResult reads.

  `null as Double` in Groovy is 0.0. If that coercion were used here, an
  unmeasured coverage would become zero percent, and the gate would refuse with
  the wrong reason: "below floor", when in fact no number exists. The correct
  move is to leave it null so the gate class can say "not measured".
*/
Map toGateQuality(Map sonar) {
    if (!sonar) return null
    def value = { String metric ->
        def c = sonar.conditions?.find { it.metricKey == metric }
        return c?.actualValue == null ? null : (c.actualValue as Double)
    }
    def status = sonar.projectStatus?.status
    return [
        status     : status == 'OK' ? 'passed' : (status ?: 'no status received'),
        coverage   : value('coverage'),
        duplication: value('duplicated_lines_density'),
    ]
}

// ── run ─────────────────────────────────────────────────────────────────────
int run(Map opts) {
    log('INFO', "start manifest=${opts.manifest ?: 'none'} scan=${opts.scan ?: 'none'} quality=${opts.quality ?: 'none'}")

    def manifest = readJson(opts.manifest, 'manifest')
    def scan = readJson(opts.scan, 'scan')
    def quality = readJson(opts.quality, 'quality')
    def build = readJson(opts.build, 'build')

    // The SBOM is a separate fact from "no findings": it exists when the file
    // exists and is not empty, not when the scanner stays quiet.
    def sbomFile = new File('sbom.json')
    boolean sbomProduced = sbomFile.exists() && sbomFile.length() > 2

    // One line per input file, saying what was taken out of it. This is written
    // before the verdict, so a reader can compare the numbers with the answer
    // instead of having to trust the answer.
    if (manifest) {
        log('INFO', "read manifest file=${opts.manifest} releaseTag=${kv(manifest.releaseTag)} " +
                "services=${(manifest.services ?: []).size()} environments=${(manifest.environments ?: []).size()}")
    } else {
        log('INFO', "read manifest file=${opts.manifest ?: 'none'} releaseTag=absent services=absent")
    }
    def gateScan = toGateScan(scan, sbomProduced)
    if (gateScan) {
        def counts = GateResult.severityCounts(gateScan.findings)
        log('INFO', "read scan file=${opts.scan} findings=${gateScan.findings.size()} critical=${counts.critical} " +
                "high=${counts.high} medium=${counts.medium} low=${counts.low} sbom=${gateScan.sbom}" +
                "${gateScan.error ? ' error=' + kv(gateScan.error) : ''}")
    } else {
        log('INFO', "read scan file=${opts.scan ?: 'none'} findings=absent sbom=${sbomProduced}")
    }
    def gateQuality = toGateQuality(quality)
    if (gateQuality) {
        log('INFO', "read quality file=${opts.quality} status=${kv(gateQuality.status)} " +
                "coverage=${kv(gateQuality.coverage)} duplication=${kv(gateQuality.duplication)}")
    } else {
        log('INFO', "read quality file=${opts.quality ?: 'none'} status=absent coverage=absent duplication=absent")
    }
    if (build) {
        log('INFO', "read build file=${opts.build} version=${kv(build.version)} status=${kv(build.status)} " +
                "artifacts=${(build.artifacts ?: []).size()} commit=${kv(build.commit)}")
    } else {
        log('INFO', "read build file=${opts.build ?: 'none'} version=absent status=absent")
    }

    def problems = []
    if (manifest) {
        def mp = ReleaseRules.validateManifest(manifest)
        mp.each { problems << "manifest: ${it}" }
        log(mp ? 'ERROR' : 'INFO', "validateManifest problems=${mp.size()}")
    } else {
        problems << 'manifest: release.json was not read, nothing can be verified'
        log('ERROR', 'validateManifest skipped=missing-manifest')
    }

    if (opts.from && opts.to) {
        def pp = ReleaseRules.validatePromotion(opts.from, opts.to)
        pp.each { problems << "promotion: ${it}" }
        log(pp ? 'ERROR' : 'INFO', "validatePromotion ${opts.from}->${opts.to} problems=${pp.size()}")
    }

    def gate = GateResult.evaluate([
        deploy : [result: build?.status ?: 'no result reported'],
        quality: gateQuality,
        scan   : gateScan,
    ])
    log(gate.passed ? 'INFO' : 'ERROR', "GateResult.evaluate passed=${gate.passed} failures=${gate.failures.size()} warnings=${gate.warnings.size()}")

    def plan = []
    if (manifest && !opts.noEnvironment) {
        def envName = opts.to ?: (manifest.environments?.find()?.env ?: 'sit')
        plan = DeploymentPlan.build(manifest, envName)
        def waves = DeploymentPlan.waves(plan)
        log('INFO', "DeploymentPlan.build env=${envName} services=${plan.size()} waves=${waves.size()}")
        // A wave is a barrier: the names in it are the ones that start together,
        // and the tier is the number the plan was sorted by.
        waves.eachWithIndex { wave, n ->
            log('INFO', "wave number=${n + 1} tier=${wave[0].tier} size=${wave.size()} services=${kv(wave.collect { it.name }.join(','))}")
        }
    }

    def verdict = [
        passed  : (boolean) (gate.passed && problems.isEmpty()),
        summary : problems.isEmpty() ? gate.summary : gate.summary + '; ' + problems.join('; '),
        failures: gate.failures + problems,
        warnings: gate.warnings,
        // The `tier` here is already the tierOf() result from build(). Calling tierOf
        // again on this line is not just wasteful: tierOf is not idempotent, it sees
        // svc.tier which is now a number, does not find it in the TIER map, and
        // returns gateway. The replay transcript caught that.
        plan    : plan.collect { [id: it.id, name: it.name, tier: it.tier, action: it.skip ? 'skipped' : 'deploy', watermark: it.watermark] },
        checkedAt: ZonedDateTime.now().format(LOG_FORMAT),
    ]

    new File('gate-verdict.json').text = JsonOutput.prettyPrint(JsonOutput.toJson(verdict)) + '\n'
    new File('gate-summary.txt').text = verdict.summary + '\n'
    log(verdict.passed ? 'INFO' : 'ERROR', "verdict written passed=${verdict.passed} file=gate-verdict.json")
    println verdict.summary
    return verdict.passed ? 0 : 1
}

// ── selftest ────────────────────────────────────────────────────────────────
/*
  Runs with no runner, no network, no pipeline files. What it tests is the thing
  that breaks silently most easily: the log line shape, and the fact that missing
  input produces a refusal, not a pass.
*/
int selftest() {
    int fails = 0
    // The parameter is deliberately untyped: the result of `=~` is a Matcher, and
    // Groovy does not coerce it to boolean at the edge of a typed closure.
    def check = { String name, ok ->
        if (!ok) { System.err.println("run-gate selftest FAIL ${name}"); fails++ }
    }

    def line = captureStderr { log('INFO', 'hello key=value') }
    check('log line shape', line =~ /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2} INFO \S+ hello key=value$/)
    check('a wrong level is refused', GateResult.evaluate(null).failures.size() == 1)

    def empty = GateResult.evaluate([:])
    check('empty input refused', !empty.passed)

    def noScan = GateResult.evaluate([deploy: [result: 'success'], quality: [status: 'passed', coverage: 80, duplication: 2], scan: null])
    check('missing scan refused', !noScan.passed && noScan.failures.any { it.contains('no report') })

    def ok = GateResult.evaluate([
        deploy : [result: 'success'],
        quality: [status: 'passed', coverage: 81.4, duplication: 3.1],
        scan   : [findings: [[severity: 'HIGH'], [severity: 'LOW']], sbom: true],
    ])
    check('complete input passes', ok.passed)
    check('backward promotion refused', ReleaseRules.validatePromotion('prod', 'sit').size() > 0)

    // Adaptors: the two traps that make a pipeline green when the data is not there.
    def adapted = toGateScan([Results: [[Vulnerabilities: [[Severity: 'CRITICAL', VulnerabilityID: 'CVE-1', PkgName: 'jackson']]]]], true)
    check('trivy adapted', adapted.findings.size() == 1 && adapted.findings[0].severity == 'CRITICAL')
    check('a dead scanner does not mean clean', toGateScan([Results: [], Error: 'timeout'], true).error == 'timeout')

    def noCoverage = toGateQuality([projectStatus: [status: 'OK'], conditions: []])
    check('missing coverage stays missing', noCoverage.coverage == null)
    check('an unmeasured value prints as absent', kv(null) == 'absent' && kv(noCoverage.coverage) == 'absent' && kv(81.4d) == '81.4')
    check('a space inside a value is escaped', kv('no result reported') == 'no\\ result\\ reported')
    def gateNoCoverage = GateResult.evaluate([deploy: [result: 'success'], quality: noCoverage, scan: [findings: [], sbom: true]])
    check('refused because it is not measured', !gateNoCoverage.passed && gateNoCoverage.failures.any { it.contains('not measured') })
    // What must never appear is an invented number: "0.0% below floor" sounds like
    // a team failed to write tests, when the scanner stayed silent.
    check('no invented percentage', !gateNoCoverage.failures.any { it =~ /0(\.0)?%/ })

    System.err.println(fails == 0 ? 'run-gate selftest: ok' : "run-gate selftest: ${fails} failures")
    return fails == 0 ? 0 : 1
}

String captureStderr(Closure c) {
    def saved = System.err
    def buf = new ByteArrayOutputStream()
    System.setErr(new PrintStream(buf, true, 'UTF-8'))
    try { c.call() } finally { System.setErr(saved) }
    return buf.toString('UTF-8').trim()
}

// ── main ────────────────────────────────────────────────────────────────────
def opts = parseArgs(args)
System.exit(opts.selftest ? selftest() : run(opts))

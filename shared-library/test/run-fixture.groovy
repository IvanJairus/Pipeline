#!/usr/bin/env groovy
/*
  The golden file behind the pipeline animation on ivanjairus.xyz.

  This is the only place the expected answers are produced: it runs the real
  Groovy classes and writes what they returned. The JavaScript port under
  rules/ has to reproduce this file, and it is not allowed to author it. That
  direction matters. If both sides could write the fixture, agreement would
  prove nothing.

      groovy -cp src test/run-fixture.groovy          # compare
      groovy -cp src test/run-fixture.groovy --write  # regenerate
*/

import com.reference.release.ReleaseRules
import com.reference.release.DeploymentPlan
import com.reference.release.GateResult
import groovy.json.JsonOutput

boolean write = args.contains('--write')

def greenGate = [
    deploy : [result: 'success'],
    quality: [status: 'passed', coverage: 71.5, duplication: 3.1],
    scan   : [sbom: true, findings: [[severity: 'LOW'], [severity: 'medium']]],
]

def manifest = [
    releaseTag: 'v1.4.2',
    services  : [
        [id: 'web', name: 'portal', artifact: 'web', owners: ['digital']],
        [id: 'api', name: 'core-api', artifact: 'jar', owners: ['core'], commit: 'a1b2c3d'],
        [id: 'img', name: 'svc-image', artifact: 'image', registry: 'registry.example.internal', owners: ['core']],
    ],
]

def cases = [
    [id: 'branch-valid', fn: 'validateBranch', input: ['fix/471-timeout']],
    [id: 'branch-no-prefix', fn: 'validateBranch', input: ['feature-471']],
    [id: 'branch-uppercase', fn: 'validateBranch', input: ['fix/471-Timeout']],
    [id: 'branch-missing', fn: 'validateBranch', input: [null]],

    [id: 'tag-valid', fn: 'validateTag', input: ['v1.4.2']],
    [id: 'tag-floating', fn: 'validateTag', input: ['latest']],
    [id: 'tag-missing', fn: 'validateTag', input: [null]],

    [id: 'promote-forward', fn: 'validatePromotion', input: ['sit', 'prod']],
    [id: 'promote-backward', fn: 'validatePromotion', input: ['uat', 'sit']],
    [id: 'promote-unknown-env', fn: 'validatePromotion', input: ['sit', 'moon']],

    [id: 'service-image-no-registry', fn: 'validateService',
     input: [[id: 'a', name: 'api', artifact: 'image', owners: ['core']]]],
    [id: 'service-unknown-artifact', fn: 'validateService',
     input: [[id: 'a', name: 'api', artifact: 'war', owners: ['core']]]],
    [id: 'service-no-owner', fn: 'validateService',
     input: [[id: 'a', name: 'api', artifact: 'jar']]],

    [id: 'manifest-duplicate-id', fn: 'validateManifest', input: [[releaseTag: 'v1.0.0', services: [
        [id: 'a', name: 'one', artifact: 'jar', owners: ['x']],
        [id: 'a', name: 'two', artifact: 'jar', owners: ['x']],
    ]]]],
    [id: 'manifest-empty', fn: 'validateManifest', input: [[releaseTag: 'v1.0.0', services: []]]],

    [id: 'approvals-complete', fn: 'approvalChain',
     input: [[team: 'dev@x', business: 'biz@x', product: 'prod@x', architecture: 'arch@x', engineering: 'eng@x']]],
    [id: 'approvals-one-signer', fn: 'approvalChain',
     input: [[team: 'a', business: 'a', product: 'a', architecture: 'a', engineering: 'a']]],
    [id: 'approvals-none', fn: 'approvalChain', input: [[:]]],

    [id: 'gate-green', fn: 'evaluateGate', input: [greenGate]],
    [id: 'gate-no-scan', fn: 'evaluateGate', input: [[deploy: greenGate.deploy, quality: greenGate.quality]]],
    [id: 'gate-scanner-error', fn: 'evaluateGate', input: [greenGate + [scan: [sbom: true, error: 'trivy timeout', findings: []]]]],
    [id: 'gate-one-critical', fn: 'evaluateGate', input: [greenGate + [scan: [sbom: true, findings: [[severity: 'CRITICAL']]]]]],
    [id: 'gate-coverage-absent', fn: 'evaluateGate', input: [greenGate + [quality: [status: 'passed', duplication: 2.0]]]],
    [id: 'gate-duplication-high', fn: 'evaluateGate', input: [greenGate + [quality: [status: 'passed', coverage: 60.0, duplication: 9.4]]]],
    [id: 'gate-no-sbom', fn: 'evaluateGate', input: [greenGate + [scan: [sbom: false, findings: []]]]],
    [id: 'gate-null', fn: 'evaluateGate', input: [null]],

    [id: 'plan-sit', fn: 'buildPlan', input: [manifest, 'sit', [:]]],
    [id: 'plan-uat-waves', fn: 'planWaves', input: [manifest, 'uat']],
    [id: 'plan-skip-success', fn: 'buildPlan', input: [manifest, 'sit',
     [(DeploymentPlan.watermark('v1.4.2', 'sit', [id: 'api', artifact: 'jar', commit: 'a1b2c3d'])): 'success']]],
    [id: 'plan-retry-failed', fn: 'buildPlan', input: [manifest, 'sit',
     [(DeploymentPlan.watermark('v1.4.2', 'sit', [id: 'api', artifact: 'jar', commit: 'a1b2c3d'])): 'failed']]],
]

def invoke = { String fn, List input ->
    switch (fn) {
        case 'validateBranch': return ReleaseRules.validateBranch(input[0])
        case 'validateTag': return ReleaseRules.validateTag(input[0])
        case 'validatePromotion': return ReleaseRules.validatePromotion(input[0], input[1])
        case 'validateService': return ReleaseRules.validateService(input[0])
        case 'validateManifest': return ReleaseRules.validateManifest(input[0])
        case 'approvalChain': return ReleaseRules.approvalChainProblems(input[0])
        case 'evaluateGate': return GateResult.evaluate(input[0])
        case 'buildPlan': return DeploymentPlan.build(input[0], input[1], input[2])
        case 'planWaves': return DeploymentPlan.waves(DeploymentPlan.build(input[0], input[1])).collect { it.collect { m -> m.id } }
    }
    throw new IllegalArgumentException("unknown fn ${fn}")
}

def produced = cases.collect { c ->
    def out = invoke(c.fn, c.input)
    [id: c.id, fn: c.fn, input: c.input, expect: out]
}

def json = JsonOutput.prettyPrint(JsonOutput.toJson([
    generated: 'by test/run-fixture.groovy --write',
    note: 'Golden file for the pipeline view. The Groovy classes author it; the ' +
          'JavaScript port in rules/ only has to match it. Do not hand-edit.',
    cases: produced,
])) + '\n'

// Resolved by searching, not by assuming the working directory: the CI job runs
// this from the repository root and a developer runs it from shared-library/.
def target = ['rules/fixture.json', '../rules/fixture.json', '../../rules/fixture.json']
    .collect { new File(it).canonicalFile }
    .find { it.exists() } ?: new File('rules/fixture.json').canonicalFile

if (write) {
    target.parentFile.mkdirs()
    target.text = json
    println "wrote ${produced.size()} cases to ${target.name}"
    System.exit(0)
}

if (!target.exists()) {
    println "FAIL ${target} missing. Run: groovy -cp src test/run-fixture.groovy --write"
    System.exit(1)
}

int failed = 0
def expected = new groovy.json.JsonSlurper().parse(target).cases
expected.each { exp ->
    def actual = invoke(exp.fn as String, exp.input as List)
    def a = JsonOutput.toJson(actual)
    def b = JsonOutput.toJson(exp.expect)
    if (a != b) {
        failed++
        println "  FAIL ${exp.id}\n         fixture: ${b}\n         groovy:  ${a}"
    } else {
        println "  ok   ${exp.id}"
    }
}
println "\n${expected.size() - failed}/${expected.size()} cases agree with the Groovy classes"
System.exit(failed == 0 ? 0 : 1)

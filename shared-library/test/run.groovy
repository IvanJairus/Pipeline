#!/usr/bin/env groovy
/*
  Plain Groovy, no test framework: a shared library that needs Gradle to prove
  its own arithmetic is a library nobody runs. Execute with

      groovy -cp src test/run.groovy

  and it exits non-zero on the first failing assertion.
*/

import com.reference.release.ReleaseRules
import com.reference.release.DeploymentPlan
import com.reference.release.GateResult

int failed = 0
int passed = 0

def check = { String name, Closure body ->
    try {
        body()
        passed++
        println "  ok   ${name}"
    } catch (AssertionError | Exception e) {
        failed++
        println "  FAIL ${name}\n         ${e.message}"
    }
}

def assertEq = { actual, expected, String hint ->
    assert actual == expected : "${hint}\n         expected: ${expected}\n         actual:   ${actual}"
}

println 'ReleaseRules'

check('a branch without a type prefix is refused', {
    assertEq(ReleaseRules.validateBranch('feature-471').size(), 1, 'one problem expected')
    assertEq(ReleaseRules.validateBranch('fix/471-timeout'), [], 'valid branch rejected')
})

check('an uppercase branch is reported, not silently accepted', {
    assertEq(ReleaseRules.validateBranch('fix/471-Timeout').size(), 2, 'prefix and case both wrong')
})

check('a tag must look like a tag', {
    assertEq(ReleaseRules.validateTag(null).size(), 1, 'missing tag')
    assertEq(ReleaseRules.validateTag('latest').size(), 1, 'floating tag')
    assertEq(ReleaseRules.validateTag('v1.4.2'), [], 'valid tag rejected')
})

check('promotion cannot move backwards', {
    assertEq(ReleaseRules.validatePromotion('uat', 'sit').size(), 1, 'backwards allowed')
    assertEq(ReleaseRules.validatePromotion('sit', 'prod'), [], 'skipping forward blocked')
    assertEq(ReleaseRules.validatePromotion('sit', 'moon').size(), 1, 'unknown target accepted')
})

check('a container without a registry is a problem', {
    def svc = [id: 'a', name: 'api', artifact: 'image', owners: ['core']]
    assertEq(ReleaseRules.validateService(svc).size(), 1, 'registry missing')
    svc.registry = 'registry.example.internal'
    assertEq(ReleaseRules.validateService(svc), [], 'valid service rejected')
})

check('a duplicate service id is caught before it overwrites', {
    def manifest = [releaseTag: 'v1.0.0', services: [
        [id: 'a', name: 'one', artifact: 'jar', owners: ['x']],
        [id: 'a', name: 'two', artifact: 'jar', owners: ['x']],
    ]]
    def problems = ReleaseRules.validateManifest(manifest)
    // The id must be named. An earlier version reported the count instead, and
    // an assertion on the phrase alone let it through.
    assertEq(problems.findAll { it.contains('service id') },
        ["manifest: service id 'a' appears 2 times; a later entry would overwrite the earlier one"],
        'duplicate not named by id')
})

check('five layers signed by one identity is not a chain', {
    def one = [team: 'a', business: 'a', product: 'a', architecture: 'a', engineering: 'a']
    assertEq(ReleaseRules.approvalChainProblems(one).size(), 1, 'single signer accepted')
    def none = ReleaseRules.approvalChainProblems([:])
    assertEq(none.size(), 5, 'each missing layer should be named')
    def good = [team: 'dev@x', business: 'biz@x', product: 'prod@x', architecture: 'arch@x', engineering: 'eng@x']
    assertEq(ReleaseRules.approvalChainProblems(good), [], 'a real chain rejected')
})

println 'DeploymentPlan'

def manifest = [
    releaseTag: 'v1.4.2',
    services  : [
        [id: 'web', name: 'portal', artifact: 'web', owners: ['digital']],
        [id: 'api', name: 'core-api', artifact: 'jar', owners: ['core']],
        [id: 'img', name: 'svc-image', artifact: 'image', registry: 'registry.example.internal', owners: ['core']],
    ],
]

check('the plan runs backend before web', {
    def plan = DeploymentPlan.build(manifest, 'sit')
    assertEq(plan.collect { it.id }, ['api', 'img', 'web'], 'wrong order')
    assertEq(plan.collect { it.tier }.unique(), [1, 3], 'tiers not ascending')
})

check('a watermark is stable for the same inputs and moves with the commit', {
    def a = DeploymentPlan.watermark('v1.4.2', 'sit', [id: 'api', artifact: 'jar', commit: 'abc'])
    def b = DeploymentPlan.watermark('v1.4.2', 'sit', [id: 'api', artifact: 'jar', commit: 'abc'])
    def c = DeploymentPlan.watermark('v1.4.2', 'sit', [id: 'api', artifact: 'jar', commit: 'def'])
    assertEq(a, b, 'same inputs produced a different watermark')
    assert a != c : 'a new commit must produce a new watermark'
})

check('only a previous success skips a run', {
    def plan = DeploymentPlan.build(manifest, 'sit')
    def done = DeploymentPlan.build(manifest, 'sit', [(plan[0].watermark): 'success'])
    assertEq(done[0].skip, true, 'a deployed service should be skipped')
    assertEq(done[1].skip, false, 'an untouched service should still run')
    def failedBefore = DeploymentPlan.build(manifest, 'sit', [(plan[0].watermark): 'failed'])
    assertEq(failedBefore[0].skip, false, 'a failed run must be retried')
})

check('waves contain only what still has to run', {
    def plan = DeploymentPlan.build(manifest, 'uat')
    assertEq(DeploymentPlan.waves(plan).size(), 2, 'backend tier and web tier')
    def allDone = DeploymentPlan.build(manifest, 'uat', plan.collectEntries { [(it.watermark): 'success'] })
    assertEq(DeploymentPlan.waves(allDone).size(), 0, 'nothing left to run')
})

println 'GateResult'

def green = [
    deploy : [result: 'success'],
    quality: [status: 'passed', coverage: 71.5, duplication: 3.1],
    scan   : [sbom: true, findings: [[severity: 'LOW'], [severity: 'medium']]],
]

check('a clean release passes and still reports its warnings', {
    def r = GateResult.evaluate(green)
    assertEq(r.passed, true, r.summary)
    assertEq(r.warnings.size(), 1, 'medium findings should warn without failing')
})

check('a missing scan report fails the gate', {
    def r = GateResult.evaluate([deploy: green.deploy, quality: green.quality])
    assertEq(r.passed, false, 'no scan treated as pass')
    assert r.failures.any { it.contains('no report') } : r.failures.join('; ')
})

check('a scanner that errored fails the gate', {
    def input = green + [scan: [sbom: true, error: 'trivy timeout', findings: []]]
    assertEq(GateResult.evaluate(input).passed, false, 'scanner error treated as pass')
})

check('one critical vulnerability stops the release', {
    def input = green + [scan: [sbom: true, findings: [[severity: 'CRITICAL']]]]
    def r = GateResult.evaluate(input)
    assertEq(r.passed, false, 'critical accepted')
    assert r.summary.contains('1 critical') : r.summary
})

check('unmeasured coverage is not zero coverage, it is a failure', {
    def input = green + [quality: [status: 'passed', duplication: 2.0]]
    assertEq(GateResult.evaluate(input).passed, false, 'absent coverage passed the gate')
})

check('a missing deployment result cannot be a success', {
    def input = [quality: green.quality, scan: green.scan]
    assertEq(GateResult.evaluate(input).passed, false, 'no deploy result reported as pass')
})

check('a null input fails rather than crashing', {
    def r = GateResult.evaluate(null)
    assertEq(r.passed, false, 'null input passed')
    assertEq(r.failures, ['gate input: missing'], r.failures.join())
})

check('severity counting is case-insensitive and ignores unknown levels', {
    def counts = GateResult.severityCounts([[severity: 'Critical'], [severity: 'CRITICAL'], [severity: 'weird'], null])
    assertEq(counts.critical, 2, 'criticals miscounted')
    assertEq(counts.high, 0, 'phantom high')
})

println "\n${passed} passed, ${failed} failed"
System.exit(failed == 0 ? 0 : 1)

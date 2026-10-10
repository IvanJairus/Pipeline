package com.reference.release

/*
  The composite gate: one verdict made of a deployment result, a code-quality
  result and a vulnerability scan.

  The rule that makes this a gate and not a report is what happens when an input
  is missing. Absent evidence fails the release. A scanner that timed out, a
  quality status that never arrived or a null severity list all read as "pass" in
  a naive implementation, and the release that follows is the one where you find
  out.
*/
class GateResult {

    static final Map THRESHOLDS = [
        criticalVulnerabilities: 0,
        highVulnerabilities    : 5,
        coverageFloor          : 40.0d,
        duplicationCeiling     : 8.0d,
    ]

    static Map evaluate(Map input) {
        def failures = []
        def warnings = []

        if (!input) return verdict(['gate input: missing'], warnings)

        // Deployment first: nothing else is meaningful if the artifact did not land.
        if (input.deploy?.result != 'success') {
            failures << "deploy: ${input.deploy?.result ?: 'no result reported'}"
        }

        def quality = input.quality
        if (!quality) {
            failures << 'quality gate: no status received, treated as failed'
        } else if (quality.status != 'passed') {
            failures << "quality gate: ${quality.status}"
        }
        if (quality) {
            def coverage = quality.coverage
            if (coverage == null) {
                failures << 'coverage: not measured, treated as below floor'
            } else if ((coverage as double) < THRESHOLDS.coverageFloor) {
                failures << "coverage: ${coverage}% below ${THRESHOLDS.coverageFloor}% floor"
            }
            if (quality.duplication != null && (quality.duplication as double) > THRESHOLDS.duplicationCeiling) {
                failures << "duplication: ${quality.duplication}% above ${THRESHOLDS.duplicationCeiling}% ceiling"
            }
        }

        def scan = input.scan
        if (!scan) {
            failures << 'vulnerability scan: no report, treated as unscanned'
        } else {
            if (scan.error) failures << "vulnerability scan: ${scan.error}"
            def counts = severityCounts(scan.findings)
            if (counts.critical > THRESHOLDS.criticalVulnerabilities) {
                failures << "vulnerabilities: ${counts.critical} critical (allowed ${THRESHOLDS.criticalVulnerabilities})"
            }
            if (counts.high > THRESHOLDS.highVulnerabilities) {
                failures << "vulnerabilities: ${counts.high} high (allowed ${THRESHOLDS.highVulnerabilities})"
            }
            if (counts.medium) warnings << "${counts.medium} medium findings accepted for this release"
            if (!scan.sbom) failures << 'sbom: not produced, a release nobody can inventory'
        }

        return verdict(failures, warnings)
    }

    static Map severityCounts(List findings) {
        def out = [critical: 0, high: 0, medium: 0, low: 0]
        (findings ?: []).each { f ->
            def level = String.valueOf(f?.severity ?: 'unknown').toLowerCase()
            if (out.containsKey(level)) out[level] = out[level] + 1
        }
        return out
    }

    private static Map verdict(List failures, List warnings) {
        return [
            passed  : failures.isEmpty(),
            failures: failures,
            warnings: warnings,
            // The line a human reads on the ticket; it must say why, not just no.
            summary : failures.isEmpty() ? 'gate passed' : 'gate failed: ' + failures.join('; '),
        ]
    }
}

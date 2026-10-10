import com.reference.release.GateResult

/*
  One verdict from three sources: did it deploy, is the code acceptable, is the
  image clean. Missing input is a failure. See GateResult for why that is the
  whole point of a gate.
*/
def call(Map args) {
    def verdict = GateResult.evaluate([deploy: args.deploy, quality: args.quality, scan: args.scan])

    // The report is written before the build is failed, because the engineer who
    // reads it tomorrow needs the reason, not the red mark.
    commentOnTicket(args.issue, verdict.passed
        ? "Quality gate: passed. ${verdict.warnings.join('; ')}"
        : "Quality gate: FAILED\n" + verdict.failures.collect { "* ${it}" }.join('\n'))

    if (!verdict.passed) {
        withNoColor { echo verdict.summary }
        error(verdict.summary)
    }
    return verdict
}

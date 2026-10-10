import com.reference.release.ReleaseRules

/*
  Gate one: the ticket must describe a release before anything runs. Every
  problem is reported at once, because a build that stops at the first one
  teaches an engineer to fix one field and re-run the whole pipeline.
*/
def call(Map args) {
    def manifest = args.manifest
    def problems = ReleaseRules.validateManifest(manifest)
    problems.addAll(ReleaseRules.validateBranch(args.branch))
    if (args.promotion) {
        problems.addAll(ReleaseRules.validatePromotion(args.from as String, args.to as String))
    }

    if (problems) {
        def body = 'Release standard not met:\n' + problems.collect { "* ${it}" }.join('\n')
        commentOnTicket(args.issue, body)
        error(body)   // fail closed: an unparseable release never reaches a runner
    }
    echo "release standard met: ${manifest.services.size()} service(s) for ${manifest.releaseTag}"
    return manifest
}

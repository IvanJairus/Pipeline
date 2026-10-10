import com.reference.release.ReleaseRules

/*
  The five-layer chain, checked where the merge happens rather than where the
  approval was recorded. The two can be minutes apart and a ticket can be
  edited in between.
*/
def call(Map args) {
    def approvals = args.approvals ?: [:]
    def problems = ReleaseRules.approvalChainProblems(approvals)

    // Segregation of duties: whoever signed the last layer may not merge.
    if (approvals.engineering && approvals.engineering == args.merger) {
        problems << "merge: ${args.merger} signed the final approval and cannot merge their own sign-off"
    }
    if (problems) {
        commentOnTicket(args.issue, 'Merge refused:\n' + problems.collect { "* ${it}" }.join('\n'))
        error("merge refused: ${problems.size()} problem(s)")
    }

    echo "merge approved by chain: ${approvals.engineering} merging as ${args.merger}"
    mergeRequest(args.mergeRequest, args.merger)
}

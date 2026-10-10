package com.reference.release

/*
  The codified standard, as data. Kept free of Jenkins types on purpose: this is
  the part that can be unit-tested without a controller, and the part a reviewer
  can read to see what "52 rules" actually checks.

  Every rule here returns a list of problems instead of throwing, because a
  pipeline that stops at the first violation teaches an engineer to fix one
  thing at a time and re-run the whole build.
*/
class ReleaseRules {

    static final List<String> ARTIFACTS = ['jar', 'image', 'apk', 'ipa', 'web']

    static final Map<String, String> ENV_TARGET_BRANCH = [
        sit : 'rel/sit',
        uat : 'rel/uat',
        prod: 'release'
    ]

    // A release branch is cut from the tag, not from whatever HEAD happens to be.
    static final String TAG_PATTERN = '^v\\d+\\.\\d+\\.\\d+$'
    static final String FEATURE_BRANCH_PATTERN = '^(feat|fix|chore|hotfix)/[a-z0-9][a-z0-9._-]{2,60}$'

    static List<String> validateBranch(String branch) {
        def problems = []
        if (!branch) {
            problems << 'branch: missing'
            return problems
        }
        if (!(branch ==~ FEATURE_BRANCH_PATTERN)) {
            problems << "branch: '${branch}' is not <type>/<slug> with type in feat|fix|chore|hotfix"
        }
        if (branch ==~ /.*[A-Z].*/) {
            problems << 'branch: contains uppercase; the board renders these inconsistently'
        }
        return problems
    }

    static List<String> validateTag(String tag) {
        if (!tag) return ['releaseTag: missing, an untagged deploy is a guess about what shipped']
        return (tag ==~ TAG_PATTERN) ? [] : ["releaseTag: '${tag}' is not vMAJOR.MINOR.PATCH"]
    }

    /*
      A promotion target must be a branch the ladder knows about. Anything else
      is a typo that would otherwise merge into a long-lived branch nobody
      reviews.
    */
    static List<String> validatePromotion(String from, String to) {
        def known = ENV_TARGET_BRANCH.keySet() as List
        def problems = []
        if (!known.contains(from)) problems << "promotion from: unknown environment '${from}'"
        if (!known.contains(to)) problems << "promotion to: unknown environment '${to}'"
        // Only compare positions of environments that actually exist; an unknown
        // name sits at index -1 and would read as "backwards".
        if (!problems && known.indexOf(from) > known.indexOf(to)) {
            problems << "promotion: ${from} -> ${to} moves backwards; the ladder is sit -> uat -> prod"
        }
        return problems
    }

    /*
      One service entry in a release manifest. `artifact` decides which stage
      runs, so an unknown value is refused rather than skipped.
    */
    static List<String> validateService(Map svc) {
        def problems = []
        if (!svc?.name) problems << 'service.name: missing'
        if (!svc?.id) problems << "service ${svc?.name}: id missing, the board links runs by id"
        if (!ARTIFACTS.contains(svc?.artifact)) {
            problems << "service ${svc?.name}: artifact '${svc?.artifact}' not in ${ARTIFACTS.join('|')}"
        }
        if (!svc?.owners) problems << "service ${svc?.name}: no owner group; nobody would be paged"
        if (svc?.artifact == 'image' && !svc?.registry) {
            problems << "service ${svc?.name}: container artifact without a registry to push to"
        }
        return problems
    }

    static List<String> validateManifest(Map manifest) {
        def problems = []
        problems.addAll(validateTag(manifest?.releaseTag))
        def services = manifest?.services
        if (!services) return problems + ['manifest.services: empty, a release with nothing in it']
        services.each { problems.addAll(validateService(it)) }

        def ids = services.collect { it.id }.findAll { it }
        // groupBy, not count: List.count { } returns an Integer, and Integer.each
        // runs once with that count as its argument, so the message below used to
        // name the number of duplicates instead of the service id. The golden
        // fixture caught it; the old assertion did not, because it only looked
        // for the phrase.
        ids.groupBy { it }.each { id, seen ->
            if (seen.size() > 1) {
                problems << "manifest: service id '${id}' appears ${seen.size()} times; a later entry would overwrite the earlier one"
            }
        }
        return problems
    }

    /*
      The five layers, in order. The chain is complete only when each layer was
      signed by a distinct identity from the layer before it. A single account
      signing all five is a formality, and this is where that gets caught.
    */
    static List<String> approvalChainProblems(Map approvals) {
        def layers = ['team', 'business', 'product', 'architecture', 'engineering']
        def problems = []
        layers.each { layer ->
            if (!approvals?.get(layer)) problems << "approval ${layer}: not granted"
        }
        def signers = layers.collect { approvals?.get(it) }.findAll { it }
        // toUnique, not unique: Groovy's unique() mutates the receiver, which made
        // the comparison below read the de-duplicated list against itself.
        if (signers.toUnique().size() < signers.size()) {
            problems << 'approval chain: the same identity signed consecutive layers'
        }
        return problems
    }
}

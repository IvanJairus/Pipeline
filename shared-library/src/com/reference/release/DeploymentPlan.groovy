package com.reference.release

import java.security.MessageDigest

/*
  Turns a validated manifest into the list of runs a release actually needs.

  Two properties matter more than the ordering: a service that already ran for
  this tag must not run twice, and the identity of a run must be computable from
  the inputs alone. Both come from the watermark, which is why it is derived here
  rather than passed in by whoever called the stage.
*/
class DeploymentPlan {

    // Services deploy in dependency order; a tier depends only on lower tiers.
    static final Map<String, Integer> TIER = [database: 0, backend: 1, gateway: 2, web: 3, mobile: 4]

    static String watermark(String releaseTag, String env, Map svc) {
        def raw = [releaseTag, env, svc.id, svc.artifact, svc.commit ?: 'HEAD'].join('|')
        return MessageDigest.getInstance('SHA-256').digest(raw.bytes).encodeHex().toString().take(16)
    }

    static int tierOf(Map svc) {
        def declared = svc.tier ?: inferTier(svc)
        TIER.containsKey(declared) ? TIER[declared] : TIER.gateway
    }

    static String inferTier(Map svc) {
        switch (svc.artifact) {
            case 'ipa':
            case 'apk': return 'mobile'
            case 'web': return 'web'
            case 'image':
            case 'jar': return 'backend'
            default: return 'gateway'
        }
    }

    /*
      previousRun maps watermark -> 'success' | 'failed'. Only a success skips;
      a failed run is retried, because the usual cause is the infrastructure and
      not the artifact.
    */
    static List<Map> build(Map manifest, String env, Map previousRun = [:]) {
        def services = (manifest.services ?: []).collect { it + [env: env] }

        services.sort { a, b ->
            def byTier = tierOf(a) <=> tierOf(b)
            byTier != 0 ? byTier : String.valueOf(a.id) <=> String.valueOf(b.id)
        }

        return services.collect { svc ->
            def key = watermark(manifest.releaseTag, env, svc)
            [
                id       : svc.id,
                name     : svc.name,
                artifact : svc.artifact,
                tier     : tierOf(svc),
                watermark: key,
                skip     : previousRun[key] == 'success',
                reason   : previousRun[key] == 'success' ? "already deployed ${env} for ${manifest.releaseTag}" : null,
            ]
        }
    }

    // Tiers are barriers: nothing in tier n starts until every tier < n settled.
    static List<List<Map>> waves(List<Map> plan) {
        return plan.findAll { !it.skip }.groupBy { it.tier }.values().toList()
    }
}

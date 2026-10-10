import com.reference.release.DeploymentPlan

/*
  Expands a manifest into waves and triggers one child pipeline per service.
  The skip decision lives in DeploymentPlan, not here, so the same rule can be
  unit-tested without a controller.
*/
def call(Map args) {
    def env = args.env
    def previous = args.previousRun ?: [:]
    def plan = DeploymentPlan.build(args.manifest, env, previous)

    plan.findAll { it.skip }.each {
        // Skipped runs are announced, not silent: a board that quietly drops a
        // service is a board people stop trusting.
        echo "skip ${it.name}: ${it.reason}"
        commentOnTicket(args.issue, "*${it.name}* already on *${env}* for ${args.manifest.releaseTag}, skipped")
    }

    def waves = DeploymentPlan.waves(plan)
    echo "plan: ${plan.size()} service(s) in ${waves.size()} wave(s)"

    waves.eachWithIndex { wave, index ->
        def runs = wave.collect { svc ->
            timestamped("deploy ${svc.id} (${svc.artifact})") {
                triggerServicePipeline(svc, env, svc.watermark)
            }
        }
        // A wave that partially failed must stop the next one; the release is
        // the unit of correctness, not the individual job.
        def failed = runs.findAll { it.result != 'success' }
        if (failed) {
            error("wave ${index + 1} failed: ${failed.collect { it.id }.join(', ')}")
        }
    }
    return plan
}

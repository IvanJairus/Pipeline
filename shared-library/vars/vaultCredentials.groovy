/*
  Short-lived credentials from Vault, bound to the job's own identity. Two rules
  that are easy to break by accident:

  - the token is never echoed and never interpolated into a shell string the
    runner logs;
  - the lease is revoked in the same scope that opened it, so a stage that fails
    halfway cannot leave a live credential behind.
*/
def call(Map args, Closure body) {
    def role = args.role
    def mount = args.mount ?: 'jwt'
    if (!role) error('vaultCredentials: role is required')

    withEnv(["VAULT_ADDR=${args.address}"]) {
        // The JWT is the runner's own service-account token; nothing secret is
        // stored in Jenkins for it to read.
        def jwt = vaultJwtForCurrentJob()
        def lease = sh(
            script: "printf %s ${jwt} | vault write -field=token -no-table ${mount}/issue/${role} ttl=${args.ttl ?: '10m'} -",
            returnStdout: true
        ).trim()
        try {
            // The lease travels as an environment variable, never as a command
            // argument: arguments end up in the step log and in `ps` output.
            withEnv(["VAULT_TOKEN=${lease}"]) { body(lease) }
        } finally {
            sh(script: 'vault token revoke -self', label: 'revoke vault lease')
        }
    }
}

#!/bin/bash
# Reusable script to configure Vault JWT Auth for GitLab
#
# Prerequisites:
# 1. Vault CLI must already be installed.
# 2. You must already be logged in to Vault (or set VAULT_ADDR and VAULT_TOKEN in the environment).
# Usage:
# 1. Edit this script if needed to adjust GITLAB_URL or NAMESPACE_ID.
# 2. Run the script with no arguments:
#    ./setup-vault-jwt.sh

set -e

# 1. Variables and Validation
# Hardcode your configuration here:
GITLAB_URL="https://git.example.internal"

# Leave it empty ("") to allow every GitLab project into Vault.
# Fill it with a single ID (e.g. "845") or several comma-separated IDs ("845,846")
# to restrict access to specific groups only.
NAMESPACE_ID="8521,8953,17161"

# Strip 'https://' or 'http://' to get the hostname
GITLAB_HOST=$(echo "$GITLAB_URL" | sed -e 's|^[^/]*//||' -e 's|/.*$||')

echo "========================================================="
echo "Starting the Vault JWT Auth configuration"
echo "Vault Address : ${VAULT_ADDR:-Local credentials / Not set}"
echo "GitLab URL    : $GITLAB_URL"
echo "GitLab Host   : $GITLAB_HOST"
if [ -n "$NAMESPACE_ID" ]; then
    echo "Namespace ID  : $NAMESPACE_ID (access restricted to these groups only)"
else
    echo "Namespace ID  : NOT SET (every project in GitLab is allowed access)"
fi
echo "========================================================="

# Make sure Vault responds
if ! vault status > /dev/null 2>&1; then
    echo "❌ ERROR: Cannot reach Vault. Check that VAULT_ADDR is correct and that you are logged in."
    exit 1
fi

# 2. Enable the JWT Auth Method
echo "[1/4] Enabling the JWT authentication method (skipped when it is already enabled)..."
vault auth enable jwt 2>/dev/null || echo "The JWT method is already enabled."

# 3. Connect Vault to GitLab OIDC Discovery
echo "[2/4] Connecting Vault to the GitLab JWKS (OIDC)..."
vault write auth/jwt/config \
    oidc_discovery_url="${GITLAB_URL}" \
    bound_issuer="${GITLAB_URL}"

# 4. Create the Universal Policy
echo "[3/4] Writing the universal policy for GitLab pipelines..."
cat <<EOF > /tmp/gitlab-pipeline-policy.hcl
# Allow read access to every secret under the 'pipeline/' path
path "secret/data/pipeline/*" {
  capabilities = ["read"]
}
EOF

vault policy write gitlab-pipeline-policy /tmp/gitlab-pipeline-policy.hcl
rm -f /tmp/gitlab-pipeline-policy.hcl

# 5. Create the Vault Role
echo "[4/4] Writing the Vault role (gitlab-role) for GitLab JWT..."

# Decide bound_claims from whether NAMESPACE_ID is set or not
if [ -n "$NAMESPACE_ID" ]; then
    # Split the comma-separated IDs into a valid JSON array using jq
    # Example output: {"namespace_id": ["845", "846"]}
    BOUND_CLAIMS=$(jq -n --arg ids "$NAMESPACE_ID" '{namespace_id: ($ids | split(",") | map(gsub(" "; "")))}')
else
    BOUND_CLAIMS="{\"project_id\": \"*\"}"
fi

vault write auth/jwt/role/gitlab-role \
    role_type="jwt" \
    policies="gitlab-pipeline-policy" \
    token_explicit_max_ttl=300 \
    user_claim="user_login" \
    claim_mappings="project_id=project_id, project_path=project_path, namespace_id=namespace_id" \
    bound_claims_type="glob" \
    bound_claims="${BOUND_CLAIMS}"

echo "✅ Vault JWT configuration complete."
echo "You can now use \$VAULT_ID_TOKEN from GitLab to log in to Vault in this environment."

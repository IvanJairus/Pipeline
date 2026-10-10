#!/bin/bash
# Skrip reusable untuk mengonfigurasi Vault JWT Auth bagi GitLab
#
# Prasyarat:
# 1. Vault CLI harus sudah terinstall.
# 2. Anda harus sudah login ke Vault (atau mengatur VAULT_ADDR dan VAULT_TOKEN di environment).
# Penggunaan:
# 1. Edit script ini jika perlu untuk menyesuaikan GITLAB_URL atau NAMESPACE_ID.
# 2. Jalankan script tanpa argumen:
#    ./setup-vault-jwt.sh

set -e

# --- 1. Variabel dan Validasi ---
# Hardcode konfigurasi Anda di sini:
GITLAB_URL="https://git.example.internal"

# Kosongkan ("") jika ingin mengizinkan semua project GitLab masuk ke Vault.
# Isi dengan ID tunggal (misal "845") atau beberapa ID dipisahkan koma ("845,846")
# jika ingin membatasi akses khusus untuk grup-grup tertentu.
NAMESPACE_ID="8521,8953,17161"

# Menghapus 'https://' atau 'http://' untuk mendapatkan hostname
GITLAB_HOST=$(echo "$GITLAB_URL" | sed -e 's|^[^/]*//||' -e 's|/.*$||')

echo "========================================================="
echo "Memulai Konfigurasi Vault JWT Auth"
echo "Vault Address : ${VAULT_ADDR:-Kredensial lokal / Belum diset}"
echo "GitLab URL    : $GITLAB_URL"
echo "GitLab Host   : $GITLAB_HOST"
if [ -n "$NAMESPACE_ID" ]; then
    echo "Namespace ID  : $NAMESPACE_ID (Akses dibatasi hanya untuk grup ini)"
else
    echo "Namespace ID  : TIDAK DISET (Semua proyek di GitLab diizinkan akses)"
fi
echo "========================================================="

# Memastikan Vault merespons
if ! vault status > /dev/null 2>&1; then
    echo "❌ ERROR: Tidak dapat terhubung ke Vault. Pastikan VAULT_ADDR sudah benar dan Anda sudah login."
    exit 1
fi

# --- 2. Mengaktifkan JWT Auth Method ---
echo "[1/4] Mengaktifkan metode otentikasi JWT (mengabaikan jika sudah aktif)..."
vault auth enable jwt 2>/dev/null || echo "Metode JWT sudah aktif."

# --- 3. Menghubungkan Vault dengan GitLab OIDC Discovery ---
echo "[2/4] Menghubungkan Vault dengan GitLab JWKS (OIDC)..."
vault write auth/jwt/config \
    oidc_discovery_url="${GITLAB_URL}" \
    bound_issuer="${GITLAB_URL}"

# --- 4. Membuat Universal Policy ---
echo "[3/4] Membuat Universal Policy untuk GitLab Pipelines..."
cat <<EOF > /tmp/gitlab-pipeline-policy.hcl
# Mengizinkan akses baca (read) ke seluruh secret yang ada di bawah path 'pipeline/'
path "secret/data/pipeline/*" {
  capabilities = ["read"]
}
EOF

vault policy write gitlab-pipeline-policy /tmp/gitlab-pipeline-policy.hcl
rm -f /tmp/gitlab-pipeline-policy.hcl

# --- 5. Membuat Vault Role ---
echo "[4/4] Membuat Vault Role (gitlab-role) untuk GitLab JWT..."

# Menentukan bound_claims berdasarkan ada atau tidaknya NAMESPACE_ID
if [ -n "$NAMESPACE_ID" ]; then
    # Memisahkan ID dengan koma menjadi array JSON yang valid menggunakan jq
    # Contoh output: {"namespace_id": ["845", "846"]}
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

echo "✅ Konfigurasi Vault JWT Selesai dan Berhasil!"
echo "Sekarang Anda dapat menggunakan \$VAULT_ID_TOKEN dari GitLab untuk login ke Vault di environment ini."

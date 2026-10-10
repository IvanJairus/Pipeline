pipeline {
    agent { 
        label "linux-node-01" 
    }

    environment {
        JIRA_TOKEN = '${VAULT_JIRA_TOKEN}'
        JIRA_URL = "https://tracker.example.internal"
    }

    stages {
        stage('Trigger Jobs') {
            steps {
                script {
                    println('=== === === === ' + STAGE_NAME + ' === === === ===')
                    def jsonObject = readJSON(text: DATA) // DATA berasal dari Post content parameters di JENKINS
                    // echo "${DATA}"

                    // Ambil dan konversi ke lowercase
                    def issueKey = jsonObject.issue?.key
                    def fromStatus = jsonObject?.changelog?.items?.getAt(0)?.fromString?.toLowerCase()
                    def toStatus = jsonObject?.changelog?.items?.getAt(0)?.toString?.toLowerCase()
                    def summary = jsonObject?.issue?.fields?.summary?.toLowerCase()
                    def stage = jsonObject?.issue?.fields?.customfield_10744?.value?.toUpperCase()

                    // Set ke env supaya bisa diakses di stage lain
                    env.ISSUE_KEY = issueKey
                    env.FROM_STATUS = fromStatus
                    env.TO_STATUS = toStatus
                    env.ISSUE_SUMMARY = summary
                    env.STAGE = stage
                    env.BRANCH = ''

                    // Cetak untuk verifikasi
                    echo "ISSUE_KEY: ${ISSUE_KEY}"
                    echo "ISSUE_SUMMARY: ${ISSUE_SUMMARY}"
                    echo "FROM_STATUS: ${FROM_STATUS}"
                    echo "TO_STATUS: ${TO_STATUS}"
                    echo "STAGE: ${STAGE}"
                    
                    triggerJobs()
                }
            }
        }
    }
}

// =============================================================================
// === FUNGSI-FUNGSI BANTUAN (HELPER FUNCTIONS) ================================
// =============================================================================


def triggerJobs() {
    def jobKey = "${FROM_STATUS}:${TO_STATUS}".trim().toLowerCase()
    
    // Mapping job berdasarkan perpindahan tiket dan parameternya masing-masing
    def jobMapping = [
        "backlog:backend": [
            jobName: "Backend",
            params: [
                string(name: 'ISSUE_KEY', value: "${ISSUE_KEY}")
            ]
        ],
        "backend:android": [
            jobName: "Android",
            params: [
                string(name: 'ISSUE_KEY', value: "${ISSUE_KEY}")
            ]
        ],
        "android:ios": [
            jobName: "iOS",
            params: [
                string(name: 'ISSUE_KEY', value: "${ISSUE_KEY}")
            ]
        ],
        "ios:pre-sast": [
            jobName: "PreSAST",
            params: [
                string(name: 'ISSUE_KEY', value: "${ISSUE_KEY}")
            ]
        ],
        "backlog:create_branch": [
            jobName: "${env.STAGE}CreateBranch",
            params: [
                string(name: 'ISSUE_KEY', value: "${ISSUE_KEY}")
            ]
        ],
        "waiting:merging": [
            jobName: "${env.STAGE}MergeRequest",
            params: [
                string(name: 'ISSUE_KEY', value: "${ISSUE_KEY}")
            ]
        ],
        "backlog:merging": [
            jobName: "${env.STAGE}MergeRequest",
            params: [
                string(name: 'ISSUE_KEY', value: "${ISSUE_KEY}")
            ]
        ],
        "merging:create_issue": [
            jobName: "${env.STAGE}CreateIssue",
            params: [
                string(name: 'ISSUE_KEY', value: "${ISSUE_KEY}")
            ]
        ],
        "backlog:create_issue": [
            jobName: "${env.STAGE}CreateIssue",
            params: [
                string(name: 'ISSUE_KEY', value: "${ISSUE_KEY}")
            ]
        ],
    ]

    echo "Daftar jobMapping keys: ${jobMapping.keySet()}"

    // Mengecek apakah perpindahan tiket memiliki job terkait
    if (jobMapping.containsKey(jobKey)) {
        def jobInfo = jobMapping[jobKey]
        echo "Menjalankan job: ${jobInfo.jobName} dengan parameter: ${jobInfo.params}"
        build wait: false, job: jobInfo.jobName, parameters: jobInfo.params
    } else {
        echo "Tidak ada job yang sesuai untuk perpindahan ${jobKey}, job tidak dijalankan."
    }
}

/**
 * Mencari lampiran di sebuah tiket Jira berdasarkan pola nama file,
 * dan mengembalikan URL konten dari lampiran yang paling baru jika ada lebih dari satu.
 *
 * @param issueKey Key dari tiket Jira.
 * @param fileNamePattern Pola nama file yang dicari (misal: "_manifest.yaml").
 * @param jiraToken Token untuk autentikasi API.
 * @return String berisi URL konten file, atau null jika tidak ditemukan.
 */
def getJiraAttachmentUrl(String issueKey, String fileNamePattern, String jiraToken) {
    echo "Searching for the latest attachment matching '*${fileNamePattern}' in ticket ${issueKey}..."
    try {
        // Minta field 'attachment' untuk mendapatkan daftar lampiran
        def response = sh(
            script: """
                curl -k --silent --show-error -X GET --location "${env.JIRA_URL}/rest/api/2/issue/${issueKey}?fields=attachment" \\
                     --header "Authorization: ${jiraToken}"
            """,
            returnStdout: true
        ).trim()

        def issueData = readJSON(text: response)
        
        if (issueData.fields.attachment) {
            // 1. Filter semua lampiran yang namanya cocok dengan pola
            def matchingAttachments = issueData.fields.attachment.findAll { 
                it.filename.endsWith(fileNamePattern) 
            }
            
            if (!matchingAttachments.isEmpty()) {
                // 2. Sortir lampiran yang cocok berdasarkan tanggal 'created' secara menurun (dari baru ke lama)
                // Tanggal dalam format ISO 8601 bisa disortir sebagai string
                def sortedAttachments = matchingAttachments.sort { a, b -> b.created <=> a.created }
                
                // 3. Ambil lampiran pertama dari daftar yang sudah disortir (ini yang paling baru)
                def latestAttachment = sortedAttachments[0]
                def contentUrl = latestAttachment.content
                
                echo "Found latest attachment: ${latestAttachment.filename} (Created on: ${latestAttachment.created})"
                echo "Attachment URL: ${contentUrl}"
                return contentUrl
            }
        }
        
        echo "Warning: No attachment found matching pattern in ticket ${issueKey}."
        return null

    } catch (e) {
        echo "Error fetching attachments: ${e.message}"
        return null
    }
}

/**
 * Memfilter daftar label dan mengembalikan hanya label yang cocok dengan pola rilis (misal: R1.x).
 *
 * @param allLabels Sebuah List berisi semua label dari tiket.
 * @return List baru yang hanya berisi label rilis.
 */
def getReleaseLabels(List allLabels) {
    // Pola yang kita cari adalah string yang diawali dengan "R1."
    def releasePattern = /^R1\.\d+$/

    // Menggunakan .findAll untuk memfilter list berdasarkan pola regex
    def releaseLabels = allLabels.findAll { label ->
        (label =~ releasePattern)
    }

    echo "Found release labels: ${releaseLabels}"
    return releaseLabels
}

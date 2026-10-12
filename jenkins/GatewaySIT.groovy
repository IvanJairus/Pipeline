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
                    def jsonObject = readJSON(text: DATA) // DATA comes from the Post content parameters in JENKINS
                    // echo "${DATA}"

                    // Read the values and normalise case
                    def issueKey = jsonObject.issue?.key
                    def fromStatus = jsonObject?.changelog?.items?.getAt(0)?.fromString?.toLowerCase()
                    def toStatus = jsonObject?.changelog?.items?.getAt(0)?.toString?.toLowerCase()
                    def summary = jsonObject?.issue?.fields?.summary?.toLowerCase()
                    def stage = jsonObject?.issue?.fields?.customfield_10744?.value?.toUpperCase()

                    // Publish to env so the other stages can read them
                    env.ISSUE_KEY = issueKey
                    env.FROM_STATUS = fromStatus
                    env.TO_STATUS = toStatus
                    env.ISSUE_SUMMARY = summary
                    env.STAGE = stage
                    env.BRANCH = ''

                    // Print them for verification
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
// === HELPER FUNCTIONS ========================================================
// =============================================================================


def triggerJobs() {
    def jobKey = "${FROM_STATUS}:${TO_STATUS}".trim().toLowerCase()
    
    // Which job to fire, keyed by the ticket transition, plus its own parameters
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

    echo "List of jobMapping keys: ${jobMapping.keySet()}"

    // Check whether this ticket transition has a job bound to it
    if (jobMapping.containsKey(jobKey)) {
        def jobInfo = jobMapping[jobKey]
        echo "Running job: ${jobInfo.jobName} with parameters: ${jobInfo.params}"
        build wait: false, job: jobInfo.jobName, parameters: jobInfo.params
    } else {
        echo "No job matches the transition ${jobKey}, so no job was triggered."
    }
}

/**
 * Find an attachment on a Jira ticket by file name pattern, and return the content
 * URL of the newest one when more than one matches.
 *
 * @param issueKey Key of the Jira ticket.
 * @param fileNamePattern File name pattern to look for (for example "_manifest.yaml").
 * @param jiraToken Token used for API authentication.
 * @return String holding the file content URL, or null when nothing was found.
 */
def getJiraAttachmentUrl(String issueKey, String fileNamePattern, String jiraToken) {
    echo "Searching for the latest attachment matching '*${fileNamePattern}' in ticket ${issueKey}..."
    try {
        // Ask for the 'attachment' field to get the list of attachments
        def response = sh(
            script: """
                curl -k --silent --show-error -X GET --location "${env.JIRA_URL}/rest/api/2/issue/${issueKey}?fields=attachment" \\
                     --header "Authorization: ${jiraToken}"
            """,
            returnStdout: true
        ).trim()

        def issueData = readJSON(text: response)
        
        if (issueData.fields.attachment) {
            // 1. Keep every attachment whose name matches the pattern
            def matchingAttachments = issueData.fields.attachment.findAll { 
                it.filename.endsWith(fileNamePattern) 
            }
            
            if (!matchingAttachments.isEmpty()) {
                // 2. Sort the matches by the 'created' date, descending (newest first)
                // ISO 8601 dates sort correctly as plain strings
                def sortedAttachments = matchingAttachments.sort { a, b -> b.created <=> a.created }
                
                // 3. Take the first entry of the sorted list; that is the newest one
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
 * Filter a label list and return only the labels matching the release pattern (for example R1.x).
 *
 * @param allLabels A List holding every label on the ticket.
 * @return A new List containing only the release labels.
 */
def getReleaseLabels(List allLabels) {
    // The shape we look for is a string starting with "R1."
    def releasePattern = /^R1\.\d+$/

    // .findAll keeps the list entries that match the regex pattern
    def releaseLabels = allLabels.findAll { label ->
        (label =~ releasePattern)
    }

    echo "Found release labels: ${releaseLabels}"
    return releaseLabels
}

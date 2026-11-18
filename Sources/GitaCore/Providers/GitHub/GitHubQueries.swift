import Foundation

/// The bounded, read-only GraphQL queries. None selects bodies, comments, logs or anything beyond display metadata.
enum GitHubQueries {
    /// Whether an account can see a repository at all; the probe that picks an account.
    static let repositoryVisible = """
        query($owner:String!,$name:String!) { repository(owner:$owner,name:$name) { nameWithOwner } }
        """

    static let pullRequestSummaries = """
        query($owner:String!,$name:String!) {
          viewer { login }
          repository(owner:$owner,name:$name) {
            nameWithOwner
            pullRequests(first:30,orderBy:{field:UPDATED_AT,direction:DESC}) {
              totalCount pageInfo { hasNextPage endCursor }
              nodes { number title state isDraft headRefName headRefOid reviewDecision url updatedAt mergeCommit { oid }
                author { login } createdAt mergedAt mergedBy { login }
                reviewRequests(first:10) { nodes { requestedReviewer { __typename ... on User { login } } } }
                commits(last:1) { nodes { commit { oid statusCheckRollup { state } } } }
              }
            }
          }
        }
        """

    static let pullRequestDetail = """
        query($owner:String!,$name:String!,$number:Int!) {
          repository(owner:$owner,name:$name) {
            nameWithOwner
            pullRequest(number:$number) {
              number title author { login } state isDraft baseRefName headRefName headRefOid
              reviewDecision mergeable url updatedAt
              latestReviews(first:50) { totalCount pageInfo { hasNextPage endCursor }
                nodes { id author { login } state submittedAt commit { oid } url }
              }
              reviewRequests(first:50) { totalCount pageInfo { hasNextPage endCursor }
                nodes { requestedReviewer { __typename
                  ... on User { id login }
                  ... on Bot { id login }
                  ... on Team { id name slug organization { login } }
                } }
              }
              commits(last:1) { nodes { commit { oid statusCheckRollup {
                state contexts(first:50) { checkRunCount statusContextCount pageInfo { hasNextPage endCursor }
                  nodes { __typename
                    ... on CheckRun { id name status conclusion startedAt completedAt detailsUrl
                      checkSuite { workflowRun { workflow { name } } }
                    }
                    ... on StatusContext { id context state targetUrl createdAt }
                  }
                }
              } } } }
            }
          }
        }
        """

    static let avatars = """
        query($owner:String!,$name:String!) {
          repository(owner:$owner,name:$name) {
            nameWithOwner
            defaultBranchRef { target { ... on Commit {
              history(first:100) { nodes { author { email user { avatarUrl(size:64) } } } }
            } } }
          }
        }
        """

    static let runFields =
        "databaseId,number,attempt,displayTitle,workflowDatabaseId,workflowName,event,headSha,headBranch,status,"
        + "conclusion,url,startedAt,updatedAt"
    static let runDetailFields =
        "databaseId,number,attempt,displayTitle,workflowName,event,status,conclusion,headSha,headBranch,url,"
        + "startedAt,updatedAt"
}

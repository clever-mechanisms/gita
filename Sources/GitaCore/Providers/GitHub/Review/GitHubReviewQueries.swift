import Foundation

/// The review window's GraphQL: one read of the conversation (opened by the user, unlike the bounded list reads it
/// selects bodies), and the mutations that send a review, reply in a thread, resolve one and merge.
enum GitHubReviewQueries {
    static let conversation = """
        query($owner:String!,$name:String!,$number:Int!) {
          viewer { login }
          repository(owner:$owner,name:$name) {
            nameWithOwner viewerPermission viewerDefaultMergeMethod
            mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed
            pullRequest(number:$number) {
              id number title body state isDraft baseRefName headRefName headRefOid reviewDecision
              viewerDidAuthor createdAt author { login } mergeable commits { totalCount }
              reviews(last:100) { totalCount nodes { id author { login } state body submittedAt } }
              comments(last:100) { totalCount nodes { id author { login } body createdAt } }
              reviewThreads(last:100) { totalCount nodes { id path line originalLine diffSide isResolved isOutdated
                comments(first:50) { totalCount nodes { id author { login } body createdAt } }
              } }
            }
          }
        }
        """

    static let submitReview = """
        mutation($pullRequestId:ID!,$commitOID:GitObjectID!,$event:PullRequestReviewEvent!,$body:String,\
        $threads:[DraftPullRequestReviewThread]) {
          addPullRequestReview(input:{pullRequestId:$pullRequestId,commitOID:$commitOID,event:$event,body:$body,\
        threads:$threads}) { pullRequestReview { id state } }
        }
        """

    static let reply = """
        mutation($threadId:ID!,$body:String!) {
          addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$threadId,body:$body}) { comment { id } }
        }
        """

    static let resolve = """
        mutation($threadId:ID!) {
          resolveReviewThread(input:{threadId:$threadId}) { thread { id isResolved } }
        }
        """

    static let unresolve = """
        mutation($threadId:ID!) {
          unresolveReviewThread(input:{threadId:$threadId}) { thread { id isResolved } }
        }
        """

    /// `expectedHeadOid` makes GitHub refuse the merge when the branch moved since it was loaded.
    static let merge = """
        mutation($pullRequestId:ID!,$mergeMethod:PullRequestMergeMethod!,$expectedHeadOid:GitObjectID!) {
          mergePullRequest(input:{pullRequestId:$pullRequestId,mergeMethod:$mergeMethod,\
        expectedHeadOid:$expectedHeadOid}) { pullRequest { id state } }
        }
        """
}

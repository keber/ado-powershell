# Pull Request Functions - Azure DevOps PowerShell Skill

Full parameter reference and examples for `scripts/ado-pullrequests.ps1` (Git REST API 7.1).
Load the skill before using: `. .github/skills/ado-powershell/load.ps1`

Conventions for every function:

- `-RepoId` takes a repository **name or id** (like `Get-AdoBranches`); it is URI-escaped.
- Branch parameters accept `main` or `refs/heads/main`. Only the exact, case-sensitive
  `refs/heads/` prefix is recognised; anything else gets it prepended.
- `-Org`, `-Project`, `-ApiV`, `-Headers` default from `$AdoSession`.
- 🔴 writes support `-WhatIf` / `-Confirm` and are refused on a `-Access Read` session
  (ErrorId `AdoReadOnlySession`). All `Get-*` functions work on a Read session.
- PAT scope: **Code (Read)** for reads, **Code (Read & Write)** for writes (see
  [errors.md](errors.md)).

---

## Pull requests

### `Get-AdoPullRequests`

| Parameter | Required | Notes |
|-----------|----------|-------|
| `-RepoId` | ✅ | Repository name or id |
| `-Status` | | `active` (API default) \| `abandoned` \| `completed` \| `all` \| `notSet` |
| `-CreatorId` / `-ReviewerId` | | Identity ids |
| `-SourceBranch` / `-TargetBranch` | | `main` or `refs/heads/main` |
| `-Top` | | Maximum PRs returned (0 = all) |
| `-PageSize` | | Items per request (default 100); pages with `$top` / `$skip`. Paging stops with a warning if the server repeats a page or after 1000 requests |

```powershell
Get-AdoPullRequests -RepoId 'MyRepo' -TargetBranch main |
    Select-Object pullRequestId, title, @{n='By';e={$_.createdBy.displayName}}
Get-AdoPullRequests -RepoId 'MyRepo' -Status completed -Top 20
```

### `Get-AdoPullRequest -PullRequestId <n> [-RepoId <r>]`

With `-RepoId` uses the repository route (and accepts `-IncludeCommits`,
`-IncludeWorkItemRefs`); without it, the project-level "by id" route.

### 🔴 `New-AdoPullRequest`

| Parameter | Required | Notes |
|-----------|----------|-------|
| `-RepoId`, `-SourceBranch`, `-TargetBranch`, `-Title` | ✅ | |
| `-Description` | | |
| `-Draft` | | Create as draft (`isDraft`) |
| `-ReviewerIds` / `-RequiredReviewerIds` | | Identity ids (optional / required reviewers) |
| `-WorkItemIds` | | Work items to link (`workItemRefs`) |
| `-Labels` | | Label names |

```powershell
$pr = New-AdoPullRequest -RepoId 'MyRepo' -SourceBranch 'feature/login' -TargetBranch 'main' `
    -Title 'Login page' -Description 'Implements #1234' -WorkItemIds 1234 -Draft
```

### 🔴 `Set-AdoPullRequest`

Sends only the fields given: `-Title`, `-Description`, `-Draft` (back to draft), `-Publish`
(publish a draft), `-TargetBranch` (retarget; requires the PR retargeting feature on the
organization). Throws if nothing is given.

### 🔴 `Stop-AdoPullRequest` (abandon, ConfirmImpact High) / `Restore-AdoPullRequest` (reactivate)

PATCH `status` to `abandoned` / `active`.

### 🔴 `Complete-AdoPullRequest` (ConfirmImpact High)

| Parameter | Default | Notes |
|-----------|---------|-------|
| `-LastMergeSourceCommitId` | fetched | When omitted, the PR is read first and its current `lastMergeSourceCommit.commitId` is sent |
| `-MergeStrategy` | `noFastForward` | `noFastForward` \| `squash` \| `rebase` \| `rebaseMerge` |
| `-DeleteSourceBranch` | off | |
| `-TransitionWorkItems` | off | |
| `-MergeCommitMessage` | | |

ADO answers `200` even when it does not merge, so the returned PR is checked and `(ok) ... completed`
is printed only when `status = completed`:

| Outcome | Result |
|---------|--------|
| `status = completed` | Success message, PR returned |
| `mergeStatus = conflicts` | Throws ErrorId `AdoPullRequestConflict` (includes `mergeFailureMessage`) |
| `mergeStatus = rejectedByPolicy` \| `failure`, or PR abandoned | Throws ErrorId `AdoPullRequestNotCompleted` |
| `status = active`, no failure (e.g. `queued`) | Warning "not completed yet", PR returned: re-read it to confirm |
| HTTP **409** (source branch moved since `lastMergeSourceCommit`, TF401192; policies) | Throws ErrorId `AdoPullRequestConflict` and the server's message |

```powershell
Complete-AdoPullRequest -RepoId 'MyRepo' -PullRequestId $pr.pullRequestId `
    -MergeStrategy squash -DeleteSourceBranch -TransitionWorkItems -Confirm:$false
```

### 🔴 `Set-AdoPullRequestAutoComplete [-Disable]`

Enables auto-complete as the authenticated user (`autoCompleteSetBy`) with the same completion
options as `Complete-AdoPullRequest`; `-Disable` sends the empty GUID.

---

## Reviewers and votes

| Function | HTTP | Notes |
|----------|------|-------|
| `Get-AdoPullRequestReviewers` | GET `.../reviewers` | Includes `vote`, `isRequired` |
| 🔴 `Add-AdoPullRequestReviewer -ReviewerId <id> [-Required]` | PUT `.../reviewers/{id}` | |
| 🔴 `Remove-AdoPullRequestReviewer -ReviewerId <id>` | DELETE `.../reviewers/{id}` | |
| 🔴 `Set-AdoPullRequestVote -Vote <v> [-ReviewerId <id>]` | PUT `.../reviewers/{id}` | |
| 🔴 `Approve-AdoPullRequest` | PUT | Shortcut for `-Vote Approve` |

| `-Vote` | Value |
|---------|-------|
| `Approve` | 10 |
| `ApproveWithSuggestions` | 5 |
| `NoVote` | 0 |
| `WaitForAuthor` | -5 |
| `Reject` | -10 |

Without `-ReviewerId` the vote is cast as the authenticated identity. `Get-AdoCurrentUserId`
reads `authenticatedUser.id` from `https://dev.azure.com/{org}/_apis/connectionData`:

- With the session's own credential it is resolved once and cached on the session as
  `AuthenticatedUserId`, together with `AuthenticatedUserKey` (a SHA-256 fingerprint of org +
  Authorization header; the header itself is never stored). Replacing the session headers
  invalidates the cache; `-Force` re-queries.
- With explicit `-Headers` of another credential the id is resolved on every call and the
  session cache is neither read nor written, so votes are cast as the identity that sends them.
- If the id cannot be resolved it throws and asks for `-ReviewerId`.

The lookup (like the pull request read in `Complete-AdoPullRequest`) happens after the
`ShouldProcess` check, so `-WhatIf` sends no request at all.

```powershell
Set-AdoPullRequestVote -RepoId 'MyRepo' -PullRequestId 42 -Vote WaitForAuthor
Approve-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42
```

---

## Threads and comments

| Function | HTTP |
|----------|------|
| `Get-AdoPullRequestThreads [-Iteration <n>] [-BaseIteration <n>]` | GET `.../threads` |
| 🔴 `New-AdoPullRequestThread -Content <t> [-Status] [-FilePath <p> [-Line <n>] [-EndLine <n>] [-Side Right\|Left]]` | POST `.../threads` |
| 🔴 `Add-AdoPullRequestComment -ThreadId <n> -Content <t> [-ParentCommentId <n>]` | POST `.../threads/{id}/comments` |
| 🔴 `Set-AdoPullRequestThreadStatus -ThreadId <n> -Status <s>` | PATCH `.../threads/{id}` |

Thread status: `active` \| `fixed` \| `wontFix` \| `closed` \| `byDesign` \| `pending`. Comments
are sent with `commentType = text`. A file anchor sets `threadContext.filePath` (a leading `/`
is added) and `rightFileStart` / `rightFileEnd` (or `left*` with `-Side Left`) with
`offset = 1`, i.e. whole lines.

```powershell
$t = New-AdoPullRequestThread -RepoId 'MyRepo' -PullRequestId 42 -Content 'Off by one?' `
        -FilePath 'src/calc.ps1' -Line 18
Add-AdoPullRequestComment -RepoId 'MyRepo' -PullRequestId 42 -ThreadId $t.id -Content 'Fixed' -ParentCommentId 1
Set-AdoPullRequestThreadStatus -RepoId 'MyRepo' -PullRequestId 42 -ThreadId $t.id -Status fixed
```

---

## Inspection

| Function | Notes |
|----------|-------|
| `Get-AdoPullRequestIterations [-IncludeCommits]` | Pushes to the PR |
| `Get-AdoPullRequestChanges [-IterationId <n>] [-CompareTo <n>] [-PageSize <1-2000>]` | Returns `changeEntries`; latest iteration by default; follows `nextSkip` / `nextTop` |
| `Get-AdoPullRequestCommits [-Top <n>]` | Follows the continuation token |
| `Get-AdoPullRequestWorkItems` | Linked work items (`id`, `url`) |

```powershell
Get-AdoPullRequestChanges -RepoId 'MyRepo' -PullRequestId 42 |
    ForEach-Object { '{0,-8} {1}' -f $_.changeType, $_.item.path }
```

---

## Labels and statuses

| Function | HTTP |
|----------|------|
| `Get-AdoPullRequestLabels` | GET `.../labels` |
| 🔴 `Add-AdoPullRequestLabel -Name <n>` | POST `.../labels` (creates the tag if needed) |
| 🔴 `Remove-AdoPullRequestLabel -Name <n>` | DELETE `.../labels/{name}` (tag itself is kept) |
| `Get-AdoPullRequestStatuses` | GET `.../statuses` |
| 🔴 `New-AdoPullRequestStatus -State <s> -ContextName <n> [-ContextGenre] [-Description] [-TargetUrl] [-IterationId]` | POST `.../statuses` |

Status state: `notSet` \| `pending` \| `succeeded` \| `failed` \| `error` \| `notApplicable`.

---

## API reference (7.1)

- Pull requests: https://learn.microsoft.com/rest/api/azure/devops/git/pull-requests?view=azure-devops-rest-7.1
- Reviewers: https://learn.microsoft.com/rest/api/azure/devops/git/pull-request-reviewers?view=azure-devops-rest-7.1
- Threads: https://learn.microsoft.com/rest/api/azure/devops/git/pull-request-threads?view=azure-devops-rest-7.1
- Thread comments: https://learn.microsoft.com/rest/api/azure/devops/git/pull-request-thread-comments?view=azure-devops-rest-7.1
- Iterations: https://learn.microsoft.com/rest/api/azure/devops/git/pull-request-iterations?view=azure-devops-rest-7.1
- Iteration changes: https://learn.microsoft.com/rest/api/azure/devops/git/pull-request-iteration-changes?view=azure-devops-rest-7.1
- Commits: https://learn.microsoft.com/rest/api/azure/devops/git/pull-request-commits?view=azure-devops-rest-7.1
- Work items: https://learn.microsoft.com/rest/api/azure/devops/git/pull-request-work-items?view=azure-devops-rest-7.1
- Labels: https://learn.microsoft.com/rest/api/azure/devops/git/pull-request-labels?view=azure-devops-rest-7.1
- Statuses: https://learn.microsoft.com/rest/api/azure/devops/git/pull-request-statuses?view=azure-devops-rest-7.1

`_apis/connectionData` has no REST reference page; it is used here as the standard way to read
the authenticated identity.

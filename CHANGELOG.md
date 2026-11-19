# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

## [1.6.0-rc.3] - 2026-11-19

Third release candidate: URL path segments (project, team, repository, work item type, label,
reviewer) are escaped (#41). Published under the npm `next` dist-tag. Validated with mocked Pester
tests on Windows PowerShell 5.1 only; not exercised against a real Azure DevOps organization or on
PowerShell 7.

### Fixed

- The project name is now escaped as a URL path segment in every request URL. All
  `{baseUrl}/{project}/_apis/...` URLs are built through the new `Get-AdoProjectUrl` helper
  (`scripts/ado-base.ps1`), and `Get-AdoTeams` escapes the project in
  `_apis/projects/{project}/teams`. A project such as `QA #1` or `R&D?` no longer truncates the URL
  at `#` or starts the query string early at `?`. Other free-text path segments go through the new
  `ConvertTo-AdoPathSegment` helper too: the team of `Get-AdoIterations -Team`, the repository
  (`-RepoId`) of `Get-AdoBranches` and every pull request function, the work item type of
  `New-AdoWorkItem` / `Get-AdoWorkItemTypeFields`, pull request label names and reviewer ids.
  Pass plain (unescaped) names; an already percent-encoded name is now encoded again. (#41)
- An empty value or the dot segment `.` / `..` (after trimming) as project, team, repository, work
  item type, label or reviewer id now throws before any request, instead of sending
  `{baseUrl}//_apis/...` or a URL that normalisation shortens (`..` would climb out of the project
  or replace the repository route). This includes `Get-AdoTeams` with an empty project. (#41)
- `Get-AdoIterations -TimeFrame` only accepts `past`, `current` or `future` and
  `Get-AdoWorkItem -Expand` only accepts `None`, `Relations`, `Fields`, `Links` or `All`
  (`ValidateSet`); both values are also escaped in the query string. (#41)
- A Pester AST scan (`tests/helpers/UrlSegmentScan.ps1`) fails the build when a free-text value
  (`$Project`, `$Team`, `$RepoId`, `$Type`, `$Name`, `$ReviewerId`, `.Project`, `['Project']` or a
  plain alias of them) reaches a string containing `/` without an escaping helper, through string
  interpolation, `-f` or `+`. (#41)

## [1.6.0-rc.2] - 2026-11-19

Second release candidate: adds pull request management (#38) and the read/write credential model
(#18) on top of the 1.6.0-rc.1 fixes. Published under the npm `next` dist-tag. Validated with mocked
Pester tests on Windows PowerShell 5.1 only; not exercised against a real Azure DevOps organization
or on PowerShell 7.

### Added

- Pull requests (`scripts/ado-pullrequests.ps1`, loaded by `load.ps1`; docs in
  `references/pullrequests.md`): list (search criteria, `$top`/`$skip` paging), get, create,
  edit/publish/retarget, abandon (`Stop-`), reactivate (`Restore-`), complete (fetches
  `lastMergeSourceCommit`; 409 thrown as `AdoPullRequestConflict`) and auto-complete; reviewers
  and votes (`Set-AdoPullRequestVote`, `Approve-AdoPullRequest`; the authenticated user id is
  resolved from `_apis/connectionData` once per session and cached as
  `$AdoSession.AuthenticatedUserId` for the session credential only); comment threads;
  iterations, changes (`nextSkip` paging), commits (continuation token) and linked work items;
  labels and statuses. Every write uses `SupportsShouldProcess` (pre-flight reads happen after
  it, so `-WhatIf` sends nothing) and is refused on a `-Access Read` session. (#38)
- Read/write credential split: `Initialize-AdoSession -Access Read|Write` (default `Write`, the
  previous behaviour) resolves `ADO_PROJECT_<ACCESS>` / `ADO_PAT_<ACCESS>` before `ADO_PROJECT` /
  `ADO_PAT` / `AZURE_DEVOPS_EXT_PAT`. The session records `Access` and `AuthScheme`. On a `Read`
  session every write is refused with ErrorId `AdoReadOnlySession` before anything is sent:
  `Invoke-AdoRequest` guards all non-GET requests unless marked `-ReadOnly` (WIQL and
  workitemsbatch are), and `Add-AdoWorkItemAttachment` guards its raw upload. New
  `Assert-AdoWriteAccess`. (#18)
- Bearer tokens: `New-AdoHeaders -Token` / `-Bearer` and `Initialize-AdoSession -Token` / `-Bearer`
  send `Authorization: Bearer` for Microsoft Entra tokens and `SYSTEM_ACCESSTOKEN`.
  `SYSTEM_ACCESSTOKEN` is also used automatically when no PAT is set; PAT variables keep
  precedence otherwise. (#18)
- Conditional Access diagnostics: `VS403463` (in `X-TFS-ServiceError` or the error body) is
  thrown by `Invoke-AdoRequest` / `Invoke-AdoGetPaged` / `Invoke-AdoDownload` and the
  `Add-AdoWorkItemAttachment` upload as ErrorId `AdoConditionalAccess`, not retried, with a
  message explaining that regenerating the PAT does not help. (#18)
- `load.ps1` auto-initialises from any credential variable and honours `ADO_ACCESS`. (#18)
- Docs: credential model (identity / context / secrets) and hard rules in `SKILL.md` and
  `references/base.md`. (#18)

### Changed

- Missing-credential errors now list the access-specific and Bearer variables that were tried
  (names only). (#18)
- `Invoke-AdoRequest`, `Invoke-AdoGetPaged` and `Invoke-AdoDownload` without `-Headers` now use
  the current session's headers, falling back to environment resolution only when there is no
  session. (#18)

### Fixed

- `SKILL.md` frontmatter: stray characters after the `compatibility` value. (#18)
- `Resolve-AdoConfig` no longer echoes the content of a malformed config file (which could
  include a legacy `pat`) in its warning; it reports the path and error type only. (#18)
- Whitespace-only `-Pat` / `-Token` / credential variables are treated as absent, so the
  session's `AuthScheme` always matches the header sent. (#18)
- `Invoke-AdoRequest` / `Invoke-AdoGetPaged`: a 409 Conflict is no longer retried for GET, PUT,
  DELETE or `-RetryNonIdempotent` requests; the original error (status and server message) is
  rethrown. (#38)

---

## [1.6.0-rc.1] - 2026-11-19

Release candidate. Fixes for the 17 issues found in the November 2026 review (#1-#17), led by two
security fixes. Published under the npm `next` dist-tag; `latest` stays on 1.5.0.

### Security

- `Save-AdoInlineImage` / `Invoke-AdoDownload`: ADO credentials are no longer sent to non-ADO hosts.
  New `Test-AdoTrustedUrl` (https only; dev.azure.com, *.visualstudio.com, the session base host).
  `Invoke-AdoDownload` throws on an untrusted host unless `-Headers` is passed explicitly; inline
  images on external hosts are skipped with a warning. (#1)
- `Save-AdoInlineImage`: image extensions are allow-listed (png, jpg, gif, bmp, webp, svg) and the
  file base name is sanitized. (#15)
- `Add-AdoWorkItemAttachment`: `-LiteralPath` resolution, leaf-file check, and the upload file name
  is URI-escaped. (#14)
- `references/config.json` no longer ships a `pat` key. (#6)

### Changed

- `Invoke-AdoRequest`: POST/PATCH are retried only on 429 (opt in with `-RetryNonIdempotent`);
  `Retry-After` is honoured, capped at 120 s. (#7)
- `Invoke-AdoPipelineRun`: `ConfirmImpact = 'High'`, so it prompts unless `-Confirm:$false`. (#16)
- `Get-AdoTestSuites` / `Get-AdoTestCases`: non-404 errors (401, 403, ...) are rethrown instead of
  returning an empty list; when every endpoint shape returns 404 the function throws. (#5)
- Sign-in pages are detected by strong markers and raised as an ErrorRecord with ErrorId
  `AdoSignInPage`, never retried. (#8) Downloads that return `text/html`, and inline images whose
  bytes are not an image, are rejected. (#9)
- List functions follow continuation tokens (new `Invoke-AdoGetPaged`); work item revisions page
  with `$top`/`$skip`; `Invoke-AdoWiql -Top` is validated (1-20000) and warns on likely truncation. (#11)
- `Get-AdoWorkItemsBatch`: new `-ErrorPolicy Omit|Fail` (default `Omit`); omitted ids are reported
  in a warning. (#12)
- Dot-sourcing the skill no longer turns on `Set-StrictMode` or changes `$ErrorActionPreference` in
  the caller session; each function sets them itself. (#17)

### Fixed

- `Invoke-AdoPipelineRun`: only the literal `refs/heads/` prefix is stripped from branch names. (#2)
- `Get-AdoPipelineRuns`: `-Branch`, `-Result` and `-Top` are applied client-side (the 7.1 API
  ignores them). (#3)
- `New-AdoWorkItem`: `-State` accepts any state of the process (ValidateSet removed). (#4)
- `Resolve-AdoConfig`: a bare `baseUrl` host gets the organization appended. (#6)
- 400 responses include the service message on PowerShell 7. (#10)
- `Invoke-AdoWiql`: link queries return ids from `workItemRelations`. (#13)
- `assets/smoke-test.ps1`: loader path. (#17)

### Not verified

All fixes were validated with mocked Pester tests on Windows PowerShell 5.1 only: no calls against a
real Azure DevOps organization and no runs on PowerShell 7.

---

## [1.5.0] - 2026-09-09

Helpers generalized from Azure DevOps scripts written independently across three QA projects, plus
the API-limit fix those scripts existed to work around. Additive: no signature changes, no removals.

### Added

- `references/base.md` and `references/content.md`: two new reference files. The base helpers belong
  to no single ADO domain, and Work Item content handling is large enough to document on its own.

**Session and response helpers** (`ado-base.ps1`)

- `Get-AdoFieldValue`: reads a Work Item field without throwing under `Set-StrictMode`. ADO omits
  unset fields from its responses, so `$wi.fields.'System.Reason'` throws whenever that field
  happens to be empty - and which fields are present varies per item, so the failure appears on
  some work items and not others. Accepts `-Default`, and a `$null` Work Item.
- `Read-AdoJsonUtf8`: reads a local JSON file as UTF-8. `Get-Content` on Windows PowerShell 5.1
  decodes with the ANSI codepage, turning `botón` into `botÃ³n`; writing that back to ADO corrupts
  the work item. PowerShell 7 defaults to UTF-8, so this reproduces on 5.1 only.
- `Test-AdoSignInResponse`: recognises an ADO sign-in page returned in place of a payload.

**Work Item relations and metadata** (`ado-workitems.ps1`)

- `Get-AdoWorkItemParent`: walks `System.LinkTypes.Hierarchy-Reverse`. Takes an id or an
  already-fetched Work Item; `-IdOnly` returns just the id.
- `Test-AdoWorkItemLink`: whether a link of a given type already exists. ADO accepts duplicate
  relations silently, so re-running a linking script accumulates identical links. Matches on the
  target id parsed from the relation URL, so it holds across host spellings.
- `Get-AdoIdFromUrl`: extracts a Work Item id from a relation URL.
- `Get-AdoWorkItemTypeFields`: field definitions for a type, including default values - what
  separates an unfilled field from one left at its template default. Cached per type.

**Work Item content and inline images** (new `ado-content.ps1`)

A description is HTML, and the UI mockup carrying the requirement is usually an embedded `<img>`
tag rather than an attachment. Reading the field as text drops it silently: the description looks
near-empty while the requirement sits in a picture.

- `ConvertFrom-AdoHtml`: HTML field to plain text. Preserves block structure as line breaks, drops
  `<script>`/`<style>`, decodes entities, and normalises `&nbsp;` to a real space - U+00A0 looks
  identical but fails a search for words a reader can plainly see.
- `Get-AdoInlineImageUrl`: embedded image URLs in document order, HTML-decoded.
- `Get-AdoWorkItemContentHtml`: ReproSteps for a Bug, Description otherwise.
- `Save-AdoInlineImage`: downloads them, handling both attachment URLs and base64 `data:` URIs.
  A failed or zero-byte download is discarded rather than left as a truncated file.
- `Resolve-AdoAttachmentUrl`: resolves host-relative URLs and appends `api-version` and
  `download=true`. Without `download=true` the attachments endpoint can answer with a document
  wrapper instead of the file bytes - the request succeeds and the saved file is not the image.

**Test Suites** (`ado-testing.ps1`)

- `Update-AdoTestSuite`: renames a suite, sending UTF-8 with an explicit charset since suite names
  carry accents.
- `Remove-AdoTestCaseFromSuite`: detaches a Test Case from a suite. Pinned to the legacy
  `/_apis/test/` route at `api-version=5.0` deliberately - the current `/_apis/testplan/` route
  answers `DELETE` for this operation with HTTP 405.

**WIQL**

- `Invoke-AdoWiql`: new `-Fields`, forwarded to the item fetch, and `-IdsOnly` to skip the fetch.
  WIQL returns ids regardless of what the query SELECTs, so results were previously always a full
  `-Expand All` payload.

### Fixed

- `Get-AdoWorkItemsBatch`, `Invoke-AdoWiql`: HTTP 400 above 200 ids. The endpoint caps a request at
  200; the limit was documented in the synopsis but not enforced, and `Invoke-AdoWiql` forwarded
  every id from a WIQL result in one call, so any `-Top` above 200 failed. Ids are now split into
  consecutive requests and the results concatenated. No signature change - a set under 200 behaves
  exactly as before. New `-BatchSize` (1-200, default 200) for a constrained gateway.
- `Get-AdoWorkItemsBatch`: HTTP 400 when `-Fields` was combined with the default `-Expand All`. ADO
  rejects `fields` alongside any `$expand` other than `None`, so `-Fields` now sets `-Expand None`.
  Passing both explicitly raises a diagnostic error rather than silently overriding the caller.
- `Invoke-AdoWiql`: threw under `Set-StrictMode` when a query matched nothing, reading
  `$r.workItems` without checking the property exists. Returns an empty array now.
- `Invoke-AdoRequest`: a sign-in page parsed into an object was not detected. Only the raw-string
  form was caught, so an authentication failure surfaced later as an opaque StrictMode error about
  a missing member instead of naming the cause.
- `Get-AdoWorkItemsBatch`, `Invoke-AdoWiql`: empty results unrolled to `$null` instead of an empty
  array, so `.Count` on a no-match result threw under `Set-StrictMode`. Every return path is now
  an array - the same defect class fixed in 1.3.1 for JSON request bodies.

### Notes

- Verified against Windows PowerShell 5.1 (the more restrictive of the two supported runtimes):
  150 behaviour checks across the added functions, including real file writes for the download
  paths and the 199/200/201 batch boundaries. The skill still ships no test suite; see
  `docs/BACKLOG-deferred.md`.
- `docs/HANDOFF-ado-qa-boundary.md` records an overlap for the `@keber/ado-qa` maintainer: several
  helpers added here already exist in that package's `_shared/ado` layer. Until those copies are
  removed and the base skill consumed, this release increases duplication between the two packages
  rather than reducing it.

---

## [1.4.0] - 2026-05-19

### Removed
- `ado-read.ps1` and `ado-write.ps1`: deprecated compatibility shims deleted. All functions were already available in the domain-specific files (`ado-workitems.ps1`, `ado-testing.ps1`, `ado-pipelines.ps1`, `ado-git.ps1`) since 1.2.0. If you were dot-sourcing either file directly, switch to the domain files or use `load.ps1`.

### Fixed
- `Add-AdoTestCaseToSuite` in `ado-write.ps1` (now removed): the `ConvertTo-Json` pipeline bug fix applied in 1.3.1 had been missed in the deprecated copy of the function. Backported before removal.

---

## [1.3.1] - 2026-05-15

### Fixed
- `New-AdoWorkItem`, `Update-AdoWorkItem`, `Add-AdoWorkItemLink`, `Add-AdoWorkItemAttachment` (ado-workitems.ps1 and deprecated ado-write.ps1), `Update-AdoTestRunResults`, `Add-AdoTestCaseToSuite` (ado-testing.ps1): HTTP 400 on PowerShell 5.1 when the patch/body array contained only one element. In PS 5.1, piping a single-element collection to `ConvertTo-Json` unwraps it and produces `{...}` instead of `[{...}]`. ADO requires a JSON array and rejects the bare object with 400. Fixed by using `ConvertTo-Json -InputObject @($ops)` in all affected call sites, which guarantees array output regardless of element count or PS version.
- `Invoke-AdoRequest`: HTTP 400 responses no longer trigger retries. The response body is now included in the thrown error message to aid diagnosis.

---

## [1.3.0] - 2026-05-15

### Added
- `New-AdoTestCase`: new optional parameter `-ExpectedResult` — plain-text expected result applied to the last step.

### Changed
- `New-AdoTestCase`: the last step in `-Steps` is now emitted as `ValidateStep` (previously all steps were `ActionStep`). The `<description/>` element is now included in every step for consistency with the ADO format.

---

## [1.2.0] - 2026-05-14

_Initial public release._

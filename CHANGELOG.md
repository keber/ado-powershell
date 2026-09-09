# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

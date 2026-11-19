# Hand-off: `ado-qa` boundary and shared-layer duplication

**Audience:** whoever maintains `@keber/ado-qa`.
**Author context:** written while scoping a promotion pass on `@keber/ado-powershell`
(2026-09-09). Nothing here is in scope for that pass — it is filed so the finding is not lost.

**Status:** advisory. No change has been made to `ado-qa`.

---

## Summary

`ado-qa` declares `@keber/ado-powershell` as a dependency and its `load.ps1` dot-sources the base
skill, but its internal shared layer at
`.github/skills/ado-qa/scripts/_shared/ado/src/` largely bypasses that dependency: it reaches
Azure DevOps with raw `Invoke-RestMethod` and resolves configuration through its own mechanism
rather than the base skill's `$AdoSession`.

Of every function in `_shared/ado/src/core.ps1` and `network.ps1`, exactly one line calls into the
base skill — `Invoke-AdoDownload` at `network.ps1:36`.

This is not urgent and nothing is broken. It matters because it makes the two packages drift, and
because a promotion pass on the base skill will make the drift worse unless `ado-qa` is adjusted
in the same period.

---

## Evidence

### Parallel work item read

`_shared/ado/src/network.ps1:102` defines `Get-WorkItem`, which reimplements the base skill's
`Get-AdoWorkItem`: builds its own URL, sets its own `$expand`, calls `Invoke-RestMethod` directly.

### Parallel configuration resolution

`_shared/ado/src/core.ps1:56` defines `Resolve-ConfigValue`, which resolves `Org` / `Project` /
`ApiV` / `Headers` from a config object, then script scope, then global scope. The base skill
resolves the same values through `Initialize-AdoSession` into `$script:AdoSession`, and every base
function defaults its parameters from there.

Two configuration mechanisms for the same four values, in packages that ship together.

### Overlapping helpers

These exist in `_shared` and are also candidates for promotion into the base skill. If they are
promoted without `ado-qa` adopting them, the result is three live implementations where there are
currently two:

| `_shared` function | Location | Base-skill equivalent |
|---|---|---|
| `Get-Field`, `Get-Prop` | `core.ps1:4`, `core.ps1:14` | proposed `Get-AdoFieldValue` |
| `Convert-HtmlToText` | `core.ps1:20` | proposed `ConvertFrom-AdoHtml` |
| `Get-ImgSrcsFromHtml` | `core.ps1:31` | proposed inline-image extraction |
| `Ensure-ApiVersionDownload` | `core.ps1:80` | (no equivalent — see below) |

---

## What `ado-qa` has that the base skill should take

Two pieces of knowledge live only in `_shared` and are generic Azure DevOps behaviour, not QA
workflow. They are candidates for the base skill; `ado-qa` would then consume them.

**1. Login-page detection on an authentication failure** — `network.ps1:113-127`.

When credentials, org, or project are wrong, Azure DevOps can return the HTML sign-in page with a
200 status. Parsed as JSON it becomes a `PSCustomObject` with no `fields` property, and the failure
surfaces much later as an opaque StrictMode error. `_shared` checks for the missing `fields`
property, sniffs the preview for sign-in markers, and raises a diagnostic error naming the likely
cause.

This belongs in the base skill's `Invoke-AdoRequest`, where every caller benefits.

**2. Attachment download URL normalisation** — `Ensure-ApiVersionDownload`, `core.ps1:80`.

Appends `api-version` and `download=true` to an attachment URL. Without `download=true` the request
can return a document wrapper rather than the binary. Other implementations of inline-image
download found in the QA projects omit this and are subtly wrong as a result.

---

## What should stay in `ado-qa`

These are QA workflow, not Azure DevOps API surface, and were explicitly excluded from the base
skill's scope:

- **Test iteration attachments** — `network.ps1:222-333`
  (`Get-TestIterationAttachments`, `Get-TestIterationAttachmentDownloadUrl`,
  `Download-TestIterationAttachment`). Targets a different host (`vstmr.dev.azure.com`,
  `api-version=7.1-preview.1`). This is consumption of test execution results.
- **`Get-PrimaryHtml`** — `core.ps1:90`. Chooses `Microsoft.VSTS.TCM.ReproSteps` over
  `System.Description` for Bugs. Presentation heuristic.
- **PowerPoint pipeline support** — `Wait-ForFileStable` (`network.ps1:143`),
  `Test-IsSupportedImage` (`network.ps1:157`, GDI+ based). Specific to the export pipeline.

---

## Suggested boundary

> `ado-powershell` is the Azure DevOps API. `ado-qa` is the QA workflow.
> If a function has to know what a bug, a sprint, or a report is, it is QA.

---

## Suggested direction

Not prescriptive — the sequencing is the `ado-qa` maintainer's call.

1. Have `_shared` consume `$AdoSession` instead of `Resolve-ConfigValue`, or make
   `Resolve-ConfigValue` fall back to `$AdoSession` so both paths converge.
2. Replace `Get-WorkItem` (`network.ps1:102`) with `Get-AdoWorkItem`, keeping the login-page
   diagnostic until the base skill carries it.
3. As helpers land in the base skill, delete the `_shared` copies rather than leaving both.

Step 3 is the one that has to be coordinated with the base skill's release: a promotion without a
matching deletion increases duplication instead of reducing it.

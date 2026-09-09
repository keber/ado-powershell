# Work Item Content and Inline Images - Azure DevOps PowerShell Skill

Functions in `scripts/ado-content.ps1`, for reading the HTML fields of a Work Item and the images
embedded in them. Load the skill before using: `. .github/skills/ado-powershell/load.ps1`

> **Why this file exists.** A Work Item description is HTML, and the UI mockup that carries the
> actual requirement is usually embedded in it as an `<img>` tag rather than attached as a file.
> Reading `System.Description` as text silently drops that image - the field looks near-empty while
> the requirement sits in a picture. Anything that classifies work items (coverage, gap analysis,
> "is this built") has to download and look at those images before concluding.

---

## `ConvertFrom-AdoHtml`

HTML field to plain text.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Html` | No | The HTML string. `$null` or empty returns `''` |

```powershell
$wi   = Get-AdoWorkItem -Id 20071
$text = ConvertFrom-AdoHtml (Get-AdoFieldValue -WorkItem $wi -Name 'System.Description')
```

Block structure survives as line breaks (`<br>` to a newline; `</p>`, `</div>`, `</li>` to a blank
line), `<script>` and `<style>` blocks are dropped, and entities are decoded. `&nbsp;` becomes a
real space rather than U+00A0 - the non-breaking variant looks identical but does not match a
search for the words a reader can see.

A text extractor, not an HTML parser. Use it to read a field, not to round-trip markup.

---

## `Get-AdoInlineImageUrl`

Image URLs embedded in an HTML field, in document order.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Html` | No | The HTML, typically `System.Description` or `ReproSteps` |
| `-AttachmentOnly` | No | Skip `data:` URIs, returning only attachment URLs |

```powershell
$html = Get-AdoWorkItemContentHtml -WorkItem $wi
Get-AdoInlineImageUrl -Html $html
```

Returns `[string[]]` always - zero and one match included, so `.Count` is safe without wrapping the
call in `@()`.

URLs are HTML-decoded. An attribute written as `...?fileName=a&amp;download=true` comes back with a
real `&`; passing the raw attribute to a download requests the wrong resource.

---

## `Get-AdoWorkItemContentHtml`

The HTML field that carries a Work Item's content: `Microsoft.VSTS.TCM.ReproSteps` for a Bug,
`System.Description` for everything else, falling back to Description when a Bug's ReproSteps is
empty.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-WorkItem` | Yes | Work Item from `Get-AdoWorkItem` / `Get-AdoWorkItemsBatch`. May be `$null` |

```powershell
$text = ConvertFrom-AdoHtml (Get-AdoWorkItemContentHtml -WorkItem $wi)
```

This is a convention, not an API guarantee. A team that fills in both fields, or neither, is doing
nothing invalid - read the field directly when the choice matters.

---

## `Save-AdoInlineImage`  🔴

Downloads the images embedded in a Work Item's content to a local directory. Supports `-WhatIf`.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-WorkItem` | Yes (or `-Html`) | Work Item whose content is scanned |
| `-Html` | Yes (or `-WorkItem`) | Scan this HTML directly |
| `-OutDirectory` | Yes | Destination. Created when missing - and not created when there is nothing to save |
| `-BaseName` | No | File name stem. Default: `inline` |
| `-IncludeAttachedFiles` | No | Also download `AttachedFile` relations whose name looks like an image. Needs relations (default `-Expand All`) |

```powershell
$wi    = Get-AdoWorkItem -Id 20071
$files = Save-AdoInlineImage -WorkItem $wi -OutDirectory ./cache/20071
# then look at each file - the mockup is often the only place that says whether the item
# describes a new screen or a section added to one that already exists
```

Files are `inline-1`, `inline-2`, ... in document order, with the extension implied by the URL or
data URI (`png` when nothing says otherwise). Both attachment URLs and base64 `data:` URIs are
handled. A download that fails or produces zero bytes is discarded rather than left behind as a
truncated file, and a warning names which image it was.

Returns `[string[]]` of the paths written - always an array.

---

## `Resolve-AdoAttachmentUrl`

Turns an attachment URL found in Work Item content into one that actually downloads. Called by
`Save-AdoInlineImage`; exposed for code that fetches attachments its own way.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Url` | Yes | URL as it appears in the HTML, or an `AttachedFile` relation url |

```powershell
Resolve-AdoAttachmentUrl -Url '/contoso/_apis/wit/attachments/abc?fileName=mock.png'
# https://dev.azure.com/contoso/_apis/wit/attachments/abc?fileName=mock.png&api-version=7.1&download=true
```

Two adjustments, both needed in practice:

- **Host-relative and scheme-less URLs are resolved** against the session's base URL. A `src`
  attribute is frequently written as `/org/_apis/wit/attachments/...`.
- **`api-version` and `download=true` are appended** when absent. Without `download=true` the
  attachments endpoint can answer with a document wrapper instead of the file bytes - the request
  succeeds and the saved file is not the image. Existing values are left alone.

A `data:` URI is returned unchanged.

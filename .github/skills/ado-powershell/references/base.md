# Session and Response Helpers - Azure DevOps PowerShell Skill

Helpers in `scripts/ado-base.ps1` that are not tied to a single ADO domain.
Load the skill before using: `. .github/skills/ado-powershell/load.ps1`

---

## `Get-AdoFieldValue`

Reads a field from a Work Item without throwing under `Set-StrictMode`.

**Use this instead of `$wi.fields.'System.Reason'`.** Every script in this skill enables
`Set-StrictMode -Version Latest`, and ADO omits unset fields from its responses entirely - so dot
notation on a field that happens to be empty throws a runtime error rather than yielding `$null`.
Which fields are present varies per work item, so the failure shows up on some items and not
others.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-WorkItem` | Yes (or `-Fields`) | Work Item from `Get-AdoWorkItem` / `Get-AdoWorkItemsBatch`. May be `$null` |
| `-Fields` | Yes (or `-WorkItem`) | A `.fields` object directly |
| `-Name` | Yes | Field reference name, e.g. `System.Title` |
| `-Default` | No | Value returned when the field is absent or null. Default: `$null` |

```powershell
$wi = Get-AdoWorkItem -Id 20071

Get-AdoFieldValue -WorkItem $wi -Name 'System.Title'
Get-AdoFieldValue -WorkItem $wi -Name 'System.Reason' -Default '(unset)'

# Reason matters: it separates "Completed" from "Removed" / "Duplicate" / "Cut",
# which State alone does not tell you.
$state  = Get-AdoFieldValue -WorkItem $wi -Name 'System.State'
$reason = Get-AdoFieldValue -WorkItem $wi -Name 'System.Reason' -Default ''
```

A `$null` Work Item returns the default rather than failing - callers that fetched an item which
turned out not to exist do not need a separate guard.

---

## `Read-AdoJsonUtf8`

Reads a local JSON file as UTF-8 and returns the parsed object.

**Use this instead of `Get-Content` for any file whose contents will be written back to ADO.**
`Get-Content` in Windows PowerShell 5.1 decodes with the ANSI codepage, not UTF-8: `botón` is read
as `botÃ³n`, and pushing that into a work item corrupts the title. PowerShell 7 defaults to UTF-8,
so the bug reproduces on 5.1 only - which makes it easy to miss during development.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Path` | Yes | Path to the JSON file |
| `-Raw` | No | Return the decoded text instead of parsing it as JSON |

```powershell
$mapping = Read-AdoJsonUtf8 -Path ./tc-mapping.json
foreach ($tc in $mapping.testCases) {
    Update-AdoWorkItem -Id $tc.id -Fields @{ 'System.Title' = $tc.title }
}

$text = Read-AdoJsonUtf8 -Path ./notes.json -Raw
```

A UTF-8 BOM is stripped; `ConvertFrom-Json` rejects it otherwise.

---

## `Test-AdoSignInResponse`

Whether a response is an ADO sign-in page rather than the resource that was requested.

`Invoke-AdoRequest` calls this on every response, so most callers never need it directly. It is
exposed for code that reaches ADO through its own HTTP path.

When the PAT is missing, expired, or scoped for a different organisation, ADO does not always
answer `401` - it can return the interactive sign-in page with **HTTP 200**. Parsed as JSON that
becomes an object with none of the expected properties, and the real failure surfaces much later
as an opaque StrictMode error about a missing member.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Response` | Yes | The value returned by `Invoke-RestMethod`. May be `$null` |

```powershell
$r = Invoke-RestMethod -Uri $customUri -Headers (New-AdoHeaders)
if (Test-AdoSignInResponse -Response $r) {
    throw 'Authentication failed - check ADO_PAT, ADO_ORG and ADO_PROJECT.'
}
```

A payload carrying any of `id`, `value`, `count`, `fields`, `workItems`, or `name` is treated as
genuine, so an unusual but legitimate response is not misread as an authentication failure.

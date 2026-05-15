# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

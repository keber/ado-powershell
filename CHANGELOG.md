# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- `New-AdoTestCase`: new optional parameter `-ExpectedResult` — plain-text expected result applied to the last step.

### Changed
- `New-AdoTestCase`: the last step in `-Steps` is now emitted as `ValidateStep` (previously all steps were `ActionStep`). The `<description/>` element is now included in every step for consistency with the ADO format.

---

## [1.2.0] - 2026-05-14

_Initial public release._

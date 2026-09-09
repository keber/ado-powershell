# Deferred work

Items identified during the 2026-09-09 promotion pass and explicitly left out of scope.
Each entry records what it is, why it was deferred, and what would need to be true to take it on.

---

## 1. Unit tests for the skill scripts

**What.** The skill ships no automated tests. Correctness today rests on
`assets/smoke-test.ps1`, which validates live connectivity and PAT permissions against a real
Azure DevOps organisation — it is a connectivity check, not a regression suite.

**Why deferred.** Meaningful coverage requires mocking `Invoke-RestMethod` / `Invoke-WebRequest`,
which is a project of its own rather than a step inside a promotion pass.

**What it would take.** Pester plus a fake HTTP layer. Two candidate seams already exist:
every request funnels through `Invoke-AdoRequest` in `scripts/ado-base.ps1`, and `ado-qa` already
carries a working `Export-ScriptFunctions` harness under
`.github/skills/ado-qa/assets/*/tests/_support/` that solves the same dot-sourcing problem.

**Worth covering first**, in rough order of risk:
- request-level behaviour in `Invoke-AdoRequest` — retry on 429/503, the non-retrying 400/404
  paths, and header construction
- `Get-AdoWorkItemsBatch` chunking, if the 200-item limit is ever enforced (see item 3)
- JSON-patch body shape in the write functions — `ConvertTo-Json` collapsing a single-element
  array has already caused a defect here (fixed in 1.3.1)

---

## 2. Generic work item read protocol

**What.** A rule stating what an agent must have read before it is entitled to state a conclusion
about a work item — that title plus state is not enough to decide "already built", "not covered",
"process gap", or any similar verdict. The full read is: title, state **and reason**, the complete
`System.Description`, every embedded image, comments, and the parent/child hierarchy.

**Origin.** A confirmed methodology failure in QA_Sispro_Exportadora (2026-07-24). Tasks 20071 and
20072 were classified as gaps based on title, state, and changed date alone. Their descriptions —
specifically the mockups embedded in them — showed both were new sections on an existing screen,
not new screens. The classification method had been checking the wrong thing.

The protocol was written up as a project-local standard at
`QA_Sispro_Exportadora/qa/00-standards/ado-workitem-full-read-protocol.md`.

**Why this repo.** That project also patched its own copy of `references/workitems.md` with a
callout pointing at the standard. The pointer is a project-local path: it breaks in any other
repository that installs the skill. Someone needed the protocol to live in the skill and had
nowhere to put it.

**Why deferred.** Two open design questions, neither mechanical:

- *Capability versus policy.* This skill documents what the API can do. A rule about what an agent
  must read before concluding something is QA policy. A generic mechanism (how to reach embedded
  images, how to walk the hierarchy) clearly belongs here; the blocking rule that an agent must do
  so before writing a verdict may belong in the QA layer.
- *How much of the cache convention generalises.* The source protocol prescribes a cache layout
  under `qa/00-standards/rag-v1/ado-workitems-cache/{id}/`, which is a project path this skill
  cannot prescribe. The proposal that raised this also suggested a per-image textual description
  (`inline-N.description.md`) so a visual read leaves a searchable artifact.

**Related, and named by the source protocol as out of scope there too:** there is no content hash
to tell whether a re-fetch actually changed anything. State or ChangedDate churn — a Closed
transition, say — should not force a re-read.

**Source proposal.** `qa-framework/temp/ADO-FIXES-ado-powershell.md`. Its item 1 (adding User Story
to a type enumeration) does not apply to this repo as written: the enumeration it patches lives in
the project-local standard, not here. The durable rule is the hierarchical one — a parent must be
read as fully as the child — which covers every work item type without enumerating any.

---

## 3. `Get-AdoWorkItemsBatch` 200-item chunking

**What.** `Get-AdoWorkItemsBatch` documents a 200-item limit in its synopsis but does not enforce
it, and `Invoke-AdoWiql` (`scripts/ado-workitems.ps1:157`) forwards every id from the WIQL result
in a single call. With `-Top` above 200, Azure DevOps rejects the request with HTTP 400.

**Why deferred.** Scope decision: current usage stays under the limit, and the QA projects that do
exceed it already chunk on their own — `export-wiql-workitems-csv.ps1`,
`republish-sprint16-testcase-titles.ps1`, and `fix-sprint16-duplicate-testcases.ps1` each implement
it independently.

**What it would take.** Chunk inside `Get-AdoWorkItemsBatch` so both entry points are fixed
transparently, with no signature change. Roughly eight lines. Pairs naturally with item 1, since
chunk-boundary behaviour is exactly what a test should pin down.

---

## 4. `Repair-AdoMojibakeText`

**What.** Re-decodes text that was written as UTF-8 and read back as CP1252 — the `botÃ³n` class of
corruption in work item titles. Implemented in
`QA_PortalProveedores/qa/08-azure-integration/scripts/fix-titles-encoding.ps1:34-46`.

**Why deferred.** It is not idempotent in practice. It ran twice over the same data and corrupted
137 titles, which required writing `recover-tc-titles.ps1` to undo. A function that damages data
is not promoted because the underlying problem is common.

**What it would take.** Strict mojibake detection — convert only on evidence of a typical sequence
(`Ã[\x80-\xBF]`, `Â.`, `â€`) rather than on a general re-decode — plus `-WhatIf` on by default, and
tests over a corpus that includes already-clean text.

**Note.** `Read-AdoJsonUtf8` (in scope for this pass) attacks the cause: reading local JSON with an
explicit UTF-8 encoding instead of the PS 5.1 ANSI codepage default. Prevention is the better half
of this problem; `Repair-AdoMojibakeText` only cleans up after it.

---

## 5. Priority map as configurable convention

**What.** `$priorityMap = @{ P0='1'; P1='2'; ... }` appears in three project scripts.

**Why deferred.** It is a Garcés Fruit convention, not Azure DevOps semantics. If it lands anywhere
it is configuration, not a function.

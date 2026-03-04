# Endpoint Reference — Azure DevOps REST API v7.1

> Base URL: `https://dev.azure.com/{org}`  
> Authentication: `Authorization: Basic base64(:PAT)`  
> All URLs require `?api-version=7.1` (or `7.1-preview.N` where indicated).

---

## Organization and projects

| Operation | Method | Path |
|-----------|--------|------|
| List projects | GET | `/_apis/projects` |
| List teams | GET | `/_apis/projects/{project}/teams` |

---

## Work Items

| Operation | Method | Path | Content-Type |
|-----------|--------|------|-------------|
| Get WI by ID | GET | `/{project}/_apis/wit/workitems/{id}?$expand=All` | — |
| Get WI (batch) | POST | `/{project}/_apis/wit/workitemsbatch` | `application/json` |
| Run WIQL | POST | `/{project}/_apis/wit/wiql?$top=N` | `application/json` |
| Get comments | GET | `/{project}/_apis/wit/workitems/{id}/comments` | — |
| Get revisions | GET | `/{project}/_apis/wit/workitems/{id}/revisions` | — |
| **Create WI** | POST | `/{project}/_apis/wit/workitems/${type}` | `application/json-patch+json` |
| **Update WI** | PATCH | `/{project}/_apis/wit/workitems/{id}` | `application/json-patch+json` |
| **Add comment** | POST | `/{project}/_apis/wit/workitems/{id}/comments` (`7.1-preview.3`) | `application/json` |
| **Upload attachment** | POST | `/{project}/_apis/wit/attachments?fileName={name}` | `application/octet-stream` |
| **Attach to WI** | PATCH | `/{project}/_apis/wit/workitems/{id}` | `application/json-patch+json` |

### Common link types (LinkType)

| LinkType | Description |
|----------|-------------|
| `System.LinkTypes.Hierarchy-Forward` | Parent includes child |
| `System.LinkTypes.Related` | Related to |
| `System.LinkTypes.Duplicate-Forward` | Duplicate of |
| `Microsoft.VSTS.Common.TestedBy-Forward` | User Story tested by Test Case |
| `Microsoft.VSTS.Common.Affects-Forward` | Affects |

---

## Iterations / Sprints

| Operation | Method | Path |
|-----------|--------|------|
| List iterations | GET | `/{project}/{team}/_apis/work/teamsettings/iterations?$timeframe=current\|past\|future` |

---

## Test Plans, Suites and Cases

| Operation | Method | Path |
|-----------|--------|------|
| List Test Plans | GET | `/{project}/_apis/testplan/plans` |
| Get Test Plan | GET | `/{project}/_apis/testplan/plans/{planId}` |
| List Test Suites | GET | `/{project}/_apis/testplan/plans/{planId}/suites` |
| List Test Cases | GET | `/{project}/_apis/testplan/plans/{planId}/suites/{suiteId}/testcase` |
| **Create Test Plan** | POST | `/{project}/_apis/testplan/plans` |
| **Create Test Suite** | POST | `/{project}/_apis/testplan/plans/{planId}/suites` |
| **Add TC to Suite** | POST | `/{project}/_apis/testplan/plans/{planId}/suites/{suiteId}/testcase` |
| **Create Test Case** | POST | `/{project}/_apis/wit/workitems/$Test Case` (`application/json-patch+json`) |
| **Create Test Run** | POST | `/{project}/_apis/test/runs` |
| List Test Runs | GET | `/{project}/_apis/test/runs?$top=N&planId={id}` |
| Get Run results | GET | `/{project}/_apis/test/runs/{runId}/results?$top=N` |
| **Publish results** | POST | `/{project}/_apis/test/runs/{runId}/results` |

---

## Git Repositories

| Operation | Method | Path |
|-----------|--------|------|
| List repositories | GET | `/{project}/_apis/git/repositories` |
| List branches | GET | `/{project}/_apis/git/repositories/{repoId}/refs?filter=heads/` |

---

## Pipelines

| Operation | Method | Path |
|-----------|--------|------|
| List pipelines | GET | `/{project}/_apis/pipelines` |
| Pipeline runs | GET | `/{project}/_apis/pipelines/{pipelineId}/runs?$top=N` |
| **Trigger pipeline run** | POST | `/{project}/_apis/pipelines/{pipelineId}/runs` |

---

## JSON Patch format (write operations)

Write operations on Work Items use the [RFC 6902 JSON Patch](https://tools.ietf.org/html/rfc6902) standard:

```json
[
  { "op": "add",     "path": "/fields/System.Title",  "value": "New title" },
  { "op": "replace", "path": "/fields/System.State",  "value": "Active" },
  { "op": "add",     "path": "/relations/-",           "value": { "rel": "...", "url": "..." } }
]
```

- `add` — for new fields or relations.
- `replace` — for fields that already exist on the Work Item.
- `remove` — to delete a field or relation (use `path` with index for relations).

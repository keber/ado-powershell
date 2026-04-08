# ado-powershell

An AI agent skill that enables GitHub Copilot, Claude Code, and other compatible agents to interact with the **Azure DevOps REST API** using PowerShell - covering Work Items, Test Plans, Pipelines, Git repositories, and more.

---

## Installation

Install the CLI globally from npm:

```sh
npm install -g ado-powershell
```

Then, inside any project where you want the skill available to your AI agent:

```sh
cd your-project
adops install --skills
```

This copies the skill files into `.github/skills/ado-powershell/` in your project. GitHub Copilot and Claude Code will discover and use them automatically.

---

## Requirements

- **Node.js** 16+ (for the CLI)
- **PowerShell** 7+ or Windows PowerShell 5.1 (for the skill scripts)
- An **Azure DevOps Personal Access Token (PAT)** with permissions matching the operations you need

---

## Configuration

Set these environment variables before the agent runs the skill:

```powershell
$env:ADO_ORG     = 'my-organization'
$env:ADO_PROJECT = 'my-project'
$env:ADO_PAT     = 'your-pat-here'   # never hardcode; read from a secret store
```

Alternatively, pass values explicitly to `Initialize-AdoSession`, or point it to a JSON config file. See the skill's [SKILL.md](.github/skills/ado-powershell/SKILL.md) for the full resolution order.

---

## What the skill provides

Once installed, the agent gets access to the following PowerShell functions:

| Domain | Functions |
|--------|-----------|
| **Work Items** | Get, batch-get, WIQL query, create, update, comment, link, attach files |
| **Testing** | Test Plans, Suites, Cases, Runs, Results (read and write) |
| **Pipelines** | List pipelines, list and filter runs, trigger a run |
| **Git** | Repositories, branches, team iterations/sprints |

All write functions support `-WhatIf` for dry-run simulation. Full parameter documentation and examples are in the [references](.github/skills/ado-powershell/references/) folder.

---

## Skill structure

```
.github/skills/ado-powershell/
  SKILL.md              # Agent entry point - quick-lookup index
  load.ps1              # Single dot-source to load all functions
  scripts/
    ado-base.ps1        # Auth, session management, HTTP core
    ado-workitems.ps1   # Work Item CRUD, WIQL, links, attachments
    ado-testing.ps1     # Test Plans, Suites, Cases, Runs, Results
    ado-pipelines.ps1   # Pipelines: list, runs, trigger
    ado-git.ps1         # Repositories, branches, iterations
  references/
    workitems.md        # Full parameter docs + examples
    testing.md
    pipelines.md
    git.md
    endpoints.md        # ADO API v7.1 endpoint reference
    errors.md           # HTTP errors and PAT permission matrix
  assets/
    smoke-test.ps1      # Connectivity and permission validation script
```

---

## Validating the installation

After installing the skill, the agent can run the smoke test to verify connectivity and PAT permissions:

```powershell
. .github/skills/ado-powershell/assets/smoke-test.ps1
```

---

## License

MIT

#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for issue #13: Invoke-AdoWiql must handle workItemRelations. Mocks only.

BeforeAll {
    $script:ScriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    . (Join-Path $script:ScriptsDir 'ado-base.ps1')
    . (Join-Path $script:ScriptsDir 'ado-workitems.ps1')
    $script:AdoSession = [pscustomobject]@{
        Org = 'fakeorg'; Project = 'fakeproj'; ApiV = '7.1'
        BaseUrl = 'https://dev.azure.com/fakeorg'
        Headers = @{ Authorization = 'Basic ZmFrZQ==' }
    }
    $script:FakeHeaders = @{ Authorization = 'Basic ZmFrZQ==' }
}

Describe 'M6 - Invoke-AdoWiql ignores workItemRelations (link/tree queries)' {
    BeforeAll { Mock Start-Sleep { } }

    It 'returns the ids of a WorkItemLinks query, handling roots with null source' {
        Mock Invoke-AdoRequest {
            [pscustomobject]@{
                queryType         = 'tree'
                workItemRelations = @(
                    [pscustomobject]@{ rel = $null; source = $null; target = [pscustomobject]@{ id = 10 } },
                    [pscustomobject]@{ rel = 'System.LinkTypes.Hierarchy-Forward'
                                       source = [pscustomobject]@{ id = 10 }
                                       target = [pscustomobject]@{ id = 11 } }
                )
            }
        }
        $ids = Invoke-AdoWiql -Query 'SELECT [System.Id] FROM WorkItemLinks MODE (Recursive)' `
                    -IdsOnly -Headers $script:FakeHeaders
        @($ids) | Should -Be @(10, 11)
    }

    It 'removes duplicate ids and preserves first-seen order' {
        Mock Invoke-AdoRequest {
            [pscustomobject]@{
                workItemRelations = @(
                    [pscustomobject]@{ rel = $null; source = $null; target = [pscustomobject]@{ id = 30 } },
                    [pscustomobject]@{ rel = 'r'; source = [pscustomobject]@{ id = 30 }; target = [pscustomobject]@{ id = 20 } },
                    [pscustomobject]@{ rel = 'r'; source = [pscustomobject]@{ id = 30 }; target = [pscustomobject]@{ id = 40 } },
                    [pscustomobject]@{ rel = 'r'; source = [pscustomobject]@{ id = 20 }; target = [pscustomobject]@{ id = 40 } }
                )
            }
        }
        $ids = Invoke-AdoWiql -Query 'SELECT [System.Id] FROM WorkItemLinks' -IdsOnly -Headers $script:FakeHeaders
        @($ids) | Should -Be @(30, 20, 40)
    }

    It 'keeps the flat workItems behaviour unchanged' {
        Mock Invoke-AdoRequest {
            [pscustomobject]@{ workItems = @([pscustomobject]@{ id = 5 }, [pscustomobject]@{ id = 3 }) }
        }
        $ids = Invoke-AdoWiql -Query 'SELECT [System.Id] FROM WorkItems' -IdsOnly -Headers $script:FakeHeaders
        @($ids) | Should -Be @(5, 3)
    }

    It 'returns an empty array when neither workItems nor workItemRelations is present' {
        Mock Invoke-AdoRequest { [pscustomobject]@{ queryType = 'flat' } }
        $ids = Invoke-AdoWiql -Query 'SELECT [System.Id] FROM WorkItems' -IdsOnly -Headers $script:FakeHeaders
        @($ids).Count | Should -Be 0
    }
}

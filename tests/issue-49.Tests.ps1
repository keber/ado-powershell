#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for issue #49: Invoke-AdoWiql, Get-AdoWorkItemsBatch, Get-AdoInlineImageUrl and
# Save-AdoInlineImage must emit their elements to the pipeline (empty result = no output) instead of
# a single nested array, so @(...), Measure-Object, Select-Object and chaining all work.
# Mocked HTTP only; no network access.

BeforeAll {
    $script:ScriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    . (Join-Path $script:ScriptsDir 'ado-base.ps1')
    . (Join-Path $script:ScriptsDir 'ado-workitems.ps1')
    . (Join-Path $script:ScriptsDir 'ado-content.ps1')
    $script:AdoSession = [pscustomobject]@{
        Org = 'fakeorg'; Project = 'fakeproj'; ApiV = '7.1'
        BaseUrl = 'https://dev.azure.com/fakeorg'
        Headers = @{ Authorization = 'Basic ZmFrZQ==' }
    }
    $script:FakeHeaders = @{ Authorization = 'Basic ZmFrZQ==' }
    $script:QueryText = 'SELECT [System.Id] FROM WorkItems'

    # WIQL answers with the ids in $script:WiqlIds; workitemsbatch echoes one item per requested id.
    function script:Initialize-Fake([int[]]$WiqlIds) {
        $script:WiqlIds = $WiqlIds
        Mock Invoke-AdoRequest {
            if ([string]$Uri -like '*/wit/wiql*') {
                return [pscustomobject]@{ workItems = @($script:WiqlIds | ForEach-Object { [pscustomobject]@{ id = $_ } }) }
            }
            $ids = @(($Body | ConvertFrom-Json).ids)
            [pscustomobject]@{ count = $ids.Count
                               value = @($ids | ForEach-Object { [pscustomobject]@{ id = $_; fields = [pscustomobject]@{ 'System.Title' = "T$_" } } }) }
        }
    }

    function script:New-Html([int]$N) {
        -join (1..$N | ForEach-Object { '<img src="data:image/png;base64,QUJD">' })
    }
}

Describe 'Get-AdoWorkItemsBatch emits to the pipeline' {
    BeforeAll { Mock Start-Sleep { } }
    BeforeEach { Initialize-Fake @() }

    It 'emits nothing for an empty -Ids' {
        $r = Get-AdoWorkItemsBatch -Ids @() -Headers $script:FakeHeaders
        $null -eq $r | Should -BeTrue
        @(Get-AdoWorkItemsBatch -Ids @() -Headers $script:FakeHeaders).Count | Should -Be 0
        (Get-AdoWorkItemsBatch -Ids @() -Headers $script:FakeHeaders | Measure-Object).Count | Should -Be 0
    }

    It 'handles <N> id(s) with @(), Measure-Object, Select-Object and .Count' -ForEach @(
        @{ N = 1 }, @{ N = 3 }
    ) {
        $ids = 1..$N
        @(Get-AdoWorkItemsBatch -Ids $ids -Headers $script:FakeHeaders).Count | Should -Be $N
        (Get-AdoWorkItemsBatch -Ids $ids -Headers $script:FakeHeaders | Measure-Object).Count | Should -Be $N
        $rows = @(Get-AdoWorkItemsBatch -Ids $ids -Headers $script:FakeHeaders | Select-Object id, @{ n = 'Title'; e = { $_.fields.'System.Title' } })
        $rows.Count | Should -Be $N
        $rows[0].id    | Should -Be 1
        $rows[0].Title | Should -Be 'T1'
        $x = Get-AdoWorkItemsBatch -Ids $ids -Headers $script:FakeHeaders
        @($x).Count | Should -Be $N
    }

    It 'returns individual items, not one nested array' {
        $first = Get-AdoWorkItemsBatch -Ids 1, 2, 3 -Headers $script:FakeHeaders | Select-Object -First 1
        $first.id | Should -Be 1
        $first -is [array] | Should -BeFalse
    }
}

Describe 'Invoke-AdoWiql emits to the pipeline' {
    BeforeAll { Mock Start-Sleep { } }

    Context 'full items' {
        It '0 matches: no output, @() and Measure-Object report 0' {
            Initialize-Fake @()
            $null -eq (Invoke-AdoWiql -Query $script:QueryText -Headers $script:FakeHeaders) | Should -BeTrue
            @(Invoke-AdoWiql -Query $script:QueryText -Headers $script:FakeHeaders).Count | Should -Be 0
            (Invoke-AdoWiql -Query $script:QueryText -Headers $script:FakeHeaders | Measure-Object).Count | Should -Be 0
        }

        It '<N> match(es): @(), Measure-Object, Select-Object see every item' -ForEach @(
            @{ N = 1 }, @{ N = 4 }
        ) {
            Initialize-Fake (1..$N)
            @(Invoke-AdoWiql -Query $script:QueryText -Headers $script:FakeHeaders).Count | Should -Be $N
            (Invoke-AdoWiql -Query $script:QueryText -Headers $script:FakeHeaders | Measure-Object).Count | Should -Be $N
            $rows = @(Invoke-AdoWiql -Query $script:QueryText -Headers $script:FakeHeaders | Select-Object id)
            $rows.Count | Should -Be $N
            $rows[0].id | Should -Be 1
        }
    }

    Context '-IdsOnly' {
        It '0 matches: no output' {
            Initialize-Fake @()
            $null -eq (Invoke-AdoWiql -Query $script:QueryText -IdsOnly -Headers $script:FakeHeaders) | Should -BeTrue
            @(Invoke-AdoWiql -Query $script:QueryText -IdsOnly -Headers $script:FakeHeaders).Count | Should -Be 0
            (Invoke-AdoWiql -Query $script:QueryText -IdsOnly -Headers $script:FakeHeaders | Measure-Object).Count | Should -Be 0
        }

        It 'a missing workItems property (nothing matched) also emits nothing' {
            Mock Invoke-AdoRequest { [pscustomobject]@{ queryType = 'flat' } }
            @(Invoke-AdoWiql -Query $script:QueryText -IdsOnly -Headers $script:FakeHeaders).Count | Should -Be 0
            @(Invoke-AdoWiql -Query $script:QueryText -Headers $script:FakeHeaders).Count | Should -Be 0
        }

        It '<N> match(es): integers are emitted one by one' -ForEach @(
            @{ N = 1 }, @{ N = 5 }
        ) {
            Initialize-Fake (1..$N)
            $r = @(Invoke-AdoWiql -Query $script:QueryText -IdsOnly -Headers $script:FakeHeaders)
            $r.Count | Should -Be $N
            $r[0] -is [int] | Should -BeTrue
            (Invoke-AdoWiql -Query $script:QueryText -IdsOnly -Headers $script:FakeHeaders | Measure-Object).Count | Should -Be $N
            (Invoke-AdoWiql -Query $script:QueryText -IdsOnly -Headers $script:FakeHeaders | Select-Object -First 1) | Should -Be 1
        }
    }

    Context 'chaining -IdsOnly into Get-AdoWorkItemsBatch -Ids' {
        It 'works with <N> id(s) through -Ids @(...)' -ForEach @(
            @{ N = 1 }, @{ N = 3 }
        ) {
            Initialize-Fake (1..$N)
            $ids   = Invoke-AdoWiql -Query $script:QueryText -IdsOnly -Headers $script:FakeHeaders
            $items = @(Get-AdoWorkItemsBatch -Ids @($ids) -Headers $script:FakeHeaders)
            $items.Count | Should -Be $N
            @($items | ForEach-Object { $_.id }) | Should -Be @(1..$N)
        }

        It 'accepts the result inline: -Ids @(Invoke-AdoWiql ... -IdsOnly)' {
            Initialize-Fake @(7, 8, 9)
            $items = @(Get-AdoWorkItemsBatch -Ids @(Invoke-AdoWiql -Query $script:QueryText -IdsOnly -Headers $script:FakeHeaders) -Headers $script:FakeHeaders)
            @($items | ForEach-Object { $_.id }) | Should -Be @(7, 8, 9)
        }

        It 'chaining an empty WIQL result yields an empty batch without calling the batch endpoint' {
            Initialize-Fake @()
            $items = @(Get-AdoWorkItemsBatch -Ids @(Invoke-AdoWiql -Query $script:QueryText -IdsOnly -Headers $script:FakeHeaders) -Headers $script:FakeHeaders)
            $items.Count | Should -Be 0
            Should -Invoke Invoke-AdoRequest -Times 1 -Exactly -ParameterFilter { [string]$Uri -like '*/wit/wiql*' }
            Should -Invoke Invoke-AdoRequest -Times 0 -Exactly -ParameterFilter { [string]$Uri -like '*workitemsbatch*' }
        }
    }
}

Describe 'Get-AdoInlineImageUrl emits to the pipeline' {
    It 'emits nothing for <Case>' -ForEach @(
        @{ Case = 'null HTML';  Html = $null }
        @{ Case = 'empty HTML'; Html = '' }
        @{ Case = 'no images';  Html = '<p>hello</p>' }
    ) {
        $null -eq (Get-AdoInlineImageUrl -Html $Html) | Should -BeTrue
        @(Get-AdoInlineImageUrl -Html $Html).Count | Should -Be 0
        (Get-AdoInlineImageUrl -Html $Html | Measure-Object).Count | Should -Be 0
    }

    It 'emits one string for a single image (not a nested array)' {
        $r = Get-AdoInlineImageUrl -Html '<img src="https://dev.azure.com/o/a.png">'
        $r | Should -BeExactly 'https://dev.azure.com/o/a.png'
        @(Get-AdoInlineImageUrl -Html '<img src="https://dev.azure.com/o/a.png">').Count | Should -Be 1
    }

    It 'emits each URL for N images, in document order' {
        $html = '<img src="https://dev.azure.com/o/a.png"><img src="https://dev.azure.com/o/b.png"><img src="https://dev.azure.com/o/c.png">'
        $r = @(Get-AdoInlineImageUrl -Html $html)
        $r.Count | Should -Be 3
        $r[2] | Should -BeExactly 'https://dev.azure.com/o/c.png'
        (Get-AdoInlineImageUrl -Html $html | Measure-Object).Count | Should -Be 3
        (Get-AdoInlineImageUrl -Html $html | Select-Object -First 1) | Should -BeExactly 'https://dev.azure.com/o/a.png'
    }
}

Describe 'Save-AdoInlineImage emits to the pipeline' {
    It 'emits nothing when there is no image' {
        $dir = Join-Path $TestDrive 'none'
        $null -eq (Save-AdoInlineImage -Html '<p>x</p>' -OutDirectory $dir -Headers $script:FakeHeaders) | Should -BeTrue
        @(Save-AdoInlineImage -Html '<p>x</p>' -OutDirectory $dir -Headers $script:FakeHeaders).Count | Should -Be 0
        (Save-AdoInlineImage -Html '<p>x</p>' -OutDirectory $dir -Headers $script:FakeHeaders | Measure-Object).Count | Should -Be 0
        Test-Path -LiteralPath $dir | Should -BeFalse
    }

    It 'emits nothing under -WhatIf when the directory would be created' {
        $dir = Join-Path $TestDrive 'whatif'
        @(Save-AdoInlineImage -Html (New-Html 1) -OutDirectory $dir -Headers $script:FakeHeaders -WhatIf).Count | Should -Be 0
    }

    It 'emits <N> path(s) as strings, countable with @() and Measure-Object' -ForEach @(
        @{ N = 1 }, @{ N = 3 }
    ) {
        $dir = Join-Path $TestDrive "n$N"
        $r   = @(Save-AdoInlineImage -Html (New-Html $N) -OutDirectory $dir -Headers $script:FakeHeaders)
        $r.Count | Should -Be $N
        $r[0] -is [string] | Should -BeTrue
        Test-Path -LiteralPath $r[0] | Should -BeTrue
        $dir2 = Join-Path $TestDrive "m$N"
        (Save-AdoInlineImage -Html (New-Html $N) -OutDirectory $dir2 -Headers $script:FakeHeaders | Measure-Object).Count | Should -Be $N
        $dir3 = Join-Path $TestDrive "s$N"
        (Save-AdoInlineImage -Html (New-Html $N) -OutDirectory $dir3 -Headers $script:FakeHeaders | Select-Object -First 1) | Should -BeLike '*-1.png'
    }
}

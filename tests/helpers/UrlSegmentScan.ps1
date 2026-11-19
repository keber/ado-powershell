# Shared AST scanner for issue #41: finds free-text values (project, team, repository, work item
# type, label name, reviewer id) placed raw into a URL-like string. Dot-sourced by
# tests/issue-41.Tests.ps1 and tests/issue-41.validation.Tests.ps1. Not a test file itself.
#
# A value is "raw" when it reaches the string without going through an escaping call such as
# [Uri]::EscapeDataString / ConvertTo-AdoPathSegment / Get-AdoProjectUrl. Detected shapes:
#   "...$Project..."  "...$($Project)..."  "...$($Project.Trim())..."  "...$($x.Project)..."
#   "...$($AdoSession['Project'])..."  "{0}/{1}" -f $a, $Project  "a/" + $Project
#   and simple aliases: $p = $Project; "...$p..."
# A string counts as URL-like when its literal text contains '/'.

function Get-AdoRawSegmentNames { @('Project', 'Team', 'RepoId', 'Type', 'Name', 'ReviewerId') }

function Get-AdoRawSegmentBaseName {
    param([System.Management.Automation.Language.VariableExpressionAst]$Variable)
    return ($Variable.VariablePath.UserPath -replace '^(script|global|local|private):', '')
}

function Test-AdoRawSegment {
    <# True when the expression yields a tracked free-text value without escaping it. #>
    param($Expr, [string[]]$Names)
    if ($null -eq $Expr) { return $false }

    if ($Expr -is [System.Management.Automation.Language.VariableExpressionAst]) {
        return ((Get-AdoRawSegmentBaseName $Expr) -in $Names)
    }
    # Method call: raw only when invoked on a raw value ($Project.Trim()); a static call on a
    # type ([Uri]::EscapeDataString($Project)) is an escaping call and therefore safe.
    if ($Expr -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
        return (Test-AdoRawSegment $Expr.Expression $Names)
    }
    if ($Expr -is [System.Management.Automation.Language.MemberExpressionAst]) {
        if ($Expr.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $Expr.Member.Value -eq 'Project' -and -not $Expr.Static) { return $true }
        return (Test-AdoRawSegment $Expr.Expression $Names)
    }
    if ($Expr -is [System.Management.Automation.Language.IndexExpressionAst]) {
        if ($Expr.Index -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $Expr.Index.Value -eq 'Project') { return $true }
        return (Test-AdoRawSegment $Expr.Target $Names)
    }
    if ($Expr -is [System.Management.Automation.Language.ConvertExpressionAst]) {
        return (Test-AdoRawSegment $Expr.Child $Names)
    }
    if ($Expr -is [System.Management.Automation.Language.SubExpressionAst] -or
        $Expr -is [System.Management.Automation.Language.ParenExpressionAst]) {
        $stmts = if ($Expr -is [System.Management.Automation.Language.SubExpressionAst]) {
            @($Expr.SubExpression.Statements)
        } else { @($Expr.Pipeline) }
        if ($stmts.Count -eq 1 -and $stmts[0] -is [System.Management.Automation.Language.PipelineAst]) {
            $els = @($stmts[0].PipelineElements)
            if ($els.Count -eq 1 -and $els[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
                return (Test-AdoRawSegment $els[0].Expression $Names)
            }
        }
        return $false
    }
    return $false
}

function Get-AdoPlusOperands {
    param($Expr)
    if ($Expr -is [System.Management.Automation.Language.BinaryExpressionAst] -and
        $Expr.Operator -eq [System.Management.Automation.Language.TokenKind]::Plus) {
        return @(Get-AdoPlusOperands $Expr.Left) + @(Get-AdoPlusOperands $Expr.Right)
    }
    if ($Expr -is [System.Management.Automation.Language.ParenExpressionAst]) {
        $p = $Expr.Pipeline
        if ($p -is [System.Management.Automation.Language.PipelineAst] -and @($p.PipelineElements).Count -eq 1 -and
            $p.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst] -and
            $p.PipelineElements[0].Expression -is [System.Management.Automation.Language.BinaryExpressionAst] -and
            $p.PipelineElements[0].Expression.Operator -eq [System.Management.Automation.Language.TokenKind]::Plus) {
            return @(Get-AdoPlusOperands $p.PipelineElements[0].Expression)
        }
    }
    return , $Expr
}

function Test-AdoSlashString {
    param($Expr)
    return (($Expr -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
             $Expr -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and
            $Expr.Value -like '*/*')
}

function Find-RawUrlInterpolation {
    <# Returns "line N: <text>" for every URL-like string that receives a raw free-text value. #>
    param([Parameter(Mandatory)]$Ast)

    # Aliases: $x = <raw value>  makes $x raw too (repeat until stable).
    $names = [System.Collections.Generic.List[string]]::new()
    Get-AdoRawSegmentNames | ForEach-Object { $names.Add($_) }
    $assigns = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))
    do {
        $added = $false
        foreach ($a in $assigns) {
            if ($a.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            $right = $a.Right
            if ($right -isnot [System.Management.Automation.Language.CommandExpressionAst]) { continue }
            $n = Get-AdoRawSegmentBaseName $a.Left
            if ($n -notin $names -and (Test-AdoRawSegment $right.Expression $names.ToArray())) {
                $names.Add($n); $added = $true
            }
        }
    } while ($added)
    $nameArr = $names.ToArray()

    $hits = [System.Collections.Generic.List[object]]::new()

    # 1. Expandable strings: "...$Project/..." with a '/' in the literal text.
    foreach ($s in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)) {
        if ($s.Value -notlike '*/*') { continue }
        if (@($s.NestedExpressions | Where-Object { Test-AdoRawSegment $_ $nameArr }).Count -gt 0) { $hits.Add($s) }
    }

    foreach ($b in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true)) {
        # 2. Format operator: '{0}/{1}' -f $a, $Project
        if ($b.Operator -eq [System.Management.Automation.Language.TokenKind]::Format) {
            if (-not (Test-AdoSlashString $b.Left)) { continue }
            $args2 = if ($b.Right -is [System.Management.Automation.Language.ArrayLiteralAst]) { @($b.Right.Elements) } else { @($b.Right) }
            if (@($args2 | Where-Object { Test-AdoRawSegment $_ $nameArr }).Count -gt 0) { $hits.Add($b) }
            continue
        }
        # 3. Concatenation chain: 'a/' + $Project (reported once, at the outermost '+').
        if ($b.Operator -eq [System.Management.Automation.Language.TokenKind]::Plus) {
            $parent = $b.Parent
            while ($parent -is [System.Management.Automation.Language.CommandExpressionAst] -or
                   $parent -is [System.Management.Automation.Language.PipelineAst] -or
                   $parent -is [System.Management.Automation.Language.ParenExpressionAst]) { $parent = $parent.Parent }
            if ($parent -is [System.Management.Automation.Language.BinaryExpressionAst] -and
                $parent.Operator -eq [System.Management.Automation.Language.TokenKind]::Plus) { continue }
            $ops = @(Get-AdoPlusOperands $b)
            if (@($ops | Where-Object { Test-AdoSlashString $_ }).Count -gt 0 -and
                @($ops | Where-Object { Test-AdoRawSegment $_ $nameArr }).Count -gt 0) { $hits.Add($b) }
        }
    }

    return @($hits | Sort-Object { $_.Extent.StartOffset } -Unique |
        ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Extent.Text)" })
}

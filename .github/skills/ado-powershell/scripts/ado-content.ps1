<#
.SYNOPSIS
  Work Item content helpers: HTML fields and the images embedded in them.
  Dot-source ado-base.ps1 before this file.

.USAGE
  . "$PSScriptRoot/ado-content.ps1"

.NOTES
  Work Item descriptions are HTML, and the UI mockups that carry the actual requirement are
  routinely embedded in that HTML as <img> tags rather than attached as files. Reading the text
  alone misses them. These helpers turn that HTML into text, and those <img> tags into local files.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region -- HTML --

function ConvertFrom-AdoHtml {
    <#
    .SYNOPSIS  Converts an ADO HTML field to plain text.

    .DESCRIPTION
      Description, ReproSteps and comment bodies are HTML. This strips the markup and decodes
      entities so the text can be searched, diffed, or written to a file.

      Block-level structure is preserved as line breaks: <br> becomes one newline, </p> and </div>
      become a blank line. Script and style blocks are dropped rather than flattened into the text.

      This is a text extractor, not an HTML parser. It is meant for reading field content, not for
      round-tripping markup.

    .PARAMETER Html  The HTML string. $null or empty returns an empty string.

    .EXAMPLE
      $wi   = Get-AdoWorkItem -Id 20071
      $text = ConvertFrom-AdoHtml (Get-AdoFieldValue -WorkItem $wi -Name 'System.Description')

    .EXAMPLE
      # Searchable plain-text copy of a description
      ConvertFrom-AdoHtml $html | Set-Content -Path ./description.txt -Encoding UTF8
    #>
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Html
    )
    if ([string]::IsNullOrEmpty($Html)) { return '' }

    $t = $Html -replace '(?is)<(script|style)[^>]*>.*?</\1>', ''
    $t = $t -replace '(?is)<br\s*/?>', "`n"
    $t = $t -replace '(?is)</(p|div|li|tr|h[1-6])>', "`n`n"
    $t = $t -replace '(?is)<[^>]+>', ''
    $t = [System.Net.WebUtility]::HtmlDecode($t)

    # &nbsp; decodes to U+00A0, which looks like a space but does not match one. Normalise it,
    # otherwise text extracted here fails a search for words a reader can plainly see.
    $t = $t -replace [char]0x00A0, ' '

    # Collapse the runs of blank lines that block-level replacement leaves behind.
    $t = $t -replace '(\r?\n[ \t]*){3,}', "`n`n"
    return $t.Trim()
}

function Get-AdoInlineImageUrl {
    <#
    .SYNOPSIS  Returns the image URLs embedded in an ADO HTML field.

    .DESCRIPTION
      Extracts the src of every <img> tag. Values are HTML-decoded, so an URL written in the markup
      as '...?fileName=a&amp;download=true' comes back with a real '&' - passing the raw attribute
      to a download would request the wrong resource.

      Both attachment URLs and inline 'data:image/...;base64,' URIs are returned; use
      Save-AdoInlineImage to write either kind to disk.

    .PARAMETER Html         The HTML string, typically System.Description or ReproSteps.
    .PARAMETER AttachmentOnly  Return only ADO attachment URLs, skipping data: URIs.

    .OUTPUTS
      [string[]] - always an array, including for zero or one match. PowerShell unrolls a
      pipeline on return, so the result is built into a typed collection and returned with a
      unary comma; a caller can rely on .Count without wrapping the call in @().

    .EXAMPLE
      $wi   = Get-AdoWorkItem -Id 20071
      $html = Get-AdoFieldValue -WorkItem $wi -Name 'System.Description'
      Get-AdoInlineImageUrl -Html $html
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Html,

        [switch]$AttachmentOnly
    )
    $out = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Html)) { return , $out.ToArray() }

    $rx = [regex]'(?is)<img[^>]+?src\s*=\s*["'']([^"''>]+)["'']'
    foreach ($m in $rx.Matches($Html)) {
        $url = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
        if ($AttachmentOnly -and $url -like 'data:*') { continue }
        $out.Add($url)
    }
    # Unary comma: without it a single element returns as [string] and none as $null.
    return , $out.ToArray()
}

function Get-AdoWorkItemContentHtml {
    <#
    .SYNOPSIS  Returns the HTML field that carries a Work Item's content.

    .DESCRIPTION
      Bugs put their content in Microsoft.VSTS.TCM.ReproSteps; everything else uses
      System.Description. A Bug with empty ReproSteps falls back to Description.

      This is a convention, not an API guarantee - a team that fills in both fields, or neither,
      is not doing anything invalid. Read the field directly when the choice matters.

    .PARAMETER WorkItem  A Work Item from Get-AdoWorkItem or Get-AdoWorkItemsBatch.

    .EXAMPLE
      $html = Get-AdoWorkItemContentHtml -WorkItem $wi
      $text = ConvertFrom-AdoHtml $html
    #>
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [AllowNull()]
        [object]$WorkItem
    )
    if ($null -eq $WorkItem) { return '' }

    $type  = Get-AdoFieldValue -WorkItem $WorkItem -Name 'System.WorkItemType' -Default ''
    $desc  = Get-AdoFieldValue -WorkItem $WorkItem -Name 'System.Description'  -Default ''

    if ($type -eq 'Bug') {
        $repro = Get-AdoFieldValue -WorkItem $WorkItem -Name 'Microsoft.VSTS.TCM.ReproSteps' -Default ''
        if (-not [string]::IsNullOrWhiteSpace($repro)) { return $repro }
    }
    return $desc
}

#endregion

#region -- Attachment URLs --

function Resolve-AdoAttachmentUrl {
    <#
    .SYNOPSIS  Turns an attachment URL found in Work Item content into one that downloads.

    .DESCRIPTION
      Two adjustments, both required in practice:

      - A src attribute may be host-relative ('/org/_apis/wit/attachments/...') or omit the scheme
        entirely. Those are resolved against the session's base URL.
      - Without 'download=true' the attachments endpoint can answer with a document wrapper rather
        than the file bytes, and without an explicit api-version the request is not versioned.
        Both are appended when absent; an existing value is left alone.

    .PARAMETER Url  The URL as it appears in the HTML, or an AttachedFile relation url.

    .OUTPUTS  [string], or $null for an empty input.

    .EXAMPLE
      Resolve-AdoAttachmentUrl -Url '/contoso/_apis/wit/attachments/abc?fileName=mock.png'
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Url,

        [string]$Org  = $script:AdoSession.Org,
        [string]$ApiV = $script:AdoSession.ApiV
    )
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    if ($Url -like 'data:*') { return $Url }

    $u = $Url.Trim()
    $base = Get-AdoBaseUrl $Org

    if ($u.StartsWith('/')) {
        $u = "$base$u"
    } elseif ($u -notmatch '^https?://') {
        $u = "$base/$($u.TrimStart('/'))"
    }

    $sep = if ($u.IndexOf('?') -ge 0) { '&' } else { '?' }
    if ($u -notmatch '(?i)[?&]api-version=') { $u = "$u${sep}api-version=$ApiV"; $sep = '&' }
    if ($u -notmatch '(?i)[?&]download=')    { $u = "$u${sep}download=true" }
    return $u
}

#endregion

#region -- Downloading --

function Save-AdoInlineImage {
    <#
    .SYNOPSIS  Downloads the images embedded in a Work Item's content to a local directory.

    .DESCRIPTION
      Writes every embedded image and, with -IncludeAttachedFiles, every attached image file.
      Both attachment URLs and base64 data: URIs are handled.

      Files are named inline-1, inline-2, ... in document order, keeping the extension implied by
      the URL or data URI (png when nothing says otherwise). A zero-byte or failed download is
      removed rather than left behind as a truncated file.

      This downloads; it does not interpret. An agent still has to look at each image: a mockup is
      frequently the only place that says whether a work item describes a new screen or a section
      added to an existing one.

    .PARAMETER WorkItem     Work Item whose content is scanned. Must include fields.
    .PARAMETER Html         Scan this HTML instead of resolving it from a Work Item.
    .PARAMETER OutDirectory Destination directory. Created when missing.
    .PARAMETER BaseName     File name stem. Default: 'inline'.
    .PARAMETER IncludeAttachedFiles
                            Also download AttachedFile relations whose name looks like an image.
                            Requires -WorkItem fetched with relations (the default -Expand All).

    .OUTPUTS  [string[]] paths of the files written, in document order. Always an array.

    .EXAMPLE
      $wi = Get-AdoWorkItem -Id 20071
      $files = Save-AdoInlineImage -WorkItem $wi -OutDirectory ./cache/20071
      # then read each file - the mockups carry the requirement

    .EXAMPLE
      Save-AdoInlineImage -WorkItem $wi -OutDirectory ./cache/20071 -IncludeAttachedFiles
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByWorkItem', SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByWorkItem', Position = 0)]
        [AllowNull()]
        [object]$WorkItem,

        [Parameter(Mandatory, ParameterSetName = 'ByHtml')]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Html,

        [Parameter(Mandatory)]
        [string]$OutDirectory,

        [string]$BaseName = 'inline',
        [switch]$IncludeAttachedFiles,

        [string]$Org  = $script:AdoSession.Org,
        [string]$ApiV = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )

    $sourceHtml = if ($PSCmdlet.ParameterSetName -eq 'ByHtml') {
        $Html
    } else {
        Get-AdoWorkItemContentHtml -WorkItem $WorkItem
    }

    # Attached image files first, then images embedded in the content, both in document order.
    $urls = New-Object System.Collections.Generic.List[string]

    if ($IncludeAttachedFiles -and $PSCmdlet.ParameterSetName -eq 'ByWorkItem' -and $null -ne $WorkItem) {
        $relsProp = $WorkItem.PSObject.Properties['relations']
        if ($relsProp -and $null -ne $relsProp.Value) {
            foreach ($r in @($relsProp.Value)) {
                if ($null -eq $r) { continue }
                if ($r.rel -ne 'AttachedFile') { continue }
                $attrName = ''
                $attrProp = $r.PSObject.Properties['attributes']
                if ($attrProp -and $null -ne $attrProp.Value) {
                    $nameProp = $attrProp.Value.PSObject.Properties['name']
                    if ($nameProp) { $attrName = [string]$nameProp.Value }
                }
                if ($attrName -match '(?i)\.(png|jpe?g|gif|bmp)$') { $urls.Add([string]$r.url) }
            }
        }
    }

    foreach ($u in (Get-AdoInlineImageUrl -Html $sourceHtml)) { $urls.Add($u) }

    if ($urls.Count -eq 0) { return , ([string[]]@()) }

    if (-not (Test-Path -LiteralPath $OutDirectory)) {
        if (-not $PSCmdlet.ShouldProcess($OutDirectory, 'Create directory')) { return , ([string[]]@()) }
        $null = New-Item -ItemType Directory -Path $OutDirectory -Force
    }

    $written = New-Object System.Collections.Generic.List[string]
    $i = 0

    foreach ($url in $urls) {
        $i++
        $isData = $url -like 'data:*'
        $ext    = Get-AdoImageExtension -Url $url

        $outFile = Join-Path $OutDirectory ("{0}-{1}.{2}" -f $BaseName, $i, $ext)

        if (-not $PSCmdlet.ShouldProcess($outFile, "Save image $i of $($urls.Count)")) { continue }

        try {
            if ($isData) {
                if ($url -notmatch '^data:image/[^;]+;base64,(.+)$') {
                    Write-Warning "Image ${i}: unsupported data URI form, skipped."
                    continue
                }
                [IO.File]::WriteAllBytes($outFile, [Convert]::FromBase64String($Matches[1]))
            } else {
                $resolved = Resolve-AdoAttachmentUrl -Url $url -Org $Org -ApiV $ApiV
                Invoke-AdoDownload -Uri $resolved -OutFile $outFile -Headers $Headers
            }

            if (-not (Test-Path -LiteralPath $outFile) -or (Get-Item -LiteralPath $outFile).Length -le 0) {
                Write-Warning "Image ${i}: download produced an empty file, discarded."
                Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
                continue
            }
            $written.Add($outFile)
        }
        catch {
            Write-Warning "Image ${i}: could not be saved ($($_.Exception.Message))"
            if (Test-Path -LiteralPath $outFile) {
                Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Unary comma keeps a single path from unrolling to a bare [string].
    return , $written.ToArray()
}

function Get-AdoImageExtension {
    <#
    .SYNOPSIS  Best-effort file extension for an image URL or data URI. Defaults to 'png'.
    .NOTES     Internal helper for Save-AdoInlineImage.
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Url
    )
    if ([string]::IsNullOrWhiteSpace($Url)) { return 'png' }

    if ($Url -match '^data:image/([A-Za-z0-9.+-]+);') {
        $e = $Matches[1].ToLowerInvariant()
        if ($e -eq 'jpeg') { $e = 'jpg' }
        return $e
    }

    # fileName= carries the real name; the path segment is usually an opaque GUID.
    if ($Url -match '(?i)[?&]fileName=([^&]+)') {
        $name = [System.Uri]::UnescapeDataString($Matches[1])
        $e = [IO.Path]::GetExtension($name).TrimStart('.').ToLowerInvariant()
        if ($e) { return $e }
    }

    try {
        $e = [IO.Path]::GetExtension(([Uri]$Url).LocalPath).TrimStart('.').ToLowerInvariant()
        if ($e) { return $e }
    } catch { }

    return 'png'
}

#endregion

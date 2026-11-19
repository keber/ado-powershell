<#
.SYNOPSIS
  Base authentication and HTTP pattern for the Azure DevOps PowerShell Skill.
  Dot-source this file before using ado-workitems.ps1, ado-testing.ps1, ado-pipelines.ps1, or ado-git.ps1.

.USAGE
  . "$PSScriptRoot/ado-base.ps1"

.NOTES
  Requires a credential in the environment: ADO_PAT (or ADO_PAT_READ / ADO_PAT_WRITE with
  Initialize-AdoSession -Access), AZURE_DEVOPS_EXT_PAT, or SYSTEM_ACCESSTOKEN in pipelines.
  Never hardcode a PAT or token in code.
  Optional variables: ADO_ORG, ADO_PROJECT / ADO_PROJECT_<ACCESS> (read from environment if present).
#>

# StrictMode / ErrorActionPreference are set inside each function, not here: this file is dot-sourced and must not alter the caller session.

#region -- Authentication --

function New-AdoHeaders {
    <#
    .SYNOPSIS  Creates the HTTP Authorization header for ADO REST API (Basic for a PAT, Bearer for a token).
    .PARAMETER Pat     Azure DevOps PAT (sent as Basic).
    .PARAMETER Token   OAuth / Microsoft Entra access token (sent as Bearer), e.g. the output of
                       az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798.
    .PARAMETER Bearer  Use $env:SYSTEM_ACCESSTOKEN (Azure Pipelines job token) even when a PAT
                       variable is also set.
    .NOTES
      Resolution order:
        -Token → -Bearer ($env:SYSTEM_ACCESSTOKEN) → -Pat → $env:ADO_PAT → $env:AZURE_DEVOPS_EXT_PAT
        → $env:SYSTEM_ACCESSTOKEN
      PAT variables win over SYSTEM_ACCESSTOKEN so that existing callers that happen to have both
      keep sending the same credential. Errors name variables only, never their values.
    .OUTPUTS   Hashtable @{ Authorization = "Basic <b64>" } or @{ Authorization = "Bearer <token>" }
    #>
    param(
        [string]$Pat   = '',
        [string]$Token = '',
        [switch]$Bearer
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'

    $hasPat   = -not [string]::IsNullOrWhiteSpace($Pat)
    $hasToken = -not [string]::IsNullOrWhiteSpace($Token)
    if ([int]$hasPat + [int]$hasToken + [int][bool]$Bearer -gt 1) {
        throw 'New-AdoHeaders: pass only one of -Pat, -Token or -Bearer.'
    }

    if ($hasToken) { return @{ Authorization = "Bearer $Token" } }

    if ($Bearer) {
        if ([string]::IsNullOrWhiteSpace($env:SYSTEM_ACCESSTOKEN)) {
            throw ('New-AdoHeaders -Bearer: SYSTEM_ACCESSTOKEN is not set. In YAML pipelines map it ' +
                   'explicitly on the step (env: SYSTEM_ACCESSTOKEN: $(System.AccessToken)).')
        }
        return @{ Authorization = "Bearer $($env:SYSTEM_ACCESSTOKEN)" }
    }

    if (-not $hasPat) { $Pat = $env:ADO_PAT }
    if ([string]::IsNullOrWhiteSpace($Pat)) { $Pat = $env:AZURE_DEVOPS_EXT_PAT }
    if ([string]::IsNullOrWhiteSpace($Pat)) {
        if (-not [string]::IsNullOrWhiteSpace($env:SYSTEM_ACCESSTOKEN)) {
            return @{ Authorization = "Bearer $($env:SYSTEM_ACCESSTOKEN)" }
        }
        throw ('No credential found. Set ADO_PAT or AZURE_DEVOPS_EXT_PAT, map SYSTEM_ACCESSTOKEN, ' +
               'or pass -Pat / -Token explicitly.')
    }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
    return @{ Authorization = "Basic $b64" }
}

function Get-AdoDefaultHeaders {
    <#
    .SYNOPSIS
      Headers used when a caller passes no -Headers: the current session's, else New-AdoHeaders.
    .DESCRIPTION
      Internal helper for Invoke-AdoRequest, Invoke-AdoGetPaged and Invoke-AdoDownload. Using the
      session's headers keeps a Read session on the credential it was initialised with (for
      example ADO_PAT_READ) instead of re-resolving ADO_PAT from the environment. Without a session
      (or a session without Headers) the legacy environment resolution applies unchanged.
    .OUTPUTS  Hashtable
    #>
    param()
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    $session = $null
    try { $session = $script:AdoSession } catch { $session = $null }
    if ($null -ne $session) {
        $hp = $session.PSObject.Properties['Headers']
        if ($hp -and $hp.Value -is [System.Collections.IDictionary] -and $hp.Value.Count -gt 0) {
            return $hp.Value
        }
    }
    return New-AdoHeaders
}

function Assert-AdoWriteAccess {
    <#
    .SYNOPSIS
      Throws when the current session was initialised with -Access Read.
    .DESCRIPTION
      Client-side guard (defense in depth): the real control is the scope of the PAT or token.
      Called by Invoke-AdoRequest for every non-GET request that is not declared -ReadOnly, and
      by functions that send writes without going through Invoke-AdoRequest. A session object
      without an Access property (built by hand, or before Access existed) counts as Write, and
      no session at all is not blocked, so existing callers are unaffected.
      The error has ErrorId AdoReadOnlySession and never contains credential values.
    .PARAMETER Operation  Short description of the refused operation, for the error message.
    #>
    param(
        [string]$Operation = 'This write operation'
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'

    $session = $null
    try { $session = $script:AdoSession } catch { $session = $null }
    if ($null -eq $session) { return }
    $accessProp = $session.PSObject.Properties['Access']
    if (-not $accessProp -or [string]$accessProp.Value -ne 'Read') { return }

    $msg = ("$Operation was refused: the Azure DevOps session was initialised with -Access Read. " +
            'Run Initialize-AdoSession -Access Write (ADO_PAT_WRITE / ADO_PROJECT_WRITE) to write.')
    throw [System.Management.Automation.ErrorRecord]::new(
        [System.InvalidOperationException]::new($msg), 'AdoReadOnlySession',
        [System.Management.Automation.ErrorCategory]::PermissionDenied, $Operation)
}

#endregion

#region -- Response helpers --

function Get-AdoFieldValue {
    <#
    .SYNOPSIS
      Safely reads a field from a Work Item under Set-StrictMode.

    .DESCRIPTION
      ADO omits empty fields from the response entirely, so dot notation
      ($wi.fields.'System.Reason') throws under Set-StrictMode whenever a field happens to be
      unset. This skill enables Set-StrictMode -Version Latest in every script, so callers need
      an accessor that returns $null - or a supplied default - instead of throwing.

    .PARAMETER WorkItem  A Work Item object as returned by Get-AdoWorkItem / Get-AdoWorkItemsBatch.
    .PARAMETER Fields    A fields object directly, as an alternative to -WorkItem.
    .PARAMETER Name      Reference name of the field, e.g. 'System.Title'.
    .PARAMETER Default   Value to return when the field is absent or empty. Default: $null.

    .EXAMPLE
      $reason = Get-AdoFieldValue -WorkItem $wi -Name 'System.Reason'
    .EXAMPLE
      # Distinguish "field absent" from "field empty" by supplying a sentinel
      $ac = Get-AdoFieldValue -WorkItem $wi -Name 'Microsoft.VSTS.Common.AcceptanceCriteria' -Default ''
    #>
    [CmdletBinding(DefaultParameterSetName = 'WorkItem')]
    param(
        # AllowNull: a caller passing a Work Item that turned out to be $null is exactly the case
        # this helper exists to absorb - it must return the default, not fail parameter binding.
        [Parameter(Mandatory, ParameterSetName = 'WorkItem', Position = 0)]
        [AllowNull()]
        [object]$WorkItem,

        [Parameter(Mandatory, ParameterSetName = 'Fields')]
        [AllowNull()]
        [object]$Fields,

        [Parameter(Mandatory, Position = 1)]
        [string]$Name,

        [object]$Default = $null
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'

    $fieldsObj = if ($PSCmdlet.ParameterSetName -eq 'Fields') {
        $Fields
    } else {
        if ($null -eq $WorkItem) { return $Default }
        $p = $WorkItem.PSObject.Properties['fields']
        if ($p) { $p.Value } else { $null }
    }

    if ($null -eq $fieldsObj) { return $Default }

    $prop = $fieldsObj.PSObject.Properties[$Name]
    if (-not $prop) { return $Default }
    if ($null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function Test-AdoSignInResponse {
    <#
    .SYNOPSIS
      Tells whether a response is an Azure DevOps sign-in page rather than the requested resource.

    .DESCRIPTION
      When the PAT is missing, expired, or scoped for a different organisation, ADO answers with
      the interactive sign-in page and HTTP 200 - not with 401. Depending on the endpoint, the
      page reaches the caller either as a raw HTML string or as an object parsed out of that HTML
      by Invoke-RestMethod. Both shapes are treated as a sign-in page here.

      A raw string counts only if it is an HTML document (starts with <!DOCTYPE html or <html)
      that contains a sign-in specific marker (__RequestVerificationToken, /_signin,
      login.microsoftonline.com, or a <title> mentioning "sign in"). Plain text that merely
      mentions "sign in" is a legitimate payload.

      A parsed sign-in page is recognised by the absence of any recognisable ADO payload property
      combined with sign-in markers in its serialised form; this keeps legitimate but unusual
      payloads from being misread as authentication failures.

    .PARAMETER Response  The value returned by Invoke-RestMethod.
    .OUTPUTS  [bool]
    #>
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object]$Response
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'

    if ($null -eq $Response) { return $false }

    # Strong sign-in markers only. Bare words such as "sign in" or a stray "<html" appear in
    # legitimate text payloads (markdown, logs, file content) and must not match on their own.
    $signInPattern = '(?i)__RequestVerificationToken|/_signin|login\.microsoftonline\.com|<title>[^<]*sign.?in'

    # Raw string: only an HTML document (after optional BOM/whitespace) carrying a strong marker.
    if ($Response -is [string]) {
        if ($Response -notmatch '(?i)^[\s\uFEFF]*<(!DOCTYPE\s+html|html)\b') { return $false }
        return [bool]($Response -match $signInPattern)
    }

    # A real ADO payload always carries at least one of these.
    foreach ($known in 'id', 'value', 'count', 'fields', 'workItems', 'name') {
        if ($Response.PSObject.Properties[$known]) { return $false }
    }

    # No recognisable payload: fall back to inspecting the serialised form.
    $text = $null
    try { $text = $Response | ConvertTo-Json -Depth 4 -Compress } catch { $text = [string]$Response }
    if (-not $text) { return $false }
    return [bool]($text -match $signInPattern)
}

function Read-AdoJsonUtf8 {
    <#
    .SYNOPSIS
      Reads a local JSON file as UTF-8 and returns the parsed object.

    .DESCRIPTION
      Get-Content in Windows PowerShell 5.1 decodes using the ANSI codepage, not UTF-8. Reading a
      UTF-8 file that way turns accented characters into mojibake ('boton' becomes 'botAn'), and
      pushing that text back into ADO corrupts the work item. This reads with an explicit UTF-8
      encoding on every PowerShell version and strips a BOM if present.

      Use it for any local file whose contents will be written to ADO.

    .PARAMETER Path  Path to the JSON file.
    .PARAMETER Raw   Return the decoded text instead of parsing it as JSON.

    .EXAMPLE
      $titles = Read-AdoJsonUtf8 -Path ./titles.json
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [switch]$Raw
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File not found: $Path"
    }

    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)

    # ReadAllText keeps the BOM as U+FEFF; ConvertFrom-Json rejects it.
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }

    if ($Raw) { return $text }
    return ($text | ConvertFrom-Json)
}

function Test-AdoConditionalAccessError {
    <#
    .SYNOPSIS
      Tells whether a failed HTTP call was rejected by a Microsoft Entra Conditional Access policy
      (Azure DevOps error VS403463).
    .DESCRIPTION
      Looks for "VS403463" in the X-TFS-ServiceError response header (URL-encoded by ADO; read
      through an indexer on Windows PowerShell 5.1 or GetValues on PowerShell 7) and in the error
      body (ErrorDetails.Message). The response stream is not read, so the 400 handling that
      follows can still consume it. Internal helper for Invoke-AdoRequest / Invoke-AdoGetPaged.
    .PARAMETER ErrorRecord  The error record caught from Invoke-RestMethod / Invoke-WebRequest.
    .OUTPUTS  [bool]
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][object]$ErrorRecord
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    if ($null -eq $ErrorRecord) { return $false }

    $texts = [System.Collections.Generic.List[string]]::new()
    try {
        if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
            $texts.Add([string]$ErrorRecord.ErrorDetails.Message)
        }
    } catch { }

    $headers = $null
    try { $headers = $ErrorRecord.Exception.Response.Headers } catch { }
    if ($null -ne $headers) {
        $value = $null
        try { $value = $headers['X-TFS-ServiceError'] } catch { }
        if (-not $value) {
            try { $value = @($headers.GetValues('X-TFS-ServiceError')) -join ' ' } catch { }
        }
        if ($value) {
            $text = [string](@($value) -join ' ')
            try { $text = [uri]::UnescapeDataString($text) } catch { }
            $texts.Add($text)
        }
    }

    foreach ($t in $texts) {
        if ($t -match '(?i)\bVS403463\b') { return $true }
    }
    return $false
}

function New-AdoConditionalAccessError {
    <#
    .SYNOPSIS  Builds the ErrorRecord (ErrorId AdoConditionalAccess) thrown for VS403463.
    .NOTES     Internal helper. The message contains the request URI only, never credentials.
    #>
    param([Parameter(Mandatory)][string]$Uri)
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    $msg = ('VS403463: Azure DevOps rejected the request because of a Microsoft Entra Conditional ' +
            'Access policy (network location / IP range or device compliance). The credential itself ' +
            'is not the problem: regenerating the PAT or token will not help. Run from an allowed ' +
            "network or device, or ask your Entra ID / Azure DevOps administrator. Request: $Uri")
    return [System.Management.Automation.ErrorRecord]::new(
        [System.UnauthorizedAccessException]::new($msg), 'AdoConditionalAccess',
        [System.Management.Automation.ErrorCategory]::PermissionDenied, $Uri)
}

#endregion

#region -- HTTP core with retries --

function Invoke-AdoRequest {
    <#
    .SYNOPSIS
      Performs an authenticated HTTP call to ADO REST API with automatic
      retries and exponential backoff.

    .PARAMETER Method       GET | POST | PATCH | PUT | DELETE
    .PARAMETER Uri          Full endpoint URL.
    .PARAMETER Body         Request body (UTF-8 string).
    .PARAMETER ContentType  Content-Type of the body. Default: application/json.
    .PARAMETER Headers      Hashtable of headers. Default: the session's headers, else New-AdoHeaders.
    .PARAMETER MaxRetries   Maximum number of attempts (default: 3).
    .PARAMETER RetryDelaySec Base seconds for backoff (default: 2).
    .PARAMETER RetryNonIdempotent
      Retry POST/PATCH on timeouts and 5xx too. Off by default: a retry after a lost response
      can repeat a write that already committed (duplicate work items, links, pipeline runs).
      Use only for read-only POSTs (WIQL, workitemsbatch).
    .PARAMETER ReadOnly
      Declares that a non-GET request does not modify data (WIQL, workitemsbatch), so it is
      allowed on a session initialised with -Access Read. Every other POST/PATCH/PUT/DELETE is
      refused on a Read session (ErrorId AdoReadOnlySession) before anything is sent.

    .NOTES
      GET/PUT/DELETE retry on 429, 503 and other transient errors. POST/PATCH retry only on
      429 (rejected before processing); any other error is thrown immediately, unretried.
      A 429 Retry-After header (seconds) is honoured when present.
      A 409 Conflict is never retried, for any method; the original error is rethrown.
      A Conditional Access rejection (VS403463) is thrown as ErrorId AdoConditionalAccess and
      is never retried.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET','POST','PATCH','PUT','DELETE')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Uri,

        [string]$Body,
        [string]$ContentType = 'application/json',
        [hashtable]$Headers,
        [int]$MaxRetries     = 3,
        [int]$RetryDelaySec  = 2,
        [switch]$RetryNonIdempotent,
        [switch]$ReadOnly
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'

    # Central write guard: any non-GET request not declared read-only is a write.
    if ($Method -ne 'GET' -and -not $ReadOnly) {
        Assert-AdoWriteAccess -Operation "$Method $Uri"
    }

    if (-not $Headers) { $Headers = Get-AdoDefaultHeaders }

    $canRetryTransient = $RetryNonIdempotent -or ($Method -in 'GET', 'PUT', 'DELETE')

    $attempt = 0
    $lastErr = $null

    while ($attempt -lt $MaxRetries) {
        $attempt++
        try {
            $params = @{
                Method      = $Method
                Uri         = $Uri
                Headers     = $Headers
                ErrorAction = 'Stop'
            }
            if ($Body) {
                $params.Body        = [Text.Encoding]::UTF8.GetBytes($Body)
                $params.ContentType = $ContentType
            }

            $response = Invoke-RestMethod @params

            # Detect a sign-in page returned instead of the requested resource.
            # ADO answers an unauthenticated request with the login page and HTTP 200, so the
            # status-code branches below never see it. The page arrives either as a raw string
            # or - when Invoke-RestMethod manages to parse it - as an object, so both are checked.
            if (Test-AdoSignInResponse -Response $response) {
                # Tagged with a distinct ErrorId so the catch below rethrows it without retrying.
                $signInMsg = ("Received an Azure DevOps sign-in page instead of a response. " +
                              "Check ADO_PAT (valid? expired? correct scopes?), ADO_ORG and " +
                              "ADO_PROJECT. Request: $Uri")
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new($signInMsg), 'AdoSignInPage',
                    [System.Management.Automation.ErrorCategory]::AuthenticationError, $Uri)
            }
            return $response
        }
        catch {
            # Sign-in page: authentication problem, retrying cannot help.
            if ($_.FullyQualifiedErrorId -eq 'AdoSignInPage') { throw }

            # Conditional Access (VS403463): a network/device policy, retrying cannot help.
            if (Test-AdoConditionalAccessError -ErrorRecord $_) {
                throw (New-AdoConditionalAccessError -Uri $Uri)
            }

            $lastErr = $_
            $status  = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }

            # 401 / 403: do not retry -- PAT is invalid or permissions are missing
            if ($status -in 401, 403) {
                $msg = if ($status -eq 401) {
                    "401 Unauthorized - check ADO_PAT."
                } else {
                    "403 Forbidden - PAT does not have sufficient permissions for: $Uri"
                }
                throw $msg
            }

            # 400: bad request - do not retry, include response body for diagnosis
            if ($status -eq 400) {
                $body400 = ''
                # PS 5.1 and 7 both populate ErrorDetails.Message when the server returns a body.
                if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                    $body400 = [string]$_.ErrorDetails.Message
                } else {
                    # Fallback for 5.1 (HttpWebResponse); absent on PS 7 (HttpResponseMessage).
                    try {
                        $stream400 = $_.Exception.Response.GetResponseStream()
                        $reader400 = [System.IO.StreamReader]::new($stream400)
                        $body400   = $reader400.ReadToEnd()
                    } catch { }
                }
                # If the body is JSON with a "message" property, surface that message.
                try {
                    $json400 = $body400 | ConvertFrom-Json -ErrorAction Stop
                    if ($json400 -and $json400.PSObject.Properties['message'] -and $json400.message) {
                        $body400 = [string]$json400.message
                    }
                } catch { }
                throw "400 Bad Request - $Uri`n$body400"
            }

            # 404: do not retry - resource does not exist
            if ($status -eq 404) {
                throw "404 Not Found - resource not found: $Uri"
            }

            # 409: do not retry for any method - the conflict is deterministic (state, merge
            # conflict, stale commit). The original error is rethrown so callers keep the status
            # code (Exception.Response.StatusCode) and the server message (ErrorDetails).
            if ($status -eq 409) {
                throw $lastErr
            }

            # POST/PATCH are not idempotent: past this point only a 429 (rejected before the
            # request was processed) is safe to retry. Anything else may have been committed
            # server-side, so surface the original error instead of repeating the write.
            if ($status -ne 429 -and -not $canRetryTransient) {
                throw $lastErr
            }

            # 429 / 503: rate-limit -- exponential backoff (honours Retry-After on 429)
            if ($status -in 429, 503) {
                $waitSec = $RetryDelaySec * [Math]::Pow(2, $attempt)
                if ($status -eq 429) {
                    $retryAfter = 0
                    try {
                        if ([int]::TryParse([string]$lastErr.Exception.Response.Headers['Retry-After'], [ref]$retryAfter) -and
                            $retryAfter -gt 0) {
                            $waitSec = [Math]::Min($retryAfter, 120)
                        }
                    } catch { }
                }
                Write-Warning "[$status] Rate-limit. Retry $attempt/$MaxRetries in ${waitSec}s..."
                Start-Sleep -Seconds $waitSec
                continue
            }

            # Other transient errors: linear backoff
            if ($attempt -lt $MaxRetries) {
                $waitSec = $RetryDelaySec * $attempt
                Write-Warning "Error (attempt $attempt/$MaxRetries): $($_.Exception.Message). Retrying in ${waitSec}s..."
                Start-Sleep -Seconds $waitSec
            }
        }
    }

    throw "Failed after $MaxRetries attempts. Last error: $($lastErr.Exception.Message)"
}

# -- Convenience alias: GET (read-only, never needs ShouldProcess)
function Invoke-AdoGet {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers,
        [int]$MaxRetries    = 3,
        [int]$RetryDelaySec = 2
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    Invoke-AdoRequest -Method GET -Uri $Uri -Headers $Headers `
        -MaxRetries $MaxRetries -RetryDelaySec $RetryDelaySec
}

function Test-AdoTrustedUrl {
    <#
    .SYNOPSIS  True only for https URLs on an Azure DevOps host: the session/org base URL host,
               dev.azure.com, or *.visualstudio.com. Gate for sending credentials.
    .NOTES     Internal helper for Save-AdoInlineImage. Plain http, userinfo URLs and lookalike
               hosts (dev.azure.com.evil.example) are rejected.
    #>
    param(
        [Parameter(Mandatory, Position = 0)][AllowNull()][AllowEmptyString()][string]$Url,
        [string]$Org = $script:AdoSession.Org
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    $uri = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.Scheme -ne 'https' -or $uri.UserInfo) { return $false }

    $h = $uri.Host.ToLowerInvariant()
    if ($h -eq 'dev.azure.com' -or $h.EndsWith('.visualstudio.com')) { return $true }

    $baseUri = $null
    if ([uri]::TryCreate((Get-AdoBaseUrl $Org), [UriKind]::Absolute, [ref]$baseUri)) {
        return ($baseUri.Scheme -eq 'https' -and $h -eq $baseUri.Host.ToLowerInvariant())
    }
    return $false
}

# -- Paged GET: follows continuation tokens (header or body) and collects every page
function Invoke-AdoGetPaged {
    <#
    .SYNOPSIS
      GETs a list endpoint and follows its continuation token until every page is collected.

    .DESCRIPTION
      Several ADO list APIs return the token in the x-ms-continuationtoken response HEADER, others
      in a continuationToken property of the BODY. Invoke-RestMethod cannot expose headers on
      Windows PowerShell 5.1, so this uses Invoke-WebRequest and parses the JSON itself (decoded
      as UTF-8 from the raw bytes, since 5.1 would otherwise decode with the ANSI codepage).
      Either token location is honoured. Paging stops when no token is returned, when the token
      repeats, or when -MaxItems items were collected.

      Same error mapping as Invoke-AdoRequest: 401/403/400/404 are not retried; 429/503 back off
      exponentially (429 honours Retry-After, capped at 120s); other errors back off linearly. A sign-in page is thrown as ErrorId AdoSignInPage and is not retried.

    .PARAMETER Uri            First-page URL (including api-version). Must not carry continuationToken.
    .PARAMETER Headers        Auth headers. Default: the session's headers, else New-AdoHeaders.
    .PARAMETER ItemsProperty  Response property holding the items (default: value).
    .PARAMETER MaxItems       Stop after this many items (0 = no limit).
    .OUTPUTS  The collected items across all pages.
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers,
        [string]$ItemsProperty = 'value',
        [int]$MaxItems         = 0,
        [int]$MaxRetries       = 3,
        [int]$RetryDelaySec    = 2
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'

    if (-not $Headers) { $Headers = Get-AdoDefaultHeaders }

    $items = [System.Collections.Generic.List[object]]::new()
    $token = $null

    while ($true) {
        $pageUri = $Uri
        if ($token) {
            $sep     = if ($Uri.Contains('?')) { '&' } else { '?' }
            $pageUri = "$Uri${sep}continuationToken=$([uri]::EscapeDataString($token))"
        }

        $attempt  = 0
        $lastErr  = $null
        $response = $null
        while ($attempt -lt $MaxRetries -and $null -eq $response) {
            $attempt++
            try {
                $response = Invoke-WebRequest -Method GET -Uri $pageUri -Headers $Headers `
                    -UseBasicParsing -ErrorAction Stop
            }
            catch {
                $lastErr = $_
                $status  = $null
                try { $status = [int]$_.Exception.Response.StatusCode } catch { }

                if (Test-AdoConditionalAccessError -ErrorRecord $_) {
                    throw (New-AdoConditionalAccessError -Uri $pageUri)
                }
                if ($status -eq 401) { throw "401 Unauthorized - check ADO_PAT." }
                if ($status -eq 403) { throw "403 Forbidden - PAT does not have sufficient permissions for: $pageUri" }
                if ($status -eq 400) {
                    $body400 = ''
                    # PS 5.1 and 7 populate ErrorDetails.Message; GetResponseStream is 5.1 only.
                    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                        $body400 = [string]$_.ErrorDetails.Message
                    } else {
                        try {
                            $reader400 = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
                            $body400   = $reader400.ReadToEnd()
                        } catch { }
                    }
                    # If the body is JSON with a "message" property, surface that message.
                    try {
                        $json400 = $body400 | ConvertFrom-Json -ErrorAction Stop
                        if ($json400 -and $json400.PSObject.Properties['message'] -and $json400.message) {
                            $body400 = [string]$json400.message
                        }
                    } catch { }
                    throw "400 Bad Request - $pageUri`n$body400"
                }
                if ($status -eq 404) { throw "404 Not Found - resource not found: $pageUri" }
                # 409: deterministic conflict, never retried (same as Invoke-AdoRequest).
                if ($status -eq 409) { throw $lastErr }

                if ($attempt -lt $MaxRetries) {
                    if ($status -in 429, 503) {
                        $waitSec = $RetryDelaySec * [Math]::Pow(2, $attempt)
                        if ($status -eq 429) {
                            # Honour Retry-After (seconds), capped at 120s, like Invoke-AdoRequest.
                            $retryAfter = 0
                            try {
                                if ([int]::TryParse([string]$lastErr.Exception.Response.Headers['Retry-After'], [ref]$retryAfter) -and
                                    $retryAfter -gt 0) {
                                    $waitSec = [Math]::Min($retryAfter, 120)
                                }
                            } catch { }
                        }
                        Write-Warning "[$status] Rate-limit. Retry $attempt/$MaxRetries in ${waitSec}s..."
                    } else {
                        $waitSec = $RetryDelaySec * $attempt
                        Write-Warning "Error (attempt $attempt/$MaxRetries): $($_.Exception.Message). Retrying in ${waitSec}s..."
                    }
                    Start-Sleep -Seconds $waitSec
                }
            }
        }
        if ($null -eq $response) {
            throw "Failed after $MaxRetries attempts. Last error: $($lastErr.Exception.Message)"
        }

        # Decode as UTF-8 from the raw bytes when available (5.1 decodes .Content as ANSI).
        $text = $null
        $rawProp = $response.PSObject.Properties['RawContentStream']
        if ($rawProp -and $rawProp.Value) {
            $ms = $rawProp.Value
            $ms.Position = 0
            $buffer = New-Object byte[] ([int]$ms.Length)
            [void]$ms.Read($buffer, 0, $buffer.Length)
            $text = [System.Text.Encoding]::UTF8.GetString($buffer)
            if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
        } else {
            $text = [string]$response.Content
        }

        $page = $null
        try { $page = $text | ConvertFrom-Json } catch { $page = $null }

        # Unparseable body: ADO answers a bad PAT with the HTML sign-in page and HTTP 200.
        # A parseable body goes through the same check (it has the known-property guard).
        $signIn = if ($null -eq $page) { Test-AdoSignInResponse -Response $text }
                  else                 { Test-AdoSignInResponse -Response $page }
        if ($signIn -or $null -eq $page) {
            # Same ErrorId as Invoke-AdoRequest; thrown outside the retry loop, so never retried.
            $signInMsg = ("Received an Azure DevOps sign-in page instead of a response. " +
                          "Check ADO_PAT (valid? expired? correct scopes?), ADO_ORG and " +
                          "ADO_PROJECT. Request: $pageUri")
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new($signInMsg), 'AdoSignInPage',
                [System.Management.Automation.ErrorCategory]::AuthenticationError, $pageUri)
        }

        $itemsProp = $page.PSObject.Properties[$ItemsProperty]
        if ($itemsProp -and $null -ne $itemsProp.Value) {
            foreach ($item in @($itemsProp.Value)) { $items.Add($item) }
        }

        if ($MaxItems -gt 0 -and $items.Count -ge $MaxItems) {
            if ($items.Count -gt $MaxItems) { $items.RemoveRange($MaxItems, $items.Count - $MaxItems) }
            break
        }

        # Token: response header first, then body.
        $next = $null
        try {
            $h = $response.Headers['x-ms-continuationtoken']
            if ($h) { $next = [string]@($h)[0] }
        } catch { }
        if (-not $next) {
            $tp = $page.PSObject.Properties['continuationToken']
            if ($tp -and $tp.Value) { $next = [string]$tp.Value }
        }

        if (-not $next) { break }
        if ($next -eq $token) {
            Write-Warning "Continuation token did not advance; stopping to avoid an endless loop: $Uri"
            break
        }
        $token = $next
    }

    return $items.ToArray()
}

# -- Authenticated file download: wraps Invoke-WebRequest -OutFile with no business logic
function Invoke-AdoDownload {
    <#
    .SYNOPSIS
      Downloads a resource from an authenticated ADO URL directly to a local file.
    .PARAMETER Uri      Full URL to download (including api-version if required).
    .PARAMETER OutFile  Local path where the file will be saved.
    .PARAMETER Headers  Auth headers (hashtable). Defaults to the session's headers (New-AdoHeaders
                        when there is no session), but then the URL
                        must be an https Azure DevOps host (Test-AdoTrustedUrl); otherwise it
                        throws. Passing -Headers explicitly is an opt-in and skips that check.
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [hashtable]$Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    if (-not $Headers) {
        if (-not (Test-AdoTrustedUrl -Url $Uri)) {
            $h = $null
            try { $h = ([uri]$Uri).Host } catch { $h = $Uri }
            throw "Invoke-AdoDownload: refusing to send Azure DevOps credentials to $h (not an https Azure DevOps host). Pass -Headers explicitly to override."
        }
        $Headers = Get-AdoDefaultHeaders
    }
    # -PassThru keeps the response object alongside -OutFile (5.1 and 7), so the Content-Type
    # can be inspected: ADO answers a bad/expired PAT with its HTML sign-in page and HTTP 200.
    try {
        $response = Invoke-WebRequest -Uri $Uri -Headers $Headers -OutFile $OutFile -PassThru -ErrorAction Stop
    } catch {
        if (Test-AdoConditionalAccessError -ErrorRecord $_) { throw (New-AdoConditionalAccessError -Uri $Uri) }
        throw
    }
    $contentType = $null
    if ($null -ne $response -and $null -ne $response.Headers) {
        $contentType = [string]($response.Headers['Content-Type'] | Select-Object -First 1)
    }
    if ($contentType -match '(?i)^\s*text/html') {
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        $signInMsg = ("Received an Azure DevOps sign-in page (text/html) instead of the requested file. " +
                      "Check ADO_PAT (valid? expired? correct scopes?), ADO_ORG and " +
                      "ADO_PROJECT. Request: $Uri")
        # Same ErrorId as Invoke-AdoRequest's sign-in detection (authentication problem).
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new($signInMsg), 'AdoSignInPage',
            [System.Management.Automation.ErrorCategory]::AuthenticationError, $Uri)
    }
}
#endregion

#region -- Session object --

function Resolve-AdoConfig {
    <#
    .SYNOPSIS
      Resolves connection settings from explicit parameters, environment variables,
      and an optional JSON config file. Returns a plain hashtable - does NOT build
      headers or create the session object.

    .DESCRIPTION
      Resolution order for each value:
        1. Explicit parameter (if non-empty)
        2. Environment variable
        3. Config file (if -ConfigPath is supplied and the file exists)

      Project resolution order (<ACCESS> is READ or WRITE, from -Access):
        -Project → $env:ADO_PROJECT_<ACCESS> → $env:ADO_PROJECT → config file

      Credential resolution order:
        -Token (Bearer) → -Bearer ($env:SYSTEM_ACCESSTOKEN) → -Pat
        → $env:ADO_PAT_<ACCESS> → $env:ADO_PAT → $env:AZURE_DEVOPS_EXT_PAT → config file
        → $env:SYSTEM_ACCESSTOKEN (Bearer)
      PAT variables win over SYSTEM_ACCESSTOKEN, so callers that have both keep their behaviour;
      pass -Bearer to prefer the pipeline token. Only one of -Pat, -Token, -Bearer may be given.

      Config file format (JSON):
        { "org": "", "project": "", "apiVersion": "", "baseUrl": "" }
        ('pat' is still read for backward compatibility but discouraged: use ADO_PAT and
        keep the file outside the repo, e.g. $HOME/.config/ado/config.json.)

    .PARAMETER Access  Read or Write (default Write: today's behaviour). Selects which
                       ADO_PAT_<ACCESS> / ADO_PROJECT_<ACCESS> pair is tried first.
    .PARAMETER Token   OAuth / Microsoft Entra access token, sent as Bearer.
    .PARAMETER Bearer  Use $env:SYSTEM_ACCESSTOKEN as Bearer even when a PAT variable is set.

    .OUTPUTS  Hashtable with keys: Org, Project, ApiV, Pat, Token, AuthScheme (Basic|Bearer),
              Access, BaseUrl. Exactly one of Pat / Token is non-empty.
    .EXAMPLE
      $cfg = Resolve-AdoConfig -Org 'contoso' -Project 'MyApp'
    .EXAMPLE
      $cfg = Resolve-AdoConfig -ConfigPath "$HOME/.config/ado-powershell/config.json"
    .EXAMPLE
      $cfg = Resolve-AdoConfig -Access Read
    #>
    param(
        [string]$Org        = '',
        [string]$Project    = '',
        [string]$ApiV       = '',
        [string]$Pat        = '',
        [string]$BaseUrl    = '',
        [string]$ConfigPath = '',
        [ValidateSet('Read', 'Write')]
        [string]$Access     = 'Write',
        [string]$Token      = '',
        [switch]$Bearer
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'

    # Canonical casing ('read' -> 'Read') and the env-var suffix ('READ').
    $Access    = if ($Access -eq 'Read') { 'Read' } else { 'Write' }
    $suffix    = $Access.ToUpperInvariant()
    $patVar    = "ADO_PAT_$suffix"
    $projVar   = "ADO_PROJECT_$suffix"
    # Whitespace-only values count as absent everywhere, so the AuthScheme reported always matches
    # the header New-AdoHeaders builds (it ignores blank -Pat / -Token too).
    $blankToEmpty = { param($v) if ([string]::IsNullOrWhiteSpace([string]$v)) { '' } else { [string]$v } }
    $Pat       = & $blankToEmpty $Pat
    $Token     = & $blankToEmpty $Token
    $accessPat = & $blankToEmpty ([Environment]::GetEnvironmentVariable($patVar))
    $accessPrj = & $blankToEmpty ([Environment]::GetEnvironmentVariable($projVar))
    $envPat    = & $blankToEmpty $env:ADO_PAT
    $envExtPat = & $blankToEmpty $env:AZURE_DEVOPS_EXT_PAT
    $envSysTok = & $blankToEmpty $env:SYSTEM_ACCESSTOKEN

    if ([int][bool]$Pat + [int][bool]$Token + [int][bool]$Bearer -gt 1) {
        throw 'Resolve-AdoConfig: pass only one of -Pat, -Token or -Bearer.'
    }

    #    optional config file
    $file = @{}
    if ($ConfigPath -and (Test-Path $ConfigPath)) {
        try {
            $raw  = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            # Under Set-StrictMode, reading an absent key (e.g. no 'pat' in the template) throws.
            $names = @($raw.PSObject.Properties.Name)
            $file = @{
                Org     = if ($names -contains 'org'        -and $raw.org)        { $raw.org        } else { '' }
                Project = if ($names -contains 'project'    -and $raw.project)    { $raw.project    } else { '' }
                ApiV    = if ($names -contains 'apiVersion' -and $raw.apiVersion) { $raw.apiVersion } else { '' }
                Pat     = if ($names -contains 'pat'        -and $raw.pat)        { $raw.pat        } else { '' }
                BaseUrl = if ($names -contains 'baseUrl'    -and $raw.baseUrl)    { $raw.baseUrl    } else { '' }
            }
        } catch {
            # Path and error type only: the parser message quotes the file content, which may
            # include a legacy 'pat'.
            Write-Warning ("Resolve-AdoConfig: Could not parse config file '$ConfigPath' " +
                           "($($_.Exception.GetType().Name)); it is ignored.")
        }
    }

    # Resolve each value: param > env > file
    # Use bracket notation ($file['Key']) - dot notation throws with Set-StrictMode on empty hashtables
    $resolvedOrg  = if ($Org)                        { $Org }
                    elseif ($env:ADO_ORG)            { $env:ADO_ORG }
                    elseif ($file['Org'])            { $file['Org'] }
                    else { '' }

    $resolvedProj = if ($Project)                    { $Project }
                    elseif ($accessPrj)              { $accessPrj }
                    elseif ($env:ADO_PROJECT)        { $env:ADO_PROJECT }
                    elseif ($file['Project'])        { $file['Project'] }
                    else { '' }

    $resolvedApiV = if ($ApiV)                       { $ApiV }
                    elseif ($env:ADO_API_VER)        { $env:ADO_API_VER }
                    elseif ($file['ApiV'])           { $file['ApiV'] }
                    else { '7.1' }

    # Credential: explicit token / -Bearer / explicit PAT, then PAT variables, then the pipeline token.
    $resolvedPat   = ''
    $resolvedToken = ''
    if ($Token)      { $resolvedToken = $Token }
    elseif ($Bearer) { $resolvedToken = $envSysTok }
    else {
        $filePat     = & $blankToEmpty $file['Pat']
        $resolvedPat = if ($Pat)           { $Pat }
                       elseif ($accessPat) { $accessPat }
                       elseif ($envPat)    { $envPat }
                       elseif ($envExtPat) { $envExtPat }
                       elseif ($filePat)   { $filePat }
                       else { '' }
        if (-not $resolvedPat -and $envSysTok) { $resolvedToken = $envSysTok }
    }
    $authScheme = if ($resolvedToken) { 'Bearer' } else { 'Basic' }

    $resolvedBase = if ($BaseUrl)                    { $BaseUrl }
                    elseif ($file['BaseUrl'])        { $file['BaseUrl'] }
                    elseif ($resolvedOrg)            { "https://dev.azure.com/$resolvedOrg" }
                    else { '' }

    # A bare host (no organization) yields broken URLs; append the org when known.
    if ($resolvedBase) { $resolvedBase = $resolvedBase.TrimEnd('/') }
    if ($resolvedOrg -and $resolvedBase -eq 'https://dev.azure.com') {
        $resolvedBase = "https://dev.azure.com/$resolvedOrg"
    }

    # Validate required fields
    $missing = @()
    if (-not $resolvedOrg)  { $missing += 'Org  (param -Org or env ADO_ORG)' }
    if (-not $resolvedProj) { $missing += "Project  (param -Project, env $projVar or env ADO_PROJECT)" }
    if (-not $resolvedPat -and -not $resolvedToken) {
        $missing += if ($Bearer) {
            'Token  (-Bearer requires env SYSTEM_ACCESSTOKEN)'
        } else {
            "PAT  (param -Pat or -Token, env $patVar, ADO_PAT, AZURE_DEVOPS_EXT_PAT or SYSTEM_ACCESSTOKEN)"
        }
    }

    # Names only: values (PATs, tokens) are never part of the message.
    if ($missing.Count -gt 0) {
        throw "Resolve-AdoConfig: Missing required config values:`n  - $($missing -join "`n  - ")"
    }

    return @{
        Org        = $resolvedOrg
        Project    = $resolvedProj
        ApiV       = $resolvedApiV
        Pat        = $resolvedPat
        Token      = $resolvedToken
        AuthScheme = $authScheme
        Access     = $Access
        BaseUrl    = $resolvedBase
    }
}

function Initialize-AdoSession {
    <#
    .SYNOPSIS
      Initializes the $AdoSession object with org, project, version, base URL, and headers.

    .DESCRIPTION
      Resolution order:
        1) Explicit parameters
        2) Environment variables  (ADO_ORG, ADO_PROJECT, ADO_API_VER)
        3) Optional config file   (-ConfigPath)

      Project and credential resolution (see Resolve-AdoConfig for the full order):
        Project:    -Project → ADO_PROJECT_<ACCESS> → ADO_PROJECT → config file
        Credential: -Token → -Bearer → -Pat → ADO_PAT_<ACCESS> → ADO_PAT → AZURE_DEVOPS_EXT_PAT
                    → config file → SYSTEM_ACCESSTOKEN
      <ACCESS> is READ or WRITE. Without -Access the session is Write and only the WRITE pair is
      added in front of today's ADO_PAT / ADO_PROJECT, so existing callers are unaffected.

      A Read session refuses every write (POST/PATCH/PUT/DELETE not declared read-only) with
      ErrorId AdoReadOnlySession. This is defense in depth: PAT scopes remain the real control.

    .PARAMETER Access  Read or Write (default Write).
    .PARAMETER Token   OAuth / Microsoft Entra access token, sent as Bearer.
    .PARAMETER Bearer  Use $env:SYSTEM_ACCESSTOKEN (Azure Pipelines) even when a PAT variable is set.

    .OUTPUTS
      PSCustomObject (Org, Project, ApiV, BaseUrl, Access, AuthScheme, Headers) used by
      ado-workitems, ado-testing, ado-pipelines, and ado-git functions as session defaults.
      The raw PAT / token is not stored on the object (only inside Headers).

    .EXAMPLE
      $AdoSession = Initialize-AdoSession

    .EXAMPLE
      $AdoSession = Initialize-AdoSession -Org 'contoso' -Project 'MyApp'

    .EXAMPLE
      $AdoSession = Initialize-AdoSession -ConfigPath "$HOME/.config/ado-powershell/config.json"

    .EXAMPLE
      # Least privilege: read with ADO_PAT_READ / ADO_PROJECT_READ; writes are refused.
      $AdoSession = Initialize-AdoSession -Access Read

    .EXAMPLE
      # Azure Pipelines step with env: SYSTEM_ACCESSTOKEN: $(System.AccessToken)
      $AdoSession = Initialize-AdoSession -Bearer
    #>
    param(
        [string]$Org        = '',
        [string]$Project    = '',
        [string]$ApiV       = '',
        [string]$Pat        = '',
        [string]$BaseUrl    = '',
        [string]$ConfigPath = '',
        [ValidateSet('Read', 'Write')]
        [string]$Access     = 'Write',
        [string]$Token      = '',
        [switch]$Bearer
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'

    $resolved = Resolve-AdoConfig `
        -Org        $Org `
        -Project    $Project `
        -ApiV       $ApiV `
        -Pat        $Pat `
        -BaseUrl    $BaseUrl `
        -ConfigPath $ConfigPath `
        -Access     $Access `
        -Token      $Token `
        -Bearer:$Bearer

    $headers = if ($resolved.AuthScheme -eq 'Bearer') { New-AdoHeaders -Token $resolved.Token }
               else                                   { New-AdoHeaders -Pat   $resolved.Pat }

    $session = [pscustomobject]@{
        Org        = $resolved.Org
        Project    = $resolved.Project
        ApiV       = $resolved.ApiV
        BaseUrl    = $resolved.BaseUrl
        Access     = $resolved.Access
        AuthScheme = $resolved.AuthScheme
        Headers    = $headers
    }

    # Export as script variable so domain files can find it
    Set-Variable -Name AdoSession -Value $session -Scope Script -Force
    return $session
}

function Get-AdoBaseUrl {
    <#
    .SYNOPSIS  Returns the base ADO URL for the given org, preferring a custom BaseUrl if set.
    #>
    param([string]$Org = $script:AdoSession.Org)
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    # If caller has a custom BaseUrl on the session (e.g. ADO Server), use it.
    if ($Org -eq $script:AdoSession.Org -and $script:AdoSession.BaseUrl) {
        return $script:AdoSession.BaseUrl
    }
    return "https://dev.azure.com/$Org"
}

#endregion

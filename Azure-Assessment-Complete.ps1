#Requires -Modules Az.Accounts, Az.Resources, Az.Compute, Az.Network, Az.Storage, Az.Monitor
<#
.SYNOPSIS
    Azure Environment Assessment - Complete 1-Shot Script
    Centre Technologies | March 2026

.DESCRIPTION
    Runs a comprehensive Azure environment assessment across ALL subscriptions in a tenant.
    Collects inventory, utilization, security, cost, and governance data.
    Exports everything to timestamped CSV files for offline analysis.

.NOTES
    Run from Azure Cloud Shell (PowerShell) or any terminal with Az modules installed.
    Some sections require optional modules: Az.ConnectedMachine, Az.Aks, Microsoft.Graph
    The script will gracefully skip sections where modules are not available.

.PARAMETER SubscriptionId
    Optional. Assess a single subscription instead of all enabled subscriptions.

.PARAMETER OutputPath
    Optional. Base output directory. Defaults to ./AzureAssessment_<timestamp>

.PARAMETER SkipMetrics
    Optional. Skip metric collection (CPU/Memory/DTU) to speed up the run.

.PARAMETER DaysBack
    Optional. Number of days to look back for metrics. Default 30.

.PARAMETER CostMonths
    Optional. Number of months of actual cost (Cost Management) to collect, including the current month. Default 3.

.PARAMETER SectionTimeoutSeconds
    Optional. Time budget for long-running queries (Resource Graph paging, file share enumeration). Default 300.
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$OutputPath,
    [switch]$SkipMetrics,
    [int]$DaysBack = 30,
    [string[]]$SubscriptionInclude,
    [string[]]$SubscriptionExclude,
    [int]$MaxRetries = 3,
    [switch]$FailOnSectionError,
    [int]$CostMonths = 3,
    [int]$SectionTimeoutSeconds = 300
)

#region -- Setup --------------------------------------------------------------
$ScriptVersion = '2026.10.0'
$ErrorActionPreference = 'Continue'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmm'
if (-not $OutputPath) { $OutputPath = "./AzureAssessment_$timestamp" }
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# Transcript logging
$transcriptPath = "$OutputPath/Assessment-Transcript.log"
try { Start-Transcript -Path $transcriptPath -Append | Out-Null } catch {}

$startTime = Get-Date
$endTime = Get-Date
$metricsStart = (Get-Date).AddDays(-$DaysBack)

# Summary collector (manifest of exported files)
$summaryData = [System.Collections.ArrayList]::new()

# Section error/timing tracking
$sectionErrors  = [System.Collections.ArrayList]::new()
$sectionTimings = [System.Collections.ArrayList]::new()
$script:currentSection = $null
$script:sectionStart   = $null
$script:currentSubName = $null

# Datasets that could not be (fully) collected: FileName -> reason.
# A dataset with rows and a note is 'Partial'; with no rows it is 'NotCollected' and no file is written.
$script:datasetNotes = @{}

function Set-NotCollected {
    param([string]$Dataset, [string]$Reason)
    if (-not $Dataset) { return }
    $existing = $script:datasetNotes[$Dataset]
    if (-not $existing) { $script:datasetNotes[$Dataset] = $Reason }
    elseif ($existing -notlike "*$Reason*") { $script:datasetNotes[$Dataset] = "$existing; $Reason" }
}

function Complete-SectionTiming {
    if ($script:currentSection -and $script:sectionStart) {
        $null = $sectionTimings.Add([PSCustomObject]@{
            Subscription = $script:currentSubName
            Section      = $script:currentSection
            Seconds      = [math]::Round(((Get-Date) - $script:sectionStart).TotalSeconds, 1)
        })
    }
    $script:currentSection = $null
    $script:sectionStart   = $null
}

function Write-Section {
    param([string]$Title)
    Complete-SectionTiming
    $script:currentSection = $Title
    $script:sectionStart   = Get-Date
    Write-Host "`n+==============================================================+" -ForegroundColor Cyan
    Write-Host "|  $Title" -ForegroundColor Cyan
    Write-Host "+==============================================================+" -ForegroundColor Cyan
}

function Write-SubSection {
    param([string]$Title)
    Write-Host "  > $Title" -ForegroundColor Yellow
}

function Write-SectionError {
    param($ErrorRecord, [string]$Context = '', [string]$Dataset = '')
    $where = if ($Context) { $Context }
             elseif ($ErrorRecord.InvocationInfo) { "Line $($ErrorRecord.InvocationInfo.ScriptLineNumber)" }
             else { 'Unknown' }
    $msg = if ($ErrorRecord.Exception) { $ErrorRecord.Exception.Message } else { "$ErrorRecord" }
    $null = $sectionErrors.Add([PSCustomObject]@{
        Subscription = $script:currentSubName
        Section      = $script:currentSection
        Context      = $where
        Dataset      = $Dataset
        Error        = $msg
    })
    Write-Host "    ! $where : $msg" -ForegroundColor DarkYellow
    if ($Dataset) {
        $subLabel = if ($script:currentSubName) { "[$($script:currentSubName)] " } else { '' }
        $short = if ($msg.Length -gt 200) { $msg.Substring(0, 200) + '...' } else { $msg }
        Set-NotCollected -Dataset $Dataset -Reason "$subLabel$short"
    }
}

function Export-SafeCsv {
    param($Data, [string]$FileName, [string[]]$Columns)
    $path = Join-Path $OutputPath $FileName
    if (-not $Columns -and $Schemas -and $Schemas.ContainsKey($FileName)) { $Columns = $Schemas[$FileName] }
    $rows  = @($Data | Where-Object { $null -ne $_ })
    $count = $rows.Count
    $note  = $script:datasetNotes[$FileName]
    if ($count -gt 0) {
        if ($Columns) {
            # Schema columns first in a stable order, then any extra properties
            $extra = @($rows[0].PSObject.Properties.Name | Where-Object { $_ -notin $Columns })
            $rows = $rows | Select-Object -Property (@($Columns) + $extra)
        }
        $rows | Export-Csv $path -NoTypeInformation -Encoding UTF8
        $status = if ($note) { 'Partial' } else { 'Collected' }
        Write-Host "    + Exported $count rows -> $FileName" -ForegroundColor Green
    } elseif ($note) {
        $status = 'NotCollected'
        Write-Host "    x Not collected: $FileName ($note)" -ForegroundColor DarkYellow
    } else {
        $status = 'Empty'
        if ($Columns) {
            # Header-only file so "nothing found" is distinguishable from "not collected"
            $header = '"' + (($Columns | ForEach-Object { $_ -replace '"', '""' }) -join '","') + '"'
            Set-Content -Path $path -Value $header -Encoding UTF8
        }
        Write-Host "    - No rows for $FileName (header only)" -ForegroundColor DarkGray
    }
    $null = $summaryData.Add([PSCustomObject]@{ File = $FileName; Rows = $count; Status = $status; Note = $note })
}

function Test-ModuleAvailable {
    param([string]$ModuleName)
    return [bool](Get-Module -ListAvailable -Name $ModuleName 2>$null)
}

function Test-CommandAvailable {
    param([string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

# Null-safe last path segment of an ARM resource ID
function Get-LastSegment {
    param($Id)
    if ($null -eq $Id) { return $null }
    $s = "$Id".Trim().TrimEnd('/')
    if (-not $s) { return $null }
    return ($s -split '/')[-1]
}

# Flatten scalars, arrays and List[string] into a single delimited string
function Join-Values {
    param($Value, [string]$Separator = ',')
    $flat = foreach ($v in @($Value)) {
        if ($null -eq $v) { continue }
        if ($v -is [string]) { $v }
        elseif ($v -is [System.Collections.IEnumerable]) { foreach ($x in $v) { if ($null -ne $x) { "$x" } } }
        else { "$v" }
    }
    $out = @($flat | Where-Object { "$_".Trim() -ne '' } | ForEach-Object { "$_".Trim() } | Select-Object -Unique)
    return ($out -join $Separator)
}

# First argument that is not null or empty
function Get-FirstNonEmpty {
    foreach ($v in $args) {
        if ($null -ne $v -and "$v" -ne '') { return $v }
    }
    return $null
}

# Read a (possibly dotted) property path from an object, dictionary, or AdditionalProperties bag. Case-insensitive.
function Get-PropValue {
    param($Object, [string[]]$Name)
    foreach ($n in $Name) {
        $cur = $Object
        foreach ($seg in ($n -split '\.')) {
            if ($null -eq $cur) { break }
            $next = $null
            if ($cur -is [System.Collections.IDictionary]) {
                foreach ($k in @($cur.Keys)) { if ("$k" -ieq $seg) { $next = $cur[$k]; break } }
            } else {
                $p = $cur.PSObject.Properties[$seg]
                if ($p) { $next = $p.Value }
                if ($null -eq $next) {
                    $ap = $cur.PSObject.Properties['AdditionalProperties']
                    if ($ap -and $ap.Value -is [System.Collections.IDictionary]) {
                        foreach ($k in @($ap.Value.Keys)) { if ("$k" -ieq $seg) { $next = $ap.Value[$k]; break } }
                    }
                }
            }
            $cur = $next
        }
        if ($null -ne $cur -and "$cur" -ne '') { return $cur }
    }
    return $null
}

function Get-MetricSafe {
    param([string]$ResourceId, [string[]]$MetricName, [string]$Aggregation = 'Average')
    try {
        $metric = Get-AzMetric -ResourceId $ResourceId `
            -MetricName $MetricName `
            -TimeGrain 1.00:00:00 `
            -StartTime $metricsStart `
            -EndTime $endTime `
            -AggregationType $Aggregation `
            -WarningAction SilentlyContinue `
            -ErrorAction SilentlyContinue
        return $metric
    } catch { return $null }
}

function Invoke-WithRetry {
    param([scriptblock]$ScriptBlock, [int]$Retries = $MaxRetries, [int]$BaseDelay = 2)
    for ($i = 0; $i -lt $Retries; $i++) {
        try { return & $ScriptBlock }
        catch {
            if ($i -eq ($Retries - 1)) { throw }
            if ($_.Exception.Message -match '429|throttle|too many requests') {
                $delay = $BaseDelay * [math]::Pow(2, $i) + (Get-Random -Minimum 0 -Maximum 2)
                Write-Host "    Throttled, retrying in ${delay}s..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds $delay
            } else { throw }
        }
    }
}

# ARM REST call via Invoke-AzRestMethod with 429/5xx retry (honours Retry-After headers),
# optional nextLink paging and a time budget. Returns one parsed object per page.
$script:lastRestTruncated = $false
function Invoke-ArmRest {
    param(
        [string]$Path,
        [ValidateSet('GET','POST','PUT','PATCH','DELETE')][string]$Method = 'GET',
        $Body,
        [int]$TimeoutSeconds = $SectionTimeoutSeconds,
        [switch]$FollowNextLink
    )
    $script:lastRestTruncated = $false
    $deadline = (Get-Date).AddSeconds([math]::Max($TimeoutSeconds, 1))
    $payload = $null
    if ($null -ne $Body) { $payload = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress } }
    $pages = [System.Collections.ArrayList]::new()
    $next = $Path
    while ($next) {
        $attempt = 0
        while ($true) {
            $p = @{ Method = $Method; ErrorAction = 'Stop' }
            if ($next -match '^https?://') { $p.Uri = $next } else { $p.Path = $next }
            if ($payload) { $p.Payload = $payload }
            $resp = Invoke-AzRestMethod @p
            $code = [int]$resp.StatusCode
            if ($code -ge 200 -and $code -lt 300) { break }
            if (($code -eq 429 -or $code -ge 500) -and $attempt -lt $MaxRetries -and (Get-Date) -lt $deadline) {
                $attempt++
                $wait = 0
                try {
                    foreach ($kv in @($resp.Headers)) {
                        if ("$($kv.Key)" -match 'retry-after$') {
                            $n = 0
                            if ([int]::TryParse("$(@($kv.Value)[0])", [ref]$n) -and $n -gt $wait) { $wait = $n }
                        }
                    }
                } catch {}
                if ($wait -le 0) { $wait = [int](2 * [math]::Pow(2, $attempt)) }
                $wait = [math]::Min($wait, 60)
                Write-Host "    HTTP $code, retrying in ${wait}s..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds $wait
                continue
            }
            $content = "$($resp.Content)"
            if ($content.Length -gt 500) { $content = $content.Substring(0, 500) }
            throw "HTTP $code from $Method $($next -replace '\?.*$', ''): $content"
        }
        $obj = if ($resp.Content) { $resp.Content | ConvertFrom-Json } else { $null }
        $null = $pages.Add($obj)
        $next = $null
        if ($FollowNextLink -and $obj) {
            $next = Get-FirstNonEmpty $obj.nextLink $(if ($obj.properties) { $obj.properties.nextLink })
            if ($next -and (Get-Date) -ge $deadline) {
                $script:lastRestTruncated = $true
                Write-Host "    Time budget reached; results truncated" -ForegroundColor DarkYellow
                $next = $null
            }
        }
    }
    return $pages
}

# Azure Resource Graph query over REST (no Az.ResourceGraph dependency), paged with $skipToken
# and bounded by a time budget. On timeout returns partial rows and marks the dataset Partial.
function Invoke-ResourceGraphQuery {
    param([string]$Query, [string[]]$Subscriptions, [string]$Dataset, [int]$TimeoutSeconds = $SectionTimeoutSeconds)
    $rows = [System.Collections.ArrayList]::new()
    $subs = @($Subscriptions | Where-Object { $_ })
    if ($subs.Count -eq 0) { return @() }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    for ($i = 0; $i -lt $subs.Count; $i += 1000) {
        $chunk = @($subs[$i..([math]::Min($i + 999, $subs.Count - 1))])
        $skip = $null
        do {
            $remaining = [int]($deadline - (Get-Date)).TotalSeconds
            if ($remaining -le 0) {
                Set-NotCollected -Dataset $Dataset -Reason "Resource Graph query exceeded ${TimeoutSeconds}s; results truncated"
                Write-Host "    Resource Graph time budget reached; partial results" -ForegroundColor DarkYellow
                return $rows
            }
            $opts = @{ '$top' = 1000; resultFormat = 'objectArray' }
            if ($skip) { $opts['$skipToken'] = $skip }
            $body = @{ subscriptions = $chunk; query = $Query; options = $opts }
            $page = @(Invoke-ArmRest -Path '/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' -Method POST -Body $body -TimeoutSeconds $remaining)[0]
            foreach ($r in @($page.data)) { if ($null -ne $r) { $null = $rows.Add($r) } }
            $skip = $page.'$skipToken'
        } while ($skip)
    }
    return $rows
}

# NSG helpers: internet-sourced prefixes and management/data ports that make an open rule CRITICAL
$internetSources = @('*', 'Internet', '0.0.0.0/0', 'Any', '::/0')
$criticalPorts   = @(22, 3389, 1433, 3306, 5432, 445)
function Test-PortSpecCovers {
    param([string[]]$PortSpecs, [int[]]$Ports)
    foreach ($spec in @($PortSpecs)) {
        $s = "$spec".Trim()
        if (-not $s) { continue }
        if ($s -eq '*') { return $true }
        if ($s -match '^(\d+)\s*-\s*(\d+)$') {
            $lo = [int]$Matches[1]; $hi = [int]$Matches[2]
            foreach ($p in $Ports) { if ($p -ge $lo -and $p -le $hi) { return $true } }
        } elseif ($s -match '^\d+$') {
            if ([int]$s -in $Ports) { return $true }
        }
    }
    return $false
}

# Az module check: import optional modules up front, record versions, and warn on anything missing
$requiredModules = @('Az.Accounts','Az.Resources','Az.Compute','Az.Network','Az.Storage','Az.Monitor')
$optionalModules = @(
    'Az.Websites','Az.Sql','Az.PostgreSql','Az.MySql','Az.CosmosDB','Az.RedisCache','Az.KeyVault',
    'Az.Security','Az.PolicyInsights','Az.Advisor','Az.Billing','Az.Reservations','Az.RecoveryServices',
    'Az.OperationalInsights','Az.Aks','Az.ContainerInstance','Az.ContainerRegistry','Az.ServiceBus',
    'Az.EventHub','Az.ApiManagement','Az.DataFactory','Az.Automation','Az.ConnectedMachine','Az.Cdn',
    'Az.PrivateDns','Az.Dns'
)
$azModuleVersions = [ordered]@{}
$missingModules = [System.Collections.ArrayList]::new()
foreach ($m in ($requiredModules + $optionalModules)) {
    $avail = Get-Module -ListAvailable -Name $m -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if ($avail) {
        $loaded = Get-Module -Name $m
        if (-not $loaded -and $m -in @('Az.Reservations','Az.PostgreSql','Az.MySql')) {
            try { Import-Module $m -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null; $loaded = Get-Module -Name $m } catch {}
        }
        $azModuleVersions[$m] = if ($loaded) { "$(@($loaded)[0].Version)" } else { "$($avail.Version)" }
    } else {
        $null = $missingModules.Add($m)
    }
}
if ($missingModules.Count -gt 0) {
    Write-Host "  ! Optional Az modules not installed (related sections fall back to REST or are skipped):" -ForegroundColor DarkYellow
    Write-Host "    Install-Module $($missingModules -join ',') -Scope CurrentUser -Repository PSGallery -Force" -ForegroundColor DarkYellow
}
#endregion

#region -- Authentication Check -----------------------------------------------
Write-Section "0. Authentication & Subscription Selection"
$ctx = Get-AzContext
if (-not $ctx) {
    Write-Host "  Not authenticated. Running Connect-AzAccount..." -ForegroundColor Yellow
    try { Connect-AzAccount -ErrorAction Stop | Out-Null } catch {}
    $ctx = Get-AzContext
}
if (-not $ctx) {
    Write-Host "  x Azure authentication failed or was cancelled. Run Connect-AzAccount and retry." -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch {}
    return
}
Write-Host "  Signed in as: $($ctx.Account.Id) ($($ctx.Account.Type))" -ForegroundColor Green
Write-Host "  Tenant:       $($ctx.Tenant.Id)" -ForegroundColor Green

# Run summary is written at startup (so a crashed run still records StartTime) and rewritten at the end
function Write-RunSummary {
    param([switch]$Final)
    $now = Get-Date
    $json = [PSCustomObject]@{
        ScriptVersion    = $ScriptVersion
        StartTime        = $startTime.ToString('o')
        EndTime          = if ($Final) { $now.ToString('o') } else { $null }
        ElapsedMinutes   = [math]::Round(($now - $startTime).TotalMinutes, 1)
        Completed        = [bool]$Final
        PowerShell       = "$($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
        AccountType      = "$($ctx.Account.Type)"
        AccountId        = "$($ctx.Account.Id)"
        TenantId         = "$($ctx.Tenant.Id)"
        Environment      = "$($ctx.Environment.Name)"
        Parameters       = [PSCustomObject]@{
            DaysBack = $DaysBack; CostMonths = $CostMonths; SkipMetrics = [bool]$SkipMetrics
            SectionTimeoutSeconds = $SectionTimeoutSeconds; SubscriptionId = $SubscriptionId
            SubscriptionInclude = $SubscriptionInclude; SubscriptionExclude = $SubscriptionExclude
        }
        AzModuleVersions = [PSCustomObject]$azModuleVersions
        MissingModules   = @($missingModules)
        Subscriptions    = @($subscriptions | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Id = $_.Id } })
        TotalErrors      = $sectionErrors.Count
        NotCollected     = @($script:datasetNotes.Keys | Sort-Object | ForEach-Object { [PSCustomObject]@{ File = $_; Reason = $script:datasetNotes[$_] } })
        SectionTimings   = @($sectionTimings)
        SectionErrors    = @($sectionErrors)
    } | ConvertTo-Json -Depth 6
    # No BOM: Windows PowerShell's UTF8 encoding adds one, which breaks strict JSON readers
    [System.IO.File]::WriteAllText((Join-Path $OutputPath 'Assessment-RunSummary.json'), $json, (New-Object System.Text.UTF8Encoding $false))
}

if ($SubscriptionId) {
    $subscriptions = @(Get-AzSubscription -SubscriptionId $SubscriptionId)
} else {
    $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }
}
if ($SubscriptionInclude) {
    $subscriptions = @($subscriptions | Where-Object { $_.Name -in $SubscriptionInclude -or $_.Id -in $SubscriptionInclude })
}
if ($SubscriptionExclude) {
    $subscriptions = @($subscriptions | Where-Object { $_.Name -notin $SubscriptionExclude -and $_.Id -notin $SubscriptionExclude })
}
Write-Host "  Subscriptions to assess: $($subscriptions.Count)" -ForegroundColor Green
if (@($subscriptions).Count -eq 0) {
    Write-Host "  x No subscriptions matched the selection criteria. Nothing to assess." -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch {}
    return
}

# Export subscription list with offer/agreement type
$subscriptions | ForEach-Object {
    $quotaId = $_.SubscriptionPolicies.QuotaId
    $offerType = switch -Wildcard ($quotaId) {
        'EnterpriseAgreement*'    { 'EA' }
        '*MS-AZR-0017P*'          { 'EA' }
        '*MS-AZR-0145P*'          { 'CSP' }
        '*MS-AZR-0146P*'          { 'CSP' }
        '*MS-AZR-0003P*'          { 'PAYG' }
        '*MS-AZR-0023P*'          { 'PAYG' }
        'MicrosoftCustomer*'      { 'MCA' }
        '*MS-AZR-0015P*'          { 'MCA' }
        'Sponsored*'              { 'Sponsored' }
        '*MSDN*'                  { 'MSDN' }
        '*MS-AZR-0063P*'          { 'Free Trial' }
        '*MicrosoftPartner*'      { 'MPN' }
        default                   { 'Unknown' }
    }
    [PSCustomObject]@{
        Name          = $_.Name
        Id            = $_.Id
        State         = $_.State
        TenantId      = $_.TenantId
        QuotaId       = $quotaId
        SpendingLimit = $_.SubscriptionPolicies.SpendingLimit
        OfferType     = $offerType
    }
} | Export-Csv "$OutputPath/Subscriptions.csv" -NoTypeInformation -Encoding UTF8
#endregion
Write-RunSummary

# ===============================================================================
# COLLECTION ARRAYS - Accumulate across all subscriptions
# ===============================================================================
$allActualCostByResource = [System.Collections.ArrayList]::new()
$allActualCostByService  = [System.Collections.ArrayList]::new()
$allGuestUsers         = [System.Collections.ArrayList]::new()
$allManagedIdentities  = [System.Collections.ArrayList]::new()
$allUserAssignedIds    = [System.Collections.ArrayList]::new()
$allDefenderRecs       = [System.Collections.ArrayList]::new()
$protectedVmIds        = @{}   # lowercased VM resource ID -> vault name
$protectedVmNames      = @{}   # lowercased "sub|rg|name" fallback when SourceResourceId is missing
$backupFailedSubs      = @{}   # subscriptions whose backup items could not be read
$privateEndpointTargets = @{}  # lowercased target resource ID -> private endpoint count
$vmSizeCache           = @{}   # "location|size" -> memory GB
$allResources          = [System.Collections.ArrayList]::new()
$allVMs                = [System.Collections.ArrayList]::new()
$allVMMetrics          = [System.Collections.ArrayList]::new()
$allVMSS               = [System.Collections.ArrayList]::new()
$allDisks              = [System.Collections.ArrayList]::new()
$allSnapshots          = [System.Collections.ArrayList]::new()
$allStorageAccounts    = [System.Collections.ArrayList]::new()
$allAppServicePlans    = [System.Collections.ArrayList]::new()
$allWebApps            = [System.Collections.ArrayList]::new()
$allFunctions          = [System.Collections.ArrayList]::new()
$allLogicApps          = [System.Collections.ArrayList]::new()
$allSQLServers         = [System.Collections.ArrayList]::new()
$allSQLDatabases       = [System.Collections.ArrayList]::new()
$allSQLManagedInst     = [System.Collections.ArrayList]::new()
$allCosmosDB           = [System.Collections.ArrayList]::new()
$allMySQL              = [System.Collections.ArrayList]::new()
$allPostgreSQL         = [System.Collections.ArrayList]::new()
$allRedisCache         = [System.Collections.ArrayList]::new()
$allVNets              = [System.Collections.ArrayList]::new()
$allPublicIPs          = [System.Collections.ArrayList]::new()
$allNSGRules           = [System.Collections.ArrayList]::new()
$allLBs                = [System.Collections.ArrayList]::new()
$allAppGateways        = [System.Collections.ArrayList]::new()
$allFirewalls          = [System.Collections.ArrayList]::new()
$allFrontDoors         = [System.Collections.ArrayList]::new()
$allBastions           = [System.Collections.ArrayList]::new()
$allNATGateways        = [System.Collections.ArrayList]::new()
$allVPNGateways        = [System.Collections.ArrayList]::new()
$allExpressRoute       = [System.Collections.ArrayList]::new()
$allPeerings           = [System.Collections.ArrayList]::new()
$allPrivateEndpoints   = [System.Collections.ArrayList]::new()
$allPrivateDNS         = [System.Collections.ArrayList]::new()
$allPublicDNS          = [System.Collections.ArrayList]::new()
$allNSGs               = [System.Collections.ArrayList]::new()
$allAKS                = [System.Collections.ArrayList]::new()
$allAKSNodePools       = [System.Collections.ArrayList]::new()
$allContainerInstances = [System.Collections.ArrayList]::new()
$allContainerApps      = [System.Collections.ArrayList]::new()
$allContainerRegistries= [System.Collections.ArrayList]::new()
$allKeyVaults          = [System.Collections.ArrayList]::new()
$allExpiringSecrets    = [System.Collections.ArrayList]::new()
$allRBAC               = [System.Collections.ArrayList]::new()
$allCustomRoles        = [System.Collections.ArrayList]::new()
$allPolicyNonCompliant = [System.Collections.ArrayList]::new()
$allPolicyAssignments  = [System.Collections.ArrayList]::new()
$allDefenderPricing    = [System.Collections.ArrayList]::new()
$allSecureScore        = [System.Collections.ArrayList]::new()
$allSecurityAlerts     = [System.Collections.ArrayList]::new()
$allAdvisorCost        = [System.Collections.ArrayList]::new()
$allAdvisorPerf        = [System.Collections.ArrayList]::new()
$allAdvisorSecurity    = [System.Collections.ArrayList]::new()
$allAdvisorAll         = [System.Collections.ArrayList]::new()
$allBackupItems        = [System.Collections.ArrayList]::new()
$allUnprotectedVMs     = [System.Collections.ArrayList]::new()
$allLAWorkspaces       = [System.Collections.ArrayList]::new()
$allDiagSettings       = [System.Collections.ArrayList]::new()
$allAlertRules         = [System.Collections.ArrayList]::new()
$allActionGroups       = [System.Collections.ArrayList]::new()
$allTagCompliance      = [System.Collections.ArrayList]::new()
$allResourceLocks      = [System.Collections.ArrayList]::new()
$allRecoveryVaults     = [System.Collections.ArrayList]::new()
$allServiceBus         = [System.Collections.ArrayList]::new()
$allEventHubs          = [System.Collections.ArrayList]::new()
$allAPIM               = [System.Collections.ArrayList]::new()
$allDataFactories      = [System.Collections.ArrayList]::new()
$allAutomationAccts    = [System.Collections.ArrayList]::new()
$allBudgets            = [System.Collections.ArrayList]::new()
$allArcMachines        = [System.Collections.ArrayList]::new()
$allNetworkWatchers    = [System.Collections.ArrayList]::new()
$allCDNProfiles        = [System.Collections.ArrayList]::new()
$allConsumption        = [System.Collections.ArrayList]::new()
$allReservations       = [System.Collections.ArrayList]::new()
$allMgmtGroups         = [System.Collections.ArrayList]::new()
$allFileShares         = [System.Collections.ArrayList]::new()

# ===============================================================================
# ITERATE SUBSCRIPTIONS
# ===============================================================================
foreach ($sub in $subscriptions) {
    Write-Host "`n-------------------------------------------------------------" -ForegroundColor White
    Write-Host "  SUBSCRIPTION: $($sub.Name) ($($sub.Id))" -ForegroundColor White
    Write-Host "-------------------------------------------------------------" -ForegroundColor White
    Set-AzContext -SubscriptionId $sub.Id | Out-Null
    $subName = $sub.Name
    $script:currentSubName = $sub.Name

    #region -- 1. Resource Inventory ------------------------------------------
    Write-Section "1. Resource Inventory"
    $resources = Get-AzResource
    $resources | Group-Object ResourceType |
        Sort-Object Count -Descending |
        ForEach-Object {
            $null = $allResources.Add([PSCustomObject]@{
                Subscription = $subName
                ResourceType = $_.Name
                Count        = $_.Count
            })
        }
    Write-Host "    Total resources: $($resources.Count)" -ForegroundColor Green
    #endregion

    #region -- 2. Compute: Virtual Machines -----------------------------------
    Write-Section "2. Compute: Virtual Machines"
    Write-SubSection "VM Inventory & Status"
    $vms = @(Get-AzVM -Status -ErrorAction SilentlyContinue)

    # Model view (LicenseType, SecurityProfile) and disks keyed by ID; the disk list is reused in section 6
    $vmModels = @{}
    try { Get-AzVM -ErrorAction Stop | ForEach-Object { if ($_.Id) { $vmModels[$_.Id.ToLower()] = $_ } } }
    catch { Write-SectionError $_ -Context 'Get-AzVM (model view)' }
    $subDisks = @(Get-AzDisk -ErrorAction SilentlyContinue)
    $diskById = @{}
    foreach ($d in $subDisks) { if ($d.Id) { $diskById[$d.Id.ToLower()] = $d } }

    # Azure Disk Encryption extensions, via Resource Graph (one query per subscription)
    $adeVmIds = @{}
    $adeQueryOk = $true
    if ($vms.Count -gt 0) {
        try {
            $adeQuery = "resources | where type =~ 'microsoft.compute/virtualmachines/extensions' | where tostring(properties.publisher) =~ 'Microsoft.Azure.Security' and tostring(properties.type) in~ ('AzureDiskEncryption','AzureDiskEncryptionForLinux') | project id"
            foreach ($ext in @(Invoke-ResourceGraphQuery -Query $adeQuery -Subscriptions @($sub.Id))) {
                $adeVmIds[(($ext.id -replace '/extensions/[^/]+$', '').ToLower())] = $true
            }
        } catch { $adeQueryOk = $false; Write-SectionError $_ -Context 'ADE extension query (Resource Graph)' }
    }

    $sseLabel = @{
        'EncryptionAtRestWithPlatformKey'           = 'SSE-PMK'
        'EncryptionAtRestWithCustomerKey'           = 'SSE-CMK'
        'EncryptionAtRestWithPlatformAndCustomerKeys' = 'SSE-DoubleEncryption'
    }

    foreach ($vm in $vms) {
        $vmKey   = "$($vm.Id)".ToLower()
        $model   = $vmModels[$vmKey]
        $secProf = Get-FirstNonEmpty $(if ($model) { $model.SecurityProfile }) $vm.SecurityProfile
        $licenseType = Get-FirstNonEmpty $(if ($model) { $model.LicenseType }) $vm.LicenseType
        $encAtHost = if ($secProf -and $null -ne $secProf.EncryptionAtHost) { [bool]$secProf.EncryptionAtHost } else { $false }
        $secType   = if ($secProf -and $secProf.SecurityType) { "$($secProf.SecurityType)" } else { 'Standard' }

        $osDiskRef = $vm.StorageProfile.OsDisk
        $osDiskId  = if ($osDiskRef -and $osDiskRef.ManagedDisk) { "$($osDiskRef.ManagedDisk.Id)".ToLower() } else { $null }
        $osDisk    = if ($osDiskId) { $diskById[$osDiskId] } else { $null }
        $osEncType = if ($osDisk -and $osDisk.Encryption) { "$($osDisk.Encryption.Type)" } elseif (-not $osDiskId) { 'Unmanaged' } else { $null }
        $dataEnc = @(foreach ($dd in @($vm.StorageProfile.DataDisks)) {
            if ($dd -and $dd.ManagedDisk -and $dd.ManagedDisk.Id) {
                $dobj = $diskById["$($dd.ManagedDisk.Id)".ToLower()]
                if ($dobj -and $dobj.Encryption) { "$($dobj.Encryption.Type)" } else { 'Unknown' }
            }
        })

        $adeSettings = ($osDiskRef -and $osDiskRef.EncryptionSettings -and $osDiskRef.EncryptionSettings.Enabled) -or
                       ($osDisk -and $osDisk.EncryptionSettingsCollection -and $osDisk.EncryptionSettingsCollection.Enabled)
        $adeExt = if (-not $adeQueryOk) { 'Unknown' } elseif ($adeVmIds.ContainsKey($vmKey)) { 'Present' } else { 'None' }
        $diskEncryption = if ($adeSettings -or $adeExt -eq 'Present') { 'ADE' }
                          elseif ($encAtHost) { 'EncryptionAtHost' }
                          elseif ($osEncType -and $sseLabel.ContainsKey($osEncType)) { $sseLabel[$osEncType] }
                          else { 'Unknown' }

        # Deallocated / stopped duration from the Activity Log (90-day retention)
        $deallocSince = $null; $deallocDays = $null; $deallocOver90 = $null
        if ($vm.PowerState -in @('VM deallocated', 'VM stopped')) {
            try {
                $events = @(Get-AzActivityLog -ResourceId $vm.Id -StartTime (Get-Date).AddDays(-89) -WarningAction SilentlyContinue -ErrorAction Stop)
                $hits = @($events | Where-Object {
                    $op = "$(Get-PropValue $_ @('OperationNameValue','OperationName.Value','OperationName'))"
                    $st = "$(Get-PropValue $_ @('Status.Value','Status'))"
                    $op -match 'virtualMachines/(deallocate|powerOff)/action|Deallocate Virtual Machine|Power Off Virtual Machine' -and $st -eq 'Succeeded'
                } | Sort-Object EventTimestamp -Descending)
                if ($hits.Count -gt 0) {
                    $ts = [datetime]$hits[0].EventTimestamp
                    $deallocSince  = $ts.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                    $deallocDays   = [int]((Get-Date).ToUniversalTime() - $ts.ToUniversalTime()).TotalDays
                    $deallocOver90 = $deallocDays -ge 90
                } else {
                    # No stop/deallocate in the retained Activity Log: stopped for at least ~89 days
                    $deallocDays   = '89+'
                    $deallocOver90 = $true
                }
            } catch { Write-SectionError $_ -Context "Activity Log for $($vm.Name)" }
        }

        $null = $allVMs.Add([PSCustomObject]@{
            Subscription   = $subName
            Name           = $vm.Name
            ResourceGroup  = $vm.ResourceGroupName
            Location       = $vm.Location
            VMSize         = $vm.HardwareProfile.VmSize
            OsType         = $vm.StorageProfile.OsDisk.OsType
            PowerState     = $vm.PowerState
            AvailabilityZone = ($vm.Zones -join ', ')
            DiskEncryption = $diskEncryption
            ResourceId     = $vm.Id
            LicenseType    = if ($licenseType) { $licenseType } else { 'None' }
            SecurityType   = $secType
            EncryptionAtHost = $encAtHost
            OsDiskEncryptionType = $osEncType
            DataDiskEncryptionTypes = Join-Values $dataEnc
            ADEExtension   = $adeExt
            DeallocatedSinceUtc = $deallocSince
            DeallocatedDays = $deallocDays
            DeallocatedOver90Days = $deallocOver90
        })
    }

    if (-not $SkipMetrics -and $vms) {
        Write-SubSection "VM CPU/Memory/Disk Metrics (${DaysBack}d)"
        $runningVMs = @($vms | Where-Object { $_.PowerState -eq 'VM running' })
        $vmCount = $runningVMs.Count
        $vmIndex = 0
        $vmMetricNames = @('Percentage CPU', 'Available Memory Bytes', 'OS Disk IOPS Consumed Percentage', 'Data Disk IOPS Consumed Percentage')
        foreach ($vm in $runningVMs) {
            $vmIndex++
            Write-Host "    [$vmIndex/$vmCount] Collecting metrics for $($vm.Name)..." -ForegroundColor DarkGray -NoNewline
            try {
                $metrics = @(Get-MetricSafe -ResourceId $vm.Id -MetricName $vmMetricNames)
                if ($metrics.Count -eq 0) { $metrics = @(Get-MetricSafe -ResourceId $vm.Id -MetricName 'Percentage CPU') }
                $byName = @{}
                foreach ($m in $metrics) { if ($m -and $m.Name) { $byName["$($m.Name.Value)"] = $m } }
                $cpuMetric = $byName['Percentage CPU']
                $avgCpu = if ($cpuMetric) { ($cpuMetric.Data | Measure-Object -Property Average -Average).Average } else { -1 }
                $maxCpu = if ($cpuMetric) { ($cpuMetric.Data | Measure-Object -Property Average -Maximum).Maximum } else { -1 }
                if ($null -eq $avgCpu) { $avgCpu = -1 }
                if ($null -eq $maxCpu) { $maxCpu = -1 }

                # Total memory for the size (cached per location)
                $vmSize = $vm.HardwareProfile.VmSize
                $sizeKey = "$($vm.Location)|$vmSize".ToLower()
                if (-not $vmSizeCache.ContainsKey($sizeKey)) {
                    try {
                        foreach ($sz in @(Get-AzVMSize -Location $vm.Location -ErrorAction Stop)) {
                            $vmSizeCache["$($vm.Location)|$($sz.Name)".ToLower()] = [math]::Round($sz.MemoryInMB / 1024, 2)
                        }
                    } catch {}
                    if (-not $vmSizeCache.ContainsKey($sizeKey)) { $vmSizeCache[$sizeKey] = $null }
                }
                $memGB = $vmSizeCache[$sizeKey]

                $avgAvailGB = $null; $minAvailGB = $null; $avgMemPct = $null; $peakMemPct = $null
                $memMetric = $byName['Available Memory Bytes']
                if ($memMetric) {
                    $vals = @($memMetric.Data | Where-Object { $null -ne $_.Average } | ForEach-Object { $_.Average })
                    if ($vals.Count -gt 0) {
                        $avgAvailGB = [math]::Round((($vals | Measure-Object -Average).Average) / 1GB, 2)
                        $minAvailGB = [math]::Round((($vals | Measure-Object -Minimum).Minimum) / 1GB, 2)
                        if ($memGB) {
                            $avgMemPct  = [math]::Round(100 * (1 - ($avgAvailGB / $memGB)), 1)
                            $peakMemPct = [math]::Round(100 * (1 - ($minAvailGB / $memGB)), 1)
                        }
                    }
                }
                $diskStat = {
                    param($m)
                    if (-not $m) { return @($null, $null) }
                    $v = @($m.Data | Where-Object { $null -ne $_.Average } | ForEach-Object { $_.Average })
                    if ($v.Count -eq 0) { return @($null, $null) }
                    return @([math]::Round((($v | Measure-Object -Average).Average), 1), [math]::Round((($v | Measure-Object -Maximum).Maximum), 1))
                }
                $osIops   = & $diskStat $byName['OS Disk IOPS Consumed Percentage']
                $dataIops = & $diskStat $byName['Data Disk IOPS Consumed Percentage']

                $null = $allVMMetrics.Add([PSCustomObject]@{
                    Subscription = $subName
                    VM           = $vm.Name
                    VMSize       = $vmSize
                    AvgCPU       = [math]::Round($avgCpu, 1)
                    PeakCPU      = [math]::Round($maxCpu, 1)
                    Recommendation = if ($avgCpu -lt 5) { 'Candidate for DEALLOCATION' }
                                     elseif ($avgCpu -lt 15) { 'Candidate for DOWNSIZE' }
                                     else { 'OK' }
                    ResourceGroup = $vm.ResourceGroupName
                    ResourceId   = $vm.Id
                    MemoryGB     = $memGB
                    AvgAvailableMemoryGB = $avgAvailGB
                    MinAvailableMemoryGB = $minAvailGB
                    AvgMemoryUsedPct  = $avgMemPct
                    PeakMemoryUsedPct = $peakMemPct
                    AvgOsDiskIopsPct  = $osIops[0]
                    PeakOsDiskIopsPct = $osIops[1]
                    AvgDataDiskIopsPct  = $dataIops[0]
                    PeakDataDiskIopsPct = $dataIops[1]
                })
                Write-Host " done" -ForegroundColor DarkGray
            } catch { Write-Host " failed" -ForegroundColor DarkYellow; Write-SectionError $_ -Context "Metrics for $($vm.Name)" }
        }
    }

    # VM Scale Sets
    Write-SubSection "VM Scale Sets"
    try {
        Get-AzVmss -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allVMSS.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                Location      = $_.Location
                SKU           = if ($_.Sku) { $_.Sku.Name } else { $null }
                Capacity      = if ($_.Sku) { $_.Sku.Capacity } else { $null }
                UpgradePolicy = if ($_.UpgradePolicy) { $_.UpgradePolicy.Mode } else { $null }
                Zones         = ($_.Zones -join ', ')
            })
        }
    } catch { Write-SectionError $_ }
    #endregion

    #region -- 3. App Services ------------------------------------------------
    Write-Section "3. App Service Plans & Web Apps"
    Write-SubSection "App Service Plans"
    $plans = Get-AzAppServicePlan -ErrorAction SilentlyContinue
    foreach ($plan in $plans) {
        $apps = Get-AzWebApp -AppServicePlan $plan.Name -ResourceGroupName $plan.ResourceGroup -ErrorAction SilentlyContinue
        $null = $allAppServicePlans.Add([PSCustomObject]@{
            Subscription  = $subName
            Name          = $plan.Name
            ResourceGroup = $plan.ResourceGroup
            Location      = $plan.Location
            SKU           = if ($plan.Sku) { $plan.Sku.Name } else { $null }
            Tier          = if ($plan.Sku) { $plan.Sku.Tier } else { $null }
            Workers       = if ($plan.Sku) { $plan.Sku.Capacity } else { $null }
            AppCount      = @($apps).Count
            Apps          = ($apps.Name -join ', ')
            Status        = $plan.Status
        })
    }

    Write-SubSection "Web Apps"
    try {
        foreach ($site in @(Get-AzWebApp -ErrorAction Stop)) {
            # The list call omits SiteConfig; fetch each app for MinTlsVersion/AlwaysOn/runtime
            $app = $null
            try { $app = Get-AzWebApp -ResourceGroupName $site.ResourceGroup -Name $site.Name -ErrorAction Stop } catch {}
            if (-not $app) { $app = $site }
            $cfg = $app.SiteConfig
            $null = $allWebApps.Add([PSCustomObject]@{
                Subscription   = $subName
                Name           = $app.Name
                ResourceGroup  = $app.ResourceGroup
                Plan           = Get-LastSegment (Get-FirstNonEmpty $app.ServerFarmId $site.ServerFarmId $app.AppServicePlanId)
                State          = $app.State
                HttpsOnly      = $app.HttpsOnly
                MinTlsVersion  = if ($cfg) { $cfg.MinTlsVersion } else { $null }
                AlwaysOn       = if ($cfg) { $cfg.AlwaysOn } else { $null }
                Runtime        = if ($cfg) { "$($cfg.LinuxFxVersion)$($cfg.WindowsFxVersion)" } else { $null }
                Kind           = $app.Kind
                ResourceId     = $app.Id
                FtpsState      = if ($cfg) { $cfg.FtpsState } else { $null }
                PublicNetworkAccess = Get-PropValue $app @('PublicNetworkAccess')
            })
        }
    } catch { Write-SectionError $_ -Context 'Get-AzWebApp' -Dataset '03_WebApps.csv' }
    #endregion

    #region -- 4. Azure Functions ----------------------------------------------
    Write-Section "4. Azure Functions"
    try {
        Get-AzResource -ResourceType 'Microsoft.Web/sites' -ErrorAction Stop |
            Where-Object { $_.Kind -match 'functionapp' } | ForEach-Object {
                $fa = Get-AzWebApp -ResourceGroupName $_.ResourceGroupName -Name $_.Name -ErrorAction SilentlyContinue
                if ($fa) {
                    $null = $allFunctions.Add([PSCustomObject]@{
                        Subscription  = $subName
                        Name          = $fa.Name
                        ResourceGroup = $fa.ResourceGroup
                        State         = $fa.State
                        Runtime       = if ($fa.SiteConfig) { "$($fa.SiteConfig.LinuxFxVersion)$($fa.SiteConfig.WindowsFxVersion)" } else { $null }
                        HttpsOnly     = $fa.HttpsOnly
                        Plan          = Get-LastSegment (Get-FirstNonEmpty $fa.ServerFarmId $fa.AppServicePlanId)
                        Kind          = $_.Kind
                        MinTlsVersion = if ($fa.SiteConfig) { $fa.SiteConfig.MinTlsVersion } else { $null }
                        ResourceId    = $fa.Id
                    })
                }
            }
    } catch { Write-SectionError $_ -Dataset '04_Functions.csv' }
    #endregion

    #region -- 5. Logic Apps --------------------------------------------------
    Write-Section "5. Logic Apps"
    try {
        Get-AzResource -ResourceType 'Microsoft.Logic/workflows' -ExpandProperties -ErrorAction Stop | ForEach-Object {
            $null = $allLogicApps.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                Location      = $_.Location
                State         = Get-PropValue $_ @('Properties.state', 'Properties.State')
                ResourceId    = $_.ResourceId
            })
        }
    } catch { Write-SectionError $_ -Dataset '05_LogicApps.csv' }
    #endregion

    #region -- 6. Storage -----------------------------------------------------
    Write-Section "6. Storage Assessment"
    Write-SubSection "Managed Disks"
    foreach ($disk in $subDisks) {
        $null = $allDisks.Add([PSCustomObject]@{
            Subscription  = $subName
            Name          = $disk.Name
            ResourceGroup = $disk.ResourceGroupName
            AttachedTo    = if ($disk.ManagedBy) { Get-LastSegment $disk.ManagedBy } else { 'UNATTACHED' }
            DiskSizeGB    = $disk.DiskSizeGB
            SKU           = if ($disk.Sku) { $disk.Sku.Name } else { $null }
            IOPS          = $disk.DiskIOPSReadWrite
            ThroughputMBps = $disk.DiskMBpsReadWrite
            Encryption    = if ($disk.EncryptionSettingsCollection) { $disk.EncryptionSettingsCollection.Enabled } else { $null }
            Location      = $disk.Location
            CreatedDate   = $disk.TimeCreated
            EncryptionType = if ($disk.Encryption) { $disk.Encryption.Type } else { $null }
            DiskState     = $disk.DiskState
            ResourceId    = $disk.Id
        })
    }

    Write-SubSection "Snapshots"
    Get-AzSnapshot -ErrorAction SilentlyContinue | ForEach-Object {
        $created = $_.TimeCreated
        $age = if ($created) { ((Get-Date) - $created).Days } else { $null }
        $null = $allSnapshots.Add([PSCustomObject]@{
            Subscription  = $subName
            Name          = $_.Name
            ResourceGroup = $_.ResourceGroupName
            DiskSizeGB    = $_.DiskSizeGB
            AgeDays       = $age
            CreatedDate   = if ($created) { $created.ToString('yyyy-MM-dd') } else { $null }
            Recommendation = if ($null -ne $age -and $age -gt 90) { 'REVIEW - Over 90 days old' } else { 'OK' }
        })
    }

    Write-SubSection "Storage Accounts"
    $storAccts = @(Get-AzStorageAccount -ErrorAction SilentlyContinue)
    $shareDeadline = (Get-Date).AddSeconds($SectionTimeoutSeconds)
    $shareTimedOut = $false
    foreach ($sa in $storAccts) {
        $acl = $sa.NetworkRuleSet
        $null = $allStorageAccounts.Add([PSCustomObject]@{
            Subscription   = $subName
            Name           = $sa.StorageAccountName
            ResourceGroup  = $sa.ResourceGroupName
            SKU            = if ($sa.Sku) { $sa.Sku.Name } else { $null }
            Kind           = $sa.Kind
            AccessTier     = $sa.AccessTier
            HttpsOnly      = $sa.EnableHttpsTrafficOnly
            MinTLS         = $sa.MinimumTlsVersion
            PublicAccess    = $sa.AllowBlobPublicAccess
            Location       = $sa.PrimaryLocation
            ResourceId     = $sa.Id
            PublicNetworkAccess = Get-FirstNonEmpty $sa.PublicNetworkAccess 'Enabled'
            NetworkDefaultAction = if ($acl) { "$($acl.DefaultAction)" } else { 'Allow' }
            IpRuleCount    = if ($acl) { @($acl.IpRules | Where-Object { $_ }).Count } else { 0 }
            VNetRuleCount  = if ($acl) { @($acl.VirtualNetworkRules | Where-Object { $_ }).Count } else { 0 }
            AllowSharedKeyAccess = if ($null -eq $sa.AllowSharedKeyAccess) { $true } else { $sa.AllowSharedKeyAccess }
            PrivateEndpointCount = $null
        })

        # File shares via the control plane (no data-plane keys, no hangs on firewalled accounts)
        if ($sa.Kind -in @('BlobStorage', 'BlockBlobStorage')) { continue }
        if ($shareTimedOut) { continue }
        if ((Get-Date) -gt $shareDeadline) {
            $shareTimedOut = $true
            Set-NotCollected -Dataset '06_FileShares.csv' -Reason "[$subName] file share enumeration exceeded ${SectionTimeoutSeconds}s; remaining accounts skipped"
            Write-Host "    File share time budget reached; skipping remaining accounts" -ForegroundColor DarkYellow
            continue
        }
        try {
            Get-AzRmStorageShare -ResourceGroupName $sa.ResourceGroupName -StorageAccountName $sa.StorageAccountName -ErrorAction Stop | ForEach-Object {
                $null = $allFileShares.Add([PSCustomObject]@{
                    Subscription   = $subName
                    StorageAccount = $sa.StorageAccountName
                    ShareName      = $_.Name
                    QuotaGB        = $_.QuotaGiB
                    AccessTier     = $_.AccessTier
                    ResourceGroup  = $sa.ResourceGroupName
                    EnabledProtocols = $_.EnabledProtocols
                })
            }
        } catch { Write-SectionError $_ -Context "File shares: $($sa.StorageAccountName)" -Dataset '06_FileShares.csv' }
    }
    #endregion

    #region -- 7. Networking --------------------------------------------------
    Write-Section "7. Networking"
    Write-SubSection "Virtual Networks & Subnets"
    Get-AzVirtualNetwork -ErrorAction SilentlyContinue | ForEach-Object {
        $vnet = $_
        @($vnet.Subnets) | Where-Object { $_ } | ForEach-Object {
            $null = $allVNets.Add([PSCustomObject]@{
                Subscription = $subName
                VNet         = $vnet.Name
                AddressSpace = ($vnet.AddressSpace.AddressPrefixes -join ', ')
                Subnet       = $_.Name
                SubnetPrefix = ($_.AddressPrefix -join ', ')
                NSG          = if ($_.NetworkSecurityGroup) { Get-LastSegment $_.NetworkSecurityGroup.Id } else { 'NONE' }
                RouteTable   = if ($_.RouteTable) { Get-LastSegment $_.RouteTable.Id } else { 'NONE' }
            })
        }

        # VNet Peerings
        @($vnet.VirtualNetworkPeerings) | Where-Object { $_ } | ForEach-Object {
            $null = $allPeerings.Add([PSCustomObject]@{
                Subscription       = $subName
                VNet               = $vnet.Name
                PeeringName        = $_.Name
                RemoteVNet         = if ($_.RemoteVirtualNetwork) { Get-LastSegment $_.RemoteVirtualNetwork.Id } else { $null }
                State              = $_.PeeringState
                AllowForwarded     = $_.AllowForwardedTraffic
                AllowGatewayTransit = $_.AllowGatewayTransit
                UseRemoteGateway   = $_.UseRemoteGateways
            })
        }
    }

    Write-SubSection "Orphaned Public IPs"
    # IPs referenced by a NAT gateway are in use even though IpConfiguration is empty
    $natIpIds = @{}
    $subNatGateways = @()
    try {
        $subNatGateways = @(Get-AzNatGateway -ErrorAction Stop)
        foreach ($ng in $subNatGateways) {
            foreach ($pip in @($ng.PublicIpAddresses)) { if ($pip -and $pip.Id) { $natIpIds[$pip.Id.ToLower()] = $ng.Name } }
        }
    } catch { Write-SectionError $_ -Context 'Get-AzNatGateway (public IP attachment)' }
    try {
        Get-AzPublicIpAddress -ErrorAction Stop | ForEach-Object {
            $attached = ($null -ne $_.IpConfiguration) -or ($null -ne $_.NatGateway) -or ($_.Id -and $natIpIds.ContainsKey($_.Id.ToLower()))
            if (-not $attached) {
                $null = $allPublicIPs.Add([PSCustomObject]@{
                    Subscription  = $subName
                    Name          = $_.Name
                    ResourceGroup = $_.ResourceGroupName
                    IpAddress     = $_.IpAddress
                    SKU           = if ($_.Sku) { $_.Sku.Name } else { $null }
                    Allocation    = $_.PublicIpAllocationMethod
                    ResourceId    = $_.Id
                    Location      = $_.Location
                })
            }
        }
    } catch { Write-SectionError $_ -Dataset '07_OrphanedPublicIPs.csv' }

    Write-SubSection "NSG Rule Audit"
    try {
        Get-AzNetworkSecurityGroup -ErrorAction Stop | ForEach-Object {
            $nsg = $_
            foreach ($rule in @($nsg.SecurityRules)) {
                if (-not $rule -or $rule.Access -ne 'Allow' -or $rule.Direction -ne 'Inbound') { continue }
                # SourceAddressPrefix / DestinationPortRange are List[string]; merge with the plural forms
                $sources = @(Join-Values @($rule.SourceAddressPrefix, $rule.SourceAddressPrefixes) -Separator "`n" | ForEach-Object { $_ -split "`n" } | Where-Object { $_ })
                $ports   = @(Join-Values @($rule.DestinationPortRange, $rule.DestinationPortRanges) -Separator "`n" | ForEach-Object { $_ -split "`n" } | Where-Object { $_ })
                $fromInternet = @($sources | Where-Object { $_ -in $internetSources }).Count -gt 0
                if (-not $fromInternet) { continue }
                $severity = 'Medium'
                if (Test-PortSpecCovers -PortSpecs $ports -Ports $criticalPorts) { $severity = 'CRITICAL' }
                $null = $allNSGRules.Add([PSCustomObject]@{
                    Subscription  = $subName
                    NSG           = $nsg.Name
                    Rule          = $rule.Name
                    Priority      = $rule.Priority
                    DestPort      = ($ports -join ',')
                    Source        = ($sources -join ',')
                    Severity      = $severity
                    ResourceGroup = $nsg.ResourceGroupName
                    Protocol      = $rule.Protocol
                    DestinationAddress = Join-Values @($rule.DestinationAddressPrefix, $rule.DestinationAddressPrefixes)
                })
            }
        }
    } catch { Write-SectionError $_ -Dataset '07_OpenNSGRules.csv' }

    Write-SubSection "Load Balancers"
    Get-AzLoadBalancer -ErrorAction SilentlyContinue | ForEach-Object {
        $null = $allLBs.Add([PSCustomObject]@{
            Subscription  = $subName
            Name          = $_.Name
            ResourceGroup = $_.ResourceGroupName
            SKU           = if ($_.Sku) { $_.Sku.Name } else { $null }
            FrontendIPs   = $_.FrontendIpConfigurations.Count
            BackendPools  = $_.BackendAddressPools.Count
            Rules         = $_.LoadBalancingRules.Count
        })
    }

    Write-SubSection "Application Gateways"
    Get-AzApplicationGateway -ErrorAction SilentlyContinue | ForEach-Object {
        $null = $allAppGateways.Add([PSCustomObject]@{
            Subscription  = $subName
            Name          = $_.Name
            ResourceGroup = $_.ResourceGroupName
            Tier          = if ($_.Sku) { $_.Sku.Tier } else { $null }
            Capacity      = if ($_.Sku) { $_.Sku.Capacity } else { $null }
            WAFEnabled    = if ($_.WebApplicationFirewallConfiguration) { $_.WebApplicationFirewallConfiguration.Enabled } else { $null }
        })
    }

    Write-SubSection "Azure Firewalls"
    try {
        Get-AzFirewall -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allFirewalls.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                SKU           = if ($_.Sku) { $_.Sku.Tier } else { $null }
                ThreatIntel   = $_.ThreatIntelMode
                ProvisionState = $_.ProvisioningState
            })
        }
    } catch { Write-SectionError $_ }

    Write-SubSection "Azure Front Door"
    try {
        Get-AzResource -ResourceType 'Microsoft.Cdn/profiles' -ErrorAction SilentlyContinue |
            Where-Object { $_.Kind -match 'frontdoor' } | ForEach-Object {
                $null = $allFrontDoors.Add([PSCustomObject]@{
                    Subscription  = $subName
                    Name          = $_.Name
                    ResourceGroup = $_.ResourceGroupName
                    Location      = $_.Location
                    Kind          = $_.Kind
                })
            }
        Get-AzResource -ResourceType 'Microsoft.Network/frontDoors' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allFrontDoors.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                Location      = $_.Location
                Kind          = 'Classic'
            })
        }
    } catch { Write-SectionError $_ }

    Write-SubSection "Azure Bastion"
    try {
        Get-AzResource -ResourceType 'Microsoft.Network/bastionHosts' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allBastions.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                Location      = $_.Location
            })
        }
    } catch { Write-SectionError $_ }

    Write-SubSection "NAT Gateways"
    try {
        $subNatGateways | ForEach-Object {
            $null = $allNATGateways.Add([PSCustomObject]@{
                Subscription        = $subName
                Name                = $_.Name
                ResourceGroup       = $_.ResourceGroupName
                Location            = $_.Location
                IdleTimeoutMinutes  = $_.IdleTimeoutInMinutes
                PublicIpCount       = @($_.PublicIpAddresses).Count
            })
        }
    } catch { Write-SectionError $_ }

    Write-SubSection "VPN Gateways"
    Get-AzResource -ResourceType 'Microsoft.Network/virtualNetworkGateways' -ErrorAction SilentlyContinue | ForEach-Object {
        $gw = Get-AzVirtualNetworkGateway -ResourceId $_.ResourceId -ErrorAction SilentlyContinue
        if ($gw) {
            $null = $allVPNGateways.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $gw.Name
                ResourceGroup = $gw.ResourceGroupName
                SKU           = if ($gw.Sku) { $gw.Sku.Name } else { $null }
                GatewayType   = $gw.GatewayType
                VpnType       = $gw.VpnType
                ActiveActive  = $gw.ActiveActive
            })
        }
    }

    Write-SubSection "ExpressRoute Circuits"
    Get-AzExpressRouteCircuit -ErrorAction SilentlyContinue | ForEach-Object {
        $null = $allExpressRoute.Add([PSCustomObject]@{
            Subscription  = $subName
            Name          = $_.Name
            SKU           = if ($_.Sku) { $_.Sku.Name } else { $null }
            Tier          = if ($_.Sku) { $_.Sku.Tier } else { $null }
            Bandwidth     = if ($_.ServiceProviderProperties) { $_.ServiceProviderProperties.BandwidthInMbps } else { $null }
            Provider      = if ($_.ServiceProviderProperties) { $_.ServiceProviderProperties.ServiceProviderName } else { $null }
            State         = $_.CircuitProvisioningState
        })
    }

    Write-SubSection "Private Endpoints & DNS"
    try {
        Get-AzPrivateEndpoint -ErrorAction Stop | ForEach-Object {
            $conns = @(@($_.PrivateLinkServiceConnections) + @($_.ManualPrivateLinkServiceConnections) | Where-Object { $_ })
            $targets = @($conns | ForEach-Object { $_.PrivateLinkServiceId } | Where-Object { $_ })
            foreach ($t in ($targets | Select-Object -Unique)) {
                $k = "$t".ToLower()
                $privateEndpointTargets[$k] = 1 + [int]$privateEndpointTargets[$k]
            }
            $null = $allPrivateEndpoints.Add([PSCustomObject]@{
                Subscription      = $subName
                Name              = $_.Name
                ResourceGroup     = $_.ResourceGroupName
                Subnet            = if ($_.Subnet) { Get-LastSegment $_.Subnet.Id } else { $null }
                PrivateLinkService = ($conns.Name -join ', ')
                TargetResourceId  = Join-Values $targets
                GroupIds          = Join-Values @($conns | ForEach-Object { $_.GroupIds })
                ConnectionState   = Join-Values @($conns | ForEach-Object { if ($_.PrivateLinkServiceConnectionState) { $_.PrivateLinkServiceConnectionState.Status } })
            })
        }
    } catch { Write-SectionError $_ -Dataset '07_PrivateEndpoints.csv' }
    Get-AzPrivateDnsZone -ErrorAction SilentlyContinue | ForEach-Object {
        $null = $allPrivateDNS.Add([PSCustomObject]@{
            Subscription  = $subName
            Name          = $_.Name
            ResourceGroup = $_.ResourceGroupName
            RecordSets    = $_.NumberOfRecordSets
            VNetLinks     = $_.NumberOfVirtualNetworkLinks
        })
    }

    Write-SubSection "Public DNS Zones"
    try {
        Get-AzDnsZone -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allPublicDNS.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                RecordSets    = $_.NumberOfRecordSets
                NameServers   = ($_.NameServers -join ', ')
            })
        }
    } catch { Write-SectionError $_ }

    Write-SubSection "Network Watchers"
    try {
        Get-AzNetworkWatcher -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allNetworkWatchers.Add([PSCustomObject]@{
                Subscription      = $subName
                Name              = $_.Name
                ResourceGroup     = $_.ResourceGroupName
                Location          = $_.Location
                ProvisioningState = $_.ProvisioningState
            })
        }
    } catch { Write-SectionError $_ }

    Write-SubSection "CDN Profiles"
    try {
        Get-AzResource -ResourceType 'Microsoft.Cdn/profiles' -ErrorAction SilentlyContinue |
            Where-Object { $_.Kind -notmatch 'frontdoor' } | ForEach-Object {
                $null = $allCDNProfiles.Add([PSCustomObject]@{
                    Subscription  = $subName
                    Name          = $_.Name
                    ResourceGroup = $_.ResourceGroupName
                    Location      = $_.Location
                    SKU           = if ($_.Sku) { $_.Sku.Name } else { $null }
                })
            }
    } catch { Write-SectionError $_ }
    #endregion

    #region -- 8. Database Services -------------------------------------------
    Write-Section "8. Database Services"
    Write-SubSection "Azure SQL"
    try {
        Get-AzSqlServer -ErrorAction Stop | ForEach-Object {
            $server = $_
            $srvRg = $server.ResourceGroupName; $srvName = $server.ServerName

            $entraOnly = $null; $entraAdmin = $null
            try { $entraOnly = (Get-AzSqlServerActiveDirectoryOnlyAuthentication -ServerName $srvName -ResourceGroupName $srvRg -ErrorAction Stop).AzureADOnlyAuthentication }
            catch { Write-SectionError $_ -Context "SQL Entra-only auth: $srvName" }
            try { $entraAdmin = (Get-AzSqlServerActiveDirectoryAdministrator -ServerName $srvName -ResourceGroupName $srvRg -ErrorAction Stop).DisplayName }
            catch {}

            $auditEnabled = $null; $auditDest = $null
            try {
                $audit = Get-AzSqlServerAudit -ServerName $srvName -ResourceGroupName $srvRg -ErrorAction Stop
                $dests = @()
                if ("$($audit.BlobStorageTargetState)" -eq 'Enabled') { $dests += 'Storage' }
                if ("$($audit.LogAnalyticsTargetState)" -eq 'Enabled') { $dests += 'LogAnalytics' }
                if ("$($audit.EventHubTargetState)" -eq 'Enabled')     { $dests += 'EventHub' }
                $auditEnabled = $dests.Count -gt 0
                $auditDest = $dests -join ','
            } catch { Write-SectionError $_ -Context "SQL auditing: $srvName" }

            $fwRules = @()
            $allowAzure = $null; $openToInternet = $null
            try {
                $fwRules = @(Get-AzSqlServerFirewallRule -ServerName $srvName -ResourceGroupName $srvRg -ErrorAction Stop)
                $allowAzure = @($fwRules | Where-Object { $_.StartIpAddress -eq '0.0.0.0' -and $_.EndIpAddress -eq '0.0.0.0' }).Count -gt 0
                # A rule spanning a /8 or more is treated as open to the internet
                $openToInternet = @($fwRules | Where-Object {
                    $s = $null; $e = $null
                    if ([System.Net.IPAddress]::TryParse("$($_.StartIpAddress)", [ref]$s) -and [System.Net.IPAddress]::TryParse("$($_.EndIpAddress)", [ref]$e)) {
                        $sb = $s.GetAddressBytes(); $eb = $e.GetAddressBytes()
                        $sv = [uint64]$sb[0] * 16777216 + [uint64]$sb[1] * 65536 + [uint64]$sb[2] * 256 + [uint64]$sb[3]
                        $ev = [uint64]$eb[0] * 16777216 + [uint64]$eb[1] * 65536 + [uint64]$eb[2] * 256 + [uint64]$eb[3]
                        ($ev - $sv) -ge 16777215 -and $ev -ge $sv
                    } else { $false }
                }).Count -gt 0
            } catch { Write-SectionError $_ -Context "SQL firewall: $srvName" }

            $null = $allSQLServers.Add([PSCustomObject]@{
                Subscription  = $subName
                ServerName    = $srvName
                ResourceGroup = $srvRg
                Location      = $server.Location
                AdminLogin    = $server.SqlAdministratorLogin
                Version       = $server.ServerVersion
                ResourceId    = $server.ResourceId
                PublicNetworkAccess = Get-FirstNonEmpty $server.PublicNetworkAccess 'Enabled'
                MinimalTlsVersion = $server.MinimalTlsVersion
                EntraOnlyAuth = $entraOnly
                EntraAdmin    = $entraAdmin
                AuditingEnabled = $auditEnabled
                AuditDestinations = $auditDest
                AllowAzureServices = $allowAzure
                OpenToInternet = $openToInternet
                FirewallRuleCount = $fwRules.Count
                PrivateEndpointCount = $null
            })
            Get-AzSqlDatabase -ServerName $srvName -ResourceGroupName $srvRg -ErrorAction SilentlyContinue |
                Where-Object { $_.DatabaseName -ne 'master' } | ForEach-Object {
                    $tde = $null
                    try { $tde = "$((Get-AzSqlDatabaseTransparentDataEncryption -ServerName $srvName -ResourceGroupName $srvRg -DatabaseName $_.DatabaseName -ErrorAction Stop).State)" }
                    catch {}
                    $null = $allSQLDatabases.Add([PSCustomObject]@{
                        Subscription     = $subName
                        Server           = $srvName
                        Database         = $_.DatabaseName
                        Edition          = $_.Edition
                        ServiceObjective = $_.CurrentServiceObjectiveName
                        MaxSizeGB        = if ($_.MaxSizeBytes) { [math]::Round($_.MaxSizeBytes / 1GB, 2) } else { $null }
                        Status           = $_.Status
                        ZoneRedundant    = $_.ZoneRedundant
                        ResourceGroup    = $srvRg
                        TDE              = $tde
                        ElasticPool      = $_.ElasticPoolName
                        ResourceId       = $_.ResourceId
                    })
                }
        }
    } catch { Write-SectionError $_ -Dataset '08_SQLServers.csv' }

    Write-SubSection "SQL Managed Instances"
    try {
        Get-AzSqlInstance -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allSQLManagedInst.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.ManagedInstanceName
                ResourceGroup = $_.ResourceGroupName
                SKU           = if ($_.Sku) { $_.Sku.Name } else { $null }
                vCores        = $_.VCores
                StorageGB     = $_.StorageSizeInGB
                LicenseType   = $_.LicenseType
                State         = $_.State
            })
        }
    } catch { Write-SectionError $_ }

    Write-SubSection "Cosmos DB"
    Get-AzResource -ResourceType 'Microsoft.DocumentDB/databaseAccounts' -ErrorAction SilentlyContinue | ForEach-Object {
        $acct = Get-AzCosmosDBAccount -ResourceGroupName $_.ResourceGroupName -Name $_.Name -ErrorAction SilentlyContinue
        if ($acct) {
            $null = $allCosmosDB.Add([PSCustomObject]@{
                Subscription             = $subName
                Name                     = $acct.Name
                ResourceGroup            = $acct.ResourceGroupName
                Kind                     = $acct.Kind
                ConsistencyLevel         = $acct.ConsistencyPolicy.DefaultConsistencyLevel
                MultipleWriteLocations   = $acct.EnableMultipleWriteLocations
                Locations                = ($acct.Locations.LocationName -join ', ')
            })
        }
    }

    # MySQL / PostgreSQL flexible servers: use the Az.MySql / Az.PostgreSql cmdlets when installed,
    # filling any gaps from the ARM resource so the section still works without the modules
    foreach ($flex in @(
        @{ Label = 'MySQL';      Type = 'Microsoft.DBforMySQL/flexibleServers';      Cmd = 'Get-AzMySqlFlexibleServer';      List = $allMySQL;      File = '08_MySQL.csv' },
        @{ Label = 'PostgreSQL'; Type = 'Microsoft.DBforPostgreSQL/flexibleServers'; Cmd = 'Get-AzPostgreSqlFlexibleServer'; List = $allPostgreSQL; File = '08_PostgreSQL.csv' }
    )) {
        Write-SubSection "$($flex.Label) Flexible Servers"
        $useCmd = Test-CommandAvailable $flex.Cmd
        try {
            Get-AzResource -ResourceType $flex.Type -ExpandProperties -ErrorAction Stop | ForEach-Object {
                $res = $_
                $srv = $null
                if ($useCmd) { try { $srv = & $flex.Cmd -ResourceGroupName $res.ResourceGroupName -Name $res.Name -ErrorAction Stop } catch {} }
                $null = $flex.List.Add([PSCustomObject]@{
                    Subscription  = $subName
                    Name          = $res.Name
                    ResourceGroup = $res.ResourceGroupName
                    SKU           = Get-FirstNonEmpty (Get-PropValue $srv @('SkuName')) (Get-PropValue $res @('Sku.Name'))
                    Tier          = Get-FirstNonEmpty (Get-PropValue $srv @('SkuTier')) (Get-PropValue $res @('Sku.Tier'))
                    StorageGB     = Get-FirstNonEmpty (Get-PropValue $srv @('StorageSizeGb','StorageSizeGB')) (Get-PropValue $res @('Properties.storage.storageSizeGB'))
                    Version       = Get-FirstNonEmpty (Get-PropValue $srv @('Version')) (Get-PropValue $res @('Properties.version'))
                    State         = Get-FirstNonEmpty (Get-PropValue $srv @('State')) (Get-PropValue $res @('Properties.state'))
                    Location      = $res.Location
                    PublicNetworkAccess = Get-PropValue $res @('Properties.network.publicNetworkAccess')
                    HighAvailability = Get-PropValue $res @('Properties.highAvailability.mode')
                    BackupRetentionDays = Get-PropValue $res @('Properties.backup.backupRetentionDays')
                    GeoRedundantBackup = Get-PropValue $res @('Properties.backup.geoRedundantBackup')
                    ResourceId    = $res.ResourceId
                })
            }
        } catch { Write-SectionError $_ -Dataset $flex.File }
    }

    Write-SubSection "Redis Cache"
    try {
        Get-AzResource -ResourceType 'Microsoft.Cache/Redis' -ErrorAction SilentlyContinue | ForEach-Object {
            $cache = Get-AzRedisCache -ResourceGroupName $_.ResourceGroupName -Name $_.Name -ErrorAction SilentlyContinue
            if ($cache) {
                $null = $allRedisCache.Add([PSCustomObject]@{
                    Subscription  = $subName
                    Name          = $cache.Name
                    ResourceGroup = $cache.ResourceGroupName
                    SKU           = if ($cache.Sku) { $cache.Sku.Name } else { $null }
                    Size          = $cache.Size
                    ShardCount    = $cache.ShardCount
                    NonSslPort    = $cache.EnableNonSslPort
                    MinTLS        = $cache.MinimumTlsVersion
                    Location      = $cache.Location
                })
            }
        }
    } catch { Write-SectionError $_ }
    #endregion

    #region -- 9. Messaging & Integration -------------------------------------
    Write-Section "9. Messaging & Integration"
    Write-SubSection "Service Bus"
    try {
        Get-AzResource -ResourceType 'Microsoft.ServiceBus/namespaces' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allServiceBus.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                Location      = $_.Location
                SKU           = if ($_.Sku) { $_.Sku.Name } else { $null }
            })
        }
    } catch { Write-SectionError $_ }

    Write-SubSection "Event Hubs"
    try {
        Get-AzResource -ResourceType 'Microsoft.EventHub/namespaces' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allEventHubs.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                Location      = $_.Location
                SKU           = if ($_.Sku) { $_.Sku.Name } else { $null }
            })
        }
    } catch { Write-SectionError $_ }

    Write-SubSection "API Management"
    try {
        Get-AzResource -ResourceType 'Microsoft.ApiManagement/service' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allAPIM.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                Location      = $_.Location
                SKU           = if ($_.Sku) { $_.Sku.Name } else { $null }
            })
        }
    } catch { Write-SectionError $_ }
    #endregion

    #region -- 10. Containers -------------------------------------------------
    Write-Section "10. Containers"
    Write-SubSection "AKS Clusters"
    try {
        Get-AzResource -ResourceType 'Microsoft.ContainerService/managedClusters' -ErrorAction SilentlyContinue | ForEach-Object {
            $cluster = Get-AzAksCluster -ResourceGroupName $_.ResourceGroupName -Name $_.Name -ErrorAction SilentlyContinue
            if ($cluster) {
                $null = $allAKS.Add([PSCustomObject]@{
                    Subscription  = $subName
                    Name          = $cluster.Name
                    ResourceGroup = $cluster.ResourceGroupName
                    K8sVersion    = $cluster.KubernetesVersion
                    NodePools     = $cluster.AgentPoolProfiles.Count
                    NetworkPlugin = if ($cluster.NetworkProfile) { $cluster.NetworkProfile.NetworkPlugin } else { $null }
                    NetworkPolicy = if ($cluster.NetworkProfile) { $cluster.NetworkProfile.NetworkPolicy } else { $null }
                    RBAC          = $cluster.EnableRBAC
                })
                $cluster.AgentPoolProfiles | ForEach-Object {
                    $null = $allAKSNodePools.Add([PSCustomObject]@{
                        Subscription = $subName
                        Cluster      = $cluster.Name
                        Pool         = $_.Name
                        VMSize       = $_.VmSize
                        Count        = $_.Count
                        MinCount     = $_.MinCount
                        MaxCount     = $_.MaxCount
                        AutoScale    = $_.EnableAutoScaling
                        OsType       = $_.OsType
                        Mode         = $_.Mode
                    })
                }
            }
        }
    } catch { Write-SectionError $_ }

    Write-SubSection "Container Instances"
    try {
        Get-AzResource -ResourceType 'Microsoft.ContainerInstance/containerGroups' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allContainerInstances.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                Location      = $_.Location
            })
        }
    } catch { Write-SectionError $_ }

    Write-SubSection "Container Apps"
    try {
        Get-AzResource -ResourceType 'Microsoft.App/containerApps' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allContainerApps.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                Location      = $_.Location
            })
        }
    } catch { Write-SectionError $_ }

    Write-SubSection "Container Registries"
    try {
        Get-AzResource -ResourceType 'Microsoft.ContainerRegistry/registries' -ErrorAction SilentlyContinue | ForEach-Object {
            $reg = Get-AzContainerRegistry -ResourceGroupName $_.ResourceGroupName -Name $_.Name -ErrorAction SilentlyContinue
            if ($reg) {
                $null = $allContainerRegistries.Add([PSCustomObject]@{
                    Subscription  = $subName
                    Name          = $reg.Name
                    ResourceGroup = $reg.ResourceGroupName
                    SKU           = $reg.SkuName
                    AdminEnabled  = $reg.AdminUserEnabled
                    LoginServer   = $reg.LoginServer
                    Location      = $reg.Location
                })
            }
        }
    } catch { Write-SectionError $_ }
    #endregion

    #region -- 11. Data & Analytics -------------------------------------------
    Write-Section "11. Data & Analytics"
    Write-SubSection "Data Factories"
    try {
        Get-AzResource -ResourceType 'Microsoft.DataFactory/factories' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allDataFactories.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                Location      = $_.Location
            })
        }
    } catch { Write-SectionError $_ }
    #endregion

    #region -- 12. Identity & RBAC --------------------------------------------
    Write-Section "12. Identity & RBAC"
    Write-SubSection "Role Assignments (incl. classic administrators)"
    try {
        Get-AzRoleAssignment -IncludeClassicAdministrators -ErrorAction Stop | ForEach-Object {
            $role    = "$($_.RoleDefinitionName)"
            $scope   = "$($_.Scope)"
            $isClassic = $role -match 'ServiceAdministrator|AccountAdministrator|CoAdministrator'
            $isOwner = ($role -eq 'Owner') -or ($role -match 'ServiceAdministrator|AccountAdministrator')
            $scopeLevel = if ($scope -eq '/' ) { 'Root' }
                          elseif ($scope -match '^/providers/Microsoft\.Management/managementGroups/') { 'ManagementGroup' }
                          elseif ($scope -match '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/') { 'Resource' }
                          elseif ($scope -match '^/subscriptions/[^/]+/resourceGroups/[^/]+$') { 'ResourceGroup' }
                          elseif ($scope -match '^/subscriptions/[^/]+$') { 'Subscription' }
                          elseif ($isClassic) { 'Subscription' }
                          else { 'Other' }
            $null = $allRBAC.Add([PSCustomObject]@{
                Subscription       = $subName
                DisplayName        = $_.DisplayName
                SignInName         = $_.SignInName
                RoleDefinitionName = $role
                Scope              = $scope
                ObjectType         = $_.ObjectType
                HighRisk           = if ($role -in @('Owner','Contributor','User Access Administrator') -or $isClassic) { 'YES' } else { 'No' }
                ObjectId           = $_.ObjectId
                RoleDefinitionId   = $_.RoleDefinitionId
                ScopeLevel         = $scopeLevel
                IsOwner            = $isOwner
                IsClassicAdmin     = $isClassic
                IsGuest            = ("$($_.SignInName)" -match '#EXT#')
                IsOrphaned         = ("$($_.ObjectType)" -eq 'Unknown')
            })
        }
    } catch { Write-SectionError $_ -Dataset '12_RoleAssignments.csv' }

    Write-SubSection "Custom Roles"
    Get-AzRoleDefinition -Custom -ErrorAction SilentlyContinue | ForEach-Object {
        $null = $allCustomRoles.Add([PSCustomObject]@{
            Subscription     = $subName
            Name             = $_.Name
            Description      = $_.Description
            Actions          = ($_.Actions -join '; ')
            AssignableScopes = ($_.AssignableScopes -join '; ')
        })
    }
    #endregion

    #region -- 13. Security & Compliance --------------------------------------
    Write-Section "13. Security & Compliance"
    Write-SubSection "Defender for Cloud"
    try {
        Get-AzSecurityPricing -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allDefenderPricing.Add([PSCustomObject]@{
                Subscription = $subName
                Plan         = $_.Name
                PricingTier  = $_.PricingTier
            })
        }
    } catch { Write-SectionError $_ }

    try {
        Get-AzSecuritySecureScore -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allSecureScore.Add([PSCustomObject]@{
                Subscription = $subName
                DisplayName  = $_.DisplayName
                Current      = $_.CurrentScore
                Max          = $_.MaxScore
                Percentage   = if ($_.MaxScore -gt 0) { [math]::Round(($_.CurrentScore / $_.MaxScore) * 100, 1) } else { $null }
            })
        }
    } catch { Write-SectionError $_ }

    Write-SubSection "Security Alerts"
    try {
        Get-AzSecurityAlert -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Active' } | ForEach-Object {
                $null = $allSecurityAlerts.Add([PSCustomObject]@{
                    Subscription = $subName
                    Alert        = $_.AlertDisplayName
                    Severity     = $_.Severity
                    Resource     = $_.CompromisedEntity
                    StartTime    = $_.StartTimeUtc
                })
            }
    } catch { Write-SectionError $_ }

    Write-SubSection "Key Vaults"
    Get-AzResource -ResourceType 'Microsoft.KeyVault/vaults' -ErrorAction SilentlyContinue | ForEach-Object {
        $vault = Get-AzKeyVault -VaultName $_.Name -ResourceGroupName $_.ResourceGroupName -ErrorAction SilentlyContinue
        if ($vault) {
        $kvAcl = $vault.NetworkAcls
        $null = $allKeyVaults.Add([PSCustomObject]@{
            Subscription    = $subName
            VaultName       = $vault.VaultName
            ResourceGroup   = $vault.ResourceGroupName
            Location        = $vault.Location
            SoftDelete      = $vault.EnableSoftDelete
            PurgeProtection = $vault.EnablePurgeProtection
            SKU             = $vault.Sku
            ResourceId      = Get-FirstNonEmpty $vault.ResourceId $_.ResourceId
            PublicNetworkAccess = Get-FirstNonEmpty $vault.PublicNetworkAccess 'Enabled'
            NetworkDefaultAction = if ($kvAcl -and $kvAcl.DefaultAction) { "$($kvAcl.DefaultAction)" } else { 'Allow' }
            IpRuleCount     = if ($kvAcl) { @($kvAcl.IpAddressRanges | Where-Object { $_ }).Count } else { 0 }
            VNetRuleCount   = if ($kvAcl) { @($kvAcl.VirtualNetworkResourceIds | Where-Object { $_ }).Count } else { 0 }
            RbacAuthorization = [bool]$vault.EnableRbacAuthorization
            PrivateEndpointCount = $null
        })

        # Check for expiring secrets/certs
        try {
            Get-AzKeyVaultSecret -VaultName $vault.VaultName -ErrorAction SilentlyContinue |
                Where-Object { $_.Expires -and $_.Expires -lt (Get-Date).AddDays(30) } |
                ForEach-Object {
                    $null = $allExpiringSecrets.Add([PSCustomObject]@{
                        Subscription = $subName
                        Vault        = $vault.VaultName
                        Name         = $_.Name
                        Type         = 'Secret'
                        Expires      = $_.Expires
                        DaysLeft     = [math]::Max(0, ($_.Expires - (Get-Date)).Days)
                    })
                }
            Get-AzKeyVaultCertificate -VaultName $vault.VaultName -ErrorAction SilentlyContinue |
                Where-Object { $_.Expires -and $_.Expires -lt (Get-Date).AddDays(30) } |
                ForEach-Object {
                    $null = $allExpiringSecrets.Add([PSCustomObject]@{
                        Subscription = $subName
                        Vault        = $vault.VaultName
                        Name         = $_.Name
                        Type         = 'Certificate'
                        Expires      = $_.Expires
                        DaysLeft     = [math]::Max(0, ($_.Expires - (Get-Date)).Days)
                    })
                }
        } catch { Write-SectionError $_ }
        }
    }

    Write-SubSection "Policy Compliance"
    try {
        Get-AzPolicyState -SubscriptionId $sub.Id -Filter "ComplianceState eq 'NonCompliant'" -ErrorAction SilentlyContinue |
            Group-Object PolicyDefinitionName |
            Sort-Object Count -Descending |
            ForEach-Object {
                $null = $allPolicyNonCompliant.Add([PSCustomObject]@{
                    Subscription    = $subName
                    PolicyName      = $_.Name
                    NonCompliantCount = $_.Count
                })
            }
    } catch { Write-SectionError $_ }
    try {
        # Az.Resources < 7 nests these under .Properties; 7+ exposes them at the top level
        Get-AzPolicyAssignment -ErrorAction Stop | ForEach-Object {
            $null = $allPolicyAssignments.Add([PSCustomObject]@{
                Subscription    = $subName
                Name            = $_.Name
                DisplayName     = Get-PropValue $_ @('DisplayName', 'Properties.DisplayName')
                Scope           = Get-PropValue $_ @('Scope', 'Properties.Scope')
                EnforcementMode = Get-FirstNonEmpty (Get-PropValue $_ @('EnforcementMode', 'Properties.EnforcementMode')) 'Default'
                PolicyDefinitionId = Get-PropValue $_ @('PolicyDefinitionId', 'Properties.PolicyDefinitionId')
                Id              = Get-PropValue $_ @('Id', 'PolicyAssignmentId', 'ResourceId')
            })
        }
    } catch { Write-SectionError $_ -Dataset '13_PolicyAssignments.csv' }
    #endregion

    #region -- 14. Cost & Advisor ---------------------------------------------
    Write-Section "14. Cost Optimization & Advisor"
    Write-SubSection "Advisor Recommendations"
    try {
        $advisorRecs = @(Get-AzAdvisorRecommendation -ErrorAction Stop)
        foreach ($rec in $advisorRecs) {
            # Az.Advisor 2.x flattens ShortDescription/ResourceMetadata; 1.x nests them
            $resId   = Get-PropValue $rec @('ResourceMetadataResourceId', 'ResourceMetadata.ResourceId')
            $annual  = Get-PropValue $rec @('ExtendedProperty.annualSavingsAmount', 'ExtendedProperties.annualSavingsAmount')
            $monthly = Get-PropValue $rec @('ExtendedProperty.savingsAmount', 'ExtendedProperties.savingsAmount')
            $row = [PSCustomObject]@{
                Subscription = $subName
                Category     = $rec.Category
                Impact       = $rec.Impact
                Problem      = Get-PropValue $rec @('ShortDescriptionProblem', 'ShortDescription.Problem', 'Problem')
                Solution     = Get-PropValue $rec @('ShortDescriptionSolution', 'ShortDescription.Solution', 'Solution')
                Resource     = Get-FirstNonEmpty (Get-PropValue $rec @('ImpactedValue')) (Get-LastSegment $resId)
                ResourceId   = $resId
                ImpactedField = Get-PropValue $rec @('ImpactedField')
                RecommendationTypeId = Get-PropValue $rec @('RecommendationTypeId')
                AnnualSavings  = $annual
                MonthlySavings = $monthly
                SavingsCurrency = Get-PropValue $rec @('ExtendedProperty.savingsCurrency', 'ExtendedProperties.savingsCurrency')
                LastUpdated  = Get-PropValue $rec @('LastUpdated')
            }
            $null = $allAdvisorAll.Add($row)
            if ("$($rec.Category)" -eq 'Cost') {
                $null = $allAdvisorCost.Add([PSCustomObject]@{
                    Subscription = $subName
                    Impact       = $row.Impact
                    Problem      = $row.Problem
                    Solution     = $row.Solution
                    Resource     = $row.Resource
                    ResourceId   = $row.ResourceId
                    ImpactedField = $row.ImpactedField
                    RecommendationTypeId = $row.RecommendationTypeId
                    AnnualSavings  = $row.AnnualSavings
                    MonthlySavings = $row.MonthlySavings
                    SavingsCurrency = $row.SavingsCurrency
                    LastUpdated  = $row.LastUpdated
                })
            }
        }
    } catch { Write-SectionError $_ -Dataset '14_AdvisorAll.csv' }

    Write-SubSection "Consumption (Last 30 Days)"
    try {
        Get-AzConsumptionUsageDetail -StartDate (Get-Date).AddDays(-30) -EndDate (Get-Date) -ErrorAction SilentlyContinue |
            Group-Object ConsumedService |
            Select-Object Name, @{N='TotalCost';E={
                [math]::Round(($_.Group | Measure-Object -Property PretaxCost -Sum).Sum, 2)
            }} |
            Sort-Object TotalCost -Descending |
            ForEach-Object {
                $null = $allConsumption.Add([PSCustomObject]@{
                    Subscription  = $subName
                    Service       = $_.Name
                    TotalCost30d  = $_.TotalCost
                })
            }
    } catch { Write-SectionError $_ }

    Write-SubSection "Actual Cost (Cost Management, $CostMonths full months + month to date)"
    try {
        $today    = (Get-Date).Date
        $costFrom = $today.AddDays(1 - $today.Day).AddMonths(-$CostMonths)
        $costBody = @{
            type       = 'ActualCost'
            timeframe  = 'Custom'
            timePeriod = @{ from = $costFrom.ToString('yyyy-MM-ddT00:00:00Z'); to = $today.ToString('yyyy-MM-ddT23:59:59Z') }
            dataset    = @{
                granularity = 'Monthly'
                aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } }
                grouping    = @(
                    @{ type = 'Dimension'; name = 'ResourceId' },
                    @{ type = 'Dimension'; name = 'ServiceName' }
                )
            }
        }
        $costPages = Invoke-ArmRest -Path "/subscriptions/$($sub.Id)/providers/Microsoft.CostManagement/query?api-version=2023-03-01" -Method POST -Body $costBody -FollowNextLink
        if ($script:lastRestTruncated) {
            Set-NotCollected -Dataset '14_ActualCostByResource.csv' -Reason "[$subName] cost query paging exceeded ${SectionTimeoutSeconds}s"
            Set-NotCollected -Dataset '14_ActualCostByService.csv' -Reason "[$subName] cost query paging exceeded ${SectionTimeoutSeconds}s"
        }
        $subCostRows = [System.Collections.ArrayList]::new()
        foreach ($pg in @($costPages)) {
            if (-not $pg -or -not $pg.properties) { continue }
            $colIdx = @{}
            $cols = @($pg.properties.columns)
            for ($i = 0; $i -lt $cols.Count; $i++) { $colIdx["$($cols[$i].name)"] = $i }
            foreach ($r in @($pg.properties.rows)) {
                if ($null -eq $r) { continue }
                $rid   = if ($colIdx.ContainsKey('ResourceId')) { "$($r[$colIdx['ResourceId']])" } else { '' }
                $month = if ($colIdx.ContainsKey('BillingMonth')) { "$($r[$colIdx['BillingMonth']])" } elseif ($colIdx.ContainsKey('UsageDate')) { "$($r[$colIdx['UsageDate']])" } else { '' }
                if ($month -match '^(\d{4})-?(\d{2})') { $month = "$($Matches[1])-$($Matches[2])" }
                $rg    = if ($rid -match '/resourcegroups/([^/]+)') { $Matches[1] } else { $null }
                $rtype = if ($rid -match '/providers/([^/]+/[^/]+)/[^/]+') { $Matches[1] } else { $null }
                $row = [PSCustomObject]@{
                    Subscription  = $subName
                    Month         = $month
                    ResourceId    = $rid
                    ResourceName  = Get-LastSegment $rid
                    ResourceGroup = $rg
                    ResourceType  = $rtype
                    ServiceName   = if ($colIdx.ContainsKey('ServiceName')) { "$($r[$colIdx['ServiceName']])" } else { $null }
                    Cost          = if ($colIdx.ContainsKey('Cost')) { [math]::Round([double]$r[$colIdx['Cost']], 2) } else { $null }
                    Currency      = if ($colIdx.ContainsKey('Currency')) { "$($r[$colIdx['Currency']])" } else { $null }
                }
                $null = $subCostRows.Add($row)
                $null = $allActualCostByResource.Add($row)
            }
        }
        $subCostRows | Group-Object Month, ServiceName, Currency | ForEach-Object {
            $first = $_.Group[0]
            $null = $allActualCostByService.Add([PSCustomObject]@{
                Subscription  = $subName
                Month         = $first.Month
                ServiceName   = $first.ServiceName
                Cost          = [math]::Round(($_.Group | Measure-Object -Property Cost -Sum).Sum, 2)
                Currency      = $first.Currency
                ResourceCount = @($_.Group | Where-Object { $_.ResourceId } | Select-Object -ExpandProperty ResourceId -Unique).Count
            })
        }
        Write-Host "    Actual cost rows: $($subCostRows.Count)" -ForegroundColor DarkGray
    } catch {
        Write-SectionError $_ -Context 'Cost Management query (needs Cost Management Reader; CSP subscriptions may return 401)' -Dataset '14_ActualCostByResource.csv'
        Set-NotCollected -Dataset '14_ActualCostByService.csv' -Reason "[$subName] Cost Management query failed"
    }

    Write-SubSection "Budgets"
    try {
        Get-AzConsumptionBudget -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allBudgets.Add([PSCustomObject]@{
                Subscription = $subName
                Name         = $_.Name
                Amount       = $_.Amount
                TimeGrain    = $_.TimeGrain
                CurrentSpend = if ($_.CurrentSpend) { $_.CurrentSpend.Amount } else { $null }
                Currency     = if ($_.CurrentSpend) { $_.CurrentSpend.Unit } else { $null }
            })
        }
    } catch { Write-SectionError $_ }
    #endregion

    #region -- 15. Backup & DR ------------------------------------------------
    Write-Section "15. Backup & Disaster Recovery"
    Write-SubSection "Recovery Services Vaults & Backup Items"
    if (-not (Test-CommandAvailable 'Get-AzRecoveryServicesBackupItem')) {
        Set-NotCollected -Dataset '15_BackupItems.csv' -Reason 'Az.RecoveryServices not installed'
        Set-NotCollected -Dataset '15_UnprotectedVMs.csv' -Reason 'Az.RecoveryServices not installed'
    } else {
        $vaults = @(Get-AzResource -ResourceType 'Microsoft.RecoveryServices/vaults' -ErrorAction SilentlyContinue | ForEach-Object {
            Get-AzRecoveryServicesVault -ResourceGroupName $_.ResourceGroupName -Name $_.Name -ErrorAction SilentlyContinue
        })
        foreach ($vault in $vaults) {
            if (-not $vault) { continue }
            $null = $allRecoveryVaults.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $vault.Name
                ResourceGroup = $vault.ResourceGroupName
                Location      = $vault.Location
            })
            try {
                # Every Azure VM backup item in the vault (no container enumeration needed)
                $items = @(Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $vault.ID -ErrorAction Stop)
                foreach ($item in $items) {
                    $parts   = "$($item.Name)" -split ';'
                    $vmName  = $parts[-1]
                    $vmRg    = if ($parts.Count -ge 2) { $parts[-2] } else { $null }
                    $srcId   = Get-FirstNonEmpty $item.SourceResourceId $item.VirtualMachineId
                    if ($srcId) {
                        $protectedVmIds["$srcId".ToLower()] = $vault.Name
                        $vmName = Get-LastSegment $srcId
                        if ("$srcId" -match '/resourceGroups/([^/]+)/') { $vmRg = $Matches[1] }
                    }
                    $protectedVmNames["$subName|$vmRg|$vmName".ToLower()] = $vault.Name
                    $null = $allBackupItems.Add([PSCustomObject]@{
                        Subscription       = $subName
                        Vault              = $vault.Name
                        VM                 = $vmName
                        ProtectionStatus   = $item.ProtectionStatus
                        LastBackup         = $item.LastBackupTime
                        LatestRecoveryPoint = $item.LatestRecoveryPoint
                        ResourceGroup      = $vmRg
                        ResourceId         = $srcId
                        ProtectionState    = $item.ProtectionState
                        LastBackupStatus   = $item.LastBackupStatus
                        PolicyName         = $item.ProtectionPolicyName
                    })
                }
            } catch {
                Write-SectionError $_ -Context "Backup items: $($vault.Name)" -Dataset '15_BackupItems.csv'
                $backupFailedSubs[$subName] = $true
                Set-NotCollected -Dataset '15_UnprotectedVMs.csv' -Reason "[$subName] backup items for vault $($vault.Name) could not be read"
            }
        }
    }
    # Unprotected VMs are computed after all subscriptions are processed
    #endregion

    #region -- 16. Monitoring -------------------------------------------------
    Write-Section "16. Monitoring & Log Analytics"
    Write-SubSection "Log Analytics Workspaces"
    Get-AzResource -ResourceType 'Microsoft.OperationalInsights/workspaces' -ErrorAction SilentlyContinue | ForEach-Object {
        $ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $_.ResourceGroupName -Name $_.Name -ErrorAction SilentlyContinue
        if ($ws) {
            $null = $allLAWorkspaces.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $ws.Name
                ResourceGroup = $ws.ResourceGroupName
                SKU           = $ws.Sku
                RetentionDays = $ws.RetentionInDays
                DailyCapGB    = if ($ws.WorkspaceCapping) { $ws.WorkspaceCapping.DailyQuotaGb } else { $null }
            })
        }
    }

    Write-SubSection "Diagnostic Settings Coverage"
    $criticalTypes = @(
        'Microsoft.Compute/virtualMachines',
        'Microsoft.Sql/servers/databases',
        'Microsoft.Network/networkSecurityGroups',
        'Microsoft.KeyVault/vaults',
        'Microsoft.Web/sites',
        'Microsoft.Network/applicationGateways',
        'Microsoft.Network/azureFirewalls',
        'Microsoft.ContainerService/managedClusters'
    )
    @($resources) | Where-Object {
        $_ -and $_.ResourceType -in $criticalTypes
    } | ForEach-Object {
        $diag = @(Get-AzDiagnosticSetting -ResourceId $_.ResourceId -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Where-Object { $_ })
        $dest = @(foreach ($d in $diag) {
            Get-LastSegment $d.WorkspaceId
            Get-LastSegment $d.StorageAccountId
            if ($d.EventHubAuthorizationRuleId) { "EventHub:$(Get-LastSegment $d.EventHubName)" }
        }) | Where-Object { $_ }
        $null = $allDiagSettings.Add([PSCustomObject]@{
            Subscription   = $subName
            Resource       = $_.Name
            Type           = Get-LastSegment $_.ResourceType
            HasDiagnostics = $diag.Count -gt 0
            Destinations   = if ($diag.Count -gt 0) { Join-Values $dest -Separator ', ' } else { 'NONE' }
        })
    }

    Write-SubSection "Alert Rules (metric, log search, activity log, smart detector)"
    $alertTypes = [ordered]@{
        'Microsoft.Insights/metricAlerts'            = 'Metric'
        'Microsoft.Insights/scheduledQueryRules'     = 'LogSearch'
        'Microsoft.Insights/activityLogAlerts'       = 'ActivityLog'
        'Microsoft.AlertsManagement/smartDetectorAlertRules' = 'SmartDetector'
    }
    foreach ($at in $alertTypes.Keys) {
        try {
            Get-AzResource -ResourceType $at -ExpandProperties -ErrorAction Stop | ForEach-Object {
                $p = $_.Properties
                # scheduledQueryRules: 2021+ shape (scopes/actions.actionGroups) or 2018 shape (source/action.aznsAction)
                $scopes = @(
                    Get-PropValue $p @('scopes', 'scope')
                    Get-PropValue $p @('source.dataSourceId')
                ) | ForEach-Object { $_ } | Where-Object { $_ }
                $agIds = @(
                    @(Get-PropValue $p @('actions')) | ForEach-Object { if ($_ -isnot [string]) { Get-PropValue $_ @('actionGroupId') } }
                    Get-PropValue $p @('actions.actionGroups')
                    @(Get-PropValue $p @('actions.actionGroups')) | ForEach-Object { if ($_ -isnot [string]) { Get-PropValue $_ @('actionGroupId') } }
                    Get-PropValue $p @('action.aznsAction.actionGroup')
                    Get-PropValue $p @('actionGroups.groupIds')
                ) | ForEach-Object { $_ } | Where-Object { $_ -is [string] -and $_ -match '/actionGroups/' } | Select-Object -Unique
                $enabledRaw = Get-PropValue $p @('enabled', 'state')
                $sev = Get-PropValue $p @('severity', 'action.severity')
                $null = $allAlertRules.Add([PSCustomObject]@{
                    Subscription  = $subName
                    Name          = $_.Name
                    ResourceGroup = $_.ResourceGroupName
                    Severity      = $sev
                    Enabled       = if ($null -eq $enabledRaw) { $null } else { "$enabledRaw" -match '^(true|enabled)$' }
                    TargetResource = Join-Values @($scopes | ForEach-Object { Get-LastSegment $_ }) -Separator ', '
                    AlertType     = $alertTypes[$at]
                    Scopes        = Join-Values $scopes -Separator '; '
                    ActionGroupCount = @($agIds).Count
                    ActionGroups  = Join-Values @($agIds | ForEach-Object { Get-LastSegment $_ }) -Separator ', '
                    ResourceId    = $_.ResourceId
                })
            }
        } catch { Write-SectionError $_ -Context "Alert rules: $at" -Dataset '16_AlertRules.csv' }
    }

    Write-SubSection "Action Groups"
    try {
        Get-AzResource -ResourceType 'Microsoft.Insights/actionGroups' -ExpandProperties -ErrorAction Stop | ForEach-Object {
            $res = $_
            $ag = $null
            try { $ag = Get-AzActionGroup -ResourceGroupName $res.ResourceGroupName -Name $res.Name -ErrorAction Stop } catch {}
            # Az.Monitor 5 uses singular property names (EmailReceiver); older versions and ARM use plural
            $getRecv = {
                param([string]$Kind)
                $v = Get-PropValue $ag @("${Kind}Receiver", "${Kind}Receivers")
                if ($null -eq $v) { $v = Get-PropValue $res @("Properties.${Kind}Receivers") }
                return ,@($v | Where-Object { $_ })
            }
            $email   = & $getRecv 'Email'
            $sms     = & $getRecv 'Sms'
            $webhook = & $getRecv 'Webhook'
            $total = 0
            foreach ($k in @('Email','Sms','Webhook','Voice','AzureAppPush','ArmRole','AzureFunction','LogicApp','AutomationRunbook','Itsm','EventHub')) {
                $total += (& $getRecv $k).Count
            }
            $enabled = Get-FirstNonEmpty $(if ($ag) { $ag.Enabled }) (Get-PropValue $res @('Properties.enabled'))
            $null = $allActionGroups.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $res.Name
                ResourceGroup = $res.ResourceGroupName
                Enabled       = $enabled
                EmailReceivers = Join-Values @($email | ForEach-Object { Get-PropValue $_ @('Name') }) -Separator ', '
                SMSReceivers   = Join-Values @($sms | ForEach-Object { Get-PropValue $_ @('Name') }) -Separator ', '
                WebhookReceivers = Join-Values @($webhook | ForEach-Object { Get-PropValue $_ @('Name') }) -Separator ', '
                EmailReceiverCount   = $email.Count
                SmsReceiverCount     = $sms.Count
                WebhookReceiverCount = $webhook.Count
                TotalReceivers       = $total
                ResourceId    = $res.ResourceId
            })
        }
    } catch { Write-SectionError $_ -Dataset '16_ActionGroups.csv' }
    #endregion
    #region -- 17. Governance & Tags ------------------------------------------
    Write-Section "17. Governance & Tagging"
    Write-SubSection "Tag Compliance"
    $requiredTags = @('Environment', 'Owner', 'CostCenter', 'Application')
    @($resources) | Where-Object { $_ } | ForEach-Object {
        $resource = $_
        $missing = $requiredTags | Where-Object {
            -not ($resource.Tags -and $resource.Tags.ContainsKey($_))
        }
        if ($missing) {
            $null = $allTagCompliance.Add([PSCustomObject]@{
                Subscription = $subName
                Resource     = $resource.Name
                Type         = Get-LastSegment $resource.ResourceType
                MissingTags  = ($missing -join ', ')
                ResourceGroup = $resource.ResourceGroupName
                ResourceId   = $resource.ResourceId
            })
        }
    }

    Write-SubSection "Resource Locks"
    try {
        Get-AzResourceLock -ErrorAction Stop | ForEach-Object {
            $null = $allResourceLocks.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                LockLevel     = Get-PropValue $_ @('Properties.Level', 'Level')
                Resource      = Get-LastSegment ("$($_.ResourceId)" -replace '/providers/Microsoft\.Authorization/locks/[^/]+$', '')
                Notes         = Get-PropValue $_ @('Properties.Notes', 'Notes')
                ResourceId    = $_.ResourceId
            })
        }
    } catch { Write-SectionError $_ -Dataset '17_ResourceLocks.csv' }
    #endregion

    #region -- 18. Automation & Hybrid ----------------------------------------
    Write-Section "18. Automation & Hybrid"
    Write-SubSection "Automation Accounts"
    try {
        Get-AzResource -ResourceType 'Microsoft.Automation/automationAccounts' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allAutomationAccts.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                Location      = $_.Location
            })
        }
    } catch { Write-SectionError $_ }

    Write-SubSection "Azure Arc Machines"
    try {
        if (Test-ModuleAvailable 'Az.ConnectedMachine') {
            Get-AzResource -ResourceType 'Microsoft.HybridCompute/machines' -ErrorAction SilentlyContinue | ForEach-Object {
                $machine = Get-AzConnectedMachine -ResourceGroupName $_.ResourceGroupName -Name $_.Name -ErrorAction SilentlyContinue
                if ($machine) {
                    $null = $allArcMachines.Add([PSCustomObject]@{
                        Subscription     = $subName
                        Name             = $machine.Name
                        ResourceGroup    = $machine.ResourceGroupName
                        OS               = $machine.OsName
                        Status           = $machine.Status
                        AgentVersion     = $machine.AgentVersion
                        LastStatusChange = $machine.LastStatusChange
                    })
                }
            }
        }
    } catch { Write-SectionError $_ }
    #endregion

} # End subscription loop
Complete-SectionTiming
$script:currentSubName = $null
$subIds = @($subscriptions | ForEach-Object { $_.Id })
$subNameById = @{}
foreach ($s in $subscriptions) { $subNameById["$($s.Id)".ToLower()] = $s.Name }

# ===============================================================================
# MANAGEMENT GROUPS (tenant-level, outside sub loop)
# ===============================================================================
Write-Section "19. Management Groups"
try {
    Get-AzManagementGroup -ErrorAction SilentlyContinue | ForEach-Object {
        $null = $allMgmtGroups.Add([PSCustomObject]@{
            Name        = $_.Name
            DisplayName = $_.DisplayName
            Id          = $_.Id
        })
    }
} catch { Write-SectionError $_ }

# ===============================================================================
# TENANT-LEVEL / CROSS-SUBSCRIPTION COLLECTION
# ===============================================================================
Write-Section "20. Reservations"
# Reservations live at tenant (billing) scope, not under a subscription
try {
    $resRows = @()
    $useCmdlet = $false
    $resCmd = Get-Command Get-AzReservation -ErrorAction SilentlyContinue
    if ($resCmd) {
        foreach ($ps in $resCmd.ParameterSets) {
            if (-not @($ps.Parameters | Where-Object { $_.IsMandatory }).Count) { $useCmdlet = $true; break }
        }
    }
    if ($useCmdlet) {
        $resRows = @(Get-AzReservation -ErrorAction Stop)
    } else {
        $pages = Invoke-ArmRest -Path '/providers/Microsoft.Capacity/reservations?api-version=2022-11-01' -FollowNextLink
        $resRows = @(foreach ($pg in @($pages)) { if ($pg) { @($pg.value) } })
        if ($script:lastRestTruncated) { Set-NotCollected -Dataset '14_Reservations.csv' -Reason "Reservation paging exceeded ${SectionTimeoutSeconds}s" }
    }
    foreach ($r in $resRows) {
        if (-not $r) { continue }
        $rid = Get-PropValue $r @('Id')
        $orderId = if ("$rid" -match '/reservationOrders/([^/]+)') { $Matches[1] } else { Get-PropValue $r @('ReservationOrderId') }
        $scopes = @(Get-PropValue $r @('Properties.appliedScopes', 'AppliedScopes', 'Properties.appliedScopeProperties.resourceGroupId', 'Properties.appliedScopeProperties.subscriptionId', 'Properties.appliedScopeProperties.managementGroupId'))
        $scopeSub = $null
        foreach ($sc in $scopes) { if ("$sc" -match '/subscriptions/([^/]+)') { $scopeSub = $subNameById["$($Matches[1])".ToLower()]; if (-not $scopeSub) { $scopeSub = $Matches[1] }; break } }
        $util = Get-PropValue $r @('Properties.utilization.aggregates', 'Utilization.Aggregates')
        $u = @{}
        foreach ($a in @($util)) {
            $g = "$(Get-PropValue $a @('grain'))"; $v = Get-PropValue $a @('value')
            if ($g) { $u[$g] = $v }
        }
        $null = $allReservations.Add([PSCustomObject]@{
            Subscription  = Get-FirstNonEmpty $scopeSub $(if ("$(Get-PropValue $r @('Properties.appliedScopeType','AppliedScopeType'))" -eq 'Shared') { 'Shared' })
            DisplayName   = Get-PropValue $r @('Properties.displayName', 'DisplayName', 'Name')
            SKU           = Get-PropValue $r @('Sku.name', 'SkuName', 'Sku')
            Location      = Get-PropValue $r @('Location')
            Quantity      = Get-PropValue $r @('Properties.quantity', 'Quantity')
            ExpiryDate    = Get-PropValue $r @('Properties.expiryDateTime', 'Properties.expiryDate', 'ExpiryDateTime', 'ExpiryDate')
            Utilization   = Get-FirstNonEmpty $u['30.0'] $u['30'] $u['7.0'] $u['7'] $u['1.0'] $u['1']
            ReservationOrderId = $orderId
            ReservationId = Get-LastSegment $rid
            AppliedScopeType = Get-PropValue $r @('Properties.appliedScopeType', 'AppliedScopeType')
            Scope         = Join-Values $scopes -Separator '; '
            Term          = Get-PropValue $r @('Properties.term', 'Term')
            ProvisioningState = Get-PropValue $r @('Properties.provisioningState', 'ProvisioningState')
            ReservedResourceType = Get-PropValue $r @('Properties.reservedResourceType', 'ReservedResourceType')
            Utilization1d  = Get-FirstNonEmpty $u['1.0'] $u['1']
            Utilization7d  = Get-FirstNonEmpty $u['7.0'] $u['7']
            Utilization30d = Get-FirstNonEmpty $u['30.0'] $u['30']
            UtilizationTrend = Get-PropValue $r @('Properties.utilization.trend', 'Utilization.Trend')
        })
    }
    Write-Host "    Reservations: $(@($allReservations).Count)" -ForegroundColor DarkGray
} catch {
    Write-SectionError $_ -Context 'Reservations (needs Reservations Reader or an Owner/Reader role on the reservation orders)' -Dataset '14_Reservations.csv'
}

Write-Section "21. Guest Users"
try {
    $guestRbac = @{}
    foreach ($ra in $allRBAC) { if ($ra.ObjectId) { $guestRbac["$($ra.ObjectId)"] = 1 + [int]$guestRbac["$($ra.ObjectId)"] } }
    $guests = @(Get-AzADUser -Filter "userType eq 'Guest'" -ErrorAction Stop)
    foreach ($g in $guests) {
        $gid = "$($g.Id)"
        $null = $allGuestUsers.Add([PSCustomObject]@{
            DisplayName       = $g.DisplayName
            UserPrincipalName = $g.UserPrincipalName
            Mail              = $g.Mail
            ObjectId          = $gid
            AccountEnabled    = $g.AccountEnabled
            HasAzureRoleAssignment = $guestRbac.ContainsKey($gid)
            AzureRoleAssignmentCount = [int]$guestRbac[$gid]
        })
    }
    # Back-fill IsGuest on role assignments whose principal is a known guest
    $guestIds = @{}; foreach ($g in $guests) { $guestIds["$($g.Id)"] = $true }
    foreach ($ra in $allRBAC) { if ($ra.ObjectId -and $guestIds.ContainsKey("$($ra.ObjectId)")) { $ra.IsGuest = $true } }
    Write-Host "    Guest users: $($guests.Count)" -ForegroundColor DarkGray
} catch {
    Write-SectionError $_ -Context 'Guest users (needs directory read: User.Read.All or Directory Readers)' -Dataset '12_GuestUsers.csv'
}

Write-Section "22. Managed Identities"
$miQuery = @"
resources
| where isnotempty(identity) and tostring(identity.type) != 'None'
| project subscriptionId, name, type, resourceGroup, id,
          identityType = tostring(identity.type),
          principalId = tostring(identity.principalId),
          userAssigned = identity.userAssignedIdentities
"@
foreach ($row in @(Invoke-ResourceGraphQuery -Query $miQuery -Subscriptions $subIds -Dataset '12_ManagedIdentities.csv')) {
    $ua = @()
    if ($row.userAssigned) { $ua = @($row.userAssigned.PSObject.Properties | ForEach-Object { Get-LastSegment $_.Name }) }
    $null = $allManagedIdentities.Add([PSCustomObject]@{
        Subscription  = Get-FirstNonEmpty $subNameById["$($row.subscriptionId)".ToLower()] $row.subscriptionId
        Name          = $row.name
        ResourceType  = $row.type
        ResourceGroup = $row.resourceGroup
        ResourceId    = $row.id
        IdentityType  = $row.identityType
        PrincipalId   = $row.principalId
        UserAssignedIdentities = Join-Values $ua -Separator '; '
    })
}
$uaQuery = @"
resources
| where type =~ 'microsoft.managedidentity/userassignedidentities'
| project subscriptionId, name, resourceGroup, id,
          principalId = tostring(properties.principalId),
          clientId = tostring(properties.clientId)
"@
foreach ($row in @(Invoke-ResourceGraphQuery -Query $uaQuery -Subscriptions $subIds -Dataset '12_UserAssignedIdentities.csv')) {
    $null = $allUserAssignedIds.Add([PSCustomObject]@{
        Subscription  = Get-FirstNonEmpty $subNameById["$($row.subscriptionId)".ToLower()] $row.subscriptionId
        Name          = $row.name
        ResourceGroup = $row.resourceGroup
        ResourceId    = $row.id
        PrincipalId   = $row.principalId
        ClientId      = $row.clientId
    })
}

Write-Section "23. Defender for Cloud Recommendations"
$defQuery = @"
securityresources
| where type == 'microsoft.security/assessments'
| where tostring(properties.status.code) == 'Unhealthy'
| extend resId = tostring(properties.resourceDetails.Id)
| project subscriptionId, name,
          recommendation = tostring(properties.displayName),
          severity = tostring(properties.metadata.severity),
          categories = properties.metadata.categories,
          resId,
          statusCause = tostring(properties.status.cause),
          statusDescription = tostring(properties.status.description),
          remediation = tostring(properties.metadata.remediationDescription)
"@
foreach ($row in @(Invoke-ResourceGraphQuery -Query $defQuery -Subscriptions $subIds -Dataset '13_DefenderRecommendations.csv')) {
    $rtype = if ("$($row.resId)" -match '/providers/([^/]+/[^/]+)/[^/]+') { $Matches[1] } elseif ("$($row.resId)" -match '/resourceGroups/[^/]+$') { 'resourceGroup' } elseif ("$($row.resId)" -match '^/subscriptions/[^/]+$') { 'subscription' } else { $null }
    $null = $allDefenderRecs.Add([PSCustomObject]@{
        Subscription      = Get-FirstNonEmpty $subNameById["$($row.subscriptionId)".ToLower()] $row.subscriptionId
        Recommendation    = $row.recommendation
        Severity          = $row.severity
        Category          = Join-Values $row.categories -Separator ', '
        ResourceId        = $row.resId
        ResourceName      = Get-LastSegment $row.resId
        ResourceType      = $rtype
        AssessmentKey     = $row.name
        StatusCause       = $row.statusCause
        StatusDescription = $row.statusDescription
        Remediation       = $row.remediation
    })
}
Write-Host "    Unhealthy assessments: $(@($allDefenderRecs).Count)" -ForegroundColor DarkGray

Write-Section "24. Cross-references"
# Private endpoint counts on data services
foreach ($list in @($allStorageAccounts, $allKeyVaults, $allSQLServers)) {
    foreach ($row in $list) {
        $k = "$($row.ResourceId)".ToLower()
        $row.PrivateEndpointCount = if ($k -and $privateEndpointTargets.ContainsKey($k)) { [int]$privateEndpointTargets[$k] } else { 0 }
    }
}

# VMs with no Azure Backup protection in any vault of any assessed subscription
# (subscriptions where backup items could not be read are skipped and the file is marked Partial)
if (Test-CommandAvailable 'Get-AzRecoveryServicesBackupItem') {
    foreach ($vm in $allVMs) {
        if ($backupFailedSubs.ContainsKey("$($vm.Subscription)")) { continue }
        $idKey   = "$($vm.ResourceId)".ToLower()
        $nameKey = "$($vm.Subscription)|$($vm.ResourceGroup)|$($vm.Name)".ToLower()
        if ($protectedVmIds.ContainsKey($idKey) -or $protectedVmNames.ContainsKey($nameKey)) { continue }
        $null = $allUnprotectedVMs.Add([PSCustomObject]@{
            Subscription  = $vm.Subscription
            VM            = $vm.Name
            Status        = 'NO BACKUP CONFIGURED'
            ResourceGroup = $vm.ResourceGroup
            ResourceId    = $vm.ResourceId
            PowerState    = $vm.PowerState
        })
    }
}
Complete-SectionTiming

# Column schema per CSV. Rows are written in this column order (extra properties follow);
# empty datasets get a header-only file. The analyzer keys on these names: add columns, never rename.
$Schemas = @{
    '01_ResourceInventory.csv'         = @('Subscription','ResourceType','Count')
    '02_VMs.csv'                       = @('Subscription','Name','ResourceGroup','Location','VMSize','OsType','PowerState','AvailabilityZone','DiskEncryption','ResourceId','LicenseType','SecurityType','EncryptionAtHost','OsDiskEncryptionType','DataDiskEncryptionTypes','ADEExtension','DeallocatedSinceUtc','DeallocatedDays','DeallocatedOver90Days')
    '02_VM_Metrics.csv'                = @('Subscription','VM','VMSize','AvgCPU','PeakCPU','Recommendation','ResourceGroup','ResourceId','MemoryGB','AvgAvailableMemoryGB','MinAvailableMemoryGB','AvgMemoryUsedPct','PeakMemoryUsedPct','AvgOsDiskIopsPct','PeakOsDiskIopsPct','AvgDataDiskIopsPct','PeakDataDiskIopsPct')
    '02_VMScaleSets.csv'               = @('Subscription','Name','ResourceGroup','Location','SKU','Capacity','UpgradePolicy','Zones')
    '03_AppServicePlans.csv'           = @('Subscription','Name','ResourceGroup','Location','SKU','Tier','Workers','AppCount','Apps','Status')
    '03_WebApps.csv'                   = @('Subscription','Name','ResourceGroup','Plan','State','HttpsOnly','MinTlsVersion','AlwaysOn','Runtime','Kind','ResourceId','FtpsState','PublicNetworkAccess')
    '04_Functions.csv'                 = @('Subscription','Name','ResourceGroup','State','Runtime','HttpsOnly','Plan','Kind','MinTlsVersion','ResourceId')
    '05_LogicApps.csv'                 = @('Subscription','Name','ResourceGroup','Location','State','ResourceId')
    '06_Disks.csv'                     = @('Subscription','Name','ResourceGroup','AttachedTo','DiskSizeGB','SKU','IOPS','ThroughputMBps','Encryption','Location','CreatedDate','EncryptionType','DiskState','ResourceId')
    '06_UnattachedDisks.csv'           = @('Subscription','Name','ResourceGroup','AttachedTo','DiskSizeGB','SKU','IOPS','ThroughputMBps','Encryption','Location','CreatedDate','EncryptionType','DiskState','ResourceId')
    '06_Snapshots.csv'                 = @('Subscription','Name','ResourceGroup','DiskSizeGB','AgeDays','CreatedDate','Recommendation')
    '06_StorageAccounts.csv'           = @('Subscription','Name','ResourceGroup','SKU','Kind','AccessTier','HttpsOnly','MinTLS','PublicAccess','Location','ResourceId','PublicNetworkAccess','NetworkDefaultAction','IpRuleCount','VNetRuleCount','AllowSharedKeyAccess','PrivateEndpointCount')
    '06_FileShares.csv'                = @('Subscription','StorageAccount','ShareName','QuotaGB','AccessTier','ResourceGroup','EnabledProtocols')
    '07_VNets_Subnets.csv'             = @('Subscription','VNet','AddressSpace','Subnet','SubnetPrefix','NSG','RouteTable')
    '07_OrphanedPublicIPs.csv'         = @('Subscription','Name','ResourceGroup','IpAddress','SKU','Allocation','ResourceId','Location')
    '07_OpenNSGRules.csv'              = @('Subscription','NSG','Rule','Priority','DestPort','Source','Severity','ResourceGroup','Protocol','DestinationAddress')
    '07_LoadBalancers.csv'             = @('Subscription','Name','ResourceGroup','SKU','FrontendIPs','BackendPools','Rules')
    '07_AppGateways.csv'               = @('Subscription','Name','ResourceGroup','Tier','Capacity','WAFEnabled')
    '07_AzureFirewalls.csv'            = @('Subscription','Name','ResourceGroup','SKU','ThreatIntel','ProvisionState')
    '07_FrontDoors.csv'                = @('Subscription','Name','ResourceGroup','Location','Kind')
    '07_Bastions.csv'                  = @('Subscription','Name','ResourceGroup','Location')
    '07_NATGateways.csv'               = @('Subscription','Name','ResourceGroup','Location','IdleTimeoutMinutes','PublicIpCount')
    '07_VPNGateways.csv'               = @('Subscription','Name','ResourceGroup','SKU','GatewayType','VpnType','ActiveActive')
    '07_ExpressRoute.csv'              = @('Subscription','Name','SKU','Tier','Bandwidth','Provider','State')
    '07_VNetPeerings.csv'              = @('Subscription','VNet','PeeringName','RemoteVNet','State','AllowForwarded','AllowGatewayTransit','UseRemoteGateway')
    '07_PrivateEndpoints.csv'          = @('Subscription','Name','ResourceGroup','Subnet','PrivateLinkService','TargetResourceId','GroupIds','ConnectionState')
    '07_PrivateDNS.csv'                = @('Subscription','Name','ResourceGroup','RecordSets','VNetLinks')
    '07_PublicDNS.csv'                 = @('Subscription','Name','ResourceGroup','RecordSets','NameServers')
    '07_NetworkWatchers.csv'           = @('Subscription','Name','ResourceGroup','Location','ProvisioningState')
    '07_CDNProfiles.csv'               = @('Subscription','Name','ResourceGroup','Location','SKU')
    '08_SQLServers.csv'                = @('Subscription','ServerName','ResourceGroup','Location','AdminLogin','Version','ResourceId','PublicNetworkAccess','MinimalTlsVersion','EntraOnlyAuth','EntraAdmin','AuditingEnabled','AuditDestinations','AllowAzureServices','OpenToInternet','FirewallRuleCount','PrivateEndpointCount')
    '08_SQLDatabases.csv'              = @('Subscription','Server','Database','Edition','ServiceObjective','MaxSizeGB','Status','ZoneRedundant','ResourceGroup','TDE','ElasticPool','ResourceId')
    '08_SQLManagedInstances.csv'       = @('Subscription','Name','ResourceGroup','SKU','vCores','StorageGB','LicenseType','State')
    '08_CosmosDB.csv'                  = @('Subscription','Name','ResourceGroup','Kind','ConsistencyLevel','MultipleWriteLocations','Locations')
    '08_MySQL.csv'                     = @('Subscription','Name','ResourceGroup','SKU','Tier','StorageGB','Version','State','Location','PublicNetworkAccess','HighAvailability','BackupRetentionDays','GeoRedundantBackup','ResourceId')
    '08_PostgreSQL.csv'                = @('Subscription','Name','ResourceGroup','SKU','Tier','StorageGB','Version','State','Location','PublicNetworkAccess','HighAvailability','BackupRetentionDays','GeoRedundantBackup','ResourceId')
    '08_RedisCache.csv'                = @('Subscription','Name','ResourceGroup','SKU','Size','ShardCount','NonSslPort','MinTLS','Location')
    '09_ServiceBus.csv'                = @('Subscription','Name','ResourceGroup','Location','SKU')
    '09_EventHubs.csv'                 = @('Subscription','Name','ResourceGroup','Location','SKU')
    '09_APIM.csv'                      = @('Subscription','Name','ResourceGroup','Location','SKU')
    '10_AKS_Clusters.csv'              = @('Subscription','Name','ResourceGroup','K8sVersion','NodePools','NetworkPlugin','NetworkPolicy','RBAC')
    '10_AKS_NodePools.csv'             = @('Subscription','Cluster','Pool','VMSize','Count','MinCount','MaxCount','AutoScale','OsType','Mode')
    '10_ContainerInstances.csv'        = @('Subscription','Name','ResourceGroup','Location')
    '10_ContainerApps.csv'             = @('Subscription','Name','ResourceGroup','Location')
    '10_ContainerRegistries.csv'       = @('Subscription','Name','ResourceGroup','SKU','AdminEnabled','LoginServer','Location')
    '11_DataFactories.csv'             = @('Subscription','Name','ResourceGroup','Location')
    '12_RoleAssignments.csv'           = @('Subscription','DisplayName','SignInName','RoleDefinitionName','Scope','ObjectType','HighRisk','ObjectId','RoleDefinitionId','ScopeLevel','IsOwner','IsClassicAdmin','IsGuest','IsOrphaned')
    '12_HighRiskRoles.csv'             = @('Subscription','DisplayName','SignInName','RoleDefinitionName','Scope','ObjectType','HighRisk','ObjectId','RoleDefinitionId','ScopeLevel','IsOwner','IsClassicAdmin','IsGuest','IsOrphaned')
    '12_CustomRoles.csv'               = @('Subscription','Name','Description','Actions','AssignableScopes')
    '12_ManagementGroups.csv'          = @('Name','DisplayName','Id')
    '12_GuestUsers.csv'                = @('DisplayName','UserPrincipalName','Mail','ObjectId','AccountEnabled','HasAzureRoleAssignment','AzureRoleAssignmentCount')
    '12_ManagedIdentities.csv'         = @('Subscription','Name','ResourceType','ResourceGroup','ResourceId','IdentityType','PrincipalId','UserAssignedIdentities')
    '12_UserAssignedIdentities.csv'    = @('Subscription','Name','ResourceGroup','ResourceId','PrincipalId','ClientId')
    '13_DefenderPricing.csv'           = @('Subscription','Plan','PricingTier')
    '13_SecureScore.csv'               = @('Subscription','DisplayName','Current','Max','Percentage')
    '13_SecurityAlerts.csv'            = @('Subscription','Alert','Severity','Resource','StartTime')
    '13_KeyVaults.csv'                 = @('Subscription','VaultName','ResourceGroup','Location','SoftDelete','PurgeProtection','SKU','ResourceId','PublicNetworkAccess','NetworkDefaultAction','IpRuleCount','VNetRuleCount','RbacAuthorization','PrivateEndpointCount')
    '13_ExpiringSecretsCerts.csv'      = @('Subscription','Vault','Name','Type','Expires','DaysLeft')
    '13_PolicyNonCompliant.csv'        = @('Subscription','PolicyName','NonCompliantCount')
    '13_PolicyAssignments.csv'         = @('Subscription','Name','DisplayName','Scope','EnforcementMode','PolicyDefinitionId','Id')
    '13_DefenderRecommendations.csv'   = @('Subscription','Recommendation','Severity','Category','ResourceId','ResourceName','ResourceType','AssessmentKey','StatusCause','StatusDescription','Remediation')
    '14_AdvisorAll.csv'                = @('Subscription','Category','Impact','Problem','Solution','Resource','ResourceId','ImpactedField','RecommendationTypeId','AnnualSavings','MonthlySavings','SavingsCurrency','LastUpdated')
    '14_AdvisorCost.csv'               = @('Subscription','Impact','Problem','Solution','Resource','ResourceId','ImpactedField','RecommendationTypeId','AnnualSavings','MonthlySavings','SavingsCurrency','LastUpdated')
    '14_ConsumptionByService.csv'      = @('Subscription','Service','TotalCost30d')
    '14_Reservations.csv'              = @('Subscription','DisplayName','SKU','Location','Quantity','ExpiryDate','Utilization','ReservationOrderId','ReservationId','AppliedScopeType','Scope','Term','ProvisioningState','ReservedResourceType','Utilization1d','Utilization7d','Utilization30d','UtilizationTrend')
    '14_Budgets.csv'                   = @('Subscription','Name','Amount','TimeGrain','CurrentSpend','Currency')
    '14_ActualCostByResource.csv'      = @('Subscription','Month','ResourceId','ResourceName','ResourceGroup','ResourceType','ServiceName','Cost','Currency')
    '14_ActualCostByService.csv'       = @('Subscription','Month','ServiceName','Cost','Currency','ResourceCount')
    '15_RecoveryVaults.csv'            = @('Subscription','Name','ResourceGroup','Location')
    '15_BackupItems.csv'               = @('Subscription','Vault','VM','ProtectionStatus','LastBackup','LatestRecoveryPoint','ResourceGroup','ResourceId','ProtectionState','LastBackupStatus','PolicyName')
    '15_UnprotectedVMs.csv'            = @('Subscription','VM','Status','ResourceGroup','ResourceId','PowerState')
    '16_LogAnalyticsWorkspaces.csv'    = @('Subscription','Name','ResourceGroup','SKU','RetentionDays','DailyCapGB')
    '16_DiagnosticSettings.csv'        = @('Subscription','Resource','Type','HasDiagnostics','Destinations')
    '16_AlertRules.csv'                = @('Subscription','Name','ResourceGroup','Severity','Enabled','TargetResource','AlertType','Scopes','ActionGroupCount','ActionGroups','ResourceId')
    '16_ActionGroups.csv'              = @('Subscription','Name','ResourceGroup','Enabled','EmailReceivers','SMSReceivers','WebhookReceivers','EmailReceiverCount','SmsReceiverCount','WebhookReceiverCount','TotalReceivers','ResourceId')
    '17_TagCompliance.csv'             = @('Subscription','Resource','Type','MissingTags','ResourceGroup','ResourceId')
    '17_ResourceLocks.csv'             = @('Subscription','Name','ResourceGroup','LockLevel','Resource','Notes','ResourceId')
    '18_AutomationAccounts.csv'        = @('Subscription','Name','ResourceGroup','Location')
    '18_ArcMachines.csv'               = @('Subscription','Name','ResourceGroup','OS','Status','AgentVersion','LastStatusChange')
    '00_ExportManifest.csv'            = @('File','Rows','Status','Note')
    '00_SectionErrors.csv'             = @('Subscription','Section','Context','Dataset','Error')
    '00_SectionTimings.csv'            = @('Subscription','Section','Seconds')
}

# ===============================================================================
# EXPORT ALL DATA
# ===============================================================================
Write-Section "EXPORTING ALL DATA"

# Core Infrastructure
Export-SafeCsv $allResources           "01_ResourceInventory.csv"
Export-SafeCsv $allVMs                 "02_VMs.csv"
Export-SafeCsv $allVMMetrics           "02_VM_Metrics.csv"
Export-SafeCsv $allVMSS               "02_VMScaleSets.csv"
Export-SafeCsv $allAppServicePlans     "03_AppServicePlans.csv"
Export-SafeCsv $allWebApps             "03_WebApps.csv"
Export-SafeCsv $allFunctions           "04_Functions.csv"
Export-SafeCsv $allLogicApps           "05_LogicApps.csv"

# Storage
Export-SafeCsv $allDisks               "06_Disks.csv"
Export-SafeCsv ($allDisks | Where-Object { $_.AttachedTo -eq 'UNATTACHED' }) "06_UnattachedDisks.csv"
Export-SafeCsv $allSnapshots           "06_Snapshots.csv"
Export-SafeCsv $allStorageAccounts     "06_StorageAccounts.csv"
Export-SafeCsv $allFileShares          "06_FileShares.csv"

# Networking
Export-SafeCsv $allVNets               "07_VNets_Subnets.csv"
Export-SafeCsv $allPublicIPs           "07_OrphanedPublicIPs.csv"
Export-SafeCsv $allNSGRules            "07_OpenNSGRules.csv"
Export-SafeCsv $allLBs                 "07_LoadBalancers.csv"
Export-SafeCsv $allAppGateways         "07_AppGateways.csv"
Export-SafeCsv $allFirewalls           "07_AzureFirewalls.csv"
Export-SafeCsv $allFrontDoors          "07_FrontDoors.csv"
Export-SafeCsv $allBastions            "07_Bastions.csv"
Export-SafeCsv $allNATGateways         "07_NATGateways.csv"
Export-SafeCsv $allVPNGateways         "07_VPNGateways.csv"
Export-SafeCsv $allExpressRoute        "07_ExpressRoute.csv"
Export-SafeCsv $allPeerings            "07_VNetPeerings.csv"
Export-SafeCsv $allPrivateEndpoints    "07_PrivateEndpoints.csv"
Export-SafeCsv $allPrivateDNS          "07_PrivateDNS.csv"
Export-SafeCsv $allPublicDNS           "07_PublicDNS.csv"
Export-SafeCsv $allNetworkWatchers     "07_NetworkWatchers.csv"
Export-SafeCsv $allCDNProfiles         "07_CDNProfiles.csv"

# Databases
Export-SafeCsv $allSQLServers          "08_SQLServers.csv"
Export-SafeCsv $allSQLDatabases        "08_SQLDatabases.csv"
Export-SafeCsv $allSQLManagedInst      "08_SQLManagedInstances.csv"
Export-SafeCsv $allCosmosDB            "08_CosmosDB.csv"
Export-SafeCsv $allMySQL               "08_MySQL.csv"
Export-SafeCsv $allPostgreSQL          "08_PostgreSQL.csv"
Export-SafeCsv $allRedisCache          "08_RedisCache.csv"

# Messaging & Integration
Export-SafeCsv $allServiceBus          "09_ServiceBus.csv"
Export-SafeCsv $allEventHubs           "09_EventHubs.csv"
Export-SafeCsv $allAPIM                "09_APIM.csv"

# Containers
Export-SafeCsv $allAKS                 "10_AKS_Clusters.csv"
Export-SafeCsv $allAKSNodePools        "10_AKS_NodePools.csv"
Export-SafeCsv $allContainerInstances  "10_ContainerInstances.csv"
Export-SafeCsv $allContainerApps       "10_ContainerApps.csv"
Export-SafeCsv $allContainerRegistries "10_ContainerRegistries.csv"

# Data & Analytics
Export-SafeCsv $allDataFactories       "11_DataFactories.csv"

# Identity & RBAC
Export-SafeCsv $allRBAC                "12_RoleAssignments.csv"
Export-SafeCsv ($allRBAC | Where-Object { $_.HighRisk -eq 'YES' }) "12_HighRiskRoles.csv"
Export-SafeCsv $allCustomRoles         "12_CustomRoles.csv"
Export-SafeCsv $allMgmtGroups          "12_ManagementGroups.csv"
Export-SafeCsv $allGuestUsers          "12_GuestUsers.csv"
Export-SafeCsv $allManagedIdentities   "12_ManagedIdentities.csv"
Export-SafeCsv $allUserAssignedIds     "12_UserAssignedIdentities.csv"

# Security
Export-SafeCsv $allDefenderPricing     "13_DefenderPricing.csv"
Export-SafeCsv $allSecureScore         "13_SecureScore.csv"
Export-SafeCsv $allSecurityAlerts      "13_SecurityAlerts.csv"
Export-SafeCsv $allKeyVaults           "13_KeyVaults.csv"
Export-SafeCsv $allExpiringSecrets     "13_ExpiringSecretsCerts.csv"
Export-SafeCsv $allPolicyNonCompliant  "13_PolicyNonCompliant.csv"
Export-SafeCsv $allPolicyAssignments   "13_PolicyAssignments.csv"
Export-SafeCsv $allDefenderRecs        "13_DefenderRecommendations.csv"

# Cost
Export-SafeCsv $allAdvisorAll          "14_AdvisorAll.csv"
Export-SafeCsv $allAdvisorCost         "14_AdvisorCost.csv"
Export-SafeCsv $allConsumption         "14_ConsumptionByService.csv"
Export-SafeCsv $allReservations        "14_Reservations.csv"
Export-SafeCsv $allBudgets             "14_Budgets.csv"
Export-SafeCsv $allActualCostByResource "14_ActualCostByResource.csv"
Export-SafeCsv $allActualCostByService  "14_ActualCostByService.csv"

# Backup & DR
Export-SafeCsv $allRecoveryVaults      "15_RecoveryVaults.csv"
Export-SafeCsv $allBackupItems         "15_BackupItems.csv"
Export-SafeCsv $allUnprotectedVMs      "15_UnprotectedVMs.csv"

# Monitoring
Export-SafeCsv $allLAWorkspaces        "16_LogAnalyticsWorkspaces.csv"
Export-SafeCsv $allDiagSettings        "16_DiagnosticSettings.csv"
Export-SafeCsv $allAlertRules          "16_AlertRules.csv"
Export-SafeCsv $allActionGroups        "16_ActionGroups.csv"

# Governance
Export-SafeCsv $allTagCompliance       "17_TagCompliance.csv"
Export-SafeCsv $allResourceLocks       "17_ResourceLocks.csv"

# Automation & Hybrid
Export-SafeCsv $allAutomationAccts     "18_AutomationAccounts.csv"
Export-SafeCsv $allArcMachines         "18_ArcMachines.csv"

# ===============================================================================
# EXECUTIVE SUMMARY
# ===============================================================================
Write-Section "EXECUTIVE SUMMARY"

$notCollectedCount = {
    # Shows "Not collected" instead of a misleading 0 when the dataset could not be gathered
    param([string]$File, $Count)
    if ($Count -eq 0 -and $script:datasetNotes[$File]) { 'Not collected' } else { $Count }
}
$lastFullMonth = (Get-Date).AddMonths(-1).ToString('yyyy-MM')
$lastMonthRows = @($allActualCostByService | Where-Object { $_.Month -eq $lastFullMonth })
$lastMonthCost = if ($lastMonthRows.Count) {
    ($lastMonthRows | Group-Object Currency | ForEach-Object {
        '{0:N2} {1}' -f ($_.Group | Measure-Object -Property Cost -Sum).Sum, $_.Name
    }) -join ' + '
} elseif ($script:datasetNotes['14_ActualCostByService.csv']) { 'Not collected' } else { 'n/a' }

$executiveSummary = [ordered]@{
    "Subscriptions Assessed"      = $subscriptions.Count
    "Total VMs"                   = @($allVMs).Count
    "Deallocated/Stopped VMs"     = @($allVMs | Where-Object { $_.PowerState -match 'stopped|deallocated' }).Count
    "VMs Deallocated 90+ Days"    = @($allVMs | Where-Object { $_.DeallocatedOver90Days -eq $true }).Count
    "VMs Using Hybrid Benefit"    = @($allVMs | Where-Object { $_.LicenseType -match 'Windows_Server|Windows_Client|RHEL_BYOS|SLES_BYOS' }).Count
    "Windows VMs w/o Hybrid Benefit" = @($allVMs | Where-Object { $_.OsType -eq 'Windows' -and $_.LicenseType -notmatch 'Windows_Server|Windows_Client' }).Count
    "VMs Without Backup"          = & $notCollectedCount '15_UnprotectedVMs.csv' @($allUnprotectedVMs).Count
    "VM Scale Sets"               = @($allVMSS).Count
    "Unattached Disks"            = @($allDisks | Where-Object { $_.AttachedTo -eq 'UNATTACHED' }).Count
    "Old Snapshots (>90d)"        = @($allSnapshots | Where-Object { $_.AgeDays -gt 90 }).Count
    "Orphaned Public IPs"         = @($allPublicIPs).Count
    "Critical NSG Rules"          = @($allNSGRules | Where-Object { $_.Severity -eq 'CRITICAL' }).Count
    "App Service Plans"           = @($allAppServicePlans).Count
    "Empty App Plans (waste)"     = @($allAppServicePlans | Where-Object { $_.AppCount -eq 0 }).Count
    "Azure Functions"             = @($allFunctions).Count
    "Logic Apps"                  = @($allLogicApps).Count
    "SQL Databases"               = @($allSQLDatabases).Count
    "SQL Servers Open to Internet"= @($allSQLServers | Where-Object { $_.OpenToInternet -eq $true }).Count
    "SQL Managed Instances"       = @($allSQLManagedInst).Count
    "Cosmos DB Accounts"          = @($allCosmosDB).Count
    "Redis Caches"                = @($allRedisCache).Count
    "AKS Clusters"                = @($allAKS).Count
    "Container Apps"              = @($allContainerApps).Count
    "Container Registries"        = @($allContainerRegistries).Count
    "Key Vaults"                  = @($allKeyVaults).Count
    "Key Vaults Public (Allow All)" = @($allKeyVaults | Where-Object { $_.PublicNetworkAccess -ne 'Disabled' -and $_.NetworkDefaultAction -eq 'Allow' -and -not $_.PrivateEndpointCount }).Count
    "Storage Public (Allow All)"  = @($allStorageAccounts | Where-Object { $_.PublicNetworkAccess -ne 'Disabled' -and $_.NetworkDefaultAction -eq 'Allow' -and -not $_.PrivateEndpointCount }).Count
    "Expiring Secrets/Certs"      = @($allExpiringSecrets).Count
    "Owner Assignments"           = & $notCollectedCount '12_RoleAssignments.csv' @($allRBAC | Where-Object { $_.IsOwner -eq $true }).Count
    "Classic Administrators"      = & $notCollectedCount '12_RoleAssignments.csv' @($allRBAC | Where-Object { $_.IsClassicAdmin -eq $true }).Count
    "Guest Users w/ Azure Roles"  = & $notCollectedCount '12_GuestUsers.csv' @($allGuestUsers | Where-Object { $_.HasAzureRoleAssignment -eq $true }).Count
    "Defender High Severity Recs" = & $notCollectedCount '13_DefenderRecommendations.csv' @($allDefenderRecs | Where-Object { $_.Severity -eq 'High' }).Count
    "Advisor Cost Recommendations"= @($allAdvisorCost).Count
    "Security Alerts (Active)"    = @($allSecurityAlerts).Count
    "Policy Non-Compliant"        = @($allPolicyNonCompliant).Count
    "Resources Missing Tags"      = @($allTagCompliance).Count
    "Resources w/o Diagnostics"   = @($allDiagSettings | Where-Object { -not $_.HasDiagnostics }).Count
    "Alert Rules w/o Action Groups" = @($allAlertRules | Where-Object { [int]$_.ActionGroupCount -eq 0 }).Count
    "Action Groups w/o Receivers" = @($allActionGroups | Where-Object { [int]$_.TotalReceivers -eq 0 }).Count
    "Reservations"                = & $notCollectedCount '14_Reservations.csv' @($allReservations).Count
    "Reservations <80% Utilized (30d)" = @($allReservations | Where-Object { "$($_.Utilization30d)" -ne '' -and [double]$_.Utilization30d -lt 80 }).Count
    "Actual Cost $lastFullMonth"  = $lastMonthCost
    "Azure Firewalls"             = @($allFirewalls).Count
    "Front Doors"                 = @($allFrontDoors).Count
    "Bastions"                    = @($allBastions).Count
    "Service Bus Namespaces"      = @($allServiceBus).Count
    "Event Hub Namespaces"        = @($allEventHubs).Count
    "API Management Instances"    = @($allAPIM).Count
    "Data Factories"              = @($allDataFactories).Count
    "Automation Accounts"         = @($allAutomationAccts).Count
    "Arc Connected Machines"      = @($allArcMachines).Count
    "Datasets Not Collected"      = @($script:datasetNotes.Keys).Count
}

$executiveSummary.GetEnumerator() | ForEach-Object {
    $color = 'Green'
    if ("$($_.Value)" -eq 'Not collected') {
        $color = 'DarkYellow'
    } elseif ($_.Key -match 'Unattached|Orphaned|Critical|Without|w/o|Expiring|Missing|Non-Compliant|Alert|Empty|waste|90\+|Open to|Public|Owner|Classic|Guest|High Severity|<80%|Not Collected') {
        if ($_.Value -is [int] -and $_.Value -gt 0) { $color = 'Red' }
    }
    Write-Host "  $($_.Key): $($_.Value)" -ForegroundColor $color
}
if ($script:datasetNotes.Count) {
    Write-Host ""
    Write-Host "  Not collected / partial (see 00_ExportManifest.csv):" -ForegroundColor DarkYellow
    foreach ($k in ($script:datasetNotes.Keys | Sort-Object)) { Write-Host "    $k" -ForegroundColor DarkYellow }
}
# Export summary
$executiveSummary.GetEnumerator() | ForEach-Object {
    [PSCustomObject]@{ Metric = $_.Key; Value = $_.Value }
} | Export-Csv "$OutputPath/00_ExecutiveSummary.csv" -NoTypeInformation -Encoding UTF8

Export-SafeCsv $summaryData "00_ExportManifest.csv"
Export-SafeCsv $sectionErrors "00_SectionErrors.csv"
Export-SafeCsv $sectionTimings "00_SectionTimings.csv"

# Run summary JSON (rewrites the startup copy with end time, timings, errors and not-collected datasets)
Complete-SectionTiming
Write-RunSummary -Final
Write-Host "    + Run summary -> Assessment-RunSummary.json" -ForegroundColor Green

# ===============================================================================
# BUNDLE INTO ZIP
# ===============================================================================
Write-Section "PACKAGING RESULTS"

$csvFiles = Get-ChildItem $OutputPath -Filter *.csv
$zipPath = "$OutputPath.zip"

try {
    # Remove existing zip if re-running
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

    # Use .NET compression (available in PS 5.1+ and PS 7+)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        (Resolve-Path $OutputPath).Path,
        (Join-Path (Resolve-Path (Split-Path $OutputPath -Parent)).Path (Split-Path $zipPath -Leaf)),
        [System.IO.Compression.CompressionLevel]::Optimal,
        $true  # includeBaseDirectory - puts CSVs inside a folder in the zip
    )

    $zipSize = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
    Write-Host "  + Zipped $($csvFiles.Count) CSVs -> $zipPath ($zipSize MB)" -ForegroundColor Green
} catch {
    # Fallback: try Compress-Archive (PS 5.1+)
    try {
        Compress-Archive -Path "$OutputPath/*" -DestinationPath $zipPath -Force
        $zipSize = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
        Write-Host "  + Zipped $($csvFiles.Count) CSVs -> $zipPath ($zipSize MB)" -ForegroundColor Green
    } catch {
        Write-Host "  ! Could not create zip. CSVs are still available in: $OutputPath" -ForegroundColor Yellow
        Write-Host "    To zip manually: Compress-Archive -Path '$OutputPath/*' -DestinationPath '$zipPath'" -ForegroundColor DarkYellow
    }
}

$elapsed = (Get-Date) - $startTime
Write-Host "`n===============================================================" -ForegroundColor Green
Write-Host "  ASSESSMENT COMPLETE" -ForegroundColor Green
Write-Host "  Output directory: $OutputPath" -ForegroundColor Green
Write-Host "  Zip package:      $zipPath" -ForegroundColor Green
Write-Host "  Total CSV files:  $($csvFiles.Count)" -ForegroundColor Green
Write-Host "  Elapsed time:     $($elapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Green
Write-Host "===============================================================" -ForegroundColor Green
Get-ChildItem $OutputPath -Filter *.csv | Sort-Object Name | Format-Table Name, @{N='SizeKB';E={[math]::Round($_.Length/1KB,1)}} -AutoSize

# ===============================================================================
# DOWNLOAD OPTIONS
# ===============================================================================
Write-Host ""
Write-Host "  +-------------------------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |  HOW TO DOWNLOAD                                            |" -ForegroundColor Cyan
Write-Host "  +-------------------------------------------------------------+" -ForegroundColor Cyan
Write-Host ""

# Detect if running in Azure Cloud Shell
$isCloudShell = $env:AZUREPS_HOST_ENVIRONMENT -match 'cloud-shell' -or $env:ACC_CLOUD -or (Test-Path '/home/*/.cloudconsole' 2>$null)

if ($isCloudShell) {
    # Copy zip to home directory for Cloud Shell download command
    $homeZip = Join-Path $HOME (Split-Path $zipPath -Leaf)
    Copy-Item $zipPath $homeZip -Force -ErrorAction SilentlyContinue

    Write-Host "  OPTION 1 - Cloud Shell built-in download (easiest)" -ForegroundColor Yellow
    Write-Host "    Run this command:" -ForegroundColor White
    Write-Host "    download $homeZip" -ForegroundColor Green
    Write-Host ""
    Write-Host "  OPTION 2 - Cloud Shell file browser" -ForegroundColor Yellow
    Write-Host "    Click the file-browser icon (page icon) in the Cloud Shell toolbar" -ForegroundColor White
    Write-Host "    Navigate to: $(Split-Path $homeZip -Leaf)" -ForegroundColor White
    Write-Host "    Right-click -> Download" -ForegroundColor White
    Write-Host ""
    Write-Host "  OPTION 3 - Upload to Storage Account + SAS link" -ForegroundColor Yellow
    Write-Host "    (Useful for sharing with team or if file > 1GB)" -ForegroundColor White
    Write-Host @"
    `$ctx = (Get-AzStorageAccount -ResourceGroupName '<rg>' -Name '<storageacct>').Context
    New-AzStorageContainer -Name 'assessments' -Context `$ctx -Permission Off -ErrorAction SilentlyContinue
    Set-AzStorageBlobContent -File '$zipPath' -Container 'assessments' -Blob '$(Split-Path $zipPath -Leaf)' -Context `$ctx
    New-AzStorageBlobSASToken -Container 'assessments' -Blob '$(Split-Path $zipPath -Leaf)' -Context `$ctx ``
        -Permission r -ExpiryTime (Get-Date).AddHours(24) -FullUri
"@ -ForegroundColor DarkGray
} else {
    Write-Host "  Local terminal detected - zip is already on disk:" -ForegroundColor Yellow
    $resolvedZip = (Resolve-Path $zipPath -ErrorAction SilentlyContinue)
    Write-Host "    $(if ($resolvedZip) { $resolvedZip.Path } else { $zipPath })" -ForegroundColor Green
    Write-Host ""
    Write-Host "  To upload to Azure Storage for sharing:" -ForegroundColor Yellow
    Write-Host @"
    `$ctx = (Get-AzStorageAccount -ResourceGroupName '<rg>' -Name '<storageacct>').Context
    New-AzStorageContainer -Name 'assessments' -Context `$ctx -Permission Off -ErrorAction SilentlyContinue
    Set-AzStorageBlobContent -File '$zipPath' -Container 'assessments' -Blob '$(Split-Path $zipPath -Leaf)' -Context `$ctx
    New-AzStorageBlobSASToken -Container 'assessments' -Blob '$(Split-Path $zipPath -Leaf)' -Context `$ctx ``
        -Permission r -ExpiryTime (Get-Date).AddHours(24) -FullUri
"@ -ForegroundColor DarkGray
}
Write-Host ""

# Stop transcript logging
try { Stop-Transcript | Out-Null } catch {}

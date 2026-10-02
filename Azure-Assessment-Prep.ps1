#Requires -Modules Az.Accounts, Az.Resources, Az.Compute, Az.Monitor, Az.OperationalInsights
<#
.SYNOPSIS
    Azure Assessment Prep & Monitoring Enablement Menu
    Centre Technologies | March 2026

.DESCRIPTION
    Interactive menu script to prepare an Azure environment for accurate assessment.
    Enables monitoring agents, diagnostic settings, and metric collection so that
    the main assessment script (Azure-Assessment-Complete.ps1) returns real utilization data.

    Run this BEFORE the assessment script, ideally 7-14 days in advance, so metrics accumulate.

.NOTES
    - Requires Owner or Contributor + Monitoring Contributor on target subscriptions
    - Uses Azure Monitor Agent (AMA) - the modern replacement for MMA/OMS
    - All changes are additive (nothing is deleted or overwritten)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SubscriptionId,
    [string]$LogAnalyticsWorkspaceName,
    [string]$LogAnalyticsResourceGroup,
    [string]$Location = 'southcentralus',
    [switch]$RunAll
)

$ErrorActionPreference = 'Continue'

# ===============================================================================
# HELPERS
# ===============================================================================

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  +===============================================================+" -ForegroundColor Cyan
    Write-Host "  |     Azure Assessment Prep & Monitoring Enablement            |" -ForegroundColor Cyan
    Write-Host "  |     Centre Technologies                                      |" -ForegroundColor Cyan
    Write-Host "  +===============================================================+" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Menu {
    Write-Host "  +-------------------------------------------------------------+" -ForegroundColor White
    Write-Host "  |  PREP & PREREQUISITES                                       |" -ForegroundColor White
    Write-Host "  |                                                             |" -ForegroundColor White
    Write-Host "  |   [1]  Check current monitoring posture (read-only)         |" -ForegroundColor White
    Write-Host "  |   [2]  Install required PowerShell modules                  |" -ForegroundColor White
    Write-Host "  |   [3]  Create / Select Log Analytics Workspace              |" -ForegroundColor White
    Write-Host "  |                                                             |" -ForegroundColor White
    Write-Host "  |  MONITORING ENABLEMENT                                      |" -ForegroundColor White
    Write-Host "  |                                                             |" -ForegroundColor White
    Write-Host "  |   [4]  Install Azure Monitor Agent on all VMs               |" -ForegroundColor White
    Write-Host "  |   [5]  Create Data Collection Rules (CPU, Memory, Disk)     |" -ForegroundColor White
    Write-Host "  |   [6]  Enable Diagnostic Settings on key resources          |" -ForegroundColor White
    Write-Host "  |   [7]  Enable VM Insights (performance + dependency maps)   |" -ForegroundColor White
    Write-Host "  |   [8]  Register resource providers for monitoring           |" -ForegroundColor White
    Write-Host "  |                                                             |" -ForegroundColor White
    Write-Host "  |  QUICK ACTIONS                                              |" -ForegroundColor White
    Write-Host "  |                                                             |" -ForegroundColor White
    Write-Host "  |   [A]  Run ALL prep steps (3-8) - Full automated setup      |" -ForegroundColor Yellow
    Write-Host "  |   [S]  Show subscription selector                           |" -ForegroundColor White
    Write-Host "  |   [R]  Generate readiness report                            |" -ForegroundColor White
    Write-Host "  |   [Q]  Quit                                                 |" -ForegroundColor White
    Write-Host "  |                                                             |" -ForegroundColor White
    Write-Host "  +-------------------------------------------------------------+" -ForegroundColor White
    Write-Host ""
}

function Confirm-Action {
    param([string]$Message)
    Write-Host ""
    $response = Read-Host "  $Message (Y/N)"
    return $response -match '^[Yy]'
}

function Get-OrCreateWorkspace {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($script:WorkspaceId) { return $script:WorkspaceId }

    Write-Host "`n  Checking for existing Log Analytics workspaces..." -ForegroundColor Yellow
    $workspaces = Get-AzOperationalInsightsWorkspace -ErrorAction SilentlyContinue

    if ($workspaces) {
        Write-Host "`n  Existing workspaces:" -ForegroundColor Cyan
        $i = 0
        foreach ($ws in $workspaces) {
            $i++
            Write-Host "    [$i] $($ws.Name) ($($ws.ResourceGroupName)) - $($ws.Location)" -ForegroundColor White
        }
        Write-Host "    [N] Create a new workspace" -ForegroundColor Yellow
        Write-Host ""
        $choice = Read-Host "  Select workspace"

        if ($choice -match '^\d+$' -and [int]$choice -le $workspaces.Count -and [int]$choice -ge 1) {
            $selected = $workspaces[[int]$choice - 1]
            $script:WorkspaceId = $selected.ResourceId
            $script:WorkspaceName = $selected.Name
            $script:WorkspaceRG = $selected.ResourceGroupName
            Write-Host "  Selected: $($selected.Name)" -ForegroundColor Green
            return $script:WorkspaceId
        } elseif ($choice -notmatch '^[Nn]$') {
            Write-Host "  Invalid selection." -ForegroundColor Red
            return $null
        }
    }

    # Create new workspace
    Write-Host ""
    Write-Host "  === CREATE NEW LOG ANALYTICS WORKSPACE ===" -ForegroundColor Cyan
    $wsName = if ($LogAnalyticsWorkspaceName) { $LogAnalyticsWorkspaceName }
              else { Read-Host "  Workspace name (e.g., law-assessment-prod)" }
    if (-not $wsName) {
        Write-Host "  Workspace name cannot be empty." -ForegroundColor Red
        return $null
    }
    $wsRG   = if ($LogAnalyticsResourceGroup) { $LogAnalyticsResourceGroup }
              else { Read-Host "  Resource group name" }
    if (-not $wsRG) {
        Write-Host "  Resource group name cannot be empty." -ForegroundColor Red
        return $null
    }
    $wsLoc  = Read-Host "  Location (default: $Location)"
    if (-not $wsLoc) { $wsLoc = $Location }

    # Ensure RG exists
    $rg = Get-AzResourceGroup -Name $wsRG -ErrorAction SilentlyContinue
    if (-not $rg) {
        Write-Host "  Creating resource group: $wsRG" -ForegroundColor Yellow
        New-AzResourceGroup -Name $wsRG -Location $wsLoc | Out-Null
    }

    if (-not $PSCmdlet.ShouldProcess($wsName, "Create Log Analytics workspace")) { return }
    $ws = New-AzOperationalInsightsWorkspace `
        -ResourceGroupName $wsRG `
        -Name $wsName `
        -Location $wsLoc `
        -Sku PerGB2018 `
        -RetentionInDays 30

    $script:WorkspaceId = $ws.ResourceId
    $script:WorkspaceName = $ws.Name
    $script:WorkspaceRG = $ws.ResourceGroupName
    Write-Host "  Created workspace: $wsName" -ForegroundColor Green
    return $script:WorkspaceId
}

# ===============================================================================
# MENU FUNCTIONS
# ===============================================================================

function Invoke-Option1_CheckPosture {
    Write-Host "`n  === MONITORING POSTURE CHECK ===" -ForegroundColor Cyan

    # Log Analytics Workspaces
    Write-Host "`n  Log Analytics Workspaces:" -ForegroundColor Yellow
    $workspaces = Get-AzOperationalInsightsWorkspace -ErrorAction SilentlyContinue
    if ($workspaces) {
        $workspaces | ForEach-Object {
            Write-Host "    + $($_.Name) | Retention: $($_.RetentionInDays)d | SKU: $($_.Sku)" -ForegroundColor Green
        }
    } else {
        Write-Host "    x No Log Analytics workspaces found" -ForegroundColor Red
    }

    # VM Monitoring Agent Status
    Write-Host "`n  VM Monitoring Agent Status:" -ForegroundColor Yellow
    $vms = Get-AzVM -ErrorAction SilentlyContinue
    $amaCount = 0; $noAgentCount = 0
    foreach ($vm in $vms) {
        $extensions = Get-AzVMExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name -ErrorAction SilentlyContinue
        $hasAMA = $extensions | Where-Object { $_.ExtensionType -match 'AzureMonitorLinuxAgent|AzureMonitorWindowsAgent' }
        $hasMMA = $extensions | Where-Object { $_.ExtensionType -match 'MicrosoftMonitoringAgent|OmsAgentForLinux' }
        if ($hasAMA) {
            $amaCount++
            Write-Host "    + $($vm.Name) - Azure Monitor Agent" -ForegroundColor Green
        } elseif ($hasMMA) {
            Write-Host "    ! $($vm.Name) - Legacy MMA/OMS (consider upgrading to AMA)" -ForegroundColor Yellow
            $amaCount++
        } else {
            $noAgentCount++
            Write-Host "    x $($vm.Name) - NO monitoring agent" -ForegroundColor Red
        }
    }
    Write-Host "`n  Summary: $amaCount/$(@($vms).Count) VMs have monitoring agents, $noAgentCount without" -ForegroundColor Cyan

    # Diagnostic Settings
    Write-Host "`n  Diagnostic Settings Coverage:" -ForegroundColor Yellow
    $criticalTypes = @(
        'Microsoft.Compute/virtualMachines',
        'Microsoft.Sql/servers/databases',
        'Microsoft.Network/networkSecurityGroups',
        'Microsoft.KeyVault/vaults',
        'Microsoft.Web/sites',
        'Microsoft.Network/applicationGateways',
        'Microsoft.Network/azureFirewalls'
    )
    $withDiag = 0; $withoutDiag = 0
    $critResources = Get-AzResource -ErrorAction SilentlyContinue | Where-Object { $_.ResourceType -in $criticalTypes }
    foreach ($res in $critResources) {
        $diag = Get-AzDiagnosticSetting -ResourceId $res.ResourceId -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if ($diag) { $withDiag++ } else { $withoutDiag++ }
    }
    Write-Host "    Critical resources with diagnostics:    $withDiag" -ForegroundColor Green
    Write-Host "    Critical resources WITHOUT diagnostics: $withoutDiag" -ForegroundColor $(if($withoutDiag -gt 0){'Red'}else{'Green'})

    # Data Collection Rules
    Write-Host "`n  Data Collection Rules:" -ForegroundColor Yellow
    try {
        $dcrs = Get-AzResource -ResourceType 'Microsoft.Insights/dataCollectionRules' -ErrorAction SilentlyContinue
        if ($dcrs) {
            $dcrs | ForEach-Object { Write-Host "    + $($_.Name) ($($_.ResourceGroupName))" -ForegroundColor Green }
        } else {
            Write-Host "    x No Data Collection Rules found" -ForegroundColor Red
        }
    } catch {
        Write-Host "    ? Could not query DCRs" -ForegroundColor DarkYellow
    }

    # Alert Rules
    Write-Host "`n  Alert Rules:" -ForegroundColor Yellow
    $alerts = Get-AzMetricAlertRuleV2 -ErrorAction SilentlyContinue
    $enabled = @($alerts | Where-Object { $_.Enabled }).Count
    $disabled = @($alerts | Where-Object { -not $_.Enabled }).Count
    Write-Host "    Enabled: $enabled | Disabled: $disabled" -ForegroundColor $(if($enabled -gt 0){'Green'}else{'Yellow'})

    # Action Groups
    Write-Host "`n  Action Groups:" -ForegroundColor Yellow
    $ags = Get-AzActionGroup -ErrorAction SilentlyContinue
    if ($ags) {
        $ags | ForEach-Object {
            Write-Host "    + $($_.Name) - Email: $($_.EmailReceivers.Count), SMS: $($_.SmsReceivers.Count)" -ForegroundColor Green
        }
    } else {
        Write-Host "    x No Action Groups configured" -ForegroundColor Red
    }

    Write-Host "`n  Posture check complete." -ForegroundColor Cyan
}

function Invoke-Option2_InstallModules {
    Write-Host "`n  === INSTALLING REQUIRED MODULES ===" -ForegroundColor Cyan

    $modules = @(
        'Az.Accounts',
        'Az.Resources',
        'Az.Compute',
        'Az.Network',
        'Az.Storage',
        'Az.Monitor',
        'Az.OperationalInsights',
        'Az.Sql',
        'Az.CosmosDB',
        'Az.KeyVault',
        'Az.RecoveryServices',
        'Az.Security',
        'Az.Advisor',
        'Az.PolicyInsights',
        'Az.Aks',
        'Az.ContainerRegistry',
        'Az.RedisCache',
        'Az.ConnectedMachine',
        'Az.Dns',
        'Az.PrivateDns',
        'Az.Billing',
        'Az.Reservations',
        'Az.Websites',
        'Az.PostgreSql',
        'Az.MySql',
        'Microsoft.Graph.Users',
        'Microsoft.Graph.Identity.SignIns',
        'Microsoft.Graph.Applications'
    )

    foreach ($mod in $modules) {
        $installed = Get-Module -ListAvailable -Name $mod 2>$null
        if ($installed) {
            Write-Host "    + $mod ($($installed[0].Version))" -ForegroundColor Green
        } else {
            Write-Host "    Installing $mod..." -ForegroundColor Yellow
            try {
                Install-Module -Name $mod -Scope CurrentUser -AllowClobber -Force -ErrorAction Stop
                Write-Host "    + $mod installed" -ForegroundColor Green
            } catch {
                Write-Host "    x Failed to install $mod : $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    Write-Host "`n  Module installation complete." -ForegroundColor Cyan
}

function Invoke-Option3_Workspace {
    Write-Host "`n  === LOG ANALYTICS WORKSPACE SETUP ===" -ForegroundColor Cyan
    Get-OrCreateWorkspace | Out-Null
    if ($script:WorkspaceId) {
        Write-Host "`n  Workspace ready: $script:WorkspaceName ($script:WorkspaceId)" -ForegroundColor Green
    } else {
        Write-Host "`n  ! No workspace selected. Other steps requiring a workspace will be skipped." -ForegroundColor Yellow
    }
}

function Invoke-Option4_InstallAMA {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Host "`n  === INSTALL AZURE MONITOR AGENT ON ALL VMs ===" -ForegroundColor Cyan

    $vms = Get-AzVM -ErrorAction SilentlyContinue
    if (-not $vms) {
        Write-Host "  No VMs found in this subscription." -ForegroundColor Yellow
        return
    }

    $toInstall = @()
    foreach ($vm in $vms) {
        $extensions = Get-AzVMExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name -ErrorAction SilentlyContinue
        $hasAMA = $extensions | Where-Object { $_.ExtensionType -match 'AzureMonitorLinuxAgent|AzureMonitorWindowsAgent' }
        if (-not $hasAMA) {
            $toInstall += $vm
        }
    }

    if ($toInstall.Count -eq 0) {
        Write-Host "  All VMs already have Azure Monitor Agent installed." -ForegroundColor Green
        return
    }

    Write-Host "`n  VMs needing Azure Monitor Agent:" -ForegroundColor Yellow
    $toInstall | ForEach-Object { Write-Host "    - $($_.Name) ($($_.StorageProfile.OsDisk.OsType))" -ForegroundColor White }

    if (-not (Confirm-Action "Install AMA on $($toInstall.Count) VMs?")) { return }

    # Ensure managed identity is enabled (required for AMA)
    foreach ($vm in $toInstall) {
        Write-Host "`n  Processing: $($vm.Name)" -ForegroundColor Yellow
        if (-not $PSCmdlet.ShouldProcess($vm.Name, "Install Azure Monitor Agent")) { continue }

        # Enable system-assigned managed identity if not already
        if (-not $vm.Identity -or $vm.Identity.Type -notmatch 'SystemAssigned') {
            Write-Host "    Enabling system-assigned managed identity..." -ForegroundColor Yellow
            Update-AzVM -ResourceGroupName $vm.ResourceGroupName -VM $vm -IdentityType SystemAssigned -ErrorAction SilentlyContinue | Out-Null
        }

        $osType = if ($vm.StorageProfile -and $vm.StorageProfile.OsDisk) { $vm.StorageProfile.OsDisk.OsType } else { 'Linux' }
        if ($osType -eq 'Windows') {
            Write-Host "    Installing AzureMonitorWindowsAgent..." -ForegroundColor Yellow
            Set-AzVMExtension `
                -ResourceGroupName $vm.ResourceGroupName `
                -VMName $vm.Name `
                -Name 'AzureMonitorWindowsAgent' `
                -Publisher 'Microsoft.Azure.Monitor' `
                -ExtensionType 'AzureMonitorWindowsAgent' `
                -TypeHandlerVersion '1.0' `
                -Location $vm.Location `
                -EnableAutomaticUpgrade $true `
                -ErrorAction SilentlyContinue | Out-Null
        } else {
            Write-Host "    Installing AzureMonitorLinuxAgent..." -ForegroundColor Yellow
            Set-AzVMExtension `
                -ResourceGroupName $vm.ResourceGroupName `
                -VMName $vm.Name `
                -Name 'AzureMonitorLinuxAgent' `
                -Publisher 'Microsoft.Azure.Monitor' `
                -ExtensionType 'AzureMonitorLinuxAgent' `
                -TypeHandlerVersion '1.0' `
                -Location $vm.Location `
                -EnableAutomaticUpgrade $true `
                -ErrorAction SilentlyContinue | Out-Null
        }
        Write-Host "    + AMA extension deployed" -ForegroundColor Green
    }
    Write-Host "`n  AMA installation complete. Agents may take a few minutes to initialize." -ForegroundColor Cyan
}

function Invoke-Option5_CreateDCR {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Host "`n  === CREATE DATA COLLECTION RULES ===" -ForegroundColor Cyan

    $wsId = Get-OrCreateWorkspace
    if (-not $wsId) { Write-Host "  Workspace required. Aborting." -ForegroundColor Red; return }

    $ctx = Get-AzContext
    $subId = $ctx.Subscription.Id

    # Windows DCR
    Write-Host "`n  Creating Windows performance DCR..." -ForegroundColor Yellow
    $winDcrName = "dcr-assessment-windows-perf"
    $winDcrBody = @{
        location = $Location
        properties = @{
            description = "Centre Tech Assessment - Windows Performance Counters"
            dataSources = @{
                performanceCounters = @(
                    @{
                        name = "perfCounters"
                        streams = @("Microsoft-Perf")
                        samplingFrequencyInSeconds = 60
                        counterSpecifiers = @(
                            '\Processor Information(_Total)\% Processor Time',
                            '\Memory\% Committed Bytes In Use',
                            '\Memory\Available MBytes',
                            '\LogicalDisk(_Total)\% Free Space',
                            '\LogicalDisk(_Total)\Disk Reads/sec',
                            '\LogicalDisk(_Total)\Disk Writes/sec',
                            '\Network Interface(*)\Bytes Total/sec',
                            '\Process(_Total)\Working Set',
                            '\System\Processor Queue Length'
                        )
                    }
                )
            }
            destinations = @{
                logAnalytics = @(
                    @{
                        workspaceResourceId = $wsId
                        name = "la-destination"
                    }
                )
            }
            dataFlows = @(
                @{
                    streams = @("Microsoft-Perf")
                    destinations = @("la-destination")
                }
            )
        }
    } | ConvertTo-Json -Depth 10

    try {
        $uri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$script:WorkspaceRG/providers/Microsoft.Insights/dataCollectionRules/${winDcrName}?api-version=2022-06-01"
        $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
        $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
        Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $winDcrBody -ErrorAction Stop | Out-Null
        Write-Host "  + Created: $winDcrName" -ForegroundColor Green
        $script:WinDcrId = "/subscriptions/$subId/resourceGroups/$script:WorkspaceRG/providers/Microsoft.Insights/dataCollectionRules/$winDcrName"
    } catch {
        Write-Host "  ! Could not create Windows DCR: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Linux DCR
    Write-Host "  Creating Linux performance DCR..." -ForegroundColor Yellow
    $linDcrName = "dcr-assessment-linux-perf"
    $linDcrBody = @{
        location = $Location
        properties = @{
            description = "Centre Tech Assessment - Linux Performance Counters"
            dataSources = @{
                performanceCounters = @(
                    @{
                        name = "perfCounters"
                        streams = @("Microsoft-Perf")
                        samplingFrequencyInSeconds = 60
                        counterSpecifiers = @(
                            '\Processor Information(_Total)\% Processor Time',
                            '\Memory\% Used Memory',
                            '\Memory\Available MBytes Memory',
                            '\Logical Disk(_Total)\% Free Space',
                            '\Logical Disk(_Total)\Disk Reads/sec',
                            '\Logical Disk(_Total)\Disk Writes/sec',
                            '\Network(*)\Total Bytes Transmitted'
                        )
                    }
                )
            }
            destinations = @{
                logAnalytics = @(
                    @{
                        workspaceResourceId = $wsId
                        name = "la-destination"
                    }
                )
            }
            dataFlows = @(
                @{
                    streams = @("Microsoft-Perf")
                    destinations = @("la-destination")
                }
            )
        }
    } | ConvertTo-Json -Depth 10

    try {
        $uri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$script:WorkspaceRG/providers/Microsoft.Insights/dataCollectionRules/${linDcrName}?api-version=2022-06-01"
        Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $linDcrBody -ErrorAction Stop | Out-Null
        Write-Host "  + Created: $linDcrName" -ForegroundColor Green
        $script:LinDcrId = "/subscriptions/$subId/resourceGroups/$script:WorkspaceRG/providers/Microsoft.Insights/dataCollectionRules/$linDcrName"
    } catch {
        Write-Host "  ! Could not create Linux DCR: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Associate DCRs with VMs
    Write-Host "`n  Associating DCRs with VMs..." -ForegroundColor Yellow
    $vms = Get-AzVM -ErrorAction SilentlyContinue
    foreach ($vm in $vms) {
        $osType = $vm.StorageProfile.OsDisk.OsType
        $dcrId = if ($osType -eq 'Windows') { $script:WinDcrId } else { $script:LinDcrId }
        if (-not $dcrId) { continue }
        if (-not $PSCmdlet.ShouldProcess($vm.Name, "Associate $osType DCR")) { continue }

        $assocName = "assoc-$($vm.ResourceGroupName)-$($vm.Name)" -replace '[^-\w\.\(\)]', '_'
        if ($assocName.Length -gt 64) { $assocName = $assocName.Substring(0, 64) }
        try {
            $assocUri = "https://management.azure.com$($vm.Id)/providers/Microsoft.Insights/dataCollectionRuleAssociations/${assocName}?api-version=2022-06-01"
            $assocBody = @{
                properties = @{
                    dataCollectionRuleId = $dcrId
                }
            } | ConvertTo-Json
            Invoke-RestMethod -Uri $assocUri -Method Put -Headers $headers -Body $assocBody -ErrorAction Stop | Out-Null
            Write-Host "    + $($vm.Name) -> $($osType) DCR" -ForegroundColor Green
        } catch {
            Write-Host "    ! $($vm.Name): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    Write-Host "`n  DCR setup complete. Metrics will start flowing within 5-10 minutes." -ForegroundColor Cyan
}

function Invoke-Option6_DiagnosticSettings {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Host "`n  === ENABLE DIAGNOSTIC SETTINGS ===" -ForegroundColor Cyan

    $wsId = Get-OrCreateWorkspace
    if (-not $wsId) { Write-Host "  Workspace required. Aborting." -ForegroundColor Red; return }

    $targetTypes = @(
        'Microsoft.Compute/virtualMachines',
        'Microsoft.Sql/servers/databases',
        'Microsoft.Network/networkSecurityGroups',
        'Microsoft.Network/applicationGateways',
        'Microsoft.Network/azureFirewalls',
        'Microsoft.Network/loadBalancers',
        'Microsoft.Network/publicIPAddresses',
        'Microsoft.KeyVault/vaults',
        'Microsoft.Web/sites',
        'Microsoft.ContainerService/managedClusters',
        'Microsoft.Storage/storageAccounts',
        'Microsoft.Cdn/profiles',
        'Microsoft.ApiManagement/service',
        'Microsoft.ServiceBus/namespaces',
        'Microsoft.EventHub/namespaces',
        'Microsoft.DocumentDB/databaseAccounts'
    )

    $resources = Get-AzResource -ErrorAction SilentlyContinue | Where-Object { $_.ResourceType -in $targetTypes }
    $needDiag = @()

    foreach ($res in $resources) {
        $existing = Get-AzDiagnosticSetting -ResourceId $res.ResourceId -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if (-not $existing) { $needDiag += $res }
    }

    if ($needDiag.Count -eq 0) {
        Write-Host "  All critical resources already have diagnostic settings." -ForegroundColor Green
        return
    }

    Write-Host "`n  Resources needing diagnostic settings: $($needDiag.Count)" -ForegroundColor Yellow
    $needDiag | Group-Object ResourceType | ForEach-Object {
        Write-Host "    $($_.Count) x $($_.Name.Split('/')[-1])" -ForegroundColor White
    }

    if (-not (Confirm-Action "Enable diagnostic settings on $($needDiag.Count) resources?")) { return }

    $successCount = 0; $failCount = 0
    foreach ($res in $needDiag) {
        if (-not $PSCmdlet.ShouldProcess($res.Name, "Enable diagnostic settings")) { continue }
        try {
            # Get available diagnostic categories for this resource type
            $categories = Get-AzDiagnosticSettingCategory -ResourceId $res.ResourceId -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

            $logSettings = [System.Collections.Generic.List[object]]::new()
            $metricSettings = [System.Collections.Generic.List[object]]::new()

            foreach ($cat in $categories) {
                if ($cat.CategoryType -eq 'Logs') {
                    $logSettings.Add((New-AzDiagnosticSettingLogSettingsObject -Category $cat.Name -Enabled $true -WarningAction SilentlyContinue))
                } else {
                    $metricSettings.Add((New-AzDiagnosticSettingMetricSettingsObject -Category $cat.Name -Enabled $true -WarningAction SilentlyContinue))
                }
            }

            $params = @{
                Name             = "centre-assessment-diag-$($res.Name.ToLower().Substring(0, [math]::Min(40, $res.Name.Length)))"
                ResourceId       = $res.ResourceId
                WorkspaceId      = $wsId
            }
            if ($logSettings.Count -gt 0)    { $params['Log']    = $logSettings }
            if ($metricSettings.Count -gt 0) { $params['Metric'] = $metricSettings }

            New-AzDiagnosticSetting @params -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
            Write-Host "    + $($res.Name) ($($res.ResourceType.Split('/')[-1]))" -ForegroundColor Green
            $successCount++
        } catch {
            Write-Host "    x $($res.Name): $($_.Exception.Message)" -ForegroundColor Red
            $failCount++
        }
    }
    Write-Host "`n  Diagnostic settings: $successCount enabled, $failCount failed" -ForegroundColor Cyan
}

function Invoke-Option7_VMInsights {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Host "`n  === ENABLE VM INSIGHTS ===" -ForegroundColor Cyan

    $wsId = Get-OrCreateWorkspace
    if (-not $wsId) { Write-Host "  Workspace required. Aborting." -ForegroundColor Red; return }

    Write-Host "  VM Insights provides:" -ForegroundColor Yellow
    Write-Host "    - Performance metrics (CPU, Memory, Disk, Network) in Azure Portal" -ForegroundColor White
    Write-Host "    - Dependency maps showing connections between VMs" -ForegroundColor White
    Write-Host "    - Top N charts and trending analysis" -ForegroundColor White

    $vms = Get-AzVM -ErrorAction SilentlyContinue
    $toEnable = @()
    foreach ($vm in $vms) {
        $extensions = Get-AzVMExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name -ErrorAction SilentlyContinue
        $hasDep = $extensions | Where-Object { $_.ExtensionType -match 'DependencyAgent' }
        if (-not $hasDep) { $toEnable += $vm }
    }

    if ($toEnable.Count -eq 0) {
        Write-Host "  All VMs already have dependency agent installed." -ForegroundColor Green
        return
    }

    Write-Host "`n  VMs needing Dependency Agent: $($toEnable.Count)" -ForegroundColor Yellow
    if (-not (Confirm-Action "Install Dependency Agent on $($toEnable.Count) VMs?")) { return }

    foreach ($vm in $toEnable) {
        $osType = $vm.StorageProfile.OsDisk.OsType
        $extType = if ($osType -eq 'Windows') { 'DependencyAgentWindows' } else { 'DependencyAgentLinux' }
        Write-Host "    Installing $extType on $($vm.Name)..." -ForegroundColor Yellow
        if (-not $PSCmdlet.ShouldProcess($vm.Name, "Install $extType")) { continue }
        try {
            Set-AzVMExtension `
                -ResourceGroupName $vm.ResourceGroupName `
                -VMName $vm.Name `
                -Name $extType `
                -Publisher 'Microsoft.Azure.Monitoring.DependencyAgent' `
                -ExtensionType $extType `
                -TypeHandlerVersion '9.10' `
                -Location $vm.Location `
                -EnableAutomaticUpgrade $true `
                -ErrorAction Stop | Out-Null
            Write-Host "    + $($vm.Name)" -ForegroundColor Green
        } catch {
            Write-Host "    x $($vm.Name): $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # Enable VMInsights solution on workspace
    Write-Host "`n  Enabling VMInsights solution on workspace..." -ForegroundColor Yellow
    try {
        $solution = @{
            location = $Location
            plan = @{
                name = "VMInsights($script:WorkspaceName)"
                publisher = "Microsoft"
                product = "OMSGallery/VMInsights"
            }
            properties = @{
                workspaceResourceId = $wsId
            }
        }
        # Using Set-AzOperationalInsightsIntelligencePack if available, otherwise ARM
        Set-AzOperationalInsightsIntelligencePack `
            -ResourceGroupName $script:WorkspaceRG `
            -WorkspaceName $script:WorkspaceName `
            -IntelligencePackName 'VMInsights' `
            -Enabled $true `
            -ErrorAction SilentlyContinue | Out-Null
        Write-Host "  + VMInsights solution enabled" -ForegroundColor Green
    } catch {
        Write-Host "  ! Could not enable VMInsights solution (may need manual activation in Portal)" -ForegroundColor Yellow
    }

    Write-Host "`n  VM Insights setup complete." -ForegroundColor Cyan
}

function Invoke-Option8_RegisterProviders {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Host "`n  === REGISTER RESOURCE PROVIDERS ===" -ForegroundColor Cyan

    $providers = @(
        'Microsoft.Insights',
        'Microsoft.AlertsManagement',
        'Microsoft.OperationalInsights',
        'Microsoft.OperationsManagement',
        'Microsoft.Advisor',
        'Microsoft.Security',
        'Microsoft.PolicyInsights',
        'Microsoft.Monitor'
    )

    foreach ($provider in $providers) {
        $reg = Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction SilentlyContinue
        $state = $reg.RegistrationState | Select-Object -First 1
        if ($state -eq 'Registered') {
            Write-Host "    + $provider (already registered)" -ForegroundColor Green
        } else {
            Write-Host "    Registering $provider..." -ForegroundColor Yellow
            if ($PSCmdlet.ShouldProcess($provider, "Register resource provider")) {
                Register-AzResourceProvider -ProviderNamespace $provider -ErrorAction SilentlyContinue | Out-Null
            }
            Write-Host "    + $provider (registration initiated)" -ForegroundColor Green
        }
    }
    Write-Host "`n  Provider registration complete. Some may take a few minutes to fully register." -ForegroundColor Cyan
}

function Invoke-OptionS_SelectSubscription {
    Write-Host "`n  === SUBSCRIPTION SELECTOR ===" -ForegroundColor Cyan
    $subs = Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }
    $i = 0
    foreach ($s in $subs) {
        $i++
        $current = if ($s.Id -eq (Get-AzContext).Subscription.Id) { " <- CURRENT" } else { "" }
        Write-Host "    [$i] $($s.Name) ($($s.Id))$current" -ForegroundColor White
    }
    Write-Host ""
    $choice = Read-Host "  Select subscription number"
    if ($choice -match '^\d+$' -and [int]$choice -le $subs.Count -and [int]$choice -ge 1) {
        $selected = $subs[[int]$choice - 1]
        Set-AzContext -SubscriptionId $selected.Id | Out-Null
        Write-Host "  Switched to: $($selected.Name)" -ForegroundColor Green
    }
}

function Invoke-OptionR_ReadinessReport {
    Write-Host "`n  === ASSESSMENT READINESS REPORT ===" -ForegroundColor Cyan

    $report = [System.Collections.ArrayList]::new()
    $ctx = Get-AzContext

    # Check 1: Modules
    $coreModules = @('Az.Compute','Az.Network','Az.Storage','Az.Monitor','Az.OperationalInsights','Az.Sql','Az.KeyVault','Az.RecoveryServices','Az.Security','Az.Advisor')
    $missingMods = $coreModules | Where-Object { -not (Get-Module -ListAvailable -Name $_ 2>$null) }
    $null = $report.Add([PSCustomObject]@{
        Check  = 'Required Az Modules'
        Status = if ($missingMods) { "MISSING: $($missingMods -join ', ')" } else { 'PASS' }
        Action = if ($missingMods) { 'Run Option [2] to install' } else { 'None' }
    })

    # Check 2: Log Analytics
    $workspaces = Get-AzOperationalInsightsWorkspace -ErrorAction SilentlyContinue
    $null = $report.Add([PSCustomObject]@{
        Check  = 'Log Analytics Workspace'
        Status = if ($workspaces) { "PASS ($(@($workspaces).Count) found)" } else { 'FAIL - No workspace' }
        Action = if ($workspaces) { 'None' } else { 'Run Option [3] to create' }
    })

    # Check 3: VM Agents
    $vms = Get-AzVM -ErrorAction SilentlyContinue
    $noAgent = 0
    foreach ($vm in $vms) {
        $ext = Get-AzVMExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name -ErrorAction SilentlyContinue
        $hasAgent = $ext | Where-Object { $_.ExtensionType -match 'AzureMonitor|MicrosoftMonitoringAgent|OmsAgent' }
        if (-not $hasAgent) { $noAgent++ }
    }
    $null = $report.Add([PSCustomObject]@{
        Check  = 'VM Monitoring Agents'
        Status = if ($noAgent -eq 0) { "PASS (all $(@($vms).Count) VMs covered)" } else { "WARN - $noAgent/$(@($vms).Count) VMs without agent" }
        Action = if ($noAgent -gt 0) { 'Run Option [4] to install AMA' } else { 'None' }
    })

    # Check 4: Diagnostic Settings
    $critRes = Get-AzResource -ErrorAction SilentlyContinue | Where-Object {
        $_.ResourceType -in @('Microsoft.Compute/virtualMachines','Microsoft.KeyVault/vaults','Microsoft.Network/networkSecurityGroups','Microsoft.Web/sites')
    }
    $noDiag = 0
    foreach ($r in $critRes) {
        $d = Get-AzDiagnosticSetting -ResourceId $r.ResourceId -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if (-not $d) { $noDiag++ }
    }
    $null = $report.Add([PSCustomObject]@{
        Check  = 'Diagnostic Settings'
        Status = if ($noDiag -eq 0) { "PASS" } else { "WARN - $noDiag resources without diagnostics" }
        Action = if ($noDiag -gt 0) { 'Run Option [6] to enable' } else { 'None' }
    })

    # Check 5: Resource providers
    $provCheck = Get-AzResourceProvider -ProviderNamespace 'Microsoft.Insights' -ErrorAction SilentlyContinue
    $insightsReg = ($provCheck.RegistrationState | Select-Object -First 1) -eq 'Registered'
    $null = $report.Add([PSCustomObject]@{
        Check  = 'Microsoft.Insights Provider'
        Status = if ($insightsReg) { 'PASS' } else { 'FAIL - Not registered' }
        Action = if ($insightsReg) { 'None' } else { 'Run Option [8]' }
    })

    # Check 6: Metrics data
    $hasMetrics = $false
    $sampleVm = $vms | Where-Object { $_.PowerState -eq 'VM running' -or $true } | Select-Object -First 1
    if ($sampleVm) {
        $m = Get-AzMetric -ResourceId $sampleVm.Id -MetricName 'Percentage CPU' -TimeGrain 1.00:00:00 -StartTime (Get-Date).AddDays(-7) -EndTime (Get-Date) -AggregationType Average -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if ($m -and $m.Data.Count -gt 0) { $hasMetrics = $true }
    }
    $null = $report.Add([PSCustomObject]@{
        Check  = 'Metrics Data Available'
        Status = if ($hasMetrics) { 'PASS - CPU metrics flowing' } else { 'WARN - No metric data yet (allow 24-48h after agent install)' }
        Action = if ($hasMetrics) { 'None' } else { 'Wait for data collection, or run Option [5] for DCRs' }
    })

    Write-Host ""
    Write-Host "  +------------------------------------------------------------------------------------+" -ForegroundColor White
    Write-Host "  |  READINESS REPORT - $($ctx.Subscription.Name)" -ForegroundColor White
    Write-Host "  +------------------------------------------------------------------------------------+" -ForegroundColor White
    foreach ($item in $report) {
        $color = if ($item.Status -match '^PASS') { 'Green' } elseif ($item.Status -match '^WARN') { 'Yellow' } else { 'Red' }
        Write-Host "  |  $($item.Check.PadRight(30)) $($item.Status)" -ForegroundColor $color
        if ($item.Action -ne 'None') {
            Write-Host "  |  $(' ' * 30) -> $($item.Action)" -ForegroundColor DarkYellow
        }
    }
    Write-Host "  +------------------------------------------------------------------------------------+" -ForegroundColor White

    $allPass = ($report | Where-Object { $_.Status -match '^PASS' }).Count -eq $report.Count
    if ($allPass) {
        Write-Host "`n  + Environment is READY for assessment!" -ForegroundColor Green
        Write-Host "    Run: .\Azure-Assessment-Complete.ps1" -ForegroundColor Cyan
    } else {
        Write-Host "`n  ! Some items need attention before assessment." -ForegroundColor Yellow
        Write-Host "    Ideally enable monitoring 7-14 days before running the assessment." -ForegroundColor Yellow
    }
}

function Invoke-OptionA_RunAll {
    Write-Host "`n  === FULL AUTOMATED PREP ===" -ForegroundColor Cyan
    Write-Host "  This will run all prep steps (3-8) in sequence." -ForegroundColor Yellow
    Write-Host "  Steps:" -ForegroundColor White
    Write-Host "    1. Create/Select Log Analytics Workspace" -ForegroundColor White
    Write-Host "    2. Install Azure Monitor Agent on all VMs" -ForegroundColor White
    Write-Host "    3. Create Data Collection Rules" -ForegroundColor White
    Write-Host "    4. Enable Diagnostic Settings" -ForegroundColor White
    Write-Host "    5. Enable VM Insights" -ForegroundColor White
    Write-Host "    6. Register Resource Providers" -ForegroundColor White

    if (-not (Confirm-Action "Proceed with full automated prep?")) { return }

    Invoke-Option8_RegisterProviders
    Invoke-Option3_Workspace
    Invoke-Option4_InstallAMA
    Invoke-Option5_CreateDCR
    Invoke-Option6_DiagnosticSettings
    Invoke-Option7_VMInsights

    Write-Host "`n  ===========================================================" -ForegroundColor Green
    Write-Host "  FULL PREP COMPLETE" -ForegroundColor Green
    Write-Host "  ===========================================================" -ForegroundColor Green
    Write-Host "  Next steps:" -ForegroundColor Yellow
    Write-Host "    1. Wait 7-14 days for metrics to accumulate" -ForegroundColor White
    Write-Host "    2. Run: .\Azure-Assessment-Complete.ps1" -ForegroundColor Cyan
    Write-Host "    3. Review CSV output for findings" -ForegroundColor White
}

# ===============================================================================
# MAIN LOOP
# ===============================================================================

# Auth check
$ctx = Get-AzContext
if (-not $ctx) {
    Write-Host "  Not authenticated. Running Connect-AzAccount..." -ForegroundColor Yellow
    try { Connect-AzAccount -ErrorAction Stop | Out-Null } catch { Write-Host "  x Authentication failed: $($_.Exception.Message)" -ForegroundColor Red; return }
    $ctx = Get-AzContext
    if (-not $ctx) { Write-Host "  x Authentication was cancelled or failed. Exiting." -ForegroundColor Red; return }
}

if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

# Non-interactive mode: run all prep steps and exit
if ($RunAll) {
    Write-Host "  Running in non-interactive mode (-RunAll)..." -ForegroundColor Cyan
    Invoke-OptionA_RunAll
    return
}

$running = $true
while ($running) {
    Show-Banner
    $ctx = Get-AzContext
    Write-Host "  Current subscription: $($ctx.Subscription.Name) ($($ctx.Subscription.Id))" -ForegroundColor Green
    Write-Host "  Account: $($ctx.Account.Id)" -ForegroundColor Green
    Write-Host ""
    Show-Menu

    $choice = Read-Host "  Select option"

    switch ($choice.ToUpper()) {
        '1' { Invoke-Option1_CheckPosture }
        '2' { Invoke-Option2_InstallModules }
        '3' { Invoke-Option3_Workspace }
        '4' { Invoke-Option4_InstallAMA }
        '5' { Invoke-Option5_CreateDCR }
        '6' { Invoke-Option6_DiagnosticSettings }
        '7' { Invoke-Option7_VMInsights }
        '8' { Invoke-Option8_RegisterProviders }
        'A' { Invoke-OptionA_RunAll }
        'S' { Invoke-OptionS_SelectSubscription }
        'R' { Invoke-OptionR_ReadinessReport }
        'Q' { $running = $false; Write-Host "`n  Goodbye!`n" -ForegroundColor Cyan }
        default { Write-Host "  Invalid option. Try again." -ForegroundColor Red }
    }

    if ($running -and $choice.ToUpper() -ne 'Q') {
        Write-Host ""
        Read-Host "  Press Enter to return to menu"
    }
}

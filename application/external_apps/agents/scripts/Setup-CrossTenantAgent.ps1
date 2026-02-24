<#
.SYNOPSIS
    Sets up a Custom Engine Agent spanning two tenants:
    - GCC (Government) tenant for M365 / Copilot / Auth
    - Commercial (ETT) tenant for Azure compute (Bot, Container Apps)

.DESCRIPTION
    This script automates the full cross-tenant setup for the "SimpleChat Agent (GCC)"
    Custom Engine Agent. It walks through each phase interactively, prompting for
    confirmation before every step, and logs every action taken.

    Architecture:
    ┌─────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
    │ GCC Tenant (gsademos)                   │   │ Commercial Tenant (ETT)                  │
    │                                         │   │                                          │
    │ • App Registration (bot identity)       │──▶│ • Azure Bot resource                     │
    │   - api://botid-{appId}                 │   │   - AppType: SingleTenant                │
    │   - Multi-tenant sign-in audience       │   │   - TenantId → GCC tenant                │
    │   - Bot Framework redirect URIs         │   │   - AppId → GCC app registration         │
    │   - Client secret                       │   │   - OAuth connection "mcp"               │
    │                                         │   │   - Messaging endpoint → Container App   │
    │ • MCP Resource App (access_as_user)     │   │                                          │
    │                                         │   │ • Container App (bot .NET code)           │
    │ • Teams App Manifest                    │   │   - appsettings.json w/ GCC credentials  │
    │   - customEngineAgents → bot            │   │                                          │
    │   - webApplicationInfo → SSO            │   │ • Container App (MCP server)              │
    │   - Uploaded to GCC Teams catalog       │   │ • Container App (SimpleChat backend)      │
    │                                         │   │ • ACR (container images)                  │
    └─────────────────────────────────────────┘   └──────────────────────────────────────────┘

    Phases:
      Phase 1 — GCC Tenant: Entra ID app registration for the bot
      Phase 2 — Commercial Tenant: Azure Bot resource + OAuth connection
      Phase 3 — Commercial Tenant: Container App for the bot .NET code
      Phase 4 — GCC Tenant: Build Teams manifest + app package ZIP
      Phase 5 — Summary and next steps

    Every phase begins by confirming which tenant (GCC vs Commercial) to log into.
    Every step within a phase prompts before making changes.
    Full -WhatIf support: run with -WhatIf to see what would happen without making changes.

.PARAMETER GccTenantId
    The Entra tenant ID (GUID) for the GCC / Government tenant.
    This is where the app registration and Teams manifest live.

.PARAMETER CommercialTenantId
    The Entra tenant ID (GUID) for the Commercial / ETT tenant.
    This is where the Azure Bot and Container Apps live.

.PARAMETER BotAppName
    Display name for the bot's Entra app registration.
    Default: "simplechat-agent-gcc"

.PARAMETER BotAppId
    If the GCC app registration already exists, provide its Application (client) ID.
    If omitted, the script creates a new one.

.PARAMETER ResourceAppId
    The Application ID of the MCP resource app (defines access_as_user scope) in GCC tenant.
    If omitted, the script searches by -ResourceAppName.

.PARAMETER ResourceAppName
    Display name pattern to search for the MCP resource app registration.
    Used only if -ResourceAppId is not provided. Default: "simplechat"

.PARAMETER McpServerUrl
    Full URL to the MCP server /mcp endpoint (running in the Commercial tenant).
    Example: https://your-mcp-server.azurecontainerapps.io/mcp

.PARAMETER AzureBotName
    Name for the Azure Bot resource in the Commercial tenant.
    Default: "simplechat-agent-gcc-bot"

.PARAMETER ResourceGroupName
    Azure resource group for the Bot (Commercial tenant).
    Default: "your-resource-group"

.PARAMETER ContainerAppName
    Name for the new Container App for the GCC bot .NET code.
    Default: "simplechat-agent-gcc"

.PARAMETER ContainerAppEnvName
    Container Apps Environment name (Commercial tenant).
    Default: auto-detected from existing container apps in the resource group.

.PARAMETER AcrName
    Azure Container Registry name (Commercial tenant).
    Default: "youracrname"

.PARAMETER SecretExpirationDays
    Days until the generated client secret expires. Default: 180

.PARAMETER SkipPhase
    Array of phase numbers to skip (e.g., @(1, 3) to skip Phases 1 and 3).

.PARAMETER OutputDir
    Output directory for the built app package. Default: ./appPackage/build

.EXAMPLE
    .\Setup-CrossTenantAgent.ps1 `
        -GccTenantId "00000000-0000-0000-0000-000000000001" `
        -CommercialTenantId "00000000-0000-0000-0000-000000000002"

    Interactive setup with prompts at each step.

.EXAMPLE
    .\Setup-CrossTenantAgent.ps1 `
        -GccTenantId "00000000-0000-0000-0000-000000000001" `
        -CommercialTenantId "00000000-0000-0000-0000-000000000002" `
        -WhatIf

    Dry run — shows what would happen without making any changes.

.EXAMPLE
    .\Setup-CrossTenantAgent.ps1 `
        -GccTenantId "00000000-0000-0000-0000-000000000001" `
        -CommercialTenantId "00000000-0000-0000-0000-000000000002" `
        -BotAppId "00000000-0000-0000-0000-000000000003" `
        -ResourceAppId "00000000-0000-0000-0000-000000000004" `
        -McpServerUrl "https://your-mcp-server.azurecontainerapps.io/mcp" `
        -SkipPhase @(1)

    Skip Phase 1 (GCC app reg already set up), provide known IDs.

.NOTES
    Prerequisites:
    - Azure CLI (az) installed
    - PowerShell 7+ recommended
    - Permissions to create app registrations in GCC tenant
    - Permissions to create Azure Bot + Container Apps in Commercial tenant
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$GccTenantId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$CommercialTenantId,

    [string]$BotAppName = "simplechat-agent-gcc",

    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$BotAppId = "",

    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$ResourceAppId = "",

    [string]$ResourceAppName = "simplechat",

    [string]$McpServerUrl = "",

    [string]$AzureBotName = "simplechat-agent-gcc-bot",

    [string]$ResourceGroupName = "your-resource-group",

    [string]$ContainerAppName = "simplechat-agent-gcc",

    [string]$ContainerAppEnvName = "",

    [string]$AcrName = "youracrname",

    [int]$SecretExpirationDays = 180,

    [int[]]$SkipPhase = @(),

    [string]$OutputDir = ""
)

#region ── Configuration ──────────────────────────────────────────────────────────
$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$AppPackageDir = Join-Path $ProjectRoot "appPackage"
$DotnetDir = Join-Path $ProjectRoot "dotnet"
$EnvDir = Join-Path $ProjectRoot "env"

if (-not $OutputDir) {
    $OutputDir = Join-Path $AppPackageDir "build"
}

# Accumulated state — values discovered/created during the script
$script:State = @{
    BotAppId         = $BotAppId
    BotAppObjectId   = ""
    BotAppSecret     = ""
    ResourceAppId    = $ResourceAppId
    ResourceSpId     = ""
    McpServerUrl     = $McpServerUrl
    MessagingEndpoint = ""
    ContainerAppFqdn = ""
    OAuthConnectionName = "mcp"
}

# Log file
$LogFile = Join-Path $ProjectRoot "setup-cross-tenant-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
#endregion

#region ── Helper Functions ───────────────────────────────────────────────────────

function Write-Log {
    <#
    .SYNOPSIS Writes a timestamped message to both console and log file.
    #>
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warn", "Error", "Detail", "Header", "Phase")]
        [string]$Level = "Info"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        "Phase" {
            Write-Host ""
            Write-Host "╔══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
            Write-Host "║  $Message" -ForegroundColor Magenta
            Write-Host "╚══════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
        }
        "Header" {
            Write-Host ""
            Write-Host "┌──────────────────────────────────────────────────────────────────────────┐" -ForegroundColor Cyan
            Write-Host "│  $Message" -ForegroundColor Cyan
            Write-Host "└──────────────────────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
        }
        "Success" { Write-Host "  ✓ $Message" -ForegroundColor Green }
        "Warn"    { Write-Host "  ⚠ $Message" -ForegroundColor Yellow }
        "Error"   { Write-Host "  ✗ $Message" -ForegroundColor Red }
        "Detail"  { Write-Host "    → $Message" -ForegroundColor Gray }
        "Info"    { Write-Host "  ℹ $Message" -ForegroundColor White }
    }

    # Always append to log file
    $logLine | Out-File -Append -FilePath $LogFile -Encoding UTF8
}

function Prompt-Continue {
    <#
    .SYNOPSIS Prompts the user to continue or abort. Returns $true to continue.
    #>
    param(
        [string]$Message = "Continue with this step?",
        [switch]$Required
    )

    if ($WhatIfPreference) {
        Write-Log "WhatIf: Would prompt — $Message" -Level Detail
        return $true
    }

    Write-Host ""
    $response = Read-Host "  $Message (Y/n)"
    if ($response -and $response -notin @('y', 'Y', 'yes', 'Yes', '')) {
        if ($Required) {
            Write-Log "User declined required step. Aborting." -Level Error
            exit 1
        }
        Write-Log "User declined. Skipping this step." -Level Warn
        return $false
    }
    return $true
}

function Prompt-TenantLogin {
    <#
    .SYNOPSIS
        Ensures the user is logged into the correct tenant via Azure CLI.
        Prompts to switch if the current login doesn't match.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [ValidateSet("GCC", "Commercial")]
        [string]$TenantLabel
    )

    Write-Log "This step requires Azure CLI login to the $TenantLabel tenant." -Level Info
    Write-Log "  Expected tenant ID: $TenantId" -Level Detail

    $currentAccount = $null
    try {
        $currentAccount = az account show --output json 2>$null | ConvertFrom-Json
    }
    catch { }

    if ($currentAccount -and $currentAccount.tenantId -eq $TenantId) {
        Write-Log "Already logged in to $TenantLabel tenant ($TenantId) as $($currentAccount.user.name)" -Level Success
        return $true
    }

    if ($currentAccount) {
        Write-Log "Currently logged in to tenant $($currentAccount.tenantId) — need $TenantLabel ($TenantId)" -Level Warn
    }
    else {
        Write-Log "Not currently logged in to Azure CLI." -Level Warn
    }

    if ($WhatIfPreference) {
        Write-Log "WhatIf: Would run 'az login --tenant $TenantId --use-device-code'" -Level Detail
        return $true
    }

    if (-not (Prompt-Continue "Log in to $TenantLabel tenant ($TenantId) now?")) {
        Write-Log "Cannot proceed without $TenantLabel tenant login." -Level Error
        return $false
    }

    Write-Log "Running: az login --tenant $TenantId --use-device-code --allow-no-subscriptions" -Level Detail
    Write-Host ""
    # Let stderr flow to console so the device code prompt is visible to the user
    # --allow-no-subscriptions is required for tenants that only have Entra ID (no Azure subscriptions)
    az login --tenant $TenantId --use-device-code --allow-no-subscriptions --output none
    Write-Host ""
    if ($LASTEXITCODE -ne 0) {
        Write-Log "az login failed. Please log in manually and re-run." -Level Error
        return $false
    }

    # Verify
    $account = az account show --output json 2>$null | ConvertFrom-Json
    if ($account.tenantId -ne $TenantId) {
        Write-Log "Login succeeded but tenant doesn't match. Got $($account.tenantId), expected $TenantId" -Level Error
        return $false
    }

    Write-Log "Logged in to $TenantLabel tenant as $($account.user.name)" -Level Success
    return $true
}

function Invoke-GraphApi {
    <#
    .SYNOPSIS Calls Microsoft Graph via az rest. Returns parsed JSON or $null.
    #>
    param(
        [string]$Method = "GET",
        [string]$Uri,
        [string]$Body = $null,
        [string]$GraphEndpoint = "https://graph.microsoft.com"
    )

    $azArgs = @("rest", "--method", $Method, "--uri", "$GraphEndpoint/$Uri", "--headers", "Content-Type=application/json", "--only-show-errors")
    if ($Body) {
        # Write body to temp file to avoid shell escaping issues
        $bodyFile = [System.IO.Path]::GetTempFileName()
        $Body | Set-Content -Path $bodyFile -Encoding UTF8 -NoNewline
        $azArgs += @("--body", "@$bodyFile")
    }

    Write-Log "Graph API: $Method $GraphEndpoint/$Uri" -Level Detail
    if ($Body) {
        Write-Log "  Body: $($Body.Substring(0, [Math]::Min($Body.Length, 200)))$(if ($Body.Length -gt 200) { '...' })" -Level Detail
    }

    try {
        $result = az @azArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Graph API call failed: $result"
        }
        if ($result) {
            return $result | ConvertFrom-Json
        }
        return $null
    }
    finally {
        if ($bodyFile -and (Test-Path $bodyFile)) {
            Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-WhatIf {
    <#
    .SYNOPSIS Outputs a WhatIf message for an operation.
    #>
    param([string]$Operation, [string]$Target)
    Write-Log "WhatIf: $Operation on '$Target'" -Level Detail
}

#endregion

#region ── Banner ─────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Magenta
Write-Host "  SimpleChat Agent (GCC) — Cross-Tenant Setup" -ForegroundColor Magenta
Write-Host "  Custom Engine Agent spanning GCC + Commercial tenants" -ForegroundColor DarkMagenta
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Magenta
Write-Host ""
Write-Log "GCC Tenant ID:         $GccTenantId" -Level Detail
Write-Log "Commercial Tenant ID:  $CommercialTenantId" -Level Detail
Write-Log "Bot App Name:          $BotAppName" -Level Detail
Write-Log "Bot App ID:            $(if ($BotAppId) { $BotAppId } else { '<will be created>' })" -Level Detail
Write-Log "Resource App ID:       $(if ($ResourceAppId) { $ResourceAppId } else { '<will be discovered>' })" -Level Detail
Write-Log "Azure Bot Name:        $AzureBotName" -Level Detail
Write-Log "Resource Group:        $ResourceGroupName" -Level Detail
Write-Log "Container App:         $ContainerAppName" -Level Detail
Write-Log "ACR:                   $AcrName" -Level Detail
Write-Log "MCP Server URL:        $(if ($McpServerUrl) { $McpServerUrl } else { '<will be provided>' })" -Level Detail
Write-Log "Log File:              $LogFile" -Level Detail

if ($WhatIfPreference) {
    Write-Host ""
    Write-Host "  *** DRY RUN MODE (-WhatIf) — No changes will be made ***" -ForegroundColor Yellow
    Write-Host ""
}

if ($SkipPhase.Count -gt 0) {
    Write-Log "Skipping phases: $($SkipPhase -join ', ')" -Level Warn
}

Write-Host ""
Prompt-Continue "Review the configuration above. Ready to begin?" -Required | Out-Null
#endregion


# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 1: GCC Tenant — Entra ID App Registration
# ═══════════════════════════════════════════════════════════════════════════════
if (1 -notin $SkipPhase) {
    Write-Log "PHASE 1: GCC Tenant — Entra ID App Registration for the Bot" -Level Phase
    Write-Log "PURPOSE: Create (or locate) the app registration in the GCC tenant that" -Level Info
    Write-Log "  will serve as the bot's identity. This app ID goes into the Teams" -Level Info
    Write-Log "  manifest, the Azure Bot resource, and the .NET appsettings." -Level Info
    Write-Host ""

    # ── Prompt for GCC tenant login ──
    if (-not (Prompt-TenantLogin -TenantId $GccTenantId -TenantLabel "GCC")) {
        Write-Log "Cannot proceed without GCC tenant login. Aborting Phase 1." -Level Error
        exit 1
    }

    # ────────────────────────────────────────────────────────────────────────
    # Step 1.1: Create or locate the bot app registration
    # ────────────────────────────────────────────────────────────────────────
    Write-Log "Step 1.1: Create or locate bot app registration" -Level Header
    Write-Log "WHAT: Look for an existing app registration named '$BotAppName' in the GCC tenant." -Level Info
    Write-Log "      If not found (and no -BotAppId provided), create a new one." -Level Info
    Write-Log "WHY:  The Azure Bot in the Commercial tenant references this app ID to authenticate" -Level Info
    Write-Log "      as the bot. The Teams manifest also uses it for SSO/identity." -Level Info

    if ($script:State.BotAppId) {
        Write-Log "Bot App ID provided via parameter: $($script:State.BotAppId)" -Level Info
        Write-Log "Looking up existing app registration..." -Level Detail

        if (-not $WhatIfPreference) {
            $existingApp = Invoke-GraphApi -Uri "v1.0/applications?`$filter=appId eq '$($script:State.BotAppId)'&`$select=id,appId,displayName,signInAudience,identifierUris,web"
            if ($existingApp.value -and $existingApp.value.Count -gt 0) {
                $script:State.BotAppObjectId = $existingApp.value[0].id
                Write-Log "Found: $($existingApp.value[0].displayName) (objectId: $($script:State.BotAppObjectId))" -Level Success
                Write-Log "  signInAudience: $($existingApp.value[0].signInAudience)" -Level Detail
                Write-Log "  identifierUris: $($existingApp.value[0].identifierUris -join ', ')" -Level Detail
            }
            else {
                Write-Log "App registration with appId $($script:State.BotAppId) not found in GCC tenant!" -Level Error
                Write-Log "Check that you are logged into the correct tenant and the app exists." -Level Error
                exit 1
            }
        }
        else {
            Write-WhatIf -Operation "Look up app registration" -Target $script:State.BotAppId
        }
    }
    else {
        Write-Log "No -BotAppId provided. Searching for existing app named '$BotAppName'..." -Level Info

        if (-not $WhatIfPreference) {
            $searchResult = az ad app list --display-name $BotAppName --output json --only-show-errors | ConvertFrom-Json
            if ($searchResult -and $searchResult.Count -gt 0) {
                $script:State.BotAppId = $searchResult[0].appId
                $script:State.BotAppObjectId = $searchResult[0].id
                Write-Log "Found existing app: $($searchResult[0].displayName) (appId: $($script:State.BotAppId))" -Level Success
                if (-not (Prompt-Continue "Use this existing app registration?")) {
                    Write-Log "User declined existing app. Will create new one." -Level Info
                    $script:State.BotAppId = ""
                    $script:State.BotAppObjectId = ""
                }
            }
        }

        if (-not $script:State.BotAppId) {
            Write-Log "Creating new app registration: $BotAppName" -Level Info
            Write-Log "  signInAudience: AzureADMultipleOrgs (multi-tenant, required for cross-tenant Bot)" -Level Detail

            if ($PSCmdlet.ShouldProcess("GCC tenant ($GccTenantId)", "Create app registration '$BotAppName'")) {
                if (Prompt-Continue "Create new app registration '$BotAppName' in GCC tenant?") {
                    $newApp = az ad app create `
                        --display-name $BotAppName `
                        --sign-in-audience AzureADMultipleOrgs `
                        --output json --only-show-errors | ConvertFrom-Json

                    if (-not $newApp) {
                        Write-Log "Failed to create app registration." -Level Error
                        exit 1
                    }

                    $script:State.BotAppId = $newApp.appId
                    $script:State.BotAppObjectId = $newApp.id
                    Write-Log "Created app registration: $BotAppName" -Level Success
                    Write-Log "  App (client) ID: $($script:State.BotAppId)" -Level Detail
                    Write-Log "  Object ID:       $($script:State.BotAppObjectId)" -Level Detail

                    # Create service principal
                    Write-Log "Creating service principal for the new app..." -Level Detail
                    az ad sp create --id $script:State.BotAppId --only-show-errors | Out-Null
                    Write-Log "Service principal created." -Level Success
                }
                else {
                    Write-Log "App registration creation declined. Cannot proceed." -Level Error
                    exit 1
                }
            }
            else {
                Write-WhatIf -Operation "Create app registration" -Target $BotAppName
                $script:State.BotAppId = "<will-be-created>"
                $script:State.BotAppObjectId = "<will-be-created>"
            }
        }
    }

    Write-Log "Bot App ID for remaining steps: $($script:State.BotAppId)" -Level Info

    # ────────────────────────────────────────────────────────────────────────
    # Step 1.2: Ensure multi-tenant sign-in audience
    # ────────────────────────────────────────────────────────────────────────
    Write-Log "Step 1.2: Ensure multi-tenant sign-in audience" -Level Header
    Write-Log "WHAT: Set signInAudience to 'AzureADMultipleOrgs' on the bot app registration." -Level Info
    Write-Log "WHY:  The Azure Bot in the Commercial tenant needs to authenticate using this" -Level Info
    Write-Log "      app registration from a different tenant. Multi-tenant audience allows that." -Level Info

    if (-not $WhatIfPreference -and $script:State.BotAppObjectId -and $script:State.BotAppObjectId -ne "<will-be-created>") {
        $appDetails = Invoke-GraphApi -Uri "v1.0/applications/$($script:State.BotAppObjectId)?`$select=signInAudience"
        $currentAudience = $appDetails.signInAudience

        if ($currentAudience -eq "AzureADMultipleOrgs") {
            Write-Log "signInAudience is already 'AzureADMultipleOrgs'. No change needed." -Level Success
        }
        else {
            Write-Log "Current signInAudience: '$currentAudience' — needs to be 'AzureADMultipleOrgs'" -Level Warn

            if ($PSCmdlet.ShouldProcess("App $($script:State.BotAppId)", "Set signInAudience to AzureADMultipleOrgs")) {
                if (Prompt-Continue "Update signInAudience to 'AzureADMultipleOrgs'?") {
                    $body = '{"signInAudience":"AzureADMultipleOrgs"}'
                    Invoke-GraphApi -Method "PATCH" -Uri "v1.0/applications/$($script:State.BotAppObjectId)" -Body $body
                    Write-Log "signInAudience updated to 'AzureADMultipleOrgs'." -Level Success
                }
            }
        }
    }
    else {
        Write-WhatIf -Operation "Ensure signInAudience = AzureADMultipleOrgs" -Target $script:State.BotAppId
    }

    # ────────────────────────────────────────────────────────────────────────
    # Step 1.3: Set identifier URI (api://botid-{appId})
    # ────────────────────────────────────────────────────────────────────────
    Write-Log "Step 1.3: Set identifier URI" -Level Header
    Write-Log "WHAT: Set the Application ID URI to 'api://botid-$($script:State.BotAppId)'." -Level Info
    Write-Log "WHY:  The Teams manifest 'webApplicationInfo.resource' references this URI" -Level Info
    Write-Log "      for SSO token exchange. It must match exactly." -Level Info

    $expectedUri = "api://botid-$($script:State.BotAppId)"

    if (-not $WhatIfPreference -and $script:State.BotAppObjectId -and $script:State.BotAppObjectId -ne "<will-be-created>") {
        $appDetails = Invoke-GraphApi -Uri "v1.0/applications/$($script:State.BotAppObjectId)?`$select=identifierUris"
        $currentUris = @($appDetails.identifierUris)

        if ($expectedUri -in $currentUris) {
            Write-Log "Identifier URI already set: $expectedUri" -Level Success
        }
        else {
            Write-Log "Current identifier URIs: $($currentUris -join ', ')" -Level Detail
            Write-Log "Need to add: $expectedUri" -Level Detail

            if ($PSCmdlet.ShouldProcess("App $($script:State.BotAppId)", "Set identifierUri to $expectedUri")) {
                if (Prompt-Continue "Set identifier URI to '$expectedUri'?") {
                    [string[]]$allUris = @(@($currentUris) + @($expectedUri) | Where-Object { $_ } | Select-Object -Unique)
                    $uriBody = @{ identifierUris = $allUris } | ConvertTo-Json -Compress
                    Invoke-GraphApi -Method "PATCH" -Uri "v1.0/applications/$($script:State.BotAppObjectId)" -Body $uriBody
                    Write-Log "Identifier URI set: $expectedUri" -Level Success
                }
            }
        }
    }
    else {
        Write-WhatIf -Operation "Set identifierUri" -Target $expectedUri
    }

    # ────────────────────────────────────────────────────────────────────────
    # Step 1.4: Add Bot Framework redirect URIs
    # ────────────────────────────────────────────────────────────────────────
    Write-Log "Step 1.4: Add Bot Framework redirect URIs" -Level Header
    Write-Log "WHAT: Add the standard Bot Framework / Teams OAuth redirect URIs to the app." -Level Info
    Write-Log "WHY:  When the Azure Bot performs OAuth (SSO or sign-in), these redirect URIs" -Level Info
    Write-Log "      are required for the token exchange flow to work." -Level Info

    $requiredRedirectUris = @(
        "https://token.botframework.com/.auth/web/redirect",
        "https://teams.microsoft.com/api/platform/v1.0/oAuthRedirect",
        "https://teams.microsoft.com/api/platform/v1.0/oAuthConsentRedirect",
        "https://m365.cloud.microsoft/api/platform/v1.0/oAuthRedirect",
        "https://m365.cloud.microsoft/api/platform/v1.0/oAuthConsentRedirect",
        "https://teams.cloud.microsoft/api/platform/v1.0/oAuthRedirect",
        "https://teams.cloud.microsoft/api/platform/v1.0/oAuthConsentRedirect"
    )

    Write-Log "Required redirect URIs:" -Level Detail
    foreach ($uri in $requiredRedirectUris) {
        Write-Log "  $uri" -Level Detail
    }

    if (-not $WhatIfPreference -and $script:State.BotAppObjectId -and $script:State.BotAppObjectId -ne "<will-be-created>") {
        $appDetails = Invoke-GraphApi -Uri "v1.0/applications/$($script:State.BotAppObjectId)?`$select=web"
        $existingRedirects = @()
        if ($appDetails.web -and $appDetails.web.redirectUris) {
            $existingRedirects = @($appDetails.web.redirectUris)
        }

        $missing = @($requiredRedirectUris | Where-Object { $_ -notin $existingRedirects })
        if ($missing.Count -eq 0) {
            Write-Log "All $($requiredRedirectUris.Count) redirect URIs already present." -Level Success
        }
        else {
            Write-Log "$($missing.Count) redirect URIs need to be added." -Level Warn
            foreach ($m in $missing) { Write-Log "  MISSING: $m" -Level Detail }

            if ($PSCmdlet.ShouldProcess("App $($script:State.BotAppId)", "Add $($missing.Count) redirect URIs")) {
                if (Prompt-Continue "Add $($missing.Count) missing redirect URIs?") {
                    [string[]]$allRedirects = @(@($existingRedirects) + @($missing) | Where-Object { $_ } | Select-Object -Unique)
                    $redirectBody = @{ web = @{ redirectUris = $allRedirects } } | ConvertTo-Json -Depth 5 -Compress
                    Invoke-GraphApi -Method "PATCH" -Uri "v1.0/applications/$($script:State.BotAppObjectId)" -Body $redirectBody
                    Write-Log "Redirect URIs updated ($($allRedirects.Count) total)." -Level Success
                }
            }
        }
    }
    else {
        Write-WhatIf -Operation "Add Bot Framework redirect URIs" -Target $script:State.BotAppId
    }

    # ────────────────────────────────────────────────────────────────────────
    # Step 1.5: Generate client secret
    # ────────────────────────────────────────────────────────────────────────
    Write-Log "Step 1.5: Generate client secret" -Level Header
    Write-Log "WHAT: Generate a client secret on the bot app registration." -Level Info
    Write-Log "WHY:  The Azure Bot resource and the .NET Container App need this secret to" -Level Info
    Write-Log "      authenticate as the bot (ServiceConnection in appsettings.json)." -Level Info
    Write-Log "NOTE: The secret will be stored in the env user file (gitignored) and displayed" -Level Info
    Write-Log "      once. Save it — you cannot retrieve it later from Entra ID." -Level Info

    if (-not $WhatIfPreference -and $script:State.BotAppId -and $script:State.BotAppId -ne "<will-be-created>") {
        $expirationDate = (Get-Date).AddDays($SecretExpirationDays).ToString("yyyy-MM-dd")
        Write-Log "Secret will expire: $expirationDate ($SecretExpirationDays days)" -Level Detail

        if ($PSCmdlet.ShouldProcess("App $($script:State.BotAppId)", "Generate client secret (expires $expirationDate)")) {
            if (Prompt-Continue "Generate a new client secret for bot app $($script:State.BotAppId)?") {
                $secret = az ad app credential reset `
                    --id $script:State.BotAppId `
                    --append `
                    --end-date $expirationDate `
                    --query password `
                    --output tsv --only-show-errors

                if (-not $secret) {
                    Write-Log "Failed to generate client secret." -Level Error
                    exit 1
                }

                $script:State.BotAppSecret = $secret
                Write-Log "Client secret generated (expires $expirationDate)." -Level Success
                Write-Log "  *** SAVE THIS SECRET — it cannot be retrieved later ***" -Level Warn
                Write-Host ""
                Write-Host "  Client Secret: $secret" -ForegroundColor Yellow
                Write-Host ""
            }
        }
    }
    else {
        Write-WhatIf -Operation "Generate client secret" -Target $script:State.BotAppId
    }

    # ────────────────────────────────────────────────────────────────────────
    # Step 1.6: Locate MCP resource app registration
    # ────────────────────────────────────────────────────────────────────────
    Write-Log "Step 1.6: Locate MCP resource app registration" -Level Header
    Write-Log "WHAT: Find (or confirm) the app registration that defines the access_as_user" -Level Info
    Write-Log "      scope for the MCP server. The bot's OAuth connection uses this scope." -Level Info
    Write-Log "WHY:  The Azure Bot OAuth connection 'mcp' needs: api://{ResourceAppId}/access_as_user" -Level Info

    if (-not $script:State.ResourceAppId) {
        Write-Log "No -ResourceAppId provided. Searching by name pattern: *$ResourceAppName*" -Level Info

        if (-not $WhatIfPreference) {
            $resourceApps = az ad app list --display-name $ResourceAppName --output json --only-show-errors | ConvertFrom-Json

            if ($resourceApps -and $resourceApps.Count -gt 0) {
                if ($resourceApps.Count -eq 1) {
                    $script:State.ResourceAppId = $resourceApps[0].appId
                    Write-Log "Found: $($resourceApps[0].displayName) (appId: $($script:State.ResourceAppId))" -Level Success
                }
                else {
                    Write-Host ""
                    Write-Host "  Multiple apps found matching '$ResourceAppName':" -ForegroundColor Yellow
                    for ($i = 0; $i -lt $resourceApps.Count; $i++) {
                        Write-Host "    [$i] $($resourceApps[$i].displayName) — $($resourceApps[$i].appId)" -ForegroundColor White
                    }
                    $selection = Read-Host "  Enter number to select (or paste an appId directly)"

                    if ($selection -match '^[0-9]+$' -and [int]$selection -lt $resourceApps.Count) {
                        $script:State.ResourceAppId = $resourceApps[[int]$selection].appId
                    }
                    elseif ($selection -match '^[0-9a-fA-F]{8}-') {
                        $script:State.ResourceAppId = $selection.Trim()
                    }
                    else {
                        Write-Log "Invalid selection." -Level Error
                        exit 1
                    }
                    Write-Log "Selected resource app: $($script:State.ResourceAppId)" -Level Success
                }
            }
            else {
                Write-Log "No apps found matching '$ResourceAppName'. Enter the Resource App ID:" -Level Warn
                $script:State.ResourceAppId = Read-Host "  Resource App ID (MCP server API)"
                if (-not $script:State.ResourceAppId) {
                    Write-Log "Resource App ID is required for the OAuth connection." -Level Error
                    exit 1
                }
            }
        }
        else {
            Write-WhatIf -Operation "Search for resource app by name" -Target $ResourceAppName
            $script:State.ResourceAppId = "<will-be-discovered>"
        }
    }
    else {
        Write-Log "Using provided Resource App ID: $($script:State.ResourceAppId)" -Level Info
    }

    # Verify the resource app and check for access_as_user scope
    if (-not $WhatIfPreference -and $script:State.ResourceAppId -ne "<will-be-discovered>") {
        Write-Log "Verifying resource app and checking for 'access_as_user' scope..." -Level Detail

        $resourceSp = Invoke-GraphApi -Uri "v1.0/servicePrincipals?`$filter=appId eq '$($script:State.ResourceAppId)'&`$select=id,displayName,oauth2PermissionScopes"

        if ($resourceSp.value -and $resourceSp.value.Count -gt 0) {
            $script:State.ResourceSpId = $resourceSp.value[0].id
            Write-Log "Resource app service principal found: $($resourceSp.value[0].displayName)" -Level Success

            $scopes = $resourceSp.value[0].oauth2PermissionScopes
            $accessScope = $scopes | Where-Object { $_.value -eq "access_as_user" }
            if ($accessScope) {
                Write-Log "Scope 'access_as_user' found (ID: $($accessScope.id))" -Level Success
            }
            else {
                Write-Log "Scope 'access_as_user' NOT found on resource app!" -Level Warn
                Write-Log "You may need to add it: Azure Portal → App registrations → Expose an API → Add a scope" -Level Detail
            }
        }
        else {
            Write-Log "Service principal for resource app $($script:State.ResourceAppId) not found in this tenant." -Level Warn
            Write-Log "You may need to create one or grant admin consent." -Level Detail
        }
    }

    # ────────────────────────────────────────────────────────────────────────
    # Step 1.7: Resolve MCP server URL
    # ────────────────────────────────────────────────────────────────────────
    Write-Log "Step 1.7: Resolve MCP server URL" -Level Header
    Write-Log "WHAT: Determine the full URL to the MCP server's /mcp endpoint." -Level Info
    Write-Log "WHY:  The OAuth connection's scope references the MCP resource app, and the" -Level Info
    Write-Log "      .NET bot sends HTTP requests to this URL at runtime." -Level Info

    if (-not $script:State.McpServerUrl) {
        if ($WhatIfPreference) {
            Write-WhatIf -Operation "Prompt for MCP server URL" -Target "<user-provided>"
            $script:State.McpServerUrl = "<will-be-provided>"
        }
        else {
            Write-Host ""
            $script:State.McpServerUrl = Read-Host "  Enter the MCP server URL (e.g. https://alb-simplechat-mcp.*.azurecontainerapps.io/mcp)"
            if (-not $script:State.McpServerUrl) {
                Write-Log "MCP server URL is required." -Level Error
                exit 1
            }
        }
    }
    Write-Log "MCP Server URL: $($script:State.McpServerUrl)" -Level Success

    # ── Phase 1 Summary ──
    Write-Host ""
    Write-Host "  ┌─ Phase 1 Summary ─────────────────────────────────────────────────────┐" -ForegroundColor Green
    Write-Host "  │  Bot App ID:      $($script:State.BotAppId)" -ForegroundColor Green
    Write-Host "  │  Resource App ID: $($script:State.ResourceAppId)" -ForegroundColor Green
    Write-Host "  │  MCP Server URL:  $($script:State.McpServerUrl)" -ForegroundColor Green
    Write-Host "  │  Secret:          $(if ($script:State.BotAppSecret) { '(generated — see above)' } else { '<not generated>' })" -ForegroundColor Green
    Write-Host "  └────────────────────────────────────────────────────────────────────────┘" -ForegroundColor Green
    Write-Host ""

    Prompt-Continue "Phase 1 complete. Continue to Phase 2 (Commercial tenant - Azure Bot)?" -Required | Out-Null
}
else {
    Write-Log "Phase 1 SKIPPED (included in -SkipPhase)." -Level Warn
    Write-Log "Using provided values: BotAppId=$($script:State.BotAppId), ResourceAppId=$($script:State.ResourceAppId)" -Level Detail
}


# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 2: Commercial Tenant — Azure Bot Resource
# ═══════════════════════════════════════════════════════════════════════════════
if (2 -notin $SkipPhase) {
    Write-Log "PHASE 2: Commercial Tenant — Azure Bot Resource" -Level Phase
    Write-Log "PURPOSE: Create an Azure Bot resource in the Commercial (ETT) tenant that" -Level Info
    Write-Log "  references the GCC app registration. This Bot will be configured as" -Level Info
    Write-Log "  SingleTenant (pointing at the GCC tenant) and will have an OAuth" -Level Info
    Write-Log "  connection for the MCP server token exchange." -Level Info
    Write-Host ""

    # ── Prompt for Commercial tenant login ──
    if (-not (Prompt-TenantLogin -TenantId $CommercialTenantId -TenantLabel "Commercial")) {
        Write-Log "Cannot proceed without Commercial tenant login. Aborting Phase 2." -Level Error
        exit 1
    }

    # Set subscription context
    Write-Log "Setting Azure subscription context..." -Level Detail
    if (-not $WhatIfPreference) {
        $sub = az account show --query id -o tsv 2>$null
        Write-Log "Active subscription: $sub" -Level Detail
    }

    # ────────────────────────────────────────────────────────────────────────
    # Step 2.1: Create Azure Bot resource
    # ────────────────────────────────────────────────────────────────────────
    Write-Log "Step 2.1: Create Azure Bot resource" -Level Header
    Write-Log "WHAT: Create an Azure Bot (az bot create) in the Commercial tenant." -Level Info
    Write-Log "      - Name: $AzureBotName" -Level Info
    Write-Log "      - App Type: SingleTenant" -Level Info
    Write-Log "      - Tenant ID: $GccTenantId (GCC — where the app registration lives)" -Level Info
    Write-Log "      - App ID: $($script:State.BotAppId) (from GCC app registration)" -Level Info
    Write-Log "WHY:  The Azure Bot resource is required for Teams channel integration." -Level Info
    Write-Log "      It bridges the GCC identity with the Commercial compute." -Level Info
    Write-Log "      'SingleTenant' with the GCC tenant ID tells Bot Framework to validate" -Level Info
    Write-Log "      tokens from the GCC tenant specifically." -Level Info

    if (-not $WhatIfPreference) {
        # Check if bot already exists
        Write-Log "Checking if Azure Bot '$AzureBotName' already exists..." -Level Detail
        $existingBot = az bot show --name $AzureBotName --resource-group $ResourceGroupName --output json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue

        if ($existingBot) {
            Write-Log "Azure Bot '$AzureBotName' already exists." -Level Success
            Write-Log "  Current App ID: $($existingBot.properties.msaAppId)" -Level Detail
            Write-Log "  Current Endpoint: $($existingBot.properties.endpoint)" -Level Detail
            Write-Log "  Current App Type: $($existingBot.properties.msaAppType)" -Level Detail
            Write-Log "  Current Tenant:   $($existingBot.properties.msaAppTenantId)" -Level Detail

            if ($existingBot.properties.msaAppId -ne $script:State.BotAppId) {
                Write-Log "WARNING: Existing bot uses App ID $($existingBot.properties.msaAppId), but we expect $($script:State.BotAppId)" -Level Warn
                Prompt-Continue "The app IDs don't match. Continue anyway?" -Required | Out-Null
            }
        }
        else {
            Write-Log "Bot not found. Will create new Azure Bot." -Level Info

            if ($PSCmdlet.ShouldProcess("Resource Group $ResourceGroupName", "Create Azure Bot '$AzureBotName' (SingleTenant, GCC tenant $GccTenantId)")) {
                if (Prompt-Continue "Create Azure Bot '$AzureBotName' in resource group '$ResourceGroupName'?") {
                    Write-Log "Running: az bot create --resource-group $ResourceGroupName --name $AzureBotName --app-type SingleTenant --appid $($script:State.BotAppId) --tenant-id $GccTenantId" -Level Detail

                    az bot create `
                        --resource-group $ResourceGroupName `
                        --name $AzureBotName `
                        --app-type SingleTenant `
                        --appid $script:State.BotAppId `
                        --tenant-id $GccTenantId `
                        --output json --only-show-errors | Out-Null

                    if ($LASTEXITCODE -ne 0) {
                        Write-Log "Failed to create Azure Bot. Check permissions and resource group." -Level Error
                        exit 1
                    }
                    Write-Log "Azure Bot '$AzureBotName' created successfully." -Level Success
                }
            }
        }
    }
    else {
        Write-WhatIf -Operation "Create Azure Bot (SingleTenant)" -Target "$AzureBotName in $ResourceGroupName"
    }

    # ────────────────────────────────────────────────────────────────────────
    # Step 2.2: Set messaging endpoint
    # ────────────────────────────────────────────────────────────────────────
    Write-Log "Step 2.2: Set messaging endpoint" -Level Header
    Write-Log "WHAT: Configure the Azure Bot's messaging endpoint to point to the .NET" -Level Info
    Write-Log "      Container App that will run in the Commercial tenant." -Level Info
    Write-Log "WHY:  When Teams sends messages to the bot, Bot Framework routes them" -Level Info
    Write-Log "      to this HTTPS endpoint (/api/messages)." -Level Info

    # Try to predict the endpoint, but the actual FQDN depends on the selected
    # Container Apps Environment (determined in Phase 3). We'll detect the environment
    # domain if possible, otherwise use a placeholder and update after creation.
    $envDomain = ""
    if (-not $WhatIfPreference) {
        # Try to get the environment domain from an existing container app in the resource group
        Write-Log "Detecting Container Apps Environment domain..." -Level Detail
        $existingFqdn = az containerapp list --resource-group $ResourceGroupName --query "[0].properties.configuration.ingress.fqdn" -o tsv 2>$null
        if ($existingFqdn) {
            # FQDN format: appname.envdomain.region.azurecontainerapps.io
            # Extract everything after the first dot
            $envDomain = $existingFqdn.Substring($existingFqdn.IndexOf('.') + 1)
            Write-Log "Detected environment domain: $envDomain" -Level Detail
        }
    }

    if ($envDomain) {
        $expectedEndpoint = "https://$ContainerAppName.$envDomain/api/messages"
    }
    else {
        $expectedEndpoint = "https://$ContainerAppName.<pending-container-app-fqdn>/api/messages"
    }
    Write-Log "Expected endpoint: $expectedEndpoint" -Level Detail
    Write-Log "(This assumes the Container App will be named '$ContainerAppName' in the same environment)" -Level Detail

    if (-not $WhatIfPreference) {
        Write-Host ""
        $customEndpoint = Read-Host "  Press Enter to use default endpoint, or type a custom one [$expectedEndpoint]"
        if ($customEndpoint) {
            $expectedEndpoint = $customEndpoint
        }

        $script:State.MessagingEndpoint = $expectedEndpoint

        if ($PSCmdlet.ShouldProcess("Azure Bot '$AzureBotName'", "Set messaging endpoint to $expectedEndpoint")) {
            if (Prompt-Continue "Set messaging endpoint to '$expectedEndpoint'?") {
                az bot update `
                    --resource-group $ResourceGroupName `
                    --name $AzureBotName `
                    --endpoint $expectedEndpoint `
                    --output json --only-show-errors | Out-Null

                if ($LASTEXITCODE -ne 0) {
                    Write-Log "Failed to update messaging endpoint." -Level Error
                }
                else {
                    Write-Log "Messaging endpoint set: $expectedEndpoint" -Level Success
                }
            }
        }
    }
    else {
        $script:State.MessagingEndpoint = $expectedEndpoint
        Write-WhatIf -Operation "Set messaging endpoint" -Target $expectedEndpoint
    }

    # ────────────────────────────────────────────────────────────────────────
    # Step 2.3: Enable Teams channel (Government for GCC)
    # ────────────────────────────────────────────────────────────────────────
    Write-Log "Step 2.3: Enable Teams channel on Azure Bot" -Level Header
    Write-Log "WHAT: Register the 'msteams' channel on the Azure Bot." -Level Info
    Write-Log "WHY:  Without this, the bot cannot receive messages from Teams/Copilot." -Level Info
    Write-Log "NOTE: For GCC tenants, the channel must be configured as 'Microsoft Teams Government'" -Level Warn
    Write-Log "      (not 'Microsoft Teams Commercial'). The Azure CLI does not support this flag," -Level Warn
    Write-Log "      so we use the ARM REST API to create the channel with the correct deployment." -Level Warn

    if (-not $WhatIfPreference) {
        # Check if Teams channel already exists
        Write-Log "Checking existing channels..." -Level Detail
        $channels = az bot msteams show --name $AzureBotName --resource-group $ResourceGroupName --output json 2>$null

        if ($channels -and $LASTEXITCODE -eq 0) {
            Write-Log "Teams channel already enabled." -Level Success
            Write-Log "⚠ IMPORTANT: Verify in Azure Portal that it is set to 'Microsoft Teams Government'," -Level Warn
            Write-Log "  NOT 'Microsoft Teams Commercial'. If wrong, delete and re-create the channel." -Level Warn
        }
        else {
            if ($PSCmdlet.ShouldProcess("Azure Bot '$AzureBotName'", "Enable Teams Government channel")) {
                if (Prompt-Continue "Enable Teams Government channel on '$AzureBotName'?") {
                    # Use ARM REST API to create the Teams channel with deploymentEnvironment = "CommercialDeployment"
                    # For GCC, this should be "GovernmentDeployment" (callingWebhook is not needed for messaging)
                    $subscriptionId = az account show --query id -o tsv 2>$null
                    $channelUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.BotService/botServices/$AzureBotName/channels/MsTeamsChannel?api-version=2022-09-15"
                    $channelBody = @{
                        location = "global"
                        properties = @{
                            channelName = "MsTeamsChannel"
                            properties = @{
                                isEnabled = $true
                                deploymentEnvironment = "GovernmentDeployment"
                            }
                        }
                    } | ConvertTo-Json -Depth 5 -Compress

                    # Write body to temp file to avoid shell escaping issues
                    $bodyFile = [System.IO.Path]::GetTempFileName()
                    $channelBody | Set-Content -Path $bodyFile -Encoding UTF8 -NoNewline

                    Write-Log "ARM API: PUT $channelUri" -Level Detail
                    Write-Log "  Body: $channelBody" -Level Detail

                    $result = az rest --method PUT --uri $channelUri --body "@$bodyFile" --headers "Content-Type=application/json" --output json --only-show-errors 2>&1
                    Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue

                    if ($LASTEXITCODE -ne 0) {
                        Write-Log "Failed to enable Teams Government channel via ARM API." -Level Error
                        Write-Log "  Error: $result" -Level Error
                        Write-Log "  You can do this manually in Azure Portal:" -Level Warn
                        Write-Log "    1. Go to Azure Bot '$AzureBotName' → Channels" -Level Warn
                        Write-Log "    2. Add Microsoft Teams channel" -Level Warn
                        Write-Log "    3. Select 'Microsoft Teams Government'" -Level Warn
                        Write-Log "    4. Click Apply" -Level Warn
                    }
                    else {
                        Write-Log "Teams Government channel enabled." -Level Success
                    }
                }
            }
        }
    }
    else {
        Write-WhatIf -Operation "Enable Teams Government channel" -Target $AzureBotName
    }

    # ────────────────────────────────────────────────────────────────────────
    # Step 2.4: Create OAuth connection setting
    # ────────────────────────────────────────────────────────────────────────
    Write-Log "Step 2.4: Create OAuth connection setting" -Level Header
    Write-Log "WHAT: Add an OAuth connection named '$($script:State.OAuthConnectionName)' to the Azure Bot." -Level Info
    Write-Log "      - Provider: Aad V2" -Level Info
    Write-Log "      - Client ID: $($script:State.BotAppId) (GCC app registration)" -Level Info
    Write-Log "      - Tenant ID: $GccTenantId (GCC tenant)" -Level Info
    Write-Log "      - Scopes: api://$($script:State.ResourceAppId)/access_as_user" -Level Info
    Write-Log "WHY:  When a user chats with the bot in Teams, the bot needs an access token" -Level Info
    Write-Log "      to call the MCP server on the user's behalf. This OAuth connection" -Level Info
    Write-Log "      handles the sign-in flow and token acquisition." -Level Info
    Write-Log "NOTE: This step often requires manual configuration in Azure Portal because" -Level Info
    Write-Log "      the 'az bot authsetting' commands have limitations. The script will" -Level Info
    Write-Log "      attempt it and provide manual instructions if it fails." -Level Info

    $oauthScope = "api://$($script:State.ResourceAppId)/access_as_user"

    if (-not $WhatIfPreference) {
        if ($PSCmdlet.ShouldProcess("Azure Bot '$AzureBotName'", "Create OAuth connection '$($script:State.OAuthConnectionName)'")) {
            if (Prompt-Continue "Create/update OAuth connection '$($script:State.OAuthConnectionName)' on bot '$AzureBotName'?") {
                # Check if the connection already exists
                $existingConn = az bot authsetting show `
                    --name $AzureBotName `
                    --resource-group $ResourceGroupName `
                    --setting-name $script:State.OAuthConnectionName `
                    --output json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue

                if ($existingConn) {
                    Write-Log "OAuth connection '$($script:State.OAuthConnectionName)' already exists." -Level Success
                    Write-Log "  Service Provider: $($existingConn.properties.serviceProviderDisplayName)" -Level Detail
                    Write-Log "  If it needs updating, use the Azure Portal:" -Level Detail
                    Write-Log "  Portal → Bot → Configuration → OAuth Connection Settings" -Level Detail
                }
                else {
                    Write-Log "Attempting to create OAuth connection via CLI..." -Level Detail
                    Write-Log "Running: az bot authsetting create ..." -Level Detail

                    # The client secret is needed for the OAuth connection
                    $oauthSecret = $script:State.BotAppSecret
                    if (-not $oauthSecret) {
                        Write-Log "Client secret not available in script state." -Level Warn
                        $oauthSecret = Read-Host "  Enter the client secret for app $($script:State.BotAppId) (will be used for OAuth)"
                    }

                    try {
                        az bot authsetting create `
                            --name $AzureBotName `
                            --resource-group $ResourceGroupName `
                            --setting-name $script:State.OAuthConnectionName `
                            --client-id $script:State.BotAppId `
                            --client-secret $oauthSecret `
                            --service "Aadv2" `
                            --provider-scope-string $oauthScope `
                            --parameters "tenantId=$GccTenantId" `
                            --output json --only-show-errors | Out-Null

                        if ($LASTEXITCODE -eq 0) {
                            Write-Log "OAuth connection '$($script:State.OAuthConnectionName)' created." -Level Success
                        }
                        else {
                            throw "CLI command returned non-zero exit code"
                        }
                    }
                    catch {
                        Write-Log "CLI creation failed. This is common — manual setup required." -Level Warn
                        Write-Host ""
                        Write-Host "  ┌─ Manual OAuth Connection Setup ────────────────────────────────────┐" -ForegroundColor Yellow
                        Write-Host "  │  1. Azure Portal → Bot Services → $AzureBotName" -ForegroundColor Yellow
                        Write-Host "  │  2. Settings → Configuration → OAuth Connection Settings" -ForegroundColor Yellow
                        Write-Host "  │  3. Add Setting:" -ForegroundColor Yellow
                        Write-Host "  │     Name:             $($script:State.OAuthConnectionName)" -ForegroundColor Yellow
                        Write-Host "  │     Service Provider:  Azure Active Directory v2" -ForegroundColor Yellow
                        Write-Host "  │     Client ID:         $($script:State.BotAppId)" -ForegroundColor Yellow
                        Write-Host "  │     Client Secret:     (the secret from Step 1.5)" -ForegroundColor Yellow
                        Write-Host "  │     Tenant ID:         $GccTenantId" -ForegroundColor Yellow
                        Write-Host "  │     Scopes:            $oauthScope" -ForegroundColor Yellow
                        Write-Host "  └────────────────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
                        Write-Host ""
                        Prompt-Continue "Press Enter after completing OAuth setup (or skip and do later)" | Out-Null
                    }
                }
            }
        }
    }
    else {
        Write-WhatIf -Operation "Create OAuth connection '$($script:State.OAuthConnectionName)'" -Target $AzureBotName
        Write-Log "  Provider: Aad V2" -Level Detail
        Write-Log "  Client ID: $($script:State.BotAppId)" -Level Detail
        Write-Log "  Tenant ID: $GccTenantId" -Level Detail
        Write-Log "  Scopes: $oauthScope" -Level Detail
    }

    # ── Phase 2 Summary ──
    Write-Host ""
    Write-Host "  ┌─ Phase 2 Summary ─────────────────────────────────────────────────────┐" -ForegroundColor Green
    Write-Host "  │  Azure Bot:      $AzureBotName (in $ResourceGroupName)" -ForegroundColor Green
    Write-Host "  │  App Type:       SingleTenant (GCC tenant: $GccTenantId)" -ForegroundColor Green
    Write-Host "  │  App ID:         $($script:State.BotAppId)" -ForegroundColor Green
    Write-Host "  │  Endpoint:       $($script:State.MessagingEndpoint)" -ForegroundColor Green
    Write-Host "  │  OAuth Conn:     $($script:State.OAuthConnectionName) → $oauthScope" -ForegroundColor Green
    Write-Host "  └────────────────────────────────────────────────────────────────────────┘" -ForegroundColor Green
    Write-Host ""

    Prompt-Continue "Phase 2 complete. Continue to Phase 3 (Container App deployment)?" -Required | Out-Null
}
else {
    Write-Log "Phase 2 SKIPPED (included in -SkipPhase)." -Level Warn
}


# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 3: Commercial Tenant — Container App for Bot .NET Code
# ═══════════════════════════════════════════════════════════════════════════════
if (3 -notin $SkipPhase) {
    Write-Log "PHASE 3: Commercial Tenant — Container App for GCC Bot" -Level Phase
    Write-Log "PURPOSE: Build the .NET bot Docker image with GCC-specific configuration" -Level Info
    Write-Log "  and deploy it to a new Container App in the Commercial tenant." -Level Info
    Write-Log "  The Container App hosts the bot's /api/messages endpoint." -Level Info
    Write-Host ""

    # ── Ensure still logged into Commercial tenant ──
    if (-not (Prompt-TenantLogin -TenantId $CommercialTenantId -TenantLabel "Commercial")) {
        Write-Log "Cannot proceed without Commercial tenant login. Aborting Phase 3." -Level Error
        exit 1
    }

    # ────────────────────────────────────────────────────────────────────────
    # Step 3.1: Generate appsettings.gcc.json
    # ────────────────────────────────────────────────────────────────────────
    Write-Log "Step 3.1: Generate appsettings.gcc.json" -Level Header
    Write-Log "WHAT: Create a GCC-specific appsettings file for the .NET bot with:" -Level Info
    Write-Log "      - GCC tenant ID and bot app ID in ServiceConnection" -Level Info
    Write-Log "      - MCP server URL" -Level Info
    Write-Log "      - OAuth connection name 'mcp' pointing to the Azure Bot OAuth setting" -Level Info
    Write-Log "WHY:  The bot code uses this config to authenticate with Bot Framework and" -Level Info
    Write-Log "      to locate the MCP server. Different from the ETT config." -Level Info

    $appSettingsGcc = @{
        TokenValidation = @{
            Enabled   = $false
            Audiences = @($script:State.BotAppId)
            TenantId  = $GccTenantId
        }
        McpServerUrl = $script:State.McpServerUrl
        McpOboScope  = "api://$($script:State.ResourceAppId)/access_as_user"
        AgentApplication = @{
            StartTypingTimer       = $false
            RemoveRecipientMention = $false
            NormalizeMentions      = $false
            UserAuthorization = @{
                AutoSignIn = $true
                Handlers = @{
                    mcp = @{
                        Settings = @{
                            AzureBotOAuthConnectionName = $script:State.OAuthConnectionName
                        }
                    }
                }
            }
        }
        Connections = @{
            ServiceConnection = @{
                Settings = @{
                    AuthType     = "ClientSecret"
                    ClientId     = $script:State.BotAppId
                    TenantId     = $GccTenantId
                    ClientSecret = ""
                }
            }
        }
        ConnectionsMap = @(
            @{
                ServiceUrl = "*"
                Connection = "ServiceConnection"
            }
        )
        Logging = @{
            LogLevel = @{
                Default                = "Information"
                "Microsoft.Agents"     = "Debug"
                "Microsoft.AspNetCore" = "Warning"
            }
        }
    }

    $appSettingsGccJson = $appSettingsGcc | ConvertTo-Json -Depth 10
    $appSettingsGccPath = Join-Path $DotnetDir "appsettings.gcc.json"

    Write-Log "Generated appsettings.gcc.json:" -Level Detail
    Write-Log "  TokenValidation.Audiences: $($script:State.BotAppId)" -Level Detail
    Write-Log "  TokenValidation.TenantId:  $GccTenantId" -Level Detail
    Write-Log "  McpServerUrl:              $($script:State.McpServerUrl)" -Level Detail
    Write-Log "  McpOboScope:               api://$($script:State.ResourceAppId)/access_as_user" -Level Detail
    Write-Log "  Connections.ClientId:       $($script:State.BotAppId)" -Level Detail
    Write-Log "  Connections.TenantId:       $GccTenantId" -Level Detail
    Write-Log "  Output path:               $appSettingsGccPath" -Level Detail

    if ($PSCmdlet.ShouldProcess($appSettingsGccPath, "Create appsettings.gcc.json")) {
        if (Prompt-Continue "Write appsettings.gcc.json to $appSettingsGccPath?") {
            $appSettingsGccJson | Set-Content -Path $appSettingsGccPath -Encoding UTF8
            Write-Log "appsettings.gcc.json written." -Level Success
        }
    }
    else {
        Write-WhatIf -Operation "Write appsettings.gcc.json" -Target $appSettingsGccPath
    }

    # ────────────────────────────────────────────────────────────────────────
    # Step 3.2: Create Dockerfile.gcc (optional - uses env var override)
    # ────────────────────────────────────────────────────────────────────────
    Write-Log "Step 3.2: Prepare Docker build" -Level Header
    Write-Log "WHAT: The same Dockerfile is used. GCC config is injected via:" -Level Info
    Write-Log "      1. appsettings.gcc.json baked into the image" -Level Info
    Write-Log "      2. ASPNETCORE_ENVIRONMENT=gcc makes .NET pick up appsettings.gcc.json" -Level Info
    Write-Log "      3. Container App env vars override ClientSecret at runtime" -Level Info
    Write-Log "WHY:  Keeps one codebase, one Dockerfile. Only the config differs." -Level Info

    # ────────────────────────────────────────────────────────────────────────
    # Step 3.3: Build and push Docker image
    # ────────────────────────────────────────────────────────────────────────
    Write-Log "Step 3.3: Build and push Docker image to ACR" -Level Header
    Write-Log "WHAT: Build the .NET bot Docker image tagged for GCC and push to ACR." -Level Info
    Write-Log "      - ACR: $AcrName.azurecr.io" -Level Info
    Write-Log "      - Image: simplechat-agent-gcc:v1" -Level Info
    Write-Log "      - Build context: $DotnetDir" -Level Info
    Write-Log "WHY:  The Container App will pull this image from the ACR." -Level Info

    $imageTag = "simplechat-agent-gcc:v1"
    $fullImageName = "$AcrName.azurecr.io/$imageTag"

    if ($PSCmdlet.ShouldProcess($fullImageName, "Build Docker image via ACR")) {
        if (Prompt-Continue "Build and push '$imageTag' to $AcrName ACR? (This may take a few minutes)") {
            Write-Log "Running: az acr build --registry $AcrName --image $imageTag --no-logs $DotnetDir" -Level Detail
            Write-Log "  (Using --no-logs to avoid colorama/cp1252 encoding issues)" -Level Detail

            if (-not $WhatIfPreference) {
                az acr build `
                    --registry $AcrName `
                    --image $imageTag `
                    --no-logs `
                    $DotnetDir 2>&1

                if ($LASTEXITCODE -ne 0) {
                    Write-Log "ACR build failed. Check the build logs in the Azure Portal." -Level Error
                    Write-Log "  Portal → Container registries → $AcrName → Services → Builds" -Level Detail
                    Prompt-Continue "Continue despite build failure?" | Out-Null
                }
                else {
                    Write-Log "Docker image built and pushed: $fullImageName" -Level Success
                }
            }
        }
    }
    else {
        Write-WhatIf -Operation "Build Docker image" -Target $fullImageName
    }

    # ────────────────────────────────────────────────────────────────────────
    # Step 3.4: Create Container App
    # ────────────────────────────────────────────────────────────────────────
    Write-Log "Step 3.4: Create Container App" -Level Header
    Write-Log "WHAT: Create a new Container App named '$ContainerAppName' in the" -Level Info
    Write-Log "      Commercial tenant using the GCC-configured Docker image." -Level Info
    Write-Log "WHY:  This hosts the bot's /api/messages endpoint that Bot Framework" -Level Info
    Write-Log "      routes Teams messages to." -Level Info

    if (-not $WhatIfPreference) {
        # Detect / select the Container Apps Environment
        if (-not $ContainerAppEnvName) {
            Write-Log "Listing Container Apps Environments in resource group '$ResourceGroupName'..." -Level Detail
            $envList = az containerapp env list --resource-group $ResourceGroupName --query "[].{name:name, location:location, provisioningState:properties.provisioningState}" -o json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue

            if ($envList -and $envList.Count -gt 0) {
                Write-Host ""
                Write-Host "  Available Container Apps Environments:" -ForegroundColor Cyan
                for ($i = 0; $i -lt $envList.Count; $i++) {
                    $env = $envList[$i]
                    Write-Host "    [$($i + 1)] $($env.name)  ($($env.location), $($env.provisioningState))" -ForegroundColor White
                }
                Write-Host ""

                if ($envList.Count -eq 1) {
                    $choice = Read-Host "  Select environment (1) or enter a name manually [default: 1]"
                    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }
                }
                else {
                    $choice = Read-Host "  Select environment (1-$($envList.Count)) or enter a name manually"
                }

                $choiceInt = 0
                if ([int]::TryParse($choice, [ref]$choiceInt) -and $choiceInt -ge 1 -and $choiceInt -le $envList.Count) {
                    $ContainerAppEnvName = $envList[$choiceInt - 1].name
                }
                elseif (-not [string]::IsNullOrWhiteSpace($choice)) {
                    $ContainerAppEnvName = $choice  # User typed a name manually
                }
                else {
                    Write-Log "No environment selected." -Level Error
                    return
                }
                Write-Log "Selected environment: $ContainerAppEnvName" -Level Success
            }
            else {
                Write-Log "No Container Apps Environments found in resource group '$ResourceGroupName'." -Level Warn
                $ContainerAppEnvName = Read-Host "  Enter the Container Apps Environment name"
            }
        }
        Write-Log "Container Apps Environment: $ContainerAppEnvName" -Level Detail

        # Check if container app already exists
        $existingCa = az containerapp show --name $ContainerAppName --resource-group $ResourceGroupName --output json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue

        if ($existingCa) {
            Write-Log "Container App '$ContainerAppName' already exists." -Level Success
            Write-Log "  Current image: $($existingCa.properties.template.containers[0].image)" -Level Detail
            Write-Log "  FQDN: $($existingCa.properties.configuration.ingress.fqdn)" -Level Detail
            $script:State.ContainerAppFqdn = $existingCa.properties.configuration.ingress.fqdn

            if (Prompt-Continue "Update existing Container App with new image '$imageTag'?") {
                Write-Log "Running: az containerapp update ..." -Level Detail

                # Store client secret as a Container Apps secret, reference it in env vars
                az containerapp secret set `
                    --name $ContainerAppName `
                    --resource-group $ResourceGroupName `
                    --secrets "bot-client-secret=$($script:State.BotAppSecret)" `
                    --output none --only-show-errors 2>$null

                az containerapp update `
                    --name $ContainerAppName `
                    --resource-group $ResourceGroupName `
                    --image "$AcrName.azurecr.io/$imageTag" `
                    --set-env-vars "ASPNETCORE_ENVIRONMENT=gcc" "Connections__ServiceConnection__Settings__ClientSecret=secretref:bot-client-secret" `
                    --output json --only-show-errors | Out-Null

                if ($LASTEXITCODE -eq 0) {
                    Write-Log "Container App updated with new image." -Level Success
                }
                else {
                    Write-Log "Container App update failed." -Level Error
                }
            }
        }
        else {
            if ($PSCmdlet.ShouldProcess($ContainerAppName, "Create Container App in $ResourceGroupName")) {
                if (Prompt-Continue "Create new Container App '$ContainerAppName'?") {
                    # Get the full environment resource ID
                    $envId = az containerapp env show --name $ContainerAppEnvName --resource-group $ResourceGroupName --query id -o tsv 2>$null

                    Write-Log "Running: az containerapp create ..." -Level Detail

                    az containerapp create `
                        --name $ContainerAppName `
                        --resource-group $ResourceGroupName `
                        --environment $ContainerAppEnvName `
                        --image "$AcrName.azurecr.io/$imageTag" `
                        --registry-server "$AcrName.azurecr.io" `
                        --target-port 8080 `
                        --ingress external `
                        --min-replicas 0 `
                        --max-replicas 1 `
                        --env-vars "ASPNETCORE_ENVIRONMENT=gcc" `
                        --output json --only-show-errors | Out-Null

                    if ($LASTEXITCODE -ne 0) {
                        Write-Log "Failed to create Container App." -Level Error
                        Prompt-Continue "Continue despite Container App creation failure?" | Out-Null
                    }
                    else {
                        Write-Log "Container App '$ContainerAppName' created." -Level Success

                        # Set secret separately (az containerapp secret set)
                        Write-Log "Setting Container App secret 'bot-client-secret'..." -Level Detail
                        az containerapp secret set `
                            --name $ContainerAppName `
                            --resource-group $ResourceGroupName `
                            --secrets "bot-client-secret=$($script:State.BotAppSecret)" `
                            --output none --only-show-errors
                        if ($LASTEXITCODE -eq 0) {
                            Write-Log "Secret 'bot-client-secret' stored." -Level Success
                        } else {
                            Write-Log "Failed to set secret. You may need to set it manually." -Level Warn
                        }

                        # Now bind the secret to an env var
                        Write-Log "Binding secret to env var 'Connections__ServiceConnection__Settings__ClientSecret'..." -Level Detail
                        az containerapp update `
                            --name $ContainerAppName `
                            --resource-group $ResourceGroupName `
                            --set-env-vars "Connections__ServiceConnection__Settings__ClientSecret=secretref:bot-client-secret" `
                            --output none --only-show-errors
                        if ($LASTEXITCODE -eq 0) {
                            Write-Log "Secret bound to env var." -Level Success
                        } else {
                            Write-Log "Failed to bind secret to env var." -Level Warn
                        }

                        # Get FQDN
                        $caInfo = az containerapp show --name $ContainerAppName --resource-group $ResourceGroupName --query "properties.configuration.ingress.fqdn" -o tsv 2>$null
                        $script:State.ContainerAppFqdn = $caInfo
                        Write-Log "FQDN: $($script:State.ContainerAppFqdn)" -Level Success

                        # Update messaging endpoint if needed
                        $actualEndpoint = "https://$($script:State.ContainerAppFqdn)/api/messages"
                        if ($actualEndpoint -ne $script:State.MessagingEndpoint) {
                            Write-Log "Container App FQDN differs from expected. Updating Bot messaging endpoint..." -Level Warn
                            Write-Log "  Old: $($script:State.MessagingEndpoint)" -Level Detail
                            Write-Log "  New: $actualEndpoint" -Level Detail

                            if (Prompt-Continue "Update Azure Bot endpoint to '$actualEndpoint'?") {
                                az bot update `
                                    --resource-group $ResourceGroupName `
                                    --name $AzureBotName `
                                    --endpoint $actualEndpoint `
                                    --output json --only-show-errors | Out-Null
                                $script:State.MessagingEndpoint = $actualEndpoint
                                Write-Log "Bot endpoint updated." -Level Success
                            }
                        }
                    }
                }
            }
        }
    }
    else {
        Write-WhatIf -Operation "Create Container App" -Target "$ContainerAppName in $ResourceGroupName"
    }

    # ── Phase 3 Summary ──
    Write-Host ""
    Write-Host "  ┌─ Phase 3 Summary ─────────────────────────────────────────────────────┐" -ForegroundColor Green
    Write-Host "  │  Container App:  $ContainerAppName" -ForegroundColor Green
    Write-Host "  │  Image:          $fullImageName" -ForegroundColor Green
    Write-Host "  │  FQDN:           $($script:State.ContainerAppFqdn)" -ForegroundColor Green
    Write-Host "  │  Endpoint:       $($script:State.MessagingEndpoint)" -ForegroundColor Green
    Write-Host "  │  Environment:    gcc (ASPNETCORE_ENVIRONMENT=gcc)" -ForegroundColor Green
    Write-Host "  └────────────────────────────────────────────────────────────────────────┘" -ForegroundColor Green
    Write-Host ""

    Prompt-Continue "Phase 3 complete. Continue to Phase 4 (Teams manifest)?" -Required | Out-Null
}
else {
    Write-Log "Phase 3 SKIPPED (included in -SkipPhase)." -Level Warn
}


# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 4: GCC Tenant — Build Teams Manifest + App Package
# ═══════════════════════════════════════════════════════════════════════════════
if (4 -notin $SkipPhase) {
    Write-Log "PHASE 4: GCC Tenant — Build Teams Manifest and App Package" -Level Phase
    Write-Log "PURPOSE: Generate the Teams app manifest (Custom Engine Agent pattern)" -Level Info
    Write-Log "  with the GCC app registration IDs, and package it as a ZIP for" -Level Info
    Write-Log "  upload to the GCC Teams catalog." -Level Info
    Write-Host ""

    # Note: No tenant login needed for Phase 4 as it's local file operations.
    Write-Log "This phase is local file operations only (no Azure CLI calls)." -Level Info

    # ────────────────────────────────────────────────────────────────────────
    # Step 4.1: Generate manifest.json
    # ────────────────────────────────────────────────────────────────────────
    Write-Log "Step 4.1: Generate manifest.json" -Level Header
    Write-Log "WHAT: Create the Teams app manifest using the Custom Engine Agent pattern." -Level Info
    Write-Log "      Key fields:" -Level Info
    Write-Log "      - id = $($script:State.BotAppId) (GCC app registration)" -Level Info
    Write-Log "      - bots[0].botId = $($script:State.BotAppId)" -Level Info
    Write-Log "      - copilotAgents.customEngineAgents[0].id = $($script:State.BotAppId)" -Level Info
    Write-Log "      - webApplicationInfo.id = $($script:State.BotAppId)" -Level Info
    Write-Log "      - webApplicationInfo.resource = api://botid-$($script:State.BotAppId)" -Level Info
    Write-Log "      - name.short = 'SimpleChat Agent (GCC)'" -Level Info
    Write-Log "WHY:  This manifest tells Teams how to display the bot and how to route" -Level Info
    Write-Log "      messages. The customEngineAgents section makes it appear in Copilot." -Level Info

    $mcpDomain = ""
    if ($script:State.McpServerUrl -and $script:State.McpServerUrl -ne "<will-be-provided>") {
        try { $mcpDomain = ([System.Uri]$script:State.McpServerUrl).Host } catch { }
    }

    $containerAppDomain = $script:State.ContainerAppFqdn
    if (-not $containerAppDomain) {
        $containerAppDomain = "$ContainerAppName.<your-environment>.<region>.azurecontainerapps.io"
    }

    $validDomains = @($containerAppDomain)
    if ($mcpDomain -and $mcpDomain -ne $containerAppDomain) {
        $validDomains += $mcpDomain
    }

    $manifest = @{
        '$schema'       = "https://developer.microsoft.com/en-us/json-schemas/teams/v1.21/MicrosoftTeams.schema.json"
        manifestVersion = "1.21"
        version         = "1.0.0"
        id              = $script:State.BotAppId
        developer       = @{
            name           = "SimpleChat"
            websiteUrl     = "https://www.example.com"
            privacyUrl     = "https://www.example.com/privacy"
            termsOfUseUrl  = "https://www.example.com/termofuse"
        }
        icons = @{
            color   = "color.png"
            outline = "outline.png"
        }
        name = @{
            short = "SimpleChat Agent (GCC)"
            full  = "SimpleChat Agent (GCC) - M365 Agents SDK"
        }
        description = @{
            short = "A bot agent that forwards messages to SimpleChat (GCC)"
            full  = "SimpleChat Agent (GCC) built with the Microsoft 365 Agents SDK for cross-tenant deployment. Send messages to interact with the SimpleChat backend. Use /status to check connectivity and /help for available commands."
        }
        accentColor = "#4F6BED"
        bots = @(
            @{
                botId            = $script:State.BotAppId
                scopes           = @("personal", "team", "groupChat")
                supportsFiles    = $false
                isNotificationOnly = $false
                commandLists     = @(
                    @{
                        scopes   = @("personal")
                        commands = @(
                            @{ title = "status"; description = "Check agent and SimpleChat connectivity status" }
                            @{ title = "help"; description = "Show available commands" }
                        )
                    }
                )
            }
        )
        copilotAgents = @{
            customEngineAgents = @(
                @{
                    type = "bot"
                    id   = $script:State.BotAppId
                }
            )
        }
        permissions  = @("identity", "messageTeamMembers")
        validDomains = $validDomains
        webApplicationInfo = @{
            id       = $script:State.BotAppId
            resource = "api://botid-$($script:State.BotAppId)"
        }
    }

    $manifestJson = $manifest | ConvertTo-Json -Depth 10

    Write-Log "Generated manifest.json:" -Level Detail
    Write-Log "  id: $($script:State.BotAppId)" -Level Detail
    Write-Log "  name.short: SimpleChat Agent (GCC)" -Level Detail
    Write-Log "  validDomains: $($validDomains -join ', ')" -Level Detail
    Write-Log "  webApplicationInfo.resource: api://botid-$($script:State.BotAppId)" -Level Detail

    # ────────────────────────────────────────────────────────────────────────
    # Step 4.2: Build app package ZIP
    # ────────────────────────────────────────────────────────────────────────
    Write-Log "Step 4.2: Build app package ZIP" -Level Header
    Write-Log "WHAT: Create a ZIP file containing manifest.json + icon files for upload" -Level Info
    Write-Log "      to the GCC Teams App Catalog." -Level Info
    Write-Log "WHY:  Teams requires a ZIP package to register a new app." -Level Info

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    $buildTemp = Join-Path $OutputDir "temp_gcc_cea_build"
    $zipName = "appPackage.gcc-cea.zip"

    if ($PSCmdlet.ShouldProcess((Join-Path $OutputDir $zipName), "Build app package ZIP")) {
        if (Prompt-Continue "Build app package ZIP?") {
            # Create temp build dir
            if (Test-Path $buildTemp) { Remove-Item -Recurse -Force $buildTemp }
            New-Item -ItemType Directory -Path $buildTemp -Force | Out-Null

            # Write manifest
            $manifestJson | Set-Content (Join-Path $buildTemp "manifest.json") -Encoding UTF8
            Write-Log "  manifest.json written" -Level Detail

            # Copy icons from appPackage dir
            $colorIcon = Join-Path $AppPackageDir "color.png"
            $outlineIcon = Join-Path $AppPackageDir "outline.png"

            if (Test-Path $colorIcon) {
                Copy-Item $colorIcon (Join-Path $buildTemp "color.png") -Force
                Write-Log "  color.png copied" -Level Detail
            }
            else {
                Write-Log "  color.png not found in $AppPackageDir — you'll need to add it" -Level Warn
            }

            if (Test-Path $outlineIcon) {
                Copy-Item $outlineIcon (Join-Path $buildTemp "outline.png") -Force
                Write-Log "  outline.png copied" -Level Detail
            }
            else {
                Write-Log "  outline.png not found in $AppPackageDir — you'll need to add it" -Level Warn
            }

            # Create ZIP
            $zipPath = Join-Path $OutputDir $zipName
            if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::CreateFromDirectory($buildTemp, $zipPath)

            Write-Log "App package created: $zipPath" -Level Success
            Write-Log "  Size: $([math]::Round((Get-Item $zipPath).Length / 1KB, 1)) KB" -Level Detail

            # List contents
            $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
            foreach ($entry in $zip.Entries) {
                Write-Log "  → $($entry.FullName) ($([math]::Round($entry.Length / 1KB, 1)) KB)" -Level Detail
            }
            $zip.Dispose()

            # Clean up temp
            Remove-Item -Recurse -Force $buildTemp

            # Also save the manifest.json standalone for reference
            $manifestStandalone = Join-Path $OutputDir "manifest.gcc-cea.json"
            $manifestJson | Set-Content $manifestStandalone -Encoding UTF8
            Write-Log "Standalone manifest also saved: $manifestStandalone" -Level Detail
        }
    }
    else {
        Write-WhatIf -Operation "Build app package ZIP" -Target (Join-Path $OutputDir $zipName)
    }

    # ── Phase 4 Summary ──
    Write-Host ""
    Write-Host "  ┌─ Phase 4 Summary ─────────────────────────────────────────────────────┐" -ForegroundColor Green
    Write-Host "  │  Manifest:       manifest.json (Custom Engine Agent pattern)" -ForegroundColor Green
    Write-Host "  │  Agent Name:     SimpleChat Agent (GCC)" -ForegroundColor Green
    Write-Host "  │  App Package:    $OutputDir\$zipName" -ForegroundColor Green
    Write-Host "  └────────────────────────────────────────────────────────────────────────┘" -ForegroundColor Green
    Write-Host ""

    Prompt-Continue "Phase 4 complete. Continue to Phase 5 (summary + upload instructions)?" -Required | Out-Null
}
else {
    Write-Log "Phase 4 SKIPPED (included in -SkipPhase)." -Level Warn
}


# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 5: Summary + Upload Instructions
# ═══════════════════════════════════════════════════════════════════════════════
Write-Log "PHASE 5: Summary and Next Steps" -Level Phase

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Host "  CROSS-TENANT SETUP SUMMARY" -ForegroundColor Green
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Host ""
Write-Host "  GCC Tenant (M365/Auth):" -ForegroundColor Cyan
Write-Host "    Tenant ID:         $GccTenantId" -ForegroundColor White
Write-Host "    Bot App ID:        $($script:State.BotAppId)" -ForegroundColor White
Write-Host "    Resource App ID:   $($script:State.ResourceAppId)" -ForegroundColor White
Write-Host "    Identifier URI:    api://botid-$($script:State.BotAppId)" -ForegroundColor White
Write-Host ""
Write-Host "  Commercial Tenant (Azure Compute):" -ForegroundColor Cyan
Write-Host "    Tenant ID:         $CommercialTenantId" -ForegroundColor White
Write-Host "    Azure Bot:         $AzureBotName" -ForegroundColor White
Write-Host "    Container App:     $ContainerAppName" -ForegroundColor White
Write-Host "    FQDN:              $($script:State.ContainerAppFqdn)" -ForegroundColor White
Write-Host "    Endpoint:          $($script:State.MessagingEndpoint)" -ForegroundColor White
Write-Host "    ACR Image:         $AcrName.azurecr.io/simplechat-agent-gcc:v1" -ForegroundColor White
Write-Host ""
Write-Host "  OAuth Connection:" -ForegroundColor Cyan
Write-Host "    Connection Name:   $($script:State.OAuthConnectionName)" -ForegroundColor White
Write-Host "    Scope:             api://$($script:State.ResourceAppId)/access_as_user" -ForegroundColor White
Write-Host ""

Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
Write-Host "  NEXT STEPS" -ForegroundColor Yellow
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. UPLOAD MANIFEST to GCC Teams App Catalog:" -ForegroundColor White
Write-Host "     • Option A: Teams Admin Center → Manage Apps → Upload new app" -ForegroundColor Gray
Write-Host "       Upload: $OutputDir\appPackage.gcc-cea.zip" -ForegroundColor Gray
Write-Host "     • Option B: Developer Portal in Teams → Apps → Import app" -ForegroundColor Gray
Write-Host ""
Write-Host "  2. VERIFY OAUTH CONNECTION on the Azure Bot:" -ForegroundColor White
Write-Host "     Azure Portal → Bot Services → $AzureBotName → Configuration" -ForegroundColor Gray
Write-Host "     → OAuth Connection Settings → '$($script:State.OAuthConnectionName)'" -ForegroundColor Gray
Write-Host "     Click 'Test Connection' to confirm it can acquire a token." -ForegroundColor Gray
Write-Host ""
Write-Host "  3. TEST THE BOT:" -ForegroundColor White
Write-Host "     Open Teams in the GCC tenant and search for 'SimpleChat Agent (GCC)'." -ForegroundColor Gray
Write-Host "     Send a message — the bot should prompt for sign-in, then respond." -ForegroundColor Gray
Write-Host ""
Write-Host "  4. CHECK LOGS if issues arise:" -ForegroundColor White
Write-Host "     az containerapp logs show --name $ContainerAppName --resource-group $ResourceGroupName --follow" -ForegroundColor Gray
Write-Host ""

Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan
Write-Host "  IMPORTANT CROSS-TENANT NOTES" -ForegroundColor DarkCyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  • The GCC app registration MUST be multi-tenant (signInAudience = AzureADMultipleOrgs)" -ForegroundColor Gray
Write-Host "    so the Commercial-tenant Azure Bot can use it." -ForegroundColor Gray
Write-Host ""
Write-Host "  • The Azure Bot uses AppType = SingleTenant with TenantId = GCC tenant." -ForegroundColor Gray
Write-Host "    This tells Bot Framework to validate tokens from the GCC tenant." -ForegroundColor Gray
Write-Host ""
Write-Host "  • The .NET bot's appsettings.gcc.json ServiceConnection uses the GCC" -ForegroundColor Gray
Write-Host "    tenant ID and app ID so it authenticates as the GCC bot identity." -ForegroundColor Gray
Write-Host ""
Write-Host "  • If the MCP resource app is also in GCC, the OAuth connection scope" -ForegroundColor Gray
Write-Host "    (api://{ResourceAppId}/access_as_user) will be consented in GCC." -ForegroundColor Gray
Write-Host ""

# Write env file for reference
$envGccFile = Join-Path $EnvDir ".env.gcc.user"
$envGccContent = @"
# ============================================================
# env/.env.gcc.user — Cross-Tenant GCC Agent (gitignored)
# ============================================================
# Generated by Setup-CrossTenantAgent.ps1 on $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
# ============================================================

# GCC Tenant
GCC_TENANT_ID=$GccTenantId

# Commercial Tenant (Azure compute)
COMMERCIAL_TENANT_ID=$CommercialTenantId

# Bot app registration (lives in GCC tenant)
BOT_APP_ID=$($script:State.BotAppId)
BOT_APP_SECRET=$($script:State.BotAppSecret)

# MCP resource app (defines access_as_user scope)
RESOURCE_APP_ID=$($script:State.ResourceAppId)

# MCP server URL (runs in Commercial tenant)
MCP_SERVER_URL=$($script:State.McpServerUrl)

# Azure Bot (Commercial tenant)
AZURE_BOT_NAME=$AzureBotName
RESOURCE_GROUP=$ResourceGroupName

# Container App (Commercial tenant)  
CONTAINER_APP_NAME=$ContainerAppName
CONTAINER_APP_FQDN=$($script:State.ContainerAppFqdn)
MESSAGING_ENDPOINT=$($script:State.MessagingEndpoint)

# ACR
ACR_NAME=$AcrName
IMAGE_TAG=simplechat-agent-gcc:v1
"@

if ($PSCmdlet.ShouldProcess($envGccFile, "Write GCC environment reference file")) {
    $envGccContent | Set-Content $envGccFile -Encoding UTF8
    Write-Log "Environment reference file written: $envGccFile" -Level Success
}

Write-Log "Full log available at: $LogFile" -Level Info
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Magenta
Write-Host "  Done." -ForegroundColor Magenta
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Magenta
Write-Host ""

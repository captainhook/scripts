param(
    [string]$AllOutputFile = "flex_migration_all.json",
    [string]$SummaryOutputFile = "flex_migration_summary.json",
    [switch]$SkipExtensionInstall
)

$ErrorActionPreference = "Stop"

function Write-Info($m) { Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Err($m)  { Write-Host "[ERR ] $m" -ForegroundColor Red }

# Helper: Extract JSON from az CLI output that may include leading informational lines
function Extract-Json {
    param([Parameter(Mandatory=$true)] [object]$Raw)
    if (-not $Raw) { return $null }
    $lines = @()
    if ($Raw -is [string]) {
        # Split single string into lines
        $lines = $Raw -split "`r?`n"
    } else {
        # Already an array of lines/strings
        $lines = $Raw
    }
    # Manually locate the first line that begins JSON (object or array) for PS 5.1 compatibility
    $startIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*(\{|\[)') { $startIndex = $i; break }
    }
    if ($startIndex -lt 0) { return $null }
    $jsonLines = $lines[$startIndex..($lines.Count-1)]
    return ($jsonLines -join "`n")
}

# 1. Capture original subscription (ignore failure if none yet)
$originalSub = ""
try {
    $originalSub = az account show --query id -o tsv 2>$null
} catch {}

# 2. Pre-req extensions
if (-not $SkipExtensionInstall) {
    Write-Info "Ensuring 'functionapp' and 'resource-graph' extensions are installed (or up to date)..."
    az extension add --name functionapp --only-show-errors 2>$null || az extension update --name functionapp --only-show-errors 2>$null
    az extension add --name resource-graph --only-show-errors 2>$null || az extension update --name resource-graph --only-show-errors 2>$null
}

# 3. Get subscriptions
Write-Info "Retrieving enabled subscriptions..."
$subsJson = az account list --query "[?state=='Enabled'].{id:id,name:name}" -o json
$subs = $subsJson | ConvertFrom-Json
if (-not $subs -or $subs.Count -eq 0) {
    Write-Warn "No enabled subscriptions found."
    exit 0
}

$results = New-Object System.Collections.Generic.List[Object]

# 4. Iterate
${subTotal} = $subs.Count
$subIndex = 0
foreach ($s in $subs) {
    $subIndex++
    Write-Info "Processing subscription ($subIndex/$subTotal): $($s.name) ($($s.id))"
    try {
        az account set --subscription $s.id | Out-Null
    } catch {
        Write-Warn "Failed to set subscription $($s.id). Skipping."
        continue
    }

    $raw = $null
    try {
        # This command prints an informational line followed by JSON. We need only the JSON.
        $raw = az functionapp flex-migration list --only-show-errors -o json 2>$null
    } catch {
        Write-Warn "Command failed in subscription $($s.id): $($_.Exception.Message)"
        continue
    }

    if (-not $raw) {
        Write-Info "No items returned (empty output)."
        continue
    }
    $jsonText = Extract-Json -Raw $raw
    if (-not $jsonText) {
        Write-Warn "Could not isolate JSON for subscription $($s.id). Skipping."
        continue
    }
    $parsed = $null
    try {
        $parsed = $jsonText | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warn "Failed to parse JSON for subscription $($s.id): $($_.Exception.Message)"
        continue
    }

    # Expect properties: eligible_apps (array), ineligible_apps (array)
    $eligible = @()
    $ineligible = @()
    if ($parsed.PSObject.Properties.Name -contains 'eligible_apps' -and $parsed.eligible_apps) {
        $eligible = $parsed.eligible_apps
    }
    if ($parsed.PSObject.Properties.Name -contains 'ineligible_apps' -and $parsed.ineligible_apps) {
        $ineligible = $parsed.ineligible_apps
    }

    foreach ($app in $eligible) {
        $results.Add([PSCustomObject]@{
            subscriptionId   = $s.id
            subscriptionName = $s.name
            functionAppName  = $app.name
            resourceGroup    = $app.resource_group
            eligibility      = 'Eligible'
            reason           = $null
        }) | Out-Null
    }
    foreach ($app in $ineligible) {
        $results.Add([PSCustomObject]@{
            subscriptionId   = $s.id
            subscriptionName = $s.name
            functionAppName  = $app.name
            resourceGroup    = $app.resource_group
            eligibility      = 'Ineligible'
            reason           = $app.reason
        }) | Out-Null
    }

    $countAdded = ($eligible.Count + $ineligible.Count)
    Write-Info "  Added $countAdded app record(s) (Eligible: $($eligible.Count); Ineligible: $($ineligible.Count))"
}

# 5. Output full JSON
Write-Info "Writing full aggregated JSON to $AllOutputFile"
($results | ConvertTo-Json -Depth 100) | Out-File $AllOutputFile -Encoding UTF8

# 6. Summary
if ($results.Count -gt 0) {
    Write-Info "Building summary..."
    $summary = $results |
        Group-Object subscriptionId |
        ForEach-Object {
            $eligibleCount   = ($_.Group | Where-Object { $_.eligibility -eq 'Eligible' }).Count
            $ineligibleCount = ($_.Group | Where-Object { $_.eligibility -eq 'Ineligible' }).Count
            [PSCustomObject]@{
                subscriptionId    = $_.Name
                subscriptionName  = $_.Group[0].subscriptionName
                totalApps         = $_.Count
                eligibleApps      = $eligibleCount
                ineligibleApps    = $ineligibleCount
            }
        } | Sort-Object totalApps -Descending

    Write-Info "Writing summary JSON to $SummaryOutputFile"
    ($summary | ConvertTo-Json -Depth 5) | Out-File $SummaryOutputFile -Encoding UTF8

    Write-Host ""
    Write-Info "Summary table:"
    $summary | Format-Table -AutoSize

    Write-Host ""
    Write-Info "Totals:"
    Write-Host ("  Subscriptions with apps  : {0}" -f $summary.Count)
    Write-Host ("  Total apps               : {0}" -f ($results.Count))
    Write-Host ("  Total eligible           : {0}" -f (($results | Where-Object { $_.eligibility -eq 'Eligible' }).Count))
    Write-Host ("  Total ineligible         : {0}" -f (($results | Where-Object { $_.eligibility -eq 'Ineligible' }).Count))
} else {
    Write-Warn "No Function Apps found across the inspected subscriptions."
}

# 7. Restore original subscription
if ($originalSub) {
    Write-Info "Restoring original subscription context..."
    az account set --subscription $originalSub 2>$null | Out-Null
}

Write-Info "Done."
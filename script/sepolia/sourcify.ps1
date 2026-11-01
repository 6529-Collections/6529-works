<#
.SYNOPSIS
    Verifies every contract of a Sepolia deployment record on Sourcify (no API key) and writes
    the results as JSON.

.DESCRIPTION
    Runs `forge verify-contract --verifier sourcify` for each contract in the record, with its
    creation transaction from forge's broadcast cache (broadcast/Deploy.s.sol/11155111/
    run-latest.json, not committed), then reads Sourcify's v2 status for the address. The
    manager is created inside the configurator's constructor, so its creation transaction is
    the configurator's. Run it from the commit the record was deployed from, after
    `forge build`. Nothing is signed.

    -StatusOnly re-reads every contract's status without submitting anything.

.EXAMPLE
    ./sourcify.ps1 -Record deployments/11155111/<timestamp>.json -Out sourcify.json
    ./sourcify.ps1 -Record deployments/11155111/<timestamp>.json -Out sourcify.json -Only Stream,Editions
    ./sourcify.ps1 -Record deployments/11155111/<timestamp>.json -Out sourcify.json -StatusOnly
#>
param(
    [Parameter(Mandatory)] [string] $Record,
    [Parameter(Mandatory)] [string] $Out,
    [string[]] $Only = @(),
    [switch] $StatusOnly,
    [string] $Run = 'broadcast/Deploy.s.sol/11155111/run-latest.json'
)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $Repo
$Out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out)
$rec = Get-Content -Raw -Encoding UTF8 (Join-Path $Repo $Record) | ConvertFrom-Json
$run = Get-Content -Raw -Encoding UTF8 (Join-Path $Repo $Run) | ConvertFrom-Json
$paths = [ordered]@{
    WorksAccessManager        = 'src/governance/WorksAccessManager.sol:WorksAccessManager'
    GovernanceConfigurator    = 'src/governance/GovernanceConfigurator.sol:GovernanceConfigurator'
    ContentStore              = 'src/content/ContentStore.sol:ContentStore'
    DependencyRegistry        = 'src/content/DependencyRegistry.sol:DependencyRegistry'
    ConsolidationAdapter      = 'src/identity/ConsolidationAdapter.sol:ConsolidationAdapter'
    ArtistRegistry            = 'src/identity/ArtistRegistry.sol:ArtistRegistry'
    ReleaseVerifier           = 'src/economics/ReleaseVerifier.sol:ReleaseVerifier'
    SplitFactory              = 'src/economics/SplitFactory.sol:SplitFactory'
    ClaimRouter               = 'src/economics/ClaimRouter.sol:ClaimRouter'
    AssetAllowlist            = 'src/economics/AssetAllowlist.sol:AssetAllowlist'
    EconomicsResolver         = 'src/economics/EconomicsResolver.sol:EconomicsResolver'
    RevenueEscrow             = 'src/economics/RevenueEscrow.sol:RevenueEscrow'
    CurationVerifier          = 'src/curation/Eip712CurationVerifier.sol:Eip712CurationVerifier'
    PackageRegistry           = 'src/curation/PackageRegistry.sol:PackageRegistry'
    StatementLog              = 'src/records/StatementLog.sol:StatementLog'
    EntropyModule             = 'src/entropy/VrfEntropyModule.sol:VrfEntropyModule'
    Renderer                  = 'src/content/Renderer.sol:Renderer'
    Stream                    = 'src/stream/Stream.sol:Stream'
    WorkRecords               = 'src/stream/WorkRecords.sol:WorkRecords'
    Editions                  = 'src/editions/Editions.sol:Editions'
    EnglishAuctionLens        = 'src/sales/EnglishAuctionLens.sol:EnglishAuctionLens'
    EnglishAuction            = 'src/sales/EnglishAuction.sol:EnglishAuction'
    UniformEditionAuctionLens = 'src/sales/UniformEditionAuctionLens.sol:UniformEditionAuctionLens'
    UniformEditionAuction     = 'src/sales/UniformEditionAuction.sol:UniformEditionAuction'
}
$names = @($rec.contracts.PSObject.Properties.Name)
$unmapped = @($names | Where-Object { -not $paths.Contains($_) })
if ($unmapped.Count) { throw "unmapped contract in the record: $($unmapped -join ', ')" }
$creation = @{}
foreach ($t in $run.transactions) {
    if ($t.transactionType -eq 'CREATE2' -and $t.contractAddress) { $creation[$t.contractAddress.ToLower()] = $t.hash }
}
$results = [ordered]@{}
if ((Test-Path $Out) -and ($Only.Count -or $StatusOnly)) {
    (Get-Content -Raw $Out | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $results[$_.Name] = $_.Value }
}
foreach ($name in $paths.Keys) {
    if (-not ($names -contains $name)) { continue }
    if ($Only.Count -and $Only -notcontains $name) { continue }
    $addr = $rec.contracts.$name.address
    $tx = if ($name -eq 'WorksAccessManager') { $creation[$rec.contracts.GovernanceConfigurator.address.ToLower()] } else { $creation[$addr.ToLower()] }
    $text = ''
    if ($StatusOnly) {
        if ($results.Contains($name)) { $text = $results[$name].forge }
    }
    else {
        $a = @('verify-contract', '--verifier', 'sourcify', '--chain', '11155111', $addr, $paths[$name], '--watch')
        if ($tx) { $a += @('--creation-transaction-hash', $tx) }
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $text = (& forge @a 2>&1 | ForEach-Object { "$_" }) -join "`n"
        $ErrorActionPreference = $previous
        Start-Sleep -Seconds 2
    }
    # The bare contract URL is cached by Sourcify's CDN for an hour, so a read right after the
    # submission can keep showing the job's first state; a `fields` query is a separate entry.
    $status = curl.exe -s "https://sourcify.dev/server/v2/contract/11155111/$($addr)?fields=creationMatch,runtimeMatch,verifiedAt" | ConvertFrom-Json
    $results[$name] = [ordered]@{
        address = $addr; path = $paths[$name]; creationTx = $tx
        match = $status.match; runtimeMatch = $status.runtimeMatch; creationMatch = $status.creationMatch
        forge = (($text -split "`n") | Select-Object -Last 2) -join ' | '
    }
    Write-Host ("{0,-26} {1} match={2} runtime={3} creation={4}" -f $name, $addr, $status.match, $status.runtimeMatch, $status.creationMatch)
}
[IO.File]::WriteAllText($Out, ($results | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))

<#
.SYNOPSIS
    Verifies every contract of a Sepolia deployment record on Sourcify (no API key) and writes
    the results as JSON.

.DESCRIPTION
    Runs `forge verify-contract --verifier sourcify` for each contract in a record written by
    script/DeployCore.s.sol (one `<name>: <address>` object; round r6 on), with its creation
    transaction from forge's broadcast cache (broadcast/DeployCore.s.sol/11155111/
    run-latest.json, not committed), then reads Sourcify's v2 status for the address. Every
    contract is created inside a transaction to the deployer's CoreFactory, and the manager
    inside the configurator's constructor: the creation transaction of each is the transaction
    whose created contracts (`additionalContracts`) include it. The manager's address is read
    from the configurator (`worksManager()`). Run it from the commit the record was deployed
    from, after `forge build`. Nothing is signed.

    -StatusOnly re-reads every contract's status without submitting anything.

.EXAMPLE
    ./sourcify.ps1 -Record deployments/11155111/core-<timestamp>.json -Out sourcify.json
    ./sourcify.ps1 -Record deployments/11155111/core-<timestamp>.json -Out sourcify.json -Only Stream6529,StreamEditions6529
    ./sourcify.ps1 -Record deployments/11155111/core-<timestamp>.json -Out sourcify.json -StatusOnly
#>
param(
    [Parameter(Mandatory)] [string] $Record,
    [Parameter(Mandatory)] [string] $Out,
    [string[]] $Only = @(),
    [switch] $StatusOnly,
    [string] $Run = 'broadcast/DeployCore.s.sol/11155111/run-latest.json',
    [string] $Rpc = 'https://ethereum-sepolia-rpc.publicnode.com'
)
$ErrorActionPreference = 'Stop'
# `powershell -File` passes `-Only A,B` as one string.
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $Repo
$Out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out)
$rec = Get-Content -Raw -Encoding UTF8 (Join-Path $Repo $Record) | ConvertFrom-Json
$addresses = [ordered]@{}
# The record also names the deployer, the delegation contract and the fork block (not contracts
# of the deployment).
foreach ($p in $rec.PSObject.Properties) {
    if (@('deployer', 'delegation', 'forkBlock') -notcontains $p.Name) { $addresses[$p.Name] = $p.Value }
}
$addresses['WorksAccessManager'] = (& cast call $addresses['GovernanceConfigurator'] 'worksManager()(address)' --rpc-url $Rpc).Trim()
if ($LASTEXITCODE -ne 0) { throw 'could not read the manager from the configurator' }
$paths = [ordered]@{
    CoreFactory                 = 'script/CoreFactory.sol:CoreFactory'
    WorksAccessManager                = 'src/governance/WorksAccessManager.sol:WorksAccessManager'
    GovernanceConfigurator            = 'src/governance/GovernanceConfigurator.sol:GovernanceConfigurator'
    ContentStore                      = 'src/content/ContentStore.sol:ContentStore'
    StreamWorkFacts6529               = 'src/core/StreamWorkFacts6529.sol:StreamWorkFacts6529'
    StreamDirectory6529               = 'src/core/StreamDirectory6529.sol:StreamDirectory6529'
    FeeRecipientVault                 = 'src/economics/GovernedVault.sol:GovernedVault'
    MuseumVault                       = 'src/economics/GovernedVault.sol:GovernedVault'
    SplitFactory                      = 'src/economics/SplitLedger.sol:SplitLedger'
    ClaimRouter                       = 'src/economics/ClaimRouter.sol:ClaimRouter'
    RevenueEscrow                     = 'src/economics/RevenueEscrow.sol:RevenueEscrow'
    Stream6529                        = 'src/core/Stream6529.sol:Stream6529'
    StreamEditions6529                = 'src/core/StreamEditions6529.sol:StreamEditions6529'
    ConsolidationAdapter              = 'src/identity/ConsolidationAdapter.sol:ConsolidationAdapter'
    Accounts                          = 'src/identity/Accounts.sol:Accounts'
    AssetAllowlist                    = 'src/economics/AssetAllowlist.sol:AssetAllowlist'
    EconomicsResolver                 = 'src/economics/EconomicsResolver.sol:EconomicsResolver'
    CurationVerifier                  = 'src/curation/Eip712CurationVerifier.sol:Eip712CurationVerifier'
    PackageRegistry                   = 'src/curation/PackageRegistry.sol:PackageRegistry'
    EntropyModule                     = 'src/entropy/VrfEntropyModule.sol:VrfEntropyModule'
    StatementLog                      = 'src/records/StatementLog.sol:StatementLog'
    DependencyRegistry                = 'src/content/DependencyRegistry.sol:DependencyRegistry'
    Renderer                          = 'src/content/Renderer.sol:Renderer'
    WorkRules                         = 'src/records/WorkRules.sol:WorkRules'
    WorkDelivery                      = 'src/stream/WorkDelivery.sol:WorkDelivery'
    StreamTerms                       = 'src/terms/StreamTerms.sol:StreamTerms'
    EnglishAuction                    = 'src/sales/EnglishAuction.sol:EnglishAuction'
    UniformEditionAuctionLens         = 'src/sales/UniformEditionAuctionLens.sol:UniformEditionAuctionLens'
    UniformEditionAuction             = 'src/sales/UniformEditionAuction.sol:UniformEditionAuction'
    IndependentStreamRegistry         = 'src/independent/IndependentStreamRegistry.sol:IndependentStreamRegistry'
    IndependentStream721Deployer      = 'src/independent/IndependentStreamDeployer.sol:IndependentStreamDeployer'
    IndependentStreamEditionsDeployer = 'src/independent/IndependentStreamDeployer.sol:IndependentStreamDeployer'
    IndependentEditionAuctionLens     = 'src/independent/IndependentEditionAuctionLens.sol:IndependentEditionAuctionLens'
    IndependentEditionAuction         = 'src/independent/IndependentEditionAuction.sol:IndependentEditionAuction'
    SaleStarter                       = 'src/sales/SaleStarter.sol:SaleStarter'
}
$unmapped = @($addresses.Keys | Where-Object { -not $paths.Contains($_) })
if ($unmapped.Count) { throw "unmapped contract in the record: $($unmapped -join ', ')" }
# The creation transactions, from forge's broadcast cache: needed to submit, not to read status.
$creation = @{}
if (-not $StatusOnly) {
    $run = Get-Content -Raw -Encoding UTF8 (Join-Path $Repo $Run) | ConvertFrom-Json
    foreach ($t in $run.transactions) {
        # On a CALL forge records the destination as contractAddress: only a creation counts.
        if ($t.contractAddress -and $t.transactionType -like 'CREATE*') {
            $creation[$t.contractAddress.ToLower()] = $t.hash
        }
        foreach ($c in @($t.additionalContracts)) {
            if ($c -and $c.address) { $creation[$c.address.ToLower()] = $t.hash }
        }
    }
}
# Earlier results are kept only for this record's addresses.
$results = [ordered]@{}
if ((Test-Path $Out) -and ($Only.Count -or $StatusOnly)) {
    (Get-Content -Raw $Out | ConvertFrom-Json).PSObject.Properties | ForEach-Object {
        $current = $addresses[$_.Name]
        if ($current -and $_.Value.address -and $current.ToLower() -eq $_.Value.address.ToLower()) {
            $results[$_.Name] = $_.Value
        }
    }
}
foreach ($name in $paths.Keys) {
    if (-not $addresses.Contains($name)) { continue }
    if ($Only.Count -and $Only -notcontains $name) { continue }
    $addr = $addresses[$name]
    $tx = $creation[$addr.ToLower()]
    $text = ''
    if ($StatusOnly) {
        if ($results.Contains($name)) { $text = $results[$name].forge; $tx = $results[$name].creationTx }
    }
    else {
        if (-not $tx) { throw "$name ($addr): no creation transaction in $Run" }
        $a = @('verify-contract', '--verifier', 'sourcify', '--chain', '11155111', $addr, $paths[$name], '--watch',
            '--creation-transaction-hash', $tx)
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $text = (& forge @a 2>&1 | ForEach-Object { "$_" }) -join "`n"
        $forgeCode = $LASTEXITCODE
        $ErrorActionPreference = $previous
        if ($forgeCode -ne 0) { $text = "forge verify-contract exited $forgeCode`n$text" }
        Start-Sleep -Seconds 2
    }
    # The bare contract URL is cached by Sourcify's CDN for an hour, so a read right after the
    # submission can keep showing the job's first state; a `fields` query is a separate entry.
    $status = $null
    try {
        $status = Invoke-RestMethod -Uri "https://sourcify.dev/server/v2/contract/11155111/$($addr)?fields=creationMatch,runtimeMatch,verifiedAt"
    }
    catch { $text = "status read failed: $_`n$text" }
    $results[$name] = [ordered]@{
        address = $addr; path = $paths[$name]; creationTx = $tx
        match = $status.match; runtimeMatch = $status.runtimeMatch; creationMatch = $status.creationMatch
        forge = (($text -split "`n") | Select-Object -Last 2) -join ' | '
    }
    Write-Host ("{0,-28} {1} match={2} runtime={3} creation={4}" -f $name, $addr, $status.match, $status.runtimeMatch, $status.creationMatch)
}
[IO.File]::WriteAllText($Out, ($results | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))

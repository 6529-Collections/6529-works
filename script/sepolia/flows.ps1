<#
.SYNOPSIS
    Runs the flows on a Sepolia rehearsal of the plain core (ADR 0010; round r6 on) and records
    the gas of every transaction. -Record is the deployment record script/DeployCore.s.sol
    wrote (one `<name>: <address>` object).

.DESCRIPTION
    script/sepolia/Flows.s.sol encodes every call and reads every EIP-712 digest from the
    contract that checks it; this driver signs the digests, sends the transactions with
    `cast send` (so each gas limit comes from the node's eth_estimateGas, which applies
    Glamsterdam's costs) and records each receipt in a JSON state file.

    No key or password is read here. Signing goes through a module, -SignerModule, that the
    operator keeps outside the repository. It must export
        Invoke-Signed <account> <program> <arguments[]>
    which runs `cast`/`forge` with the account's signer options appended (for example
    `--keystore <file> --password-file <file>`) and returns the program's output.

    Accounts are keystore names in the operator's signer set; see $Accounts below. A plan line
    whose sender is `safe:<address>` is a call that Safe makes: the driver signs the Safe
    transaction hash with the owner keystores in $SafeSigners (threshold many, sorted by owner
    address) and relays `execTransaction` from the `any` account.
    The Safe transaction hash the owners sign is computed locally (SafeTx.ps1); the Safe's own
    answer through the RPC is only compared with it, and a difference stops the step. Before the
    first signature or transaction the driver also requires the RPC to report Sepolia's chain
    ID (11155111).

    -ExpectRevert sends a transaction that must fail on chain (a refused bid, a refused
    withdrawal): the driver reads the revert with eth_call first, sends with a fixed gas limit
    (-GasLimit) so the node does not refuse to estimate it, and records the failed receipt.

.EXAMPLE
    $r = 'deployments/11155111/core-<timestamp>.json'
    ./flows.ps1 -SignerModule <path> -State <state.json> -Record $r -Step content
    ./flows.ps1 -SignerModule <path> -State <state.json> -Record $r -Step starter -Index 0
    ./flows.ps1 -SignerModule <path> -State <state.json> -Record $r -Step settle -TokenId 6
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step bid -TokenId 2 -Bidder bidder1 -Amount 60000000000000000 -Label bid-2-antisnipe
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step openEdition -Index 5 -TokenId 2
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step editionBid -TokenId 2 -Bidder bidder3 -EditionStep 30 -Quantity 2
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step editionSettle -TokenId 3 -Settler wallet3 -Order 1
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step bid -TokenId 2 -Bidder bidder1 -Amount 1 -ExpectRevert -Label bid-1-wei
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step finalize -TokenId 1
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step release -Index 5
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step pause -TokenId 1
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step editionState -TokenId 2 -Label before-antisnipe
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step independentDeploy
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step independentList -Token <token>
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step independentStart -Token <token> -Bidder bidder2 -Amount 20000000000000000
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step settle -Token <token> -TokenId 1
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step start -Index 1 -MoveSigner wallet2
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step starterRequest -Index 5 -Out starts/item-5.json
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step independentList -Token <token> -Work 1
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step independentEditionsDeploy -Token <token>
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step independentEditionsList -Editions <editions>
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step independentOpenEdition -Editions <editions> -TokenId 1 -Work 1
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step editionBid -Editions <editions> -TokenId 1 -Bidder bidder3 -EditionStep 30
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step independentStartNoBid -Token <token> -Work 2
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step restart -Token <token> -TokenId 1
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step clock -Token <token> -TokenId 1 -Label clock-before
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step prague
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step gateDeploy
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step gateGrant
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step gateState
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step gateCollection -From artist -Name 'Open gate'
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step gatePackage
    ./flows.ps1 -SignerModule <path> -State <state.json> $r -Step gateRevoke

    The prague step replays each recorded transaction with
    `cast run <tx> --quick --evm-version prague`: the parent block's state, Prague gas costs.
    Run it soon after the transactions: a public RPC keeps only recent historical state (or
    pass an archive RPC with -Rpc, such as https://sepolia.gateway.tenderly.co).

    The gate* steps are for a test instance that opens the curated path to any wallet
    (script/sepolia/open-gate.md): script/sepolia/OpenGate.s.sol plans them. gateDeploy creates
    SepoliaOpenGate (a Sepolia test convenience, never for mainnet) at its fixed address;
    gateGrant has the network Safe grant it CURATION_SIGNER and PLATFORM, and gateRevoke takes
    them back; gateState prints the address and the roles; gateCollection creates a collection
    through it (-From, -Name); gatePackage is the `package` step with the gate's approval in
    place of a curation signer's and with no curator statement.
#>
param(
    [Parameter(Mandatory)] [string] $SignerModule,
    [Parameter(Mandatory)] [string] $State,
    [Parameter(Mandatory)] [ValidateSet('content', 'collections', 'package', 'start', 'starter', 'startWithBid',
        'bid', 'openRecord', 'sync', 'finalize', 'requestSeed', 'settle', 'openEdition',
        'editionBid', 'editionRaise', 'editionSettle', 'claimBid', 'claimBidFor',
        'claimCredits', 'release', 'forward', 'editionState', 'englishState', 'pause',
        'englishWithdraw', 'outcome', 'cancel', 'send', 'safeCall', 'record', 'prague',
        'report', 'independentContent', 'independentDeploy', 'independentList',
        'independentStart', 'independentOpenRecord', 'starterRequest',
        'independentEditionsDeploy', 'independentEditionsList', 'independentOpenEdition',
        'independentStartNoBid', 'restart', 'clock', 'gateDeploy', 'gateGrant', 'gateRevoke',
        'gateState', 'gateCollection', 'gatePackage')] [string] $Step,
    [string] $Rpc = 'https://ethereum-sepolia-rpc.publicnode.com',
    # The deployment record, relative to the repository root (script/DeployCore.s.sol writes
    # deployments/11155111/core-<timestamp>.json).
    [Parameter(Mandatory)] [string] $Record,
    # The keystore that relays permissionless calls (role `any`): the keeper, an EOA with no
    # role. A second relayer lets the content uploads run beside the sale flow, each with its
    # own state file.
    [string] $Relay = 'flows-keeper',
    [int] $Index = -1,
    [int] $TokenId = 0,
    [string] $Bidder = 'bidder1',
    [string] $Amount = '0',
    [string] $Label = '',
    [string] $From = 'any',
    [string] $To = '',
    [string] $Data = '',
    # The edition auction: a ladder step, a quantity, a bid ID, and a settler's explicit
    # departure order (comma-separated indexes; omitted: the settler's own rest).
    [int] $EditionStep = -1,
    [int] $Quantity = 1,
    [int] $BidId = 0,
    [string] $Settler = 'any',
    [string] $Order = $null,
    # claimCredits: which adapter holds the credits (`english` or `edition`).
    [ValidateSet('english', 'edition', 'independentEdition')] [string] $Adapter = 'english',
    # The account that pauses (a pauser key) or the Safe that cancels (the network).
    [string] $Safe = '',
    # An artist's Independent Stream 1/1 contract. The independent* steps need it (after
    # independentDeploy, which prints and notes it); bid, settle, finalize, sync and englishState
    # act on it instead of Stream6529 when it is given.
    [string] $Token = '',
    # independentDeploy: the artist's salt (any text); independentList: the royalty rate the
    # artist approves the work with, out of 100,000.
    [string] $Salt = 'flows-independent-1',
    [int] $RoyaltyRate = 5000,
    # The artist's Independent Stream editions contract (after independentEditionsDeploy, which
    # prints and notes it). independentEditionsList and independentOpenEdition need it; the edition
    # steps (editionBid, editionRaise, editionSettle, claimBid, claimBidFor, editionState) act on
    # its sales in the Independent Stream edition auction when it is given.
    [string] $Editions = '',
    # Which Independent Stream work the independent* steps act on: 0, an original; 1 to 4, an
    # edition master (each with its own media, so one pair of contracts runs several edition sales).
    [ValidateSet(0, 1, 2, 3, 4)] [int] $Work = 0,
    # start, starter, startWithBid, starterRequest: the role whose wallet signs the artist's move
    # when it is not the account's root (a wallet consolidated with the artist, such as wallet2).
    [string] $MoveSigner = '',
    # starterRequest: the request file to write for the reference keeper's --starts folder.
    [string] $Out = '',
    # gateCollection: the name of the collection created through the open gate.
    [string] $Name = 'Open gate',
    [switch] $ExpectRevert,
    [string] $GasLimit = '500000'
)
$ErrorActionPreference = 'Stop'
Import-Module $SignerModule -Force
# The Safe transaction digest, computed locally, and the Sepolia chain ID check.
. (Join-Path $PSScriptRoot 'SafeTx.ps1')
# .NET file calls resolve relative paths against the process directory, not PowerShell's.
$State = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($State)

$Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Script = 'script/sepolia/Flows.s.sol:Flows'
# The plans of the gate* steps (a Sepolia test convenience; script/sepolia/open-gate.md).
$GateScript = 'script/sepolia/OpenGate.s.sol:OpenGate'
$env:FLOWS_RECORD = $Record
if ($Token) { $env:FLOWS_TOKEN = $Token } else { Remove-Item Env:FLOWS_TOKEN -ErrorAction SilentlyContinue }
if ($Editions) { $env:FLOWS_EDITIONS = $Editions } else { Remove-Item Env:FLOWS_EDITIONS -ErrorAction SilentlyContinue }
$env:FLOWS_INDEPENDENT_WORK = "$Work"
if ($Out) { $Out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out) }
$Contracts = Get-Content -Raw -Encoding UTF8 (Join-Path $Repo $Record) | ConvertFrom-Json
# 0.05 gwei and 0.2 gwei by default (cast's own max fee can fall below the priority fee);
# FLOWS_PRIORITY_FEE and FLOWS_MAX_FEE (wei) override them when Sepolia's base fee is near zero.
$PriorityFee = if ($env:FLOWS_PRIORITY_FEE) { $env:FLOWS_PRIORITY_FEE } else { '50000000' }
$MaxFee = if ($env:FLOWS_MAX_FEE) { $env:FLOWS_MAX_FEE } else { '200000000' }
# Role -> keystore account name in the operator's signer set.
$Accounts = @{
    any      = $Relay               # relays permissionless calls; holds no role
    platform = 'stream-platform'    # PLATFORM
    curator  = 'curator'            # CURATOR
    artist   = 'stream-artist'      # the lead artist of the package
    signer   = 'curation-1'         # CURATION_SIGNER (signs only)
    pauser   = 'pauser-1'           # PAUSER (a key)
    bidder1  = 'flows-bidder-1'
    bidder2  = 'flows-bidder-2'
    wallet2  = 'flows-consolidated'  # the artist's consolidated second wallet
    wallet3  = 'flows-wallet3'       # a wallet consolidated after the artist registers
    bidder3  = 'flows-bidder-3'
    bidder4  = 'flows-bidder-4'
}
# Safe -> the owner keystores that sign for it (threshold many), from the genesis holders.
$SafeSigners = @{
    '0x54a769fe591c3f47cf83d30b69e576497ce34454' = @('safe-owner-1', 'safe-owner-2')  # the network Safe (r5 to r8), 2-of-3
}
$Zero = '0x0000000000000000000000000000000000000000'

# ---------------------------------------------------------------------------- state

function Read-State {
    if (Test-Path -LiteralPath $State) {
        return Get-Content -Raw -Encoding UTF8 -LiteralPath $State | ConvertFrom-Json
    }
    return [pscustomobject]@{ addresses = [pscustomobject]@{}; txs = @(); notes = [pscustomobject]@{} }
}

function Write-State($s) {
    [IO.File]::WriteAllText($State, ($s | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}

function Set-Note([string]$Key, $Value) {
    $s = Read-State
    $s.notes | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
    Write-State $s
}

function Get-Note([string]$Key) {
    $s = Read-State
    $p = $s.notes.PSObject.Properties[$Key]
    if ($p) { return $p.Value }
    return $null
}

function Get-Address([string]$Role) {
    $s = Read-State
    $p = $s.addresses.PSObject.Properties[$Role]
    if ($p) { return $p.Value }
    $address = (Invoke-Signed $Accounts[$Role] 'cast' @('wallet', 'address')).Trim()
    $s.addresses | Add-Member -NotePropertyName $Role -NotePropertyValue $address -Force
    Write-State $s
    return $address
}

# The role whose account is $Address (case-insensitive). Addresses already in the state file are
# matched first; the others are resolved one by one, and a role whose keystore the operator does
# not hold (for example `pauser` on an earlier record) is skipped, not fatal.
function Get-Role([string]$Address) {
    $cached = (Read-State).addresses
    foreach ($p in $cached.PSObject.Properties) {
        if ($Accounts.ContainsKey($p.Name) -and $p.Value -eq $Address) { return $p.Name }
    }
    $missing = @()
    foreach ($role in $Accounts.Keys) {
        if ($cached.PSObject.Properties[$role]) { continue }
        try { $resolved = Get-Address $role }
        catch { $missing += $role; continue }
        if ($resolved -eq $Address) { return $role }
    }
    $note = if ($missing.Count) { " (not resolvable here: $($missing -join ', '))" } else { '' }
    throw "no account for $Address$note"
}

# ---------------------------------------------------------------------------- forge and cast

# Runs a native program and returns its output; throws on a non-zero exit. Windows
# PowerShell turns native stderr into error records, so they are collected, not raised.
function Invoke-Cli([string]$Program, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $Program @Arguments 2>&1; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    $text = ($out | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0) { throw "$Program $($Arguments[0]) failed ($code): $text" }
    return $text
}

# -AtBlock pins the read to one block (`--fork-block-number`), for a snapshot whose values and
# recorded block must be the same block.
function Invoke-Plan([string]$Sig, [string[]]$Arguments, [string]$AtBlock = '', [string]$PlanScript = $Script) {
    $pin = if ($AtBlock) { @('--fork-block-number', $AtBlock) } else { @() }
    Push-Location $Repo
    try {
        # A load-balanced public RPC can answer "block not found" for a block another backend
        # just reported; retry the read-only run.
        for ($attempt = 1; ; $attempt++) {
            try {
                $out = Invoke-Cli 'forge' (@('script', $PlanScript, '--sig', $Sig) + $Arguments + @('--rpc-url', $Rpc) + $pin)
                break
            }
            catch { if ($attempt -ge 4) { throw }; Start-Sleep -Seconds 5 }
        }
    }
    finally { Pop-Location }
    $items = @()
    foreach ($line in ($out -split "`n")) {
        $t = $line.Trim()
        if ($t -match '^(TX|SIGN|INFO) ') { $items += , ($t -split ' ') }
    }
    # The unary comma keeps a one-line plan an array of lines.
    return , $items
}

function Get-Sign($Items, [string]$Name) {
    foreach ($i in $Items) { if ($i[0] -eq 'SIGN' -and $i[1] -eq $Name) { return $i } }
    throw "no digest $Name"
}

function Get-Info($Items, [string]$Name) {
    foreach ($i in $Items) { if ($i[0] -eq 'INFO' -and $i[1] -eq $Name) { return $i[2] } }
    return $null
}

# Stops unless the RPC endpoint reports Sepolia's chain ID. Asked once per run, before the
# first signature or transaction: this driver signs and sends for Sepolia only.
$ChainConfirmed = $false
function Confirm-Chain {
    if ($script:ChainConfirmed) { return }
    Assert-SepoliaChain (Invoke-Cli 'cast' @('chain-id', '--rpc-url', $Rpc))
    $script:ChainConfirmed = $true
}

# Signs a digest from the plan with the role whose address the plan names.
function New-Signature($Sign) {
    Confirm-Chain
    $role = Get-Role $Sign[2]
    $sig = (Invoke-Signed $Accounts[$role] 'cast' @('wallet', 'sign', '--no-hash', $Sign[3])).Trim()
    if ($sig -notmatch '^0x[0-9a-fA-F]{130}$') { throw "bad signature for $($Sign[1])" }
    # Throws unless the signature recovers to the address the plan names.
    Invoke-Cli 'cast' @('wallet', 'verify', '--address', $Sign[2], '--no-hash', $Sign[3], $sig) | Out-Null
    return $sig
}

function Add-Receipt([string]$Label, [string]$Role, $Receipt, [string]$Expected = '') {
    $s = Read-State
    $row = [pscustomobject]@{
        label   = $Label
        from    = $Role
        hash    = $Receipt.transactionHash
        block   = [Convert]::ToInt64($Receipt.blockNumber, 16)
        gasUsed = [Convert]::ToInt64($Receipt.gasUsed, 16)
        status  = $Receipt.status
        prague  = $null
    }
    # A refusal sent on purpose records the revert eth_call read before sending.
    if ($Expected) { $row | Add-Member -NotePropertyName expectedRevert -NotePropertyValue $Expected }
    # One row per transaction: recording a hash twice (a re-run `record`, or a stale forge
    # broadcast file) is an error, not a second measurement.
    if (@($s.txs | Where-Object { $_.hash -eq $row.hash }).Count -ne 0) {
        throw "$Label`: $($row.hash) is already recorded"
    }
    $s.txs = @($s.txs) + $row
    Write-State $s
    Write-Host ("{0,-34} {1,12:N0} gas  {2} {3}" -f $Label, $row.gasUsed, $row.hash, $Receipt.status)
    if ($Expected) {
        if ($Receipt.status -ne '0x0') { throw "$Label was expected to revert: $($Receipt.transactionHash)" }
    }
    elseif ($Receipt.status -ne '0x1') { throw "$Label reverted: $($Receipt.transactionHash)" }
    return $Receipt
}

# Sends one planned transaction. Calldata above Windows' command-line limit goes through
# forge's broadcast instead (only the 24 KB chunk).
function Send-Planned([string]$Label, [string]$Role, [string]$To, [string]$Value, [string]$Calldata) {
    Confirm-Chain
    if ($Role -match '^0x') { $Role = Get-Role $Role }
    $account = $Accounts[$Role]
    $call = @('send', $To)
    if ($Calldata -and $Calldata -ne '0x') { $call += $Calldata }
    $call += @('--value', $Value, '--rpc-url', $Rpc, '--priority-gas-price', $PriorityFee,
        '--gas-price', $MaxFee, '--json')
    $expected = ''
    if ($ExpectRevert) {
        # Read the refusal first; a call that succeeds is not sent.
        $read = @('call', $To)
        if ($Calldata -and $Calldata -ne '0x') { $read += $Calldata }
        $read += @('--from', (Get-Address $Role), '--value', $Value, '--rpc-url', $Rpc)
        try { Invoke-Cli 'cast' $read | Out-Null; throw "$Label`: the call succeeds, nothing to refuse" }
        catch {
            $text = "$_"
            if ($text -match 'nothing to refuse') { throw }
            # Only a revert is the expected refusal; an RPC or argument error is not.
            if ($text -notmatch 'revert') { throw }
            $expected = if ($text -match '(execution reverted[^\n]*)') { $Matches[1] } else { $text }
            $expected = ($expected -split "`n")[0].Trim()
            Write-Host "expected revert: $expected"
        }
        $call += @('--gas-limit', $GasLimit)
    }
    for ($attempt = 1; ; $attempt++) {
        try { $json = Invoke-Signed $account 'cast' $call; break }
        catch {
            # Errors a load-balanced RPC returns before anything is broadcast (a lagging
            # backend's nonce, block or fee view). Anything else is not retried.
            # "replacement transaction underpriced": a backend that has not yet seen the previous
            # transaction mined hands out its nonce again (seen on r5).
            $transient = "$_" -match 'nonce too low|block not found|header not found|max priority fee per gas higher|replacement transaction underpriced'
            if (-not $transient -or $attempt -ge 5) { throw }
            Start-Sleep -Seconds 6
        }
    }
    return Add-Receipt $Label $Role ($json | ConvertFrom-Json) $expected
}

# Relays a call `$Safe` makes: its owners sign the Safe transaction hash (EOA signatures,
# sorted by owner address) and the `any` account sends `execTransaction`. The Safe reverts
# (GS013) if the inner call fails, so a recorded success means the call succeeded.
# The digest the owners sign is computed here from the transaction's fields and Sepolia's chain
# ID (SafeTx.ps1, EIP-712). The Safe's own `getTransactionHash`, read through the RPC, is only
# compared with it: a different answer stops the step before anything is signed. The nonce is
# the one value still taken from the RPC; a wrong one yields signatures for the same call at
# another nonce, which the Safe refuses.
function Send-Safe([string]$Label, [string]$Safe, [string]$To, [string]$Value, [string]$Calldata) {
    $signers = $SafeSigners[$Safe.ToLower()]
    if (-not $signers) { throw "no signers for Safe $Safe" }
    Confirm-Chain
    $nonce = (Invoke-Cli 'cast' @('call', $Safe, 'nonce()(uint256)', '--rpc-url', $Rpc)).Trim()
    if ($nonce -notmatch '^[0-9]+$') { throw "bad Safe nonce '$nonce'" }
    $digest = Get-SafeTxDigest $Safe $To $Value $Calldata $nonce
    $remote = (Invoke-Cli 'cast' @('call', $Safe,
            'getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)',
            $To, $Value, $Calldata, '0', '0', '0', '0', $Zero, $Zero, $nonce, '--rpc-url', $Rpc)).Trim()
    Assert-SafeTxDigest $digest $remote
    $owned = @()
    foreach ($k in $signers) {
        $owner = (Invoke-Signed $k 'cast' @('wallet', 'address')).Trim()
        $owned += , @($owner, $k)
    }
    $owned = $owned | Sort-Object { [System.Numerics.BigInteger]::Parse('0' + $_[0].Substring(2), 'AllowHexSpecifier') }
    $sigs = '0x'
    foreach ($o in $owned) {
        $sig = (Invoke-Signed $o[1] 'cast' @('wallet', 'sign', '--no-hash', $digest)).Trim()
        Invoke-Cli 'cast' @('wallet', 'verify', '--address', $o[0], '--no-hash', $digest, $sig) | Out-Null
        $sigs += $sig.Substring(2)
    }
    $exec = (Invoke-Cli 'cast' @('calldata',
            'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)',
            $To, $Value, $Calldata, '0', '0', '0', '0', $Zero, $Zero, $sigs)).Trim()
    Write-Host "Safe $Safe nonce $nonce, tx hash $digest"
    return Send-Planned $Label 'any' $Safe '0' $exec
}

function Send-Broadcast([string]$Label, [string]$Sig, [string[]]$Arguments) {
    Confirm-Chain
    $sender = Get-Address 'any'
    Push-Location $Repo
    try {
        $out = Invoke-Signed $Accounts['any'] 'forge' (@('script', $Script, '--sig', $Sig) + $Arguments +
            @('--rpc-url', $Rpc, '--sender', $sender, '--broadcast', '--slow', '--skip-simulation',
                '--priority-gas-price', $PriorityFee, '--with-gas-price', $MaxFee))
    }
    finally { Pop-Location }
    # forge records the receipt with the broadcast (a gitignored cache for chain 11155111).
    $name = ($Sig -split '\(')[0]
    $run = Get-Content -Raw -Encoding UTF8 "$Repo/broadcast/Flows.s.sol/11155111/$name-latest.json" | ConvertFrom-Json
    return Add-Receipt $Label 'any' $run.receipts[-1]
}

# Sends every TX line of a plan; -Label renames the transaction of a one-transaction plan.
function Send-Items($Items) {
    foreach ($i in $Items) {
        if ($i[0] -ne 'TX') { continue }
        if ($Label) {
            if (@($Items | Where-Object { $_[0] -eq 'TX' }).Count -ne 1) { throw "-Label needs a one-transaction plan" }
            $i[1] = $Label
        }
        # Windows limits a command line to 32,767 characters; 30,000 leaves room for the
        # rest of the `cast send` arguments.
        if ($i[5].Length -gt 30000) {
            if ($i[1] -notmatch '^writeChunk-b64-(\d+)$') { throw "$($i[1]): calldata too long for cast" }
            Send-Broadcast $i[1] 'broadcastB64Chunk(uint256)' @("$(Get-Info $Items "b64-$($Matches[1])-k")") | Out-Null
        }
        elseif ($i[2] -match '^safe:(0x[0-9a-fA-F]{40})$') { Send-Safe $i[1] $Matches[1] $i[3] $i[4] $i[5] | Out-Null }
        else { Send-Planned $i[1] $i[2] $i[3] $i[4] $i[5] | Out-Null }
    }
}

# Reads a view plan at one block and keeps its INFO lines in the state file under
# notes.snapshots.<label>, with that block's number and time: the head is resolved first and the
# plan reads exactly that block, so the values and the recorded block cannot be a block apart.
# (Snapshots recorded up to r8 took the head after the read and can name the block after it.)
function Save-Snapshot([string]$Sig, [string[]]$Arguments, [string]$Name) {
    $block = Invoke-Cli 'cast' @('block', 'latest', '--json', '--rpc-url', $Rpc) | ConvertFrom-Json
    $number = [Convert]::ToInt64($block.number, 16)
    $Items = Invoke-Plan $Sig $Arguments "$number"
    $snap = [ordered]@{ block = $number; timestamp = [Convert]::ToInt64($block.timestamp, 16) }
    foreach ($i in $Items) { if ($i[0] -eq 'INFO') { $snap[$i[1]] = $i[2] } }
    $snap.GetEnumerator() | ForEach-Object { Write-Host ("{0,-16} {1}" -f $_.Key, $_.Value) }
    if ($Name) {
        $s = Read-State
        if (-not $s.notes.PSObject.Properties['snapshots']) {
            $s.notes | Add-Member -NotePropertyName snapshots -NotePropertyValue ([pscustomobject]@{})
        }
        $s.notes.snapshots | Add-Member -NotePropertyName $Name -NotePropertyValue ([pscustomobject]$snap) -Force
        Write-State $s
    }
}

function Get-Timestamp {
    return [Convert]::ToInt64((Invoke-Cli 'cast' @('block', 'latest', '--field', 'timestamp', '--rpc-url', $Rpc)).Trim())
}

# Move nonces are sequential per artist (src/curation/README.md): 0, 1, 2, ...
function Get-MoveNonce {
    $n = Get-Note 'nextMoveNonce'
    if ($null -eq $n) { $n = 0 }
    Set-Note 'nextMoveNonce' ($n + 1)
    return $n
}

function Get-MoveSignature([int]$Item) {
    $nonce = Get-MoveNonce
    $deadline = (Get-Timestamp) + 7 * 86400
    $items = Invoke-Plan 'moveDigest(uint256,uint256,uint64)' @("$Item", "$nonce", "$deadline")
    $sig = New-Signature (Get-Sign $items "move-$Item")
    return @("$nonce", "$deadline", $sig)
}

# ---------------------------------------------------------------------------- steps

# The wallet that signs the move (Flows.s.sol reads FLOWS_MOVE_SIGNER): the account's root unless
# -MoveSigner names a consolidated wallet's role.
if ($MoveSigner) {
    if (-not $Accounts.ContainsKey($MoveSigner)) { throw "unknown role for -MoveSigner: $MoveSigner" }
    $env:FLOWS_MOVE_SIGNER = Get-Address $MoveSigner
}
else { Remove-Item Env:FLOWS_MOVE_SIGNER -ErrorAction SilentlyContinue }
# The curation signer whose approval the package step collects (Flows.s.sol reads FLOWS_SIGNER).
if ($Step -eq 'package') { $env:FLOWS_SIGNER = Get-Address 'signer' }

switch ($Step) {
    'content' {
        Send-Items (Invoke-Plan 'content()' @())
    }
    'collections' {
        $stream = $Contracts.Stream6529
        # Creates only the collections an instance lacks, so a re-run is a no-op where both
        # exist. The package uses collection IDs 1 and 2, not names.
        $count = [int](Invoke-Cli 'cast' @('call', $stream, 'collectionCount()(uint256)', '--rpc-url', $Rpc)).Trim()
        foreach ($name in (@('Flows', 'Flows 2') | Select-Object -Skip $count)) {
            $hash = (Invoke-Cli 'cast' @('keccak', "6529-stream/sepolia/flows/collection/$name")).Trim()
            $data = (Invoke-Cli 'cast' @('calldata', 'createCollection(string,bytes32)', $name, $hash)).Trim()
            Send-Planned "createCollection-$($name -replace ' ', '-')" 'platform' $stream '0' $data | Out-Null
        }
    }
    'package' {
        $deadline = (Get-Timestamp) + 7 * 86400
        $plan = Invoke-Plan 'package(uint64)' @("$deadline")
        Set-Note 'root' (Get-Info $plan 'root')
        $approval = New-Signature (Get-Sign $plan 'approval')
        $acceptance = New-Signature (Get-Sign $plan 'acceptance')
        Send-Items (Invoke-Plan 'registerTx(bytes)' @($approval))
        Send-Items (Invoke-Plan 'curatorTx()' @())
        Send-Items (Invoke-Plan 'acceptTx(uint64,bytes)' @("$deadline", $acceptance))
    }
    'start' {
        Send-Items (Invoke-Plan 'startTx(uint256,uint256,uint64,bytes)' ((@("$Index") + (Get-MoveSignature $Index))))
    }
    'starter' {
        # SaleStarter.start: auction, seller and royalty vaults and record in one transaction.
        Send-Items (Invoke-Plan 'starterTx(uint256,uint256,uint64,bytes)' ((@("$Index") + (Get-MoveSignature $Index))))
    }
    'starterRequest' {
        # The same start as `starter`, written as a request file for the reference keeper
        # (keeper/README.md, "Start requests") instead of being sent: the keeper sends it.
        if (-not $Out) { throw 'starterRequest needs -Out' }
        $plan = Invoke-Plan 'starterRequest(uint256,uint256,uint64,bytes)' ((@("$Index") + (Get-MoveSignature $Index)))
        $request = [ordered]@{ mintData = (Get-Info $plan 'mintData'); media = (Get-Info $plan 'media') }
        foreach ($key in 'mintData', 'media') {
            # Whole bytes of hex, or the keeper would fail on the file later.
            if ("$($request[$key])" -notmatch '^0x([0-9a-fA-F]{2})+$') { throw "starterRequest: the plan's $key is not hex" }
        }
        [IO.File]::WriteAllText($Out, ($request | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        Write-Host "wrote $Out"
    }
    'startWithBid' {
        $bidder = Get-Address $Bidder
        Send-Items (Invoke-Plan 'startWithBidTx(uint256,uint256,uint64,bytes,address,uint256)' `
            (@("$Index") + (Get-MoveSignature $Index) + @($bidder, $Amount)))
    }
    'bid' {
        Send-Items (Invoke-Plan 'bidTx(uint256,address,uint256)' @("$TokenId", (Get-Address $Bidder), $Amount))
    }
    'openRecord' {
        Send-Items (Invoke-Plan 'openRecordTx(uint256,uint256)' @("$Index", "$TokenId"))
    }
    'sync' {
        # Records in WorkFacts that every media file of the work is complete in the content store.
        # Not `$work`: PowerShell names are case-insensitive and -Work is a typed parameter.
        $workToken = if ($Token) { $Token } else { $Contracts.Stream6529 }
        $data = (Invoke-Cli 'cast' @('calldata', 'markOnChainComplete(address,uint256)', $workToken, "$TokenId")).Trim()
        Send-Planned "markOnChainComplete-$TokenId" 'any' $Contracts.StreamWorkFacts6529 '0' $data | Out-Null
    }
    'finalize' {
        Send-Items (Invoke-Plan 'finalizeTx(uint256)' @("$TokenId"))
    }
    'requestSeed' {
        Send-Items (Invoke-Plan 'requestSeedTx()' @())
    }
    'settle' {
        Send-Items (Invoke-Plan 'settleTx(uint256)' @("$TokenId"))
    }
    'openEdition' {
        Send-Items (Invoke-Plan 'openEditionTx(uint256,uint256)' @("$Index", "$TokenId"))
    }
    'editionBid' {
        Send-Items (Invoke-Plan 'editionBidTx(uint256,address,uint256,uint256)' `
            @("$TokenId", (Get-Address $Bidder), "$EditionStep", "$Quantity"))
    }
    'editionRaise' {
        Send-Items (Invoke-Plan 'editionRaiseTx(uint256,uint256,uint256)' @("$TokenId", "$BidId", "$EditionStep"))
    }
    'editionSettle' {
        $settler = Get-Address $Settler
        if ($PSBoundParameters.ContainsKey('Order')) {
            Send-Items (Invoke-Plan 'editionSettleOrderTx(uint256,address,uint256[])' @("$TokenId", $settler, "[$Order]"))
        }
        else { Send-Items (Invoke-Plan 'editionSettleTx(uint256,address)' @("$TokenId", $settler)) }
    }
    'claimBid' {
        Send-Items (Invoke-Plan 'claimBidTx(uint256,uint256)' @("$TokenId", "$BidId"))
    }
    'claimBidFor' {
        Send-Items (Invoke-Plan 'claimBidForTx(uint256,uint256)' @("$TokenId", "$BidId"))
    }
    'claimCredits' {
        $adapterAddress = switch ($Adapter) {
            'english' { $Contracts.EnglishAuction }
            'edition' { $Contracts.UniformEditionAuction }
            default { $Contracts.IndependentEditionAuction }
        }
        Send-Items (Invoke-Plan 'claimCreditsTx(address,address)' @($adapterAddress, (Get-Address $Bidder)))
    }
    'release' {
        Send-Items (Invoke-Plan 'releaseTx(uint256)' @("$Index"))
    }
    'forward' {
        Send-Items (Invoke-Plan 'forwardTx()' @())
    }
    'editionState' {
        Save-Snapshot 'editionState(uint256)' @("$TokenId") $Label
    }
    'englishState' {
        Save-Snapshot 'englishState(uint256)' @("$TokenId") $Label
    }
    'pause' {
        # The pauser key, or -Safe for a pauser that is a Safe.
        $guardian = if ($Safe) { $Safe } else { Get-Address 'pauser' }
        Send-Items (Invoke-Plan 'pauseTx(uint256,address)' @("$TokenId", $guardian))
    }
    'englishWithdraw' {
        Send-Items (Invoke-Plan 'englishWithdrawTx(uint256)' @("$TokenId"))
    }
    'outcome' {
        Send-Items (Invoke-Plan 'outcomeTx(uint256)' @("$TokenId"))
    }
    'cancel' {
        # The network (the manager's `network()`; the manager is the configurator's
        # `streamManager()`). -Safe overrides. Send-Safe refuses a Safe without configured signers.
        $network = $Safe
        if (-not $network) {
            $manager = (Invoke-Cli 'cast' @('call', $Contracts.GovernanceConfigurator,
                    'streamManager()(address)', '--rpc-url', $Rpc)).Trim()
            $network = (Invoke-Cli 'cast' @('call', $manager, 'network()(address)', '--rpc-url', $Rpc)).Trim()
        }
        if (-not $SafeSigners[$network.ToLower()]) { throw "no signers configured for network Safe $network" }
        Send-Items (Invoke-Plan 'cancelTx(uint256,address)' @("$TokenId", $network))
    }
    'independentContent' {
        Send-Items (Invoke-Plan 'independentContent()' @())
    }
    'independentDeploy' {
        # The artist deploys its own 1/1 contract from the approved template; the address is
        # kept in the state file (notes.independentToken) for the steps that take -Token.
        $salt = (Invoke-Cli 'cast' @('keccak', "6529-stream/sepolia/flows/independent/$Salt")).Trim()
        $plan = Invoke-Plan 'independentDeployTx(bytes32)' @($salt)
        $token = Get-Info $plan 'token'
        Send-Items $plan
        Set-Note 'independentToken' $token
        Write-Host "Independent Stream token: $token"
    }
    'independentList' {
        if (-not $Token) { throw 'independentList needs -Token' }
        $deadline = (Get-Timestamp) + 86400
        $consent = New-Signature (Get-Sign (Invoke-Plan 'independentConsent(address,uint64)' @($Token, "$deadline")) 'consent')
        Send-Items (Invoke-Plan 'independentListTx(address,uint64,bytes,uint24)' @($Token, "$deadline", $consent, "$RoyaltyRate"))
    }
    'independentStart' {
        if (-not $Token) { throw 'independentStart needs -Token' }
        Send-Items (Invoke-Plan 'independentStartTx(address,address,uint256)' @($Token, (Get-Address $Bidder), $Amount))
    }
    'independentStartNoBid' {
        # `start` with no bid, sent by the relay: the sale ends unsold unless someone bids.
        if (-not $Token) { throw 'independentStartNoBid needs -Token' }
        Send-Items (Invoke-Plan 'independentStartNoBidTx(address)' @($Token))
    }
    'restart' {
        # Offers an unsold Independent Stream work again (-Token, -TokenId); with -ExpectRevert the
        # refusal is read first and the failed transaction recorded (too early, or a 6529 Stream sale).
        Send-Items (Invoke-Plan 'restartTx(uint256)' @("$TokenId"))
    }
    'clock' {
        # auctionClock's four words (state, end, pause start, last restart), kept under -Label.
        # For r8 and later: the English auctions of r6 and r7 answer three words, which this
        # step cannot decode.
        Save-Snapshot 'clock(uint256)' @("$TokenId") $Label
    }
    'independentEditionsDeploy' {
        # The artist deploys the editions contract of its 1/1 contract -Token; the address is kept
        # in the state file (notes.independentEditions) for the steps that take -Editions.
        if (-not $Token) { throw 'independentEditionsDeploy needs -Token (the 1/1 contract)' }
        $salt = (Invoke-Cli 'cast' @('keccak', "6529-stream/sepolia/flows/independent-editions/$Salt")).Trim()
        $plan = Invoke-Plan 'independentEditionsDeployTx(bytes32,address)' @($salt, $Token)
        $deployed = Get-Info $plan 'editions'
        Send-Items $plan
        Set-Note 'independentEditions' $deployed
        Write-Host "Independent Stream editions: $deployed"
    }
    'independentEditionsList' {
        if (-not $Editions) { throw 'independentEditionsList needs -Editions' }
        $deadline = (Get-Timestamp) + 86400
        $consent = New-Signature (Get-Sign (Invoke-Plan 'independentEditionsConsent(address,uint64)' @($Editions, "$deadline")) 'consent')
        Send-Items (Invoke-Plan 'independentEditionsListTx(address,uint64,bytes)' @($Editions, "$deadline", $consent))
    }
    'independentOpenEdition' {
        if (-not $Editions) { throw 'independentOpenEdition needs -Editions' }
        Send-Items (Invoke-Plan 'independentOpenEditionTx(address,uint256)' @($Editions, "$TokenId"))
    }
    'independentOpenRecord' {
        if (-not $Token) { throw 'independentOpenRecord needs -Token' }
        Send-Items (Invoke-Plan 'independentOpenRecordTx(address,uint256)' @($Token, "$TokenId"))
    }
    'gateDeploy' {
        # Creates SepoliaOpenGate at its fixed address (the relay sends it; the gate has no owner).
        # A no-op when it exists. The address is kept in the state file (notes.openGate).
        $plan = Invoke-Plan 'deployTx()' @() '' $GateScript
        Send-Items $plan
        Set-Note 'openGate' (Get-Info $plan 'gate')
        Write-Host "SepoliaOpenGate: $(Get-Info $plan 'gate')"
    }
    'gateGrant' {
        # The network Safe grants the gate CURATION_SIGNER and PLATFORM (no delay: the network is
        # the admin of both roles at once). One Safe transaction per role; a role it holds is skipped.
        Send-Items (Invoke-Plan 'grantTx()' @() '' $GateScript)
    }
    'gateRevoke' {
        # The network Safe revokes the gate's roles: the gate is closed.
        Send-Items (Invoke-Plan 'revokeTx()' @() '' $GateScript)
    }
    'gateState' {
        foreach ($i in (Invoke-Plan 'state()' @() '' $GateScript)) {
            if ($i[0] -eq 'INFO') { Write-Host ("{0,-16} {1}" -f $i[1], $i[2]) }
        }
    }
    'gateCollection' {
        # -From creates a collection through the gate (any account may).
        $plan = Invoke-Plan 'collectionTx(address,string)' @((Get-Address $From), $Name) '' $GateScript
        Write-Host "collection ID: $(Get-Info $plan 'collectionId')"
        Send-Items $plan
    }
    'gatePackage' {
        # The `package` step through the gate: the gate's approval in place of a curation signer's
        # signature, no curator statement, then the artist's acceptance.
        $deadline = (Get-Timestamp) + 7 * 86400
        $plan = Invoke-Plan 'package(uint64)' @("$deadline")
        $root = Get-Info $plan 'root'
        Set-Note 'root' $root
        $acceptance = New-Signature (Get-Sign $plan 'acceptance')
        Send-Items (Invoke-Plan 'registerTx(bytes32)' @($root) '' $GateScript)
        Send-Items (Invoke-Plan 'acceptTx(uint64,bytes)' @("$deadline", $acceptance))
    }
    'record' {
        # Records a transaction sent outside this driver (for example by the Chainlink node).
        $receipt = Invoke-Cli 'cast' @('receipt', $Data, '--rpc-url', $Rpc, '--json') | ConvertFrom-Json
        Add-Receipt $Label $From $receipt | Out-Null
    }
    'send' {
        # A call that needs no encoding help, for example the delegation registrations.
        Send-Planned $Label $From $To $Amount $Data | Out-Null
    }
    'safeCall' {
        # A call the Safe -Safe makes, for example the network's acceptNetwork() on the manager:
        # its owners in $SafeSigners sign and the `any` account relays execTransaction.
        if (-not $Safe -or -not $To -or -not $Label) { throw 'safeCall needs -Safe, -To and -Label' }
        Send-Safe $Label $Safe $To $Amount $(if ($Data) { $Data } else { '0x' }) | Out-Null
    }
    'prague' {
        # The same transaction replayed on its parent block's state with Prague gas costs.
        $s = Read-State
        foreach ($row in $s.txs) {
            if ($null -ne $row.prague) { continue }
            # A pruned node cannot replay old blocks: report the row and go on (pass an archive
            # RPC with -Rpc to fill it in).
            try { $out = Invoke-Cli 'cast' @('run', $row.hash, '--quick', '--evm-version', 'prague', '--rpc-url', $Rpc) }
            catch { Write-Host ("{0,-34} not replayed: {1}" -f $row.label, ("$_" -split "`n")[0]); continue }
            if ($out -notmatch 'Gas used: (\d+)') { throw "$($row.label): no gas in the cast run output" }
            $row.prague = [int64]$Matches[1]
            Write-State $s
            Write-Host ("{0,-34} {1,12:N0} {2,12:N0}" -f $row.label, $row.gasUsed, $row.prague)
        }
    }
    'report' {
        $s = Read-State
        foreach ($row in $s.txs) {
            $ratio = if ($row.prague) { '{0:N2}' -f ($row.gasUsed / $row.prague) } else { '' }
            Write-Host ("{0,-34} {1,12:N0} {2,12:N0} {3,6} {4}" -f $row.label, $row.gasUsed, $row.prague, $ratio, $row.hash)
        }
    }
}

<#
.SYNOPSIS
    Runs the v1 flows on a Sepolia rehearsal deployment (r4 by default; -Record selects
    another) and records the gas of every transaction (deployments/11155111/flows.md).

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

    -ExpectRevert sends a transaction that must fail on chain (a refused bid, a refused
    withdrawal): the driver reads the revert with eth_call first, sends with a fixed gas limit
    (-GasLimit) so the node does not refuse to estimate it, and records the failed receipt.

.EXAMPLE
    ./flows.ps1 -SignerModule <path> -State <state.json> -Step content
    ./flows.ps1 -SignerModule <path> -State <state.json> -Step start -Index 0
    ./flows.ps1 -SignerModule <path> -State <state.json> -Step settle -TokenId 6
    ./flows.ps1 -SignerModule <path> -State <state.json> -Step bid -TokenId 2 -Bidder bidder1 -Amount 50000000000000000 -Label bid-2-antisnipe
    ./flows.ps1 -SignerModule <path> -State <r1-state.json> -Record deployments/11155111/1791746472.json -Step settle -TokenId 6
    ./flows.ps1 -SignerModule <path> -State <state.json> -Step openEdition -Index 5 -TokenId 2
    ./flows.ps1 -SignerModule <path> -State <state.json> -Step editionBid -TokenId 2 -Bidder bidder3 -EditionStep 30 -Quantity 2
    ./flows.ps1 -SignerModule <path> -State <state.json> -Step editionSettle -TokenId 3 -Settler wallet3 -Order 1
    ./flows.ps1 -SignerModule <path> -State <state.json> -Step bid -TokenId 2 -Bidder bidder1 -Amount 1 -ExpectRevert -Label bid-1-wei
    ./flows.ps1 -SignerModule <path> -State <state.json> -Step pause -TokenId 1
    ./flows.ps1 -SignerModule <path> -State <state.json> -Step editionState -TokenId 2 -Label before-antisnipe
    ./flows.ps1 -SignerModule <path> -State <state.json> -Step prague

    The prague step replays each recorded transaction with
    `cast run <tx> --quick --evm-version prague`: the parent block's state, Prague gas costs.
    Run it soon after the transactions: a public RPC keeps only recent historical state (or
    pass an archive RPC with -Rpc; r4 used https://sepolia.gateway.tenderly.co).
#>
param(
    [Parameter(Mandatory)] [string] $SignerModule,
    [Parameter(Mandatory)] [string] $State,
    [Parameter(Mandatory)] [ValidateSet('content', 'collections', 'package', 'start', 'startWithBid',
        'bid', 'openRecord', 'sync', 'requestSeed', 'settle', 'createEdition', 'openEdition',
        'editionBid', 'editionRaise', 'editionWithdraw', 'editionSettle', 'claimBid', 'claimBidFor',
        'claimCredits', 'editionState', 'englishState', 'pause', 'englishWithdraw', 'outcome',
        'scheduleCancel', 'executeCancel', 'send', 'record', 'prague', 'report')] [string] $Step,
    [string] $Rpc = 'https://ethereum-sepolia-rpc.publicnode.com',
    # The deployment record, relative to the repository root (r4 by default).
    [string] $Record = 'deployments/11155111/1793536584.json',
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
    [ValidateSet('english', 'edition')] [string] $Adapter = 'english',
    # The Safe that pauses (a guardian) or schedules and executes a cancel (the hot admin).
    [string] $Safe = '',
    [switch] $ExpectRevert,
    [string] $GasLimit = '500000'
)
$ErrorActionPreference = 'Stop'
Import-Module $SignerModule -Force
# .NET file calls resolve relative paths against the process directory, not PowerShell's.
$State = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($State)

$Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Script = 'script/sepolia/Flows.s.sol:Flows'
$env:FLOWS_RECORD = $Record
$Contracts = (Get-Content -Raw -Encoding UTF8 (Join-Path $Repo $Record) | ConvertFrom-Json).contracts
$PriorityFee = '50000000'   # 0.05 gwei
$MaxFee = '200000000'       # 0.2 gwei: cast's own max fee can fall below the priority fee
# Role -> keystore account name in the operator's signer set.
$Accounts = @{
    any      = $Relay               # relays permissionless calls; holds no role
    platform = 'stream-platform'    # PLATFORM
    curator  = 'curator'            # CURATOR
    artist   = 'stream-artist'      # the lead artist of the package
    signer   = 'curation-1'         # CURATION_SIGNER (signs only)
    bidder1  = 'flows-bidder-1'
    bidder2  = 'flows-bidder-2'
    wallet2  = 'flows-consolidated'  # the artist's consolidated second wallet (from r1)
    wallet3  = 'flows-wallet3'       # a wallet consolidated after the artist registers on r2
    bidder3  = 'flows-bidder-3'      # r4 on
    bidder4  = 'flows-bidder-4'      # r4 on
}
# Safe -> the owner keystores that sign for it (threshold many), from the genesis holders.
$SafeSigners = @{
    '0x5d1103f2fc0ce8d0e81a918a3819182208b6e916' = @('guardian1-1', 'guardian1-2')  # Guardian Safe 1, 2-of-3
    '0x2588a62384f41bb32412841ab774cd574b427bd5' = @('hot-1', 'hot-2')              # Hot admin Safe, 2-of-3
}
# The genesis holders the dispute steps act as.
$GuardianSafe = '0x5d1103f2FC0ce8D0E81a918A3819182208B6E916'
$HotAdminSafe = '0x2588A62384F41bB32412841ab774CD574b427bd5'
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

function Get-Role([string]$Address) {
    foreach ($role in $Accounts.Keys) {
        if ((Get-Address $role) -eq $Address) { return $role }
    }
    throw "no account for $Address"
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

function Invoke-Plan([string]$Sig, [string[]]$Arguments) {
    Push-Location $Repo
    try {
        # A load-balanced public RPC can answer "block not found" for a block another backend
        # just reported; retry the read-only run.
        for ($attempt = 1; ; $attempt++) {
            try {
                $out = Invoke-Cli 'forge' (@('script', $Script, '--sig', $Sig) + $Arguments + @('--rpc-url', $Rpc))
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

# Signs a digest from the plan with the role whose address the plan names.
function New-Signature($Sign) {
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
            $transient = "$_" -match 'nonce too low|block not found|header not found|max priority fee per gas higher'
            if (-not $transient -or $attempt -ge 5) { throw }
            Start-Sleep -Seconds 6
        }
    }
    return Add-Receipt $Label $Role ($json | ConvertFrom-Json) $expected
}

# Relays a call `$Safe` makes: its owners sign the Safe transaction hash (EOA signatures,
# sorted by owner address) and the `any` account sends `execTransaction`. The Safe reverts
# (GS013) if the inner call fails, so a recorded success means the call succeeded.
function Send-Safe([string]$Label, [string]$Safe, [string]$To, [string]$Value, [string]$Calldata) {
    $signers = $SafeSigners[$Safe.ToLower()]
    if (-not $signers) { throw "no signers for Safe $Safe" }
    $nonce = (Invoke-Cli 'cast' @('call', $Safe, 'nonce()(uint256)', '--rpc-url', $Rpc)).Trim()
    $hash = (Invoke-Cli 'cast' @('call', $Safe,
            'getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)',
            $To, $Value, $Calldata, '0', '0', '0', '0', $Zero, $Zero, $nonce, '--rpc-url', $Rpc)).Trim()
    $owned = @()
    foreach ($k in $signers) {
        $owner = (Invoke-Signed $k 'cast' @('wallet', 'address')).Trim()
        $owned += , @($owner, $k)
    }
    $owned = $owned | Sort-Object { [System.Numerics.BigInteger]::Parse('0' + $_[0].Substring(2), 'AllowHexSpecifier') }
    $sigs = '0x'
    foreach ($o in $owned) {
        $sig = (Invoke-Signed $o[1] 'cast' @('wallet', 'sign', '--no-hash', $hash)).Trim()
        Invoke-Cli 'cast' @('wallet', 'verify', '--address', $o[0], '--no-hash', $hash, $sig) | Out-Null
        $sigs += $sig.Substring(2)
    }
    $exec = (Invoke-Cli 'cast' @('calldata',
            'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)',
            $To, $Value, $Calldata, '0', '0', '0', '0', $Zero, $Zero, $sigs)).Trim()
    Write-Host "Safe $Safe nonce $nonce, tx hash $hash"
    return Send-Planned $Label 'any' $Safe '0' $exec
}

function Send-Broadcast([string]$Label, [string]$Sig, [string[]]$Arguments) {
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

# Prints a plan's INFO lines and keeps them in the state file under notes.snapshots.<label>,
# with the latest block's number and time.
function Save-Snapshot($Items, [string]$Name) {
    $block = Invoke-Cli 'cast' @('block', 'latest', '--json', '--rpc-url', $Rpc) | ConvertFrom-Json
    $snap = [ordered]@{ block = [Convert]::ToInt64($block.number, 16); timestamp = [Convert]::ToInt64($block.timestamp, 16) }
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

switch ($Step) {
    'content' {
        Send-Items (Invoke-Plan 'content()' @())
    }
    'collections' {
        $stream = $Contracts.Stream.address
        # Creates only the collections an instance lacks, so a re-run is a no-op where both
        # exist. r1's two were created under earlier names ("r1 Flows", "r1 Flows 2"); the
        # package uses collection IDs 1 and 2, not names.
        $count = [int](Invoke-Cli 'cast' @('call', $stream, 'collectionCount()(uint256)', '--rpc-url', $Rpc)).Trim()
        foreach ($name in (@('Flows', 'Flows 2') | Select-Object -Skip $count)) {
            $hash = (Invoke-Cli 'cast' @('keccak', "6529-works/sepolia/flows/collection/$name")).Trim()
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
        $records = $Contracts.WorkRecords.address
        $data = (Invoke-Cli 'cast' @('calldata', 'syncOnChain(uint256)', "$TokenId")).Trim()
        Send-Planned "syncOnChain-$TokenId" 'any' $records '0' $data | Out-Null
    }
    'requestSeed' {
        Send-Items (Invoke-Plan 'requestSeedTx()' @())
    }
    'settle' {
        Send-Items (Invoke-Plan 'settleTx(uint256)' @("$TokenId"))
    }
    'createEdition' {
        Send-Items (Invoke-Plan 'createEditionTx(uint256,uint256)' @("$Index", "$TokenId"))
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
    'editionWithdraw' {
        Send-Items (Invoke-Plan 'editionWithdrawTx(uint256,uint256)' @("$TokenId", "$BidId"))
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
        $adapterAddress = if ($Adapter -eq 'english') { $Contracts.EnglishAuction.address } else { $Contracts.UniformEditionAuction.address }
        Send-Items (Invoke-Plan 'claimCreditsTx(address,address)' @($adapterAddress, (Get-Address $Bidder)))
    }
    'editionState' {
        Save-Snapshot (Invoke-Plan 'editionState(uint256)' @("$TokenId")) $Label
    }
    'englishState' {
        Save-Snapshot (Invoke-Plan 'englishState(uint256)' @("$TokenId")) $Label
    }
    'pause' {
        $guardian = if ($Safe) { $Safe } else { $GuardianSafe }
        Send-Items (Invoke-Plan 'pauseTx(uint256,address)' @("$TokenId", $guardian))
    }
    'englishWithdraw' {
        Send-Items (Invoke-Plan 'englishWithdrawTx(uint256)' @("$TokenId"))
    }
    'outcome' {
        Send-Items (Invoke-Plan 'outcomeTx(uint256)' @("$TokenId"))
    }
    'scheduleCancel' {
        $admin = if ($Safe) { $Safe } else { $HotAdminSafe }
        $plan = Invoke-Plan 'scheduleCancelTx(uint256,address)' @("$TokenId", $admin)
        Set-Note "cancelOperation-$TokenId" (Get-Info $plan 'operationId')
        Send-Items $plan
    }
    'executeCancel' {
        $admin = if ($Safe) { $Safe } else { $HotAdminSafe }
        Send-Items (Invoke-Plan 'executeCancelTx(uint256,address)' @("$TokenId", $admin))
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

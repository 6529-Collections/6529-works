<#
.SYNOPSIS
    Simulates (default) or broadcasts script/DeployCore.s.sol for a Sepolia rehearsal, with the
    public inputs of an env file (config/sepolia-<instance>/deploy.env).

.DESCRIPTION
    No key or password is read here. Signing goes through a module the operator keeps outside
    the repository (-SignerModule), as for script/sepolia/flows.ps1: it must export
        Invoke-Signed <account> <program> <arguments[]>
    which runs the program with the account's signer options appended (for example
    `--keystore <file> --password-file <file>`), and
        Invoke-Tool <program> <arguments[]>
    which runs it without them. Both return the program's output and throw when it exits
    non-zero; this script checks the exit code as well.

    Sepolia runs Glamsterdam, which reprices state creation and which Foundry 1.7.1 cannot
    simulate: the broadcast skips forge's replay (--skip-simulation) and, with --slow, takes
    each transaction's gas limit from the node's eth_estimateGas just before sending it
    (script/README.md, section Sepolia). The script itself, with every check, still runs first.

.EXAMPLE
    ./deploy.ps1 -SignerModule <path> -EnvFile config/sepolia-r6/deploy.env -Log sim.txt
    ./deploy.ps1 -SignerModule <path> -EnvFile config/sepolia-r6/deploy.env -Broadcast -Log run.txt
#>
param(
    [Parameter(Mandatory)] [string] $SignerModule,
    [Parameter(Mandatory)] [string] $EnvFile,
    [string] $Account = 'stream-deployer',
    [string] $Log = '',
    [switch] $Broadcast,
    [switch] $Resume,
    [string] $PriorityFee = '50000000',  # 0.05 gwei
    [string] $MaxFee = '200000000',      # 0.2 gwei
    # Overrides the env file's SEPOLIA_RPC_URL. Up to r5, WorkRecords' creation needed about
    # 51.2M gas under Glamsterdam, above the 50M eth_estimateGas cap of most public RPCs. In r6's
    # simulation (22 November 2026) the largest creation publicnode could estimate on its own was
    # the Renderer's, 37,690,858 gas; FederationRegistry, the largest in forge's Prague
    # simulation (7,606,183), and the others whose constructors read contracts of the same
    # deployment cannot be estimated before those exist.
    [string] $Rpc = ''
)
$ErrorActionPreference = 'Stop'
Import-Module $SignerModule -Force
$Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $Repo
foreach ($line in Get-Content -Encoding UTF8 (Join-Path $Repo $EnvFile)) {
    if ($line -match '^\s*([A-Z0-9_]+)=(.*)$') { Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2].Trim() }
}
if ($Rpc) { $env:SEPOLIA_RPC_URL = $Rpc }
$a = @('script', 'script/DeployCore.s.sol', '--rpc-url', $env:SEPOLIA_RPC_URL, '--sender', $env:DEPLOYER)
# Endpoints whose eth_estimateGas cap (50M) refused WorkRecords' creation up to r5 (about 51.2M
# under Sepolia's Glamsterdam pricing): a broadcast through one stopped partway. They are fine
# for the simulation. r6's measured creations are under the cap, but not all could be measured
# in advance, so the broadcast still uses an endpoint with a higher cap (-Rpc).
$EstimateCapped = @('ethereum-sepolia-rpc.publicnode.com')
if ($Broadcast) {
    $rpcHost = ([Uri]$env:SEPOLIA_RPC_URL).Host
    if ($EstimateCapped -contains $rpcHost) {
        throw ("$rpcHost caps eth_estimateGas at 50M, which refused the largest creation up to r5 (about " +
            "51.2M on Sepolia), so a broadcast could stop partway. Pass -Rpc with an endpoint whose estimate " +
            "cap is higher (script/README.md, section Sepolia).")
    }
    $a += @('--broadcast', '--slow', '--skip-simulation', '--priority-gas-price', $PriorityFee,
        '--with-gas-price', $MaxFee)
    if ($Resume) { $a += '--resume' }
    $out = Invoke-Signed $Account 'forge' $a
}
else {
    $out = Invoke-Tool 'forge' $a
}
if ($LASTEXITCODE -ne 0) { throw "forge script failed ($LASTEXITCODE)" }
if ($Log) { [IO.File]::WriteAllText($Log, $out, [Text.UTF8Encoding]::new($false)) }
$out

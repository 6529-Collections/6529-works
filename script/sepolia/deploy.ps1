<#
.SYNOPSIS
    Simulates (default) or broadcasts script/Deploy.s.sol for a Sepolia rehearsal, with the
    public inputs of an env file (config/sepolia-<instance>/deploy.env).

.DESCRIPTION
    No key or password is read here. Signing goes through a module the operator keeps outside
    the repository (-SignerModule), as for script/sepolia/flows.ps1: it must export
        Invoke-Signed <account> <program> <arguments[]>
    which runs the program with the account's signer options appended (for example
    `--keystore <file> --password-file <file>`), and
        Invoke-Tool <program> <arguments[]>
    which runs it without them. Both return the program's output.

    Sepolia runs Glamsterdam, which reprices state creation and which Foundry 1.7.1 cannot
    simulate: the broadcast skips forge's replay (--skip-simulation) and, with --slow, takes
    each transaction's gas limit from the node's eth_estimateGas just before sending it
    (script/README.md, step 10). The script itself, with every check, still runs first.

.EXAMPLE
    ./deploy.ps1 -SignerModule <path> -EnvFile config/sepolia-r4/deploy.env -Log sim.txt
    ./deploy.ps1 -SignerModule <path> -EnvFile config/sepolia-r4/deploy.env -Broadcast -Log run.txt
#>
param(
    [Parameter(Mandatory)] [string] $SignerModule,
    [Parameter(Mandatory)] [string] $EnvFile,
    [string] $Account = 'stream-deployer',
    [string] $Log = '',
    [switch] $Broadcast,
    [switch] $Resume,
    [string] $PriorityFee = '50000000',  # 0.05 gwei
    [string] $MaxFee = '200000000'       # 0.2 gwei
)
$ErrorActionPreference = 'Stop'
Import-Module $SignerModule -Force
$Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $Repo
foreach ($line in Get-Content -Encoding UTF8 (Join-Path $Repo $EnvFile)) {
    if ($line -match '^\s*([A-Z0-9_]+)=(.*)$') { Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2].Trim() }
}
$a = @('script', 'script/Deploy.s.sol', '--rpc-url', $env:SEPOLIA_RPC_URL, '--sender', $env:DEPLOYER)
if ($Broadcast) {
    $a += @('--broadcast', '--slow', '--skip-simulation', '--priority-gas-price', $PriorityFee,
        '--with-gas-price', $MaxFee)
    if ($Resume) { $a += '--resume' }
    $out = Invoke-Signed $Account 'forge' $a
}
else {
    $out = Invoke-Tool 'forge' $a
}
if ($Log) { [IO.File]::WriteAllText($Log, $out, [Text.UTF8Encoding]::new($false)) }
$out

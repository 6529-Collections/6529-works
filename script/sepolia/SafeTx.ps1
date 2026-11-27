<#
.SYNOPSIS
    The Safe transaction digest, computed locally, for script/sepolia/flows.ps1.

.DESCRIPTION
    Dot-source this file. It defines:

    Get-SafeTxDigest   the EIP-712 digest a Safe's owners sign for one transaction, computed
                       with `cast` from the fields alone (no RPC): the domain separator of the
                       Sepolia chain ID and the Safe's address, and the hash of the `SafeTx`
                       struct. Operation is a call (0); safeTxGas, baseGas and gasPrice are zero;
                       gasToken and refundReceiver are the zero address, as flows.ps1 sends them.
    Assert-SafeTxDigest  throws unless the digest computed here and the one the Safe answered
                       through the RPC (`getTransactionHash`) are the same 32 bytes.
    Assert-SepoliaChain  throws unless a chain ID is Sepolia's.

    The owners sign the digest computed here. An endpoint's answer is only compared with it, so
    a wrong answer stops the step instead of being signed. The two type hashes are those of
    Safe 1.3.0 and 1.4.1 (the same in both).

    No key or password is read here, and nothing is signed or sent.
#>

# keccak256("EIP712Domain(uint256 chainId,address verifyingContract)")
$SafeDomainTypehash = '0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218'
# keccak256("SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)")
$SafeTxTypehash = '0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8'
$SepoliaChainId = '11155111'
$SafeTxZero = '0x0000000000000000000000000000000000000000'

# Runs `cast` offline and returns its trimmed output; throws on a non-zero exit.
function Invoke-SafeTxCast([string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & cast @Arguments 2>&1; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    $text = (($out | ForEach-Object { "$_" }) -join "`n").Trim()
    if ($code -ne 0) { throw "cast $($Arguments[0]) failed ($code): $text" }
    return $text
}

function Assert-SepoliaChain([string]$ChainId) {
    if ($ChainId.Trim() -ne $SepoliaChainId) {
        throw "the RPC endpoint reports chain ID '$($ChainId.Trim())', not Sepolia ($SepoliaChainId): nothing is signed or sent"
    }
}

function Get-SafeTxDigest([string]$Safe, [string]$To, [string]$Value, [string]$Calldata, [string]$Nonce) {
    foreach ($a in @($Safe, $To)) {
        if ($a -notmatch '^0x[0-9a-fA-F]{40}$') { throw "not an address: '$a'" }
    }
    if ($Calldata -notmatch '^0x([0-9a-fA-F]{2})*$') { throw "not hex data: '$Calldata'" }
    foreach ($n in @($Value, $Nonce)) {
        if ($n -notmatch '^[0-9]+$') { throw "not a decimal number: '$n'" }
    }
    $domain = Invoke-SafeTxCast @('keccak', (Invoke-SafeTxCast @('abi-encode', 'f(bytes32,uint256,address)',
                $SafeDomainTypehash, $SepoliaChainId, $Safe)))
    $dataHash = Invoke-SafeTxCast @('keccak', $Calldata)
    $struct = Invoke-SafeTxCast @('keccak', (Invoke-SafeTxCast @('abi-encode',
                'f(bytes32,address,uint256,bytes32,uint8,uint256,uint256,uint256,address,address,uint256)',
                $SafeTxTypehash, $To, $Value, $dataHash, '0', '0', '0', '0', $SafeTxZero, $SafeTxZero, $Nonce)))
    $digest = Invoke-SafeTxCast @('keccak', (Invoke-SafeTxCast @('concat-hex', '0x1901', $domain, $struct)))
    if ($digest -notmatch '^0x[0-9a-f]{64}$') { throw "bad digest '$digest'" }
    return $digest
}

function Assert-SafeTxDigest([string]$Local, [string]$Remote) {
    if ($Local -notmatch '^0x[0-9a-fA-F]{64}$') { throw "bad local digest '$Local'" }
    if ($Local.ToLower() -ne $Remote.Trim().ToLower()) {
        throw "the Safe transaction hash the RPC endpoint answered ($($Remote.Trim())) is not the digest computed locally ($Local): nothing is signed"
    }
}

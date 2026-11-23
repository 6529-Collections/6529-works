// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title SplitVault
/// @notice The split wallet's code: a minimal vault that holds ETH and ERC-20s and moves them only
///         when its deployer, the split ledger, tells it to (ADR 0001 section 7). It keeps no
///         state and makes no decision; every rule lives in the permanent ledger. Written in raw
///         EVM bytecode so that a wallet is 66 bytes (a deployment costs the code of 66 bytes,
///         not of a full contract) and so that its address depends on these documented bytes,
///         never on a compiler version or metadata.
/// @dev Internal constants only, so nothing here is a linked library. No `delegatecall`, no
///      `selfdestruct`, no storage. The same vault in plain Solidity is
///      `test/economics/SplitVaultReference.sol`, several times the size compiled and so
///      several times the cost of each wallet's creation;
///      `test/economics/SplitVaultDifferential.t.sol` runs every call shape against both and
///      compares the outcome, return data, balances and logs.
///
///      Runtime (66 bytes; `LEDGER` is the 20-byte address of the deploying ledger):
///      ```
///      0x00 73 LEDGER      PUSH20 ledger
///      0x15 33 14          CALLER EQ
///      0x17 60 1f 57       JUMPI ledger            ; the ledger: execute its instruction
///      0x1a 36 60 36 57    CALLDATASIZE JUMPI fail ; anyone else with calldata: revert
///      0x1e 00             STOP                    ; anyone else, no calldata: accept ETH
///      0x1f 5b             ledger:
///      0x20 5f 5f          retSize 0, retOffset 0
///      0x22 60 40 36 03    size = CALLDATASIZE - 64
///      0x26 80 60 40 5f 37 CALLDATACOPY(0, 64, size)
///      0x2b 5f             argsOffset 0
///      0x2c 60 20 35       value  = CALLDATALOAD(32)
///      0x2f 5f 35          target = CALLDATALOAD(0)
///      0x31 5a f1          CALL(GAS, target, value, 0, size, 0, 0)
///      0x33 60 3a 57       JUMPI ok
///      0x36 5b 5f 5f fd    fail: REVERT(0, 0)
///      0x3a 5b 3d 5f 5f 3e ok: RETURNDATACOPY(0, 0, RETURNDATASIZE)
///      0x3f 3d 5f f3       RETURN(0, RETURNDATASIZE)
///      ```
///      An instruction is `abi.encodePacked(uint256(uint160(target)), value, data)`: the vault
///      calls `target` with `value` wei of its own and `data`, forwarding all its gas, and returns
///      the callee's return data, or reverts with no data if the call failed. The ledger sends
///      ETH as `(recipient, amount, "")` and an ERC-20 as `(token, 0, transfer(recipient,
///      amount))`, and checks the outcome itself.
///
///      Return data is copied whole (`RETURNDATACOPY(0, 0, RETURNDATASIZE)`), with no bound in
///      the vault; the ledger copies at most one word of what the vault returns and reads a
///      longer answer as a failure. So a callee that answers with a large return only makes its
///      own instruction fail or cost more: an ETH recipient (the payee's own account, or the
///      recipient the payee signed for) that answers with data fails that payee's release
///      (`ETHTransferFailed`), and an ERC-20 that does fails that token's releases from the
///      wallet (`TokenCallFailed`), as reverting would; a copy that exhausts the vault's gas
///      reverts the release with `BoundedCall.BoundedCallShortfall`. Nothing is recorded for a
///      failed release, and no other payee, asset or wallet is affected. Kept, rather than
///      bounded in the vault, because the vault's bytes are its address derivation, and a bound
///      would give no payee anything a callee cannot already take by reverting.
///
///      Anyone else's call with no calldata succeeds at a cost of 36 gas, so a vault accepts ETH
///      even within the 2,300-gas stipend of Solidity's `transfer`. Anyone else's call with
///      calldata reverts, as a contract without a fallback would, so a vault is not an ERC-721 or
///      ERC-1155 receiver and a token's "safe" transfer to it fails.
///
///      Init code (68 bytes, the same for every wallet, so a wallet's CREATE2 address depends only
///      on the ledger, the payee list and the salt): write `0x73 || CALLER` at memory 0 (shifted
///      into the top 21 bytes of the word), copy the 45 runtime bytes that follow the address
///      from the init code to memory 21, and return the 66 bytes.
///      ```
///      33 60 73 60 a0 1b 17 60 58 1b 5f 52   MSTORE(0, (0x73 << 160 | CALLER) << 88)
///      60 2d 60 17 60 15 39                  CODECOPY(21, 23, 45)
///      60 42 5f f3                           RETURN(0, 66)
///      ```
library SplitVault {
    /// @notice The init code every split wallet is created with.
    bytes internal constant INIT_CODE = hex"33607360a01b1760581b5f52602d601760153960425ff3"
        hex"3314601f573660365700" hex"5b5f5f6040360380" hex"60405f375f6020355f355af1"
        hex"603a575b5f5ffd5b3d5f5f3e3d5ff3";

    /// @notice The 45 runtime bytes after `PUSH20 ledger`, for checks that rebuild a wallet's
    ///         code: a wallet's runtime is `0x73 || ledger || RUNTIME_TAIL`.
    bytes internal constant RUNTIME_TAIL = hex"3314601f573660365700" hex"5b5f5f6040360380"
        hex"60405f375f6020355f355af1" hex"603a575b5f5ffd5b3d5f5f3e3d5ff3";
}

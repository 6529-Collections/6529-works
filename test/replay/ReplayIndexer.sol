// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, Vm } from "forge-std/Test.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { SplitVault } from "src/economics/SplitVault.sol";

/// @notice The shared part of the reference indexers in `test/replay/`. Each indexer rebuilds one
///         permanent contract's consensus-relevant state from that contract's own logs, in log
///         order, and never calls it; `assertMatches` then compares every public view the logs
///         should explain with the live contract and fails on the first difference (the 6529
///         network's consensus reads logs only, ADR 0007, WS-44). They are the test-side model of
///         what `docs/integrators/events-and-indexing.md` tells an indexer author to do.
/// @dev An unknown topic0 from the watched contract reverts, so an event added without replay
///      coverage fails the suite the first time it is emitted; `seen` counts every topic0 applied,
///      for the suites' check that every event of the contract's ABI was replayed at least once.
///      A log carries no timestamp in Foundry, so the caller passes the block timestamp of the
///      logs it applies, as a real indexer reads it from the log's block.
abstract contract ReplayIndexer is Test {
    /// @notice The contract this indexer rebuilds; logs of every other emitter are ignored.
    address public immutable target;
    /// @notice How many logs with each topic0 the indexer applied.
    mapping(bytes32 topic0 => uint256 count) public seen;
    /// @dev The block timestamp of the log being applied.
    uint256 internal _now;

    constructor(address target_) {
        target = target_;
    }

    /// @notice Applies one log if `target` emitted it.
    function applyLog(Vm.Log memory log, uint256 timestamp) external {
        if (log.emitter != target) return;
        _now = timestamp;
        ++seen[log.topics[0]];
        _apply(log);
    }

    /// @notice Applies every log `target` emitted, in order.
    function ingest(Vm.Log[] memory logs, uint256 timestamp) external {
        _now = timestamp;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != target) continue;
            ++seen[logs[i].topics[0]];
            _apply(logs[i]);
        }
    }

    /// @notice Compares every rebuilt value with the live contract's view of it.
    function assertMatches() external view virtual;

    function _apply(Vm.Log memory log) internal virtual;

    function _unknown(bytes32 topic0) internal pure {
        revert(string.concat("indexer: unknown event ", vm.toString(topic0)));
    }

    function _addr(bytes32 topic) internal pure returns (address) {
        return address(uint160(uint256(topic)));
    }

    /// @dev The split wallet `ledger` deploys for `payees` and `salt`: CREATE2 arithmetic on
    ///      published constants (`SplitLedger.walletFor`'s formula), not a call.
    function _walletFor(address ledger, ISplitWallet.Payee[] memory payees, bytes32 salt)
        internal
        pure
        returns (address)
    {
        bytes32 walletSalt = keccak256(abi.encode(keccak256(abi.encode(payees)), salt));
        return Create2.computeAddress(walletSalt, keccak256(SplitVault.INIT_CODE), ledger);
    }

    /// @dev A work's royalty receiver (ECO-7): the seller wallet at a zero fee share, else the
    ///      salt-zero wallet of the canonical royalty payee list.
    function _royaltyReceiver(address ledger, address seller, address feeRecipient, uint32 share)
        internal
        pure
        returns (address)
    {
        if (share == 0) return seller;
        return _walletFor(ledger, Splits.royaltyPayees(seller, feeRecipient, share), bytes32(0));
    }
}

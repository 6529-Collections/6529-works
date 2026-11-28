// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";
import { StreamHashing } from "src/interfaces/types/StreamHashing.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Helpers shared by the record, content, credit and identity suites on the real stack:
///         governed calls expected to revert, sold works, consents, renunciations, consolidation.
abstract contract RecordFlowsBase is IntegrationBase {
    /// @dev The 6529 delegation contract's "all collections" address and consolidation use case.
    address internal constant ALL_COLLECTIONS = 0x8888888888888888888888888888888888888888;
    uint256 internal constant CONSOLIDATION = 999;

    /// @dev Runs a governed call as `caller` like `_govern` and expects the target to revert with
    ///      `reason` (the scheduled path executes after the role's delay, as `_govern` does).
    function _governExpectRevert(
        address caller,
        address target,
        bytes memory data,
        bytes memory reason
    ) internal {
        (bool immediate, uint32 delay) = manager.canCall(caller, target, bytes4(data));
        if (immediate) {
            vm.prank(caller);
            (bool ok, bytes memory returned) = target.call(data);
            assertFalse(ok, "the governed call did not revert");
            assertEq(returned, reason, "the governed call's revert reason");
            return;
        }
        require(delay != 0, "caller has no role for this selector");
        vm.prank(caller);
        manager.schedule(target, data, 0);
        vm.warp(block.timestamp + delay);
        vm.prank(caller);
        vm.expectRevert(reason);
        manager.execute(target, data);
        // A refused execution leaves its schedule standing: the caller withdraws it.
        vm.prank(caller);
        manager.cancel(caller, target, data);
    }

    /// @dev Publishes `works`, starts item `index` through `SaleStarter` (vaults and record),
    ///      takes one bid of `price` from `bidder` and settles at the end.
    function _soldAndOpen(
        bytes32 root,
        Work[] memory works,
        uint256 index,
        address bidder,
        uint256 price
    ) internal returns (uint256 tokenId) {
        uint256 saleId;
        (saleId, tokenId) = _startAndOpen(root, works, index);
        _ethBid(saleId, bidder, price);
        _settleAtEnd(saleId);
    }

    function _state(uint256 tokenId) internal view returns (bytes32) {
        return rules.workStateHash(address(stream), tokenId);
    }

    /// @dev One relicense consent per signer, in order, bound to the current state.
    function _relicenseSigs(
        uint256 tokenId,
        License memory next,
        address[] memory signers,
        uint64 deadline
    ) internal view returns (bytes32 state, bytes[] memory sigs) {
        state = _state(tokenId);
        bytes32 digest = _typedDigest(
            address(rules),
            keccak256(
                abi.encode(
                    rules.RELICENSE_TYPEHASH(),
                    address(stream),
                    tokenId,
                    StreamHashing.licenseKey(next.spdxId),
                    next.textFileId,
                    state,
                    deadline
                )
            )
        );
        sigs = new bytes[](signers.length);
        for (uint256 i; i < signers.length; ++i) {
            sigs[i] = abi.encodePacked(signers[i], _sign(signers[i], digest));
        }
    }

    /// @dev The network's relicense call for `w` with every signer's consent.
    function _relicenseCall(
        uint256 tokenId,
        Work memory w,
        License memory next,
        address[] memory signers
    ) internal view returns (bytes memory) {
        uint64 deadline = uint64(block.timestamp + 30 days);
        (bytes32 state, bytes[] memory sigs) = _relicenseSigs(tokenId, next, signers, deadline);
        return abi.encodeCall(
            rules.relicense, (address(stream), tokenId, next, w.item, state, deadline, sigs)
        );
    }

    /// @dev The lead artist's (`wallet` of its account) signed renunciation of `powers`.
    function _renounceArgs(uint256 tokenId, uint16 powers, address wallet)
        internal
        view
        returns (bytes32 state, uint64 deadline, bytes memory proof)
    {
        state = _state(tokenId);
        deadline = uint64(block.timestamp + 30 days);
        bytes32 digest = _typedDigest(
            address(rules),
            keccak256(
                abi.encode(
                    rules.RENOUNCE_POWERS_TYPEHASH(),
                    address(stream),
                    tokenId,
                    powers,
                    state,
                    deadline
                )
            )
        );
        proof = abi.encodePacked(wallet, _sign(wallet, digest));
    }

    /// @dev `_withCollaborator` with the two payees in the ledger's canonical order (ascending
    ///      artist ID).
    function _withCollaboratorSorted(Work memory w, address collaborator, uint32 share)
        internal
        pure
        returns (Work memory)
    {
        w = _withCollaborator(w, collaborator, share);
        if (w.item.payees[0].artistId > w.item.payees[1].artistId) {
            (w.item.payees[0], w.item.payees[1]) = (w.item.payees[1], w.item.payees[0]);
        }
        return w;
    }

    function _list(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _list(address a, address b) internal pure returns (address[] memory list) {
        list = new address[](2);
        (list[0], list[1]) = (a, b);
    }

    /// @dev `a` and `b` register each other as consolidated (both directions, all collections).
    function _consolidate(address a, address b) internal {
        vm.prank(a);
        delegation.registerDelegationAddress(
            ALL_COLLECTIONS, b, type(uint64).max, CONSOLIDATION, true, 0
        );
        vm.prank(b);
        delegation.registerDelegationAddress(
            ALL_COLLECTIONS, a, type(uint64).max, CONSOLIDATION, true, 0
        );
    }

    /// @dev The account's identity with another root and payout.
    function _identity(uint256 artistId, address root, address payout)
        internal
        view
        returns (ArtistIdentity memory id)
    {
        (id,) = accounts.artist(artistId);
        (id.root, id.payout) = (root, payout);
    }

    /// @dev Moves the clock by `seconds_`.
    function _wait(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
    }
}

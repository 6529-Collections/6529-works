// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Splits } from "src/economics/Splits.sol";
import { MintFacts } from "src/interfaces/core/CoreTypes.sol";
import { ITerms } from "src/interfaces/core/ITerms.sol";
import { RulesFixture } from "../records/RulesFixture.sol";

/// @notice The fee share of an edition's royalties through `StreamTerms` (ED-29): lowered with
///         its master's or on its own, and never raised.
contract StreamTermsRulesTest is RulesFixture {
    address internal constant SELLER = address(0x5E11);
    uint24 internal constant RATE = 5_000;

    /// @dev The split ledger's network fee vault: the one fee party `lowerFeeShare` accepts.
    address internal fee;
    address internal s;
    address internal e;

    function setUp() public override {
        super.setUp();
        s = address(stream);
        e = address(editions);
        fee = ledger.network();
    }

    /// @dev The royalty receiver of (SELLER, fee vault) at `share`, deployed.
    function _vault(uint32 share) internal returns (address) {
        return ledger.createWallet(Splits.royaltyPayees(SELLER, fee, share), 0);
    }

    /// @dev A master whose royalty receiver is the vault at `masterShare`, and its edition with
    ///      the receiver `editionReceiver`.
    function _masterAndEdition(uint256 n, uint32 masterShare, address editionReceiver)
        internal
        returns (uint256 id)
    {
        MintFacts memory f;
        f.itemHash = keccak256(abi.encode("item", n));
        f.contentHash = keccak256(abi.encode("content", n));
        f.artistId = uint160(artist);
        f.collectionId = 1;
        f.royaltyReceiver = _vault(masterShare);
        f.royaltyRate = RATE;
        f.seller = SELLER;
        id = sale.mint(s, f);
        sale.createEdition(e, id, 0, editionReceiver, RATE);
    }

    /// ED-29: the network's call through the TERMS module lowers an edition's fee share; the
    /// same share, a higher one, and a way back up after a lowering are refused with
    /// `InvalidFeeShare`, and nobody but the network may call.
    function test_LowerFeeShare_AnEditionsShareGoesDownAndNeverUp() public {
        address start = _vault(8_000);
        uint256 id = _masterAndEdition(1, 10_000, start);
        address masterReceiver = stream.workOf(id).royaltyReceiver;

        vm.expectRevert(ITerms.InvalidFeeShare.selector);
        streamTerms.lowerFeeShare(e, id, SELLER, fee, 8_000, 8_000);
        vm.expectRevert(ITerms.InvalidFeeShare.selector);
        streamTerms.lowerFeeShare(e, id, SELLER, fee, 8_000, 8_001);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        streamTerms.lowerFeeShare(e, id, SELLER, fee, 8_000, 2_000);
        assertEq(editions.editionOf(id).royaltyReceiver, start);

        address lowered = ledger.walletFor(Splits.royaltyPayees(SELLER, fee, 2_000), 0);
        vm.expectEmit(address(streamTerms));
        emit ITerms.FeeShareLowered(e, id, 8_000, 2_000, lowered);
        streamTerms.lowerFeeShare(e, id, SELLER, fee, 8_000, 2_000);
        assertEq(editions.editionOf(id).royaltyReceiver, lowered);
        assertEq(editions.editionOf(id).royaltyRate, RATE);
        assertEq(stream.workOf(id).royaltyReceiver, masterReceiver, "the master keeps its own");

        // No way back up: neither from the share in force nor from the one it replaced.
        vm.expectRevert(ITerms.InvalidFeeShare.selector);
        streamTerms.lowerFeeShare(e, id, SELLER, fee, 2_000, 8_000);
        vm.expectRevert(ITerms.InvalidFeeShare.selector);
        streamTerms.lowerFeeShare(e, id, SELLER, fee, 8_000, 7_999);
        assertEq(editions.editionOf(id).royaltyReceiver, lowered);
    }

    /// ED-29: an edition that shares its master's receiver is lowered in the same call as its
    /// master, to the same receiver.
    function test_LowerFeeShare_AnEditionOnItsMastersReceiverIsLoweredWithIt() public {
        uint256 id = _masterAndEdition(1, 10_000, _vault(10_000));
        assertEq(editions.editionOf(id).royaltyReceiver, stream.workOf(id).royaltyReceiver);
        address lowered = ledger.walletFor(Splits.royaltyPayees(SELLER, fee, 3_000), 0);
        streamTerms.lowerFeeShare(s, id, SELLER, fee, 10_000, 3_000);
        assertEq(stream.workOf(id).royaltyReceiver, lowered);
        assertEq(editions.editionOf(id).royaltyReceiver, lowered);
        vm.expectRevert(ITerms.InvalidFeeShare.selector);
        streamTerms.lowerFeeShare(e, id, SELLER, fee, 3_000, 10_000);
    }
}

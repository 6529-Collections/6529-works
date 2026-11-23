// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { Splits } from "src/economics/Splits.sol";
import { MintFacts, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IDirectory } from "src/interfaces/core/IDirectory.sol";
import { ITerms } from "src/interfaces/core/ITerms.sol";
import { StreamTerms } from "src/terms/StreamTerms.sol";
import { Stream6529 } from "src/core/Stream6529.sol";
import { StreamEditions6529 } from "src/core/StreamEditions6529.sol";
import { HostileModule } from "../mocks/core/CoreMocks.sol";
import { FeeGate } from "../mocks/records/RulesMocks.sol";
import { RevertingGate } from "../mocks/terms/TermsMocks.sol";
import { RulesFixture } from "../records/RulesFixture.sol";

/// @notice `StreamTerms`, the TERMS module: rates only through the RECORDS module, the
///         network's share only lowered, the receiver always a deployed vault (or the seller).
contract StreamTermsTest is RulesFixture {
    address internal constant SELLER = address(0x5E11);
    /// @dev The split ledger's network fee vault: the one fee party `lowerFeeShare` accepts.
    address internal FEE;
    address internal s;

    function setUp() public override {
        super.setUp();
        s = address(stream);
        FEE = ledger.network();
    }

    /// @dev The royalty receiver of (SELLER, FEE) at `share`, deployed.
    function _vault(uint32 share) internal returns (address) {
        if (share == 0) return SELLER;
        return ledger.createWallet(Splits.royaltyPayees(SELLER, FEE, share), 0);
    }

    function _mintAt(Stream6529 token, uint256 n, uint32 share) internal returns (uint256) {
        MintFacts memory f;
        f.itemHash = keccak256(abi.encode("item", n));
        f.contentHash = keccak256(abi.encode("content", n));
        f.artistId = uint160(artist);
        f.collectionId = 1;
        f.royaltyReceiver = _vault(share);
        f.royaltyRate = 5_000;
        f.seller = SELLER;
        return sale.mint(address(token), f);
    }

    // ------------------------------------------------------------- the RECORDS module

    function test_SetRoyaltyRate_OnlyTheTokensRecordsModule() public {
        uint256 id = _mintAt(stream, 1, 10_000);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ITerms.NotRecordsModule.selector, s, stranger));
        streamTerms.setRoyaltyRate(s, id, 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ITerms.NotRecordsModule.selector, s, stranger));
        streamTerms.lockRoyaltyRate(s, id);
        address receiver = stream.workOf(id).royaltyReceiver;
        vm.prank(address(rules));
        streamTerms.setRoyaltyRate(s, id, 7_000);
        assertEq(stream.workOf(id).royaltyRate, 7_000);
        assertEq(stream.workOf(id).royaltyReceiver, receiver);
        vm.prank(address(rules));
        streamTerms.lockRoyaltyRate(s, id);
        assertTrue(stream.workOf(id).royaltyRateLocked);
    }

    function test_SetRoyaltyRate_TheEditionFollowsWithItsOwnReceiver() public {
        uint256 id = _mintAt(stream, 1, 10_000);
        uint256 lone = _mintAt(stream, 2, 10_000);
        sale.createEdition(address(editions), id, 0, address(0xED), 5_000);
        vm.startPrank(address(rules));
        streamTerms.setRoyaltyRate(s, id, 1_234);
        // A master with no edition changes alone.
        streamTerms.setRoyaltyRate(s, lone, 4_321);
        vm.stopPrank();
        assertEq(editions.editionOf(id).royaltyRate, 1_234);
        assertEq(editions.editionOf(id).royaltyReceiver, address(0xED));
        assertEq(editions.editionOf(lone).minter, address(0));
    }

    /// @dev A hostile module that is not the token's RECORDS module changes no rate.
    function test_Hostile_AnotherModuleCannotSetARate() public {
        uint256 id = _mintAt(stream, 1, 10_000);
        HostileModule hostile = new HostileModule();
        (bool ok,) = hostile.exec(
            address(streamTerms), abi.encodeCall(ITerms.setRoyaltyRate, (s, id, 100_000))
        );
        assertFalse(ok);
        (ok,) = hostile.exec(address(streamTerms), abi.encodeCall(ITerms.lockRoyaltyRate, (s, id)));
        assertFalse(ok);
        (ok,) = hostile.exec(
            address(streamTerms),
            abi.encodeCall(ITerms.lowerFeeShare, (s, id, SELLER, FEE, 10_000, 0))
        );
        assertFalse(ok);
        assertEq(stream.workOf(id).royaltyRate, 5_000);
        assertFalse(stream.workOf(id).royaltyRateLocked);
    }

    // ------------------------------------------------------------------ lowerFeeShare

    function test_LowerFeeShare_DeploysTheNewVaultFirstAndKeepsTheRate() public {
        uint256 id = _mintAt(stream, 1, 10_000);
        address expected = ledger.walletFor(Splits.royaltyPayees(SELLER, FEE, 4_000), 0);
        assertEq(expected.code.length, 0);
        vm.expectEmit(address(streamTerms));
        emit ITerms.FeeShareLowered(s, id, 10_000, 4_000, expected);
        streamTerms.lowerFeeShare(s, id, SELLER, FEE, 10_000, 4_000);
        assertEq(stream.workOf(id).royaltyReceiver, expected);
        assertGt(expected.code.length, 0);
        assertTrue(ledger.isWallet(expected));
        assertEq(stream.workOf(id).royaltyRate, 5_000);
        // To zero: the seller.
        streamTerms.lowerFeeShare(s, id, SELLER, FEE, 4_000, 0);
        assertEq(stream.workOf(id).royaltyReceiver, SELLER);
    }

    function test_LowerFeeShare_TheNetworkOnlyLowerOnlySelfVerifying() public {
        uint256 id = _mintAt(stream, 1, 10_000);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        streamTerms.lowerFeeShare(s, id, SELLER, FEE, 10_000, 1);
        vm.expectRevert(ITerms.InvalidFeeShare.selector);
        streamTerms.lowerFeeShare(s, id, SELLER, FEE, 10_000, 10_000);
        vm.expectRevert(ITerms.InvalidFeeShare.selector);
        streamTerms.lowerFeeShare(s, id, SELLER, FEE, 10_000, 20_000);
        // Stated terms that do not derive the stored receiver.
        vm.expectRevert(ITerms.InvalidFeeShare.selector);
        streamTerms.lowerFeeShare(s, id, SELLER, FEE, 20_000, 10_000);
        vm.expectRevert(ITerms.InvalidFeeShare.selector);
        streamTerms.lowerFeeShare(s, id, address(0xBAD), FEE, 10_000, 1);
        vm.expectRevert(ITerms.InvalidFeeShare.selector);
        streamTerms.lowerFeeShare(s, id, SELLER, address(0xBAD), 10_000, 1);
    }

    /// @dev Whatever the network states, the share only goes down and the receiver is always a
    ///      deployed vault of the stated parties, or the seller.
    function testFuzz_LowerFeeShare_LowerOnlyNeverAnUndeployedReceiver(uint32 current, uint32 next)
        public
    {
        current = uint32(bound(current, 1, 99_999));
        next = uint32(bound(next, 0, 100_000));
        uint256 id = _mintAt(stream, 1, current);
        address before = stream.workOf(id).royaltyReceiver;
        if (next >= current) {
            vm.expectRevert(ITerms.InvalidFeeShare.selector);
            streamTerms.lowerFeeShare(s, id, SELLER, FEE, current, next);
            assertEq(stream.workOf(id).royaltyReceiver, before);
            return;
        }
        streamTerms.lowerFeeShare(s, id, SELLER, FEE, current, next);
        address receiver = stream.workOf(id).royaltyReceiver;
        if (next == 0) assertEq(receiver, SELLER);
        else assertGt(receiver.code.length, 0);
        // The old terms no longer derive the receiver: no second lowering from them.
        vm.expectRevert(ITerms.InvalidFeeShare.selector);
        streamTerms.lowerFeeShare(s, id, SELLER, FEE, current, 0);
    }

    /// @dev The same vault, stated the other way round (the seller as the fee party, at the
    ///      complementary share), would lower the seller's share and so raise the network's. It
    ///      is refused for a work and for an edition; the ordinary lowering then still works.
    function test_LowerFeeShare_ThePartiesStatedTheOtherWayRoundAreRefused() public {
        uint256 id = _mintAt(stream, 1, 10_000);
        address vault = stream.workOf(id).royaltyReceiver;
        // The swapped statement derives the very same vault.
        assertEq(ledger.walletFor(Splits.royaltyPayees(FEE, SELLER, 90_000), 0), vault);
        vm.expectRevert(ITerms.InvalidFeeShare.selector);
        streamTerms.lowerFeeShare(s, id, FEE, SELLER, 90_000, 50_000);
        vm.expectRevert(ITerms.InvalidFeeShare.selector);
        streamTerms.lowerFeeShare(s, id, FEE, SELLER, 90_000, 0);
        assertEq(stream.workOf(id).royaltyReceiver, vault);
        sale.createEdition(address(editions), id, 0, _vault(8_000), 5_000);
        vm.expectRevert(ITerms.InvalidFeeShare.selector);
        streamTerms.lowerFeeShare(address(editions), id, FEE, SELLER, 92_000, 10_000);
        assertEq(editions.editionOf(id).royaltyReceiver, _vault(8_000));
        streamTerms.lowerFeeShare(s, id, SELLER, FEE, 10_000, 4_000);
        assertEq(
            stream.workOf(id).royaltyReceiver,
            ledger.walletFor(Splits.royaltyPayees(SELLER, FEE, 4_000), 0)
        );
    }

    /// @dev Whatever is stated, the network fee vault's share of the stored receiver never
    ///      rises: a call either reverts or leaves a vault of (other party, fee vault) at a
    ///      lower share for the fee vault.
    function testFuzz_LowerFeeShare_TheFeeVaultsShareNeverRises(
        bool swapped,
        uint32 stated,
        uint32 next
    ) public {
        uint256 id = _mintAt(stream, 1, 30_000);
        // One run in three states the share that derives the stored vault under its labels.
        stated = stated % 3 == 0 ? (swapped ? 70_000 : 30_000) : uint32(bound(stated, 1, 99_999));
        next = uint32(bound(next, 0, 99_999));
        (address a, address b) = swapped ? (FEE, SELLER) : (SELLER, FEE);
        try streamTerms.lowerFeeShare(s, id, a, b, stated, next) {
            assertFalse(swapped, "only the fee vault's share is lowered");
            assertEq(stated, 30_000);
            assertLt(next, 30_000);
            assertEq(stream.workOf(id).royaltyReceiver, _vault(next));
        } catch {
            assertEq(stream.workOf(id).royaltyReceiver, _vault(30_000));
        }
    }

    function test_LowerFeeShare_TheEditionMovesWhenItSharesTheReceiver() public {
        uint256 id = _mintAt(stream, 1, 10_000);
        address oldVault = stream.workOf(id).royaltyReceiver;
        sale.createEdition(address(editions), id, 0, oldVault, 5_000);
        streamTerms.lowerFeeShare(s, id, SELLER, FEE, 10_000, 3_000);
        assertEq(editions.editionOf(id).royaltyReceiver, stream.workOf(id).royaltyReceiver);
        // An edition with its own receiver stays, and is lowered by naming the editions.
        uint256 other = _mintAt(stream, 2, 10_000);
        address editionVault = _vault(8_000);
        sale.createEdition(address(editions), other, 0, editionVault, 5_000);
        streamTerms.lowerFeeShare(s, other, SELLER, FEE, 10_000, 3_000);
        assertEq(editions.editionOf(other).royaltyReceiver, editionVault);
        streamTerms.lowerFeeShare(address(editions), other, SELLER, FEE, 8_000, 2_000);
        address lowered = editions.editionOf(other).royaltyReceiver;
        assertEq(lowered, ledger.walletFor(Splits.royaltyPayees(SELLER, FEE, 2_000), 0));
        assertGt(lowered.code.length, 0);
        assertEq(editions.editionOf(other).royaltyRate, 5_000);
        vm.expectRevert(
            abi.encodeWithSelector(StreamTerms.UnknownWork.selector, address(editions), 3)
        );
        streamTerms.lowerFeeShare(address(editions), 3, SELLER, FEE, 8_000, 2_000);
    }

    function test_LowerFeeShare_AIndependentTokenNeverGoesAboveTheRegistrysShare() public {
        _install(address(bare), Slots.TERMS, address(streamTerms));
        FeeGate fees = new FeeGate();
        directory.setModuleDelay(0);
        directory.proposeModule(Slots.INDEPENDENT_STREAM, address(fees));
        directory.activateModule(Slots.INDEPENDENT_STREAM);
        uint256 id = _mintAt(bare, 1, 10_000);
        fees.setFeeShare(address(bare), 5_000);
        vm.expectRevert(ITerms.InvalidFeeShare.selector);
        streamTerms.lowerFeeShare(address(bare), id, SELLER, FEE, 10_000, 6_000);
        streamTerms.lowerFeeShare(address(bare), id, SELLER, FEE, 10_000, 5_000);
        assertEq(
            bare.workOf(id).royaltyReceiver,
            ledger.walletFor(Splits.royaltyPayees(SELLER, FEE, 5_000), 0)
        );
        // 6529 Stream itself is not bound by the Independent Stream module.
        uint256 own = _mintAt(stream, 2, 10_000);
        streamTerms.lowerFeeShare(s, own, SELLER, FEE, 10_000, 9_000);
    }

    // ---------------------------------------------------------------------- editions

    function test_SetEditions_TheNetworkPairsAMatchingEditionsContract() public {
        assertEq(streamTerms.editionsOf(s), address(editions));
        assertEq(streamTerms.tokenOfEditions(address(editions)), s);
        StreamEditions6529 next = new StreamEditions6529(
            address(manager), s, marketOwner, address(terms), new address[](0)
        );
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        streamTerms.setEditions(s, address(next));
        vm.expectRevert(
            abi.encodeWithSelector(
                StreamTerms.InvalidEditions.selector, address(bare), address(next)
            )
        );
        streamTerms.setEditions(address(bare), address(next));
        vm.expectRevert(
            abi.encodeWithSelector(StreamTerms.InvalidEditions.selector, s, address(editions))
        );
        streamTerms.setEditions(s, address(editions));
        vm.expectEmit(address(streamTerms));
        emit StreamTerms.EditionsSet(s, address(next));
        streamTerms.setEditions(s, address(next));
        assertEq(streamTerms.editionsOf(s), address(next));
        assertEq(streamTerms.tokenOfEditions(address(editions)), address(0));
    }

    function test_Wiring() public view {
        assertEq(streamTerms.splitFactory(), address(ledger));
        assertEq(streamTerms.stream(), s);
        assertEq(streamTerms.directory(), address(directory));
        assertEq(IDirectory(address(directory)).moduleOf(Slots.ACCOUNTS), address(signers));
    }

    // ---------------------------------------------------- pinned by mutation testing

    function test_Constructor_WithoutEditionsPairsNothing() public {
        StreamTerms lone = new StreamTerms(
            address(manager), address(ledger), s, address(0), address(directory)
        );
        assertEq(lone.editionsOf(s), address(0));
        assertEq(lone.tokenOfEditions(address(editions)), address(0));
    }

    function test_LowerFeeShare_NeedsALiveWork() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 99));
        streamTerms.lowerFeeShare(s, 99, SELLER, FEE, 10_000, 1);
    }

    /// @dev The stated current terms are only compared with the stored receiver: a vault that
    ///      was never deployed stays undeployed; only the new one is created.
    function test_LowerFeeShare_NeverDeploysTheOldVault() public {
        address old = ledger.walletFor(Splits.royaltyPayees(SELLER, FEE, 10_000), 0);
        MintFacts memory f;
        f.itemHash = keccak256("item");
        f.contentHash = keccak256("content");
        f.artistId = uint160(artist);
        f.collectionId = 1;
        f.royaltyReceiver = old;
        f.royaltyRate = 5_000;
        f.seller = SELLER;
        uint256 id = sale.mint(s, f);
        streamTerms.lowerFeeShare(s, id, SELLER, FEE, 10_000, 4_000);
        assertEq(old.code.length, 0);
        assertGt(stream.workOf(id).royaltyReceiver.code.length, 0);
    }

    /// @dev A pairing the network set here is answered without the Independent Stream module,
    ///      so 6529 Stream, its editions and every pair set here keep working while that
    ///      module is down.
    function test_Pairing_APairSetHereNeverAsksTheIndependentStreamModule() public {
        uint256 id = _mintAt(stream, 1, 10_000);
        sale.createEdition(address(editions), id, 0, _vault(8_000), 5_000);
        StreamEditions6529 bareEditions = new StreamEditions6529(
            address(manager), address(bare), marketOwner, address(terms), new address[](0)
        );
        streamTerms.setEditions(address(bare), address(bareEditions));
        directory.setModuleDelay(0);
        directory.proposeModule(Slots.INDEPENDENT_STREAM, address(new RevertingGate()));
        directory.activateModule(Slots.INDEPENDENT_STREAM);
        assertEq(streamTerms.editionsOf(s), address(editions));
        assertEq(streamTerms.tokenOfEditions(address(editions)), s);
        assertEq(streamTerms.tokenOfEditions(s), address(0));
        assertEq(streamTerms.editionsOf(address(bare)), address(bareEditions));
        assertEq(streamTerms.tokenOfEditions(address(bareEditions)), address(bare));
        streamTerms.lowerFeeShare(address(editions), id, SELLER, FEE, 8_000, 2_000);
        assertEq(
            editions.editionOf(id).royaltyReceiver,
            ledger.walletFor(Splits.royaltyPayees(SELLER, FEE, 2_000), 0)
        );
    }

    function test_Pairing_AnEmptyIndependentStreamSlotListsNoPair() public {
        directory.removeModule(Slots.INDEPENDENT_STREAM);
        assertEq(streamTerms.editionsOf(address(bare)), address(0));
        assertEq(streamTerms.tokenOfEditions(address(bare)), address(0));
    }
}

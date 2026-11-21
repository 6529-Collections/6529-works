// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { EditionsAdapterMock } from "../mocks/editions/EditionsMocks.sol";
import { EditionsBase } from "./EditionsBase.sol";
import { EditionsHandler } from "./EditionsHandler.sol";
import { HandlerReach } from "../helpers/HandlerReach.sol";

/// @notice Stateful invariants of 6529 Stream Editions over three editions: one capped at 20,
///         one uncapped, and one capped at 30, minted and sealed through two uniform-auction
///         adapters that governance removes and re-admits (each edition binds to the first that
///         mints it) and probed by an admitted adapter of the wrong sale kind.
contract EditionsInvariantTest is StdInvariant, EditionsBase {
    EditionsHandler internal handler;
    uint256[] internal ids;
    bytes32[] internal contentHashes;
    address[] internal royaltyReceivers;
    uint256[] internal royaltyAmounts;

    function setUp() public override {
        super.setUp();
        PackageItem[] memory items = new PackageItem[](3);
        items[0] = _item(20);
        items[1] = _item(0);
        items[2] = _item(30);
        for (uint256 i; i < items.length; ++i) {
            uint256 id = _create(items[i]);
            ids.push(id);
            contentHashes.push(items[i].contentHash);
            (address receiver, uint256 amount) = editions.royaltyInfo(id, 1 ether);
            royaltyReceivers.push(receiver);
            royaltyAmounts.push(amount);
        }
        EditionsAdapterMock wrongKind = new EditionsAdapterMock(SaleKind.ENGLISH_AUCTION);
        vm.prank(governor);
        editions.setAdmittedMinter(address(wrongKind), true);
        handler = new EditionsHandler(
            editions, stream, adapter, secondAdapter, wrongKind, governor, ids, items
        );

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = EditionsHandler.buy.selector;
        selectors[1] = EditionsHandler.buy.selector; // mints twice as often
        selectors[2] = EditionsHandler.buyWithWrongKind.selector;
        selectors[3] = EditionsHandler.mintAsOutsider.selector;
        selectors[4] = EditionsHandler.burnFromCustody.selector;
        selectors[5] = EditionsHandler.transfer.selector;
        selectors[6] = EditionsHandler.warp.selector;
        selectors[7] = EditionsHandler.recreate.selector;
        selectors[8] = EditionsHandler.moveMaster.selector;
        selectors[9] = EditionsHandler.seal.selector;
        selectors[10] = EditionsHandler.toggleAdmission.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// @notice Every mint matched the model: within the creator cap, from the edition's bound
    ///         adapter, of the uniform-auction kind, by an admitted minter only; and no copy was
    ///         accepted beyond the cap or from another adapter.
    function invariant_MintsFollowEditionTerms() public view {
        assertEq(handler.unexpected(), 0, "an outcome differed from the edition terms");
        assertEq(handler.overCapMints(), 0, "a copy was minted beyond the cap");
        assertEq(handler.unboundMints(), 0, "a copy was minted by an unbound adapter");
        assertEq(handler.removedUnsealedMints(), 0, "a removed adapter minted an unsealed edition");
    }

    /// @notice ED-25: once sealed, an edition's supply never exceeds the sealed count, its
    ///         maximum is that count, and it stays sealed; before the seal only the bound adapter
    ///         minted (checked per call by `unboundMints` and `unexpected`).
    function invariant_SealedSupplyNeverExceedsTheSealedCount() public view {
        assertEq(handler.overSealMints(), 0, "a copy was minted past the seal");
        for (uint256 i; i < ids.length; ++i) {
            IEditions.Edition memory e = editions.edition(ids[i]);
            assertEq(e.supplySealed, handler.ghostSealed(ids[i]), "seal flag");
            assertLe(e.minted, e.maxSupply, "minted within the maximum");
            if (e.supplySealed) {
                assertEq(e.maxSupply, handler.ghostSealCount(ids[i]), "sealed count");
                assertLe(e.minted, handler.ghostSealCount(ids[i]), "sealed supply");
            }
        }
    }

    /// @notice Supply: `minted` counts every copy ever minted, never exceeds the cap, and the
    ///         holders' balances equal minted minus burned.
    function invariant_SupplyAccounting() public view {
        address[] memory holders = handler.holders();
        for (uint256 i; i < ids.length; ++i) {
            IEditions.Edition memory e = editions.edition(ids[i]);
            assertEq(e.minted, handler.ghostMinted(ids[i]), "minted counter");
            if (e.terms.maxCount != 0) assertLe(e.minted, e.terms.maxCount, "creator cap");
            uint256 sum;
            for (uint256 h; h < holders.length; ++h) {
                sum += editions.balanceOf(holders[h], ids[i]);
            }
            assertEq(sum, e.minted - handler.ghostBurned(ids[i]), "balances");
        }
    }

    /// @notice An edition binds to the first adapter that minted it and never rebinds; an
    ///         edition never minted is unbound.
    function invariant_BoundToTheFirstMinter() public view {
        for (uint256 i; i < ids.length; ++i) {
            IEditions.Edition memory e = editions.edition(ids[i]);
            assertEq(e.minter, handler.ghostMinter(ids[i]), "bound adapter");
            if (e.minted == 0) assertEq(e.minter, address(0));
        }
    }

    /// @notice The link and the locked terms never change: both directions, the content and the
    ///         royalty (no handler action changes the rate).
    function invariant_LinkAndRoyaltyFixed() public view {
        for (uint256 i; i < ids.length; ++i) {
            (address s, uint256 workId, bytes32 contentHash) = editions.masterOf(ids[i]);
            assertEq(s, address(stream));
            assertEq(workId, ids[i]);
            assertEq(contentHash, contentHashes[i]);
            (address linked, uint256 editionId) = stream.editionOf(ids[i]);
            assertEq(linked, address(editions));
            assertEq(editionId, ids[i]);
            (address receiver, uint256 amount) = editions.royaltyInfo(ids[i], 1 ether);
            assertEq(receiver, royaltyReceivers[i]);
            assertEq(amount, royaltyAmounts[i]);
        }
    }

    /// @notice Handler self-test: mints, seals, burns, transfers and admission changes write
    ///         Editions; mints and seals are also refused (cap, binding, admission, range); the
    ///         wrong-kind adapter, the outsider and the re-creation reach Editions and are
    ///         refused; the master moves in the Stream stand-in. Then every invariant holds.
    function test_HandlerPathsReachState() public {
        uint8 w = HandlerReach.WRITES;
        uint8 r = HandlerReach.REFUSED;
        HandlerReach.Expect[] memory e = new HandlerReach.Expect[](10);
        e[0] = HandlerReach.Expect(EditionsHandler.buy.selector, w | r);
        e[1] = HandlerReach.Expect(EditionsHandler.buyWithWrongKind.selector, r);
        e[2] = HandlerReach.Expect(EditionsHandler.mintAsOutsider.selector, r);
        e[3] = HandlerReach.Expect(EditionsHandler.burnFromCustody.selector, w);
        e[4] = HandlerReach.Expect(EditionsHandler.transfer.selector, w);
        e[5] = HandlerReach.Expect(EditionsHandler.warp.selector, HandlerReach.CLOCK);
        e[6] = HandlerReach.Expect(EditionsHandler.recreate.selector, r);
        e[7] = HandlerReach.Expect(EditionsHandler.moveMaster.selector, w);
        e[8] = HandlerReach.Expect(EditionsHandler.seal.selector, w | r);
        e[9] = HandlerReach.Expect(EditionsHandler.toggleAdmission.selector, w);
        HandlerReach.covers(targetSelectors()[0].selectors, e);
        address[] memory sut = new address[](2);
        sut[0] = address(editions);
        sut[1] = address(stream);
        HandlerReach.check(e, HandlerReach.drive(address(handler), e, sut, 60, 1));
        assertGt(handler.mints(), 0);
        assertGt(handler.seals(), 0);
        invariant_MintsFollowEditionTerms();
        invariant_SealedSupplyNeverExceedsTheSealedCount();
        invariant_SupplyAccounting();
        invariant_BoundToTheFirstMinter();
        invariant_LinkAndRoyaltyFixed();
    }
}

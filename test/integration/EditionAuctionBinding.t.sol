// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEditions } from "src/interfaces/IEditions.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { PRODUCT_EDITIONS } from "src/interfaces/types/EconomicsTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { UniformEditionAuction } from "src/sales/UniformEditionAuction.sol";
import { EditionsAdapterMock } from "test/mocks/editions/EditionsMocks.sol";
import { EditionAuctionStack } from "./EditionAuctionStack.sol";

/// @notice An edition is bound to the adapter whose sale opened it, on the real stack (ADR 0005,
///         amended 31 October 2026): `open` calls `Editions.bindMinter` before it records the
///         sale, so a second admitted adapter of the same kind can never open the same edition
///         (whose winners the first claim would otherwise lock out after its seller was paid);
///         a removed adapter's winners still claim, within the creator's cap, and it opens
///         nothing new; anyone may open, but only the adapter of the edition's kind binds; and
///         the edition records the economics its sale locked and paid.
contract EditionAuctionBindingTest is EditionAuctionStack {
    address internal artist;
    address internal collector = makeAddr("oneOfOneCollector");
    address internal attacker = makeAddr("attacker");

    function setUp() public override {
        super.setUp();
        artist = _actor("masterArtist");
    }

    /// @dev A second uniform auction, admitted on Editions and listing it, as an upgrade would
    ///      deploy one (its 30-day admission waited out before any sale starts).
    function _secondAdapter() internal returns (UniformEditionAuction a) {
        a = new UniformEditionAuction(
            address(manager), address(escrow), address(editions), address(auction), _editionConfig()
        );
        _govern(
            hotAdmin,
            address(editions),
            abi.encodeCall(editions.setAdmittedMinter, (address(a), true))
        );
        _govern(hotAdmin, address(a), abi.encodeCall(a.setTarget, (address(editions), true)));
    }

    /// @dev Publishes a master and starts its 1/1, without opening its edition sale.
    function _startUnopened(uint32 maxCount)
        internal
        returns (bytes32 root, Work memory w, uint256 oneSaleId, uint256 tokenId)
    {
        w = _masterWork(artist, maxCount);
        root = _publish(_one(w));
        (oneSaleId, tokenId) = _start(root, _one(w), 0);
    }

    function test_Binding_ASecondAdapterOfTheKindCannotOpenABoundEdition() public {
        UniformEditionAuction second = _secondAdapter();
        (bytes32 root, Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId) =
            _startMaster(artist, 0);
        // The second adapter's open reverts before it records a sale.
        vm.expectRevert(
            abi.encodeWithSelector(
                IEditions.MinterMismatch.selector, tokenId, address(editionAuction)
            )
        );
        second.open(address(editions), tokenId, abi.encode(w.item));
        uint256 secondSale = second.saleIdOf(address(editions), tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.UnknownAuction.selector, secondSale)
        );
        IUniformEditionAuction(address(second)).auction(secondSale);
        // No re-open by the adapter that holds the edition.
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.AuctionExists.selector, saleId)
        );
        editionAuction.open(address(editions), tokenId, abi.encode(w.item));

        // The converse: whichever adapter opens first holds the edition.
        (, Work memory w2,, uint256 token2) = _startUnopened(0);
        vm.prank(attacker);
        second.open(address(editions), token2, abi.encode(w2.item));
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.MinterMismatch.selector, token2, address(second))
        );
        editionAuction.open(address(editions), token2, abi.encode(w2.item));

        // The first sale runs to the end on its own adapter.
        _editionBid(saleId, makeAddr("fan"), 20, 3);
        _settleOneOfOneAndCreate(oneSaleId, root, w);
        assertEq(editions.edition(tokenId).minter, address(editionAuction));
        _settleEditions(saleId);
        vm.prank(makeAddr("fan"));
        (uint256 won,) = editionAuction.claimBid(saleId, 1, makeAddr("fan"));
        assertEq(won, 3);
        assertEq(editions.balanceOf(makeAddr("fan"), tokenId), 3);
    }

    /// @dev Governance removes the adapter after its sale settled (the seller paid): every
    ///      winner still claims, exactly the cleared count within the cap, and the removed
    ///      adapter opens no new sale.
    function test_Binding_ARemovedAdaptersWinnersStillClaim() public {
        (bytes32 root, Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId) =
            _startMaster(artist, 10);
        address fan1 = makeAddr("fan1");
        address fan2 = makeAddr("fan2");
        _editionBid(saleId, fan1, 30, 6);
        _editionBid(saleId, fan2, 25, 8);
        _settleOneOfOneAndCreate(oneSaleId, root, w);
        _settleEditions(saleId);
        uint256 count = ea.settlement(saleId).count;
        assertEq(count, 10, "the cap binds");

        _govern(
            hotAdmin,
            address(editions),
            abi.encodeCall(editions.setAdmittedMinter, (address(editionAuction), false))
        );
        assertFalse(editions.isAdmittedMinter(address(editionAuction)));
        vm.prank(fan1);
        (uint256 won1,) = editionAuction.claimBid(saleId, 1, fan1);
        vm.prank(fan2);
        (uint256 won2,) = editionAuction.claimBid(saleId, 2, fan2);
        assertEq(won1 + won2, count);
        assertEq(editions.edition(tokenId).minted, count);
        assertEq(editions.balanceOf(fan1, tokenId) + editions.balanceOf(fan2, tokenId), 10);

        // Removed: no new sale.
        (, Work memory w2,, uint256 token2) = _startUnopened(0);
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(editionAuction))
        );
        editionAuction.open(address(editions), token2, abi.encode(w2.item));
    }

    /// @dev `open` is permissionless, so an attacker may trigger it: it binds only the adapter
    ///      whose kind the edition's terms name. Binding directly, through an admitted adapter
    ///      of another kind, or with a forged item all fail.
    function test_Binding_AnAttackerBindsOnlyTheMatchingKind() public {
        EditionsAdapterMock fixedKind = new EditionsAdapterMock(SaleKind.FIXED_PRICE);
        _govern(
            hotAdmin,
            address(editions),
            abi.encodeCall(editions.setAdmittedMinter, (address(fixedKind), true))
        );
        (, Work memory w,, uint256 tokenId) = _startUnopened(0);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, attacker));
        editions.bindMinter(tokenId, w.item);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintTarget.SaleKindMismatch.selector,
                SaleKind.UNIFORM_AUCTION,
                SaleKind.FIXED_PRICE
            )
        );
        fixedKind.bind(editions, tokenId, w.item);
        Work memory forged = _masterWork(artist, 7);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISaleAdapter.InvalidSaleTerms.selector, address(editions), tokenId
            )
        );
        editionAuction.open(address(editions), tokenId, abi.encode(forged.item));

        vm.expectEmit(true, true, false, true, address(editions));
        emit IEditions.EditionMinterBound(tokenId, address(editionAuction));
        vm.prank(attacker);
        editionAuction.open(address(editions), tokenId, abi.encode(w.item));
        // Bound now: the other kind still cannot take it.
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintTarget.SaleKindMismatch.selector,
                SaleKind.UNIFORM_AUCTION,
                SaleKind.FIXED_PRICE
            )
        );
        fixedKind.bind(editions, tokenId, w.item);
    }

    /// @dev The fee snapshot: the network fee changes after the edition sale opened and before
    ///      the edition is created. The sale pays the economics it locked at open, and the
    ///      edition, bound in that transaction, records exactly those.
    function test_Binding_TheEditionReportsTheSplitItsSalePaid() public {
        address newFee = makeAddr("newNetworkFee");
        bytes memory change =
            abi.encodeCall(economics.setFeeTerms, (PRODUCT_EDITIONS, 1, newFee, 10_000));
        (bool immediate, uint32 delay) =
            manager.canCall(hotAdmin, address(economics), bytes4(change));
        if (!immediate) {
            _schedule(hotAdmin, address(economics), change);
            vm.warp(block.timestamp + delay - 1 hours);
        }
        (bytes32 root, Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId) =
            _startMaster(artist, 0);
        address seller = _editionSeller(w);
        _editionBid(saleId, makeAddr("fan"), 40, 5);
        if (!immediate) vm.warp(block.timestamp + 1 hours);
        vm.prank(hotAdmin);
        if (immediate) {
            (bool ok,) = address(economics).call(change);
            require(ok, "fee change");
        } else {
            manager.execute(address(economics), change);
        }
        assertEq(economics.newWorkTerms(PRODUCT_EDITIONS, w.item.payees).feeShare, 10_000);

        _settleOneOfOneAndCreate(oneSaleId, root, w);
        IEditions.Edition memory e = editions.edition(tokenId);
        assertEq(e.seller, seller);
        assertEq(e.feeRecipient, networkFee);
        assertEq(e.feeShare, 25_000);
        uint256 revenue = ea.clearing(saleId).revenue;
        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = networkFee.balance;
        _settleEditions(saleId);
        assertEq(networkFee.balance - feeBefore, revenue * e.feeShare / 100_000, "the fee paid");
        assertEq(seller.balance - sellerBefore, revenue - revenue * e.feeShare / 100_000);
        assertEq(newFee.balance, 0);
    }
}

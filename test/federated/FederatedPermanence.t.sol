// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { FederatedEditionAuction } from "src/federated/FederatedEditionAuction.sol";
import { FederatedEditionAuctionLens } from "src/federated/FederatedEditionAuctionLens.sol";
import { FederatedEditions } from "src/federated/FederatedEditions.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { IFederatedEditions } from "src/interfaces/IFederatedEditions.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IEnglishAuctionRefusal } from "src/interfaces/IEnglishAuctionRefusal.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { License, Party, PartyRole } from "src/interfaces/types/PackageTypes.sol";
import { StreamLayout } from "src/stream/StreamLayout.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { FederationBase } from "./FederationBase.sol";

/// @notice What the federated templates and adapters owe the permanence rules of ADR 0007 after
///         its review fixes: the shared renderer reads a federated work through the same native
///         path as a 6529 Stream work (`coreOf` and `extsload` at `StreamLayout`'s slots), a
///         work's own locator can never break its metadata, an item names only its artist and
///         consenting parties, and a federated edition sale's abandonment waits only its locked
///         delay (a federated 1/1 has no rescue).
contract FederatedPermanenceTest is FederationBase {
    /// @dev The failure injected into a master's settlement.
    error InjectedSettlementFailure();

    FederatedEditionAuction internal fea;
    IUniformEditionAuctionLens internal fl;
    FederatedStream internal pairStream;
    FederatedEditions internal pairEditions;
    address internal collector = makeAddr("collector");

    function setUp() public override {
        super.setUp();
        FederatedEditionAuctionLens lens = new FederatedEditionAuctionLens(
            address(auction), address(escrow), address(artists), address(economics)
        );
        fea = new FederatedEditionAuction(
            address(manager),
            address(escrow),
            address(auction),
            address(lens),
            address(lens).codehash,
            DeployV1.editionAuctionDefaults(),
            DeployV1.editionAuctionLimits()
        );
        fl = IUniformEditionAuctionLens(address(fea));
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(fedRegistry.setAdapter, (address(fea), true))
        );
        _joinedFed();
        (pairStream, pairEditions) = _pair(fedArtist);
    }

    // ------------------------------------------------------------------ the renderer's path

    /// @dev The renderer reads the serial and the collection name with `extsload` at the slots
    ///      `StreamLayout` publishes for 6529 Stream. The template keeps its token words and its
    ///      one collection there: the minting adapter in the low 160 bits, the work ID (the
    ///      serial) in the next 32, the ERC-721 name two slots into the collection's entry.
    function test_Layout_TheTemplateAnswersTheRenderersNativeReads() public {
        (, uint256 tokenId) = _startFed(_fedWork(fedArtist));
        (, uint256 second) = _startFed(_fedWork(fedArtist));
        bytes32[] memory word = fed.extsload(StreamLayout.tokenSlot(second), 1);
        assertEq(address(uint160(uint256(word[0]))), address(auction), "the minting adapter");
        assertEq(uint32(uint256(word[0]) >> 160), 2, "the work ID, shown as the serial");
        word = fed.extsload(StreamLayout.tokenSlot(tokenId), 1);
        assertEq(uint32(uint256(word[0]) >> 160), 1);
        bytes32 name = fed.extsload(bytes32(uint256(StreamLayout.collectionSlot(1)) + 2), 1)[0];
        // "Artist Works", 12 bytes, a short storage string: twice its length in the low byte.
        assertEq(name, bytes32("Artist Works") | bytes32(uint256(24)));
        (,, uint256 collectionId,,,) = fed.coreOf(second);
        assertEq(collectionId, 1);
        string memory uri = fed.tokenURI(second);
        assertTrue(_contains(uri, "Artist Works"), "the collection trait");
        assertTrue(_contains(uri, '"Serial","value":2}'), "the serial trait");
    }

    // ------------------------------------------------------------------ locators

    /// @dev WS-40's rule on the template's own locators: printable ASCII without `"` or `\`, at
    ///      most `Limits.MAX_URI_BYTES`, so the renderer's UTF-8 check can never refuse one and
    ///      no locator can break the work's metadata.
    function test_Locator_OnlyPrintableAsciiWithinTheBound() public {
        (, uint256 tokenId) = _startFed(_fedWork(fedArtist));
        string memory before = fed.tokenURI(tokenId);
        string[8] memory bad = [
            _s(hex"61ff"),
            _s(hex"c3a9"),
            "a b",
            _s(hex"610a"),
            _s(hex"617f"),
            'a"b',
            "a\\b",
            string(new bytes(2049))
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(fedArtist);
            vm.expectRevert(IFederatedStream.InvalidLocator.selector);
            fed.setLocator(tokenId, 0, 1, bad[i]);
        }
        assertEq(fed.tokenURI(tokenId), before, "metadata unchanged");
        bytes memory longest = new bytes(2048);
        for (uint256 i; i < longest.length; ++i) {
            longest[i] = "a";
        }
        // One allowed byte more than the bound: only the length refuses it.
        vm.prank(fedArtist);
        vm.expectRevert(IFederatedStream.InvalidLocator.selector);
        fed.setLocator(tokenId, 0, 1, string(abi.encodePacked(longest, "a")));
        vm.startPrank(fedArtist);
        fed.setLocator(tokenId, 0, 1, "https://x.test/a-b_c.d~e!$&'()*+,;=:@/?%20[]{}|^`<>");
        fed.setLocator(tokenId, 0, 1, string(longest));
        vm.stopPrank();
        assertTrue(_contains(fed.tokenURI(tokenId), "data:application/json"));
    }

    // ------------------------------------------------------------------ who an item names

    /// @dev The first party is the contract's artist and every later party consents on chain
    ///      (`FederationSecondPass.t.sol` covers consents): a later party without a consent, an
    ///      artist ID as a payee that names no party, an item with no parties, and a license ID
    ///      outside the mint rule are refused. A fixed payee is an account the parties pay.
    function test_Mint_TheItemNamesOnlyConsentingParties() public {
        address other = _actor("anotherArtist");
        Work memory w = _fedWork(fedArtist);
        w.item.parties = new Party[](2);
        w.item.parties[0] = Party(fedArtist, uint8(PartyRole.ARTIST));
        w.item.parties[1] = Party(other, uint8(PartyRole.ARTIST));
        _refused(w);

        w = _fedWork(fedArtist);
        w.item.payees = new ISplitWallet.Payee[](2);
        (uint160 lo, uint160 hi) = uint160(fedArtist) < uint160(other)
            ? (uint160(fedArtist), uint160(other))
            : (uint160(other), uint160(fedArtist));
        w.item.payees[0] = ISplitWallet.Payee(lo, address(0), 50_000);
        w.item.payees[1] = ISplitWallet.Payee(hi, address(0), 50_000);
        _refused(w);

        w = _fedWork(fedArtist);
        w.item.license = License("CC0 1.0", w.item.license.textFileId);
        _refused(w);

        w = _fedWork(fedArtist);
        w.item.parties = new Party[](0);
        _refused(w);

        // The artist alone, with a fixed payee it pays: accepted.
        w = _fedWork(fedArtist);
        w.item.payees = new ISplitWallet.Payee[](2);
        w.item.payees[0] = ISplitWallet.Payee(0, other, 30_000);
        w.item.payees[1] = ISplitWallet.Payee(uint160(fedArtist), address(0), 70_000);
        (uint256 saleId,) = _startFed(w);
        assertGt(saleId, 0);
    }

    function _s(bytes memory b) internal pure returns (string memory) {
        return string(b);
    }

    function _refused(Work memory w) internal {
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(w), RATE);
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        auction.start(address(fed), _mintData(w));
    }

    // ------------------------------------------------------------------ abandonment

    /// @dev R16: a federated sale whose master's sale never completes (its settlement fails,
    ///      so its 1/1 closes refused after the fixed 2-day exit) is abandoned 21 days after its
    ///      close, in the lens and in the adapter; while the 1/1 is unsettled it is refused.
    function test_Abandon_AFederatedSaleAfterARefusedMaster() public {
        Work memory w = _fedMaster(fedArtist, 0);
        (uint256 oneSaleId, uint256 tokenId) = _startFed(pairStream, fedArtist, w, RATE);
        uint256 saleId = fea.open(address(pairEditions), tokenId, abi.encode(w.item));
        // The master's settlement fails, so its 1/1 stays ended and unsettled.
        vm.mockCallRevert(
            address(pairStream),
            abi.encodeWithSelector(IMintTarget.settlePrimary.selector),
            abi.encodeWithSelector(InjectedSettlementFailure.selector)
        );
        uint256 oneEnd = auction.auction(oneSaleId).endTime;
        vm.warp(oneEnd);
        vm.expectRevert(InjectedSettlementFailure.selector);
        auction.settle(oneSaleId);
        uint256 end = fl.endTimes(saleId).endTime;
        vm.warp(end + 21 days);
        (bool ok, uint256 abandonAt) = fl.abandonable(saleId);
        assertFalse(ok, "the 1/1 is unsettled");
        assertEq(abandonAt, 0);
        IEnglishAuctionRefusal(address(auction)).settleOrRefund(oneSaleId);
        (, abandonAt) = fl.abandonable(saleId);
        assertEq(abandonAt, end + 21 days);
        vm.warp(end + 21 days - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.NotAbandonable.selector, saleId)
        );
        fea.abandon(saleId, abi.encode(w.item));
        vm.warp(end + 21 days);
        fea.abandon(saleId, abi.encode(w.item));
        assertEq(uint8(fl.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
    }

    /// @dev Pass 3: a federated edition sale voided while its best-effort seal was refused
    ///      leaves the edition bound to this adapter's void sale for good: the adapter never
    ///      reopens it and another adapter cannot bind it.
    function test_Abandon_ARefusedSealLeavesTheEditionDeadForGood() public {
        Work memory w = _fedMaster(fedArtist, 0);
        (uint256 oneSaleId, uint256 tokenId) = _startFed(pairStream, fedArtist, w, RATE);
        uint256 saleId = fea.open(address(pairEditions), tokenId, abi.encode(w.item));
        vm.mockCallRevert(
            address(pairStream), abi.encodeWithSelector(IMintTarget.settlePrimary.selector), "x"
        );
        vm.mockCallRevert(
            address(pairEditions),
            abi.encodeWithSelector(IFederatedEditions.sealSupply.selector),
            "x"
        );
        vm.warp(auction.auction(oneSaleId).endTime + 2 days);
        IEnglishAuctionRefusal(address(auction)).settleOrRefund(oneSaleId);
        (, uint256 abandonAt) = fl.abandonable(saleId);
        vm.warp(abandonAt);
        fea.abandon(saleId, abi.encode(w.item));
        assertEq(uint8(fl.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        vm.clearMockedCalls();
        // The 1/1 closed refused (its work pending for the artist), so the edition is never
        // created; it stays bound to `fea`'s void sale.
        assertFalse(pairEditions.exists(tokenId), "never created");
        oneSaleId;
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.AuctionExists.selector, saleId)
        );
        fea.open(address(pairEditions), tokenId, abi.encode(w.item));
        vm.prank(address(auction));
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederatedEditions.MinterMismatch.selector, tokenId, address(fea)
            )
        );
        pairEditions.bindMinter(tokenId, w.item);
    }
}

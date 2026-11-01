// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { Roles } from "src/governance/Roles.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import {
    LockedTerms,
    PrimaryOutcome,
    PrimaryTerms,
    SaleKind
} from "src/interfaces/types/SaleTypes.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { VerifyV1 } from "script/VerifyV1.sol";
import { HostileActor, MockMintTarget } from "../mocks/sales/AuctionMocks.sol";
import { MockFederationRegistry } from "../mocks/sales/SaleMocks.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice D140 on the real stack (ADR 0005; owner decisions 9, 10 and 11). The 6529 Network
///         Museum is set in the economics resolver at genesis and changed only through the
///         14-day FUNDS_SETTER class. It receives every unbid canonical 6529 Stream 1/1, read
///         when the sale settles: after no bid, while the artist is restrained, and at the
///         30-day currency-freeze exit, with the standing bid credited back. Stream moves the
///         work there itself when the auction reports the outcome (owner decision 17), so nothing
///         is ever pending, and records the outcome. An unbid federated work stays with its artist.
contract MuseumTest is IntegrationBase {
    address internal artist;
    address internal collector = makeAddr("museumCollector");
    address internal federatedArtist = makeAddr("federatedArtist");
    bytes32 internal root;

    function setUp() public override {
        super.setUp();
        artist = _actor("museumArtist");
        Work[] memory works = new Work[](3);
        for (uint256 i; i < works.length; ++i) {
            works[i] = _work(artist, collectionId);
        }
        root = _publish(works);
        _keep(root, works);
    }

    /// @dev External, so `vm.expectRevert` sees the readback's revert at this call depth.
    function checkMuseum(address recorded) external view {
        VerifyV1.checkMuseum(deployment, recorded);
    }

    function _startItem(uint256 index) internal returns (uint256 saleId, uint256 tokenId) {
        (saleId, tokenId) = _start(root, _package(root), index);
    }

    /// @dev Governance moves the museum (FUNDS_SETTER, 14 days).
    function _setMuseum(address next) internal {
        _govern(
            hotAdmin,
            address(economics),
            abi.encodeCall(economics.setMuseum, (economics.museumRevision(), next))
        );
    }

    /// @dev A federated ERC-721 whose artist is `federatedArtist`, registered ACTIVE with a 10%
    ///      fee in a registry governance installs on the auction (SUCCESSOR_SETTER, 30 days).
    function _federatedToken() internal returns (MockMintTarget fed) {
        MockFederationRegistry reg = new MockFederationRegistry();
        fed = new MockMintTarget();
        fed.setAdmittedMinter(address(auction), true);
        fed.setTerms(
            PrimaryTerms(
                SaleKind.ENGLISH_AUCTION,
                CURRENCY_ETH,
                0,
                "",
                makeAddr("federatedSeller"),
                address(0),
                0,
                federatedArtist
            )
        );
        _govern(
            hotAdmin,
            address(auction),
            abi.encodeCall(auction.setFederationRegistry, (address(0), address(reg)))
        );
        reg.register(
            address(fed),
            IFederationRegistry.Entry(
                IFederationRegistry.Form.ERC721,
                address(0),
                uint160(federatedArtist),
                1,
                address(fed).codehash,
                10_000,
                IFederationRegistry.Status.ACTIVE
            )
        );
    }

    /// @dev Another ERC-721 governance lists on the auction (`setTarget`, SUCCESSOR_SETTER, 30
    ///      days), whose artist is `federatedArtist`. It is not 6529 Stream, the token the auction
    ///      was deployed with.
    function _listedToken() internal returns (MockMintTarget token) {
        token = new MockMintTarget();
        token.setAdmittedMinter(address(auction), true);
        token.setTerms(
            PrimaryTerms(
                SaleKind.ENGLISH_AUCTION,
                CURRENCY_ETH,
                0,
                "",
                makeAddr("listedSeller"),
                networkFee,
                25_000,
                federatedArtist
            )
        );
        _govern(
            hotAdmin, address(auction), abi.encodeCall(auction.setTarget, (address(token), true))
        );
        assertTrue(auction.isTarget(address(token)));
    }

    function _deprecateEth() internal returns (uint256 frozenAt) {
        _govern(
            guardian1, address(allowlist), abi.encodeCall(allowlist.deprecateAsset, (CURRENCY_ETH))
        );
        frozenAt = block.timestamp;
    }

    // ------------------------------------------------------------------ genesis and governance

    /// @dev Owner decision 11: genesis sets the museum in the resolver (a constructor value
    ///      `Verify.s.sol` reads back) and maps `setMuseum` to FUNDS_SETTER, the 14-day class.
    function test_GenesisWiresTheMuseumInTheFundsClass() public {
        assertEq(economics.museum(), museum);
        assertEq(
            manager.getTargetFunctionRole(
                address(economics), IEconomicsResolver.setMuseum.selector
            ),
            Roles.FUNDS_SETTER
        );
        (bool immediate, uint32 delay) =
            manager.canCall(hotAdmin, address(economics), IEconomicsResolver.setMuseum.selector);
        assertFalse(immediate);
        assertEq(delay, Roles.FUNDS);
        this.checkMuseum(museum);
        vm.expectRevert(
            abi.encodeWithSelector(VerifyV1.MuseumMismatch.selector, networkFee, museum)
        );
        this.checkMuseum(networkFee);
    }

    /// @dev A governed change waits its 14 days, names the old and the new museum in its event,
    ///      and then fails Verify's genesis readback by design. Nobody else may call the setter.
    function test_SetMuseum_GovernedChangeWaitsFourteenDays() public {
        address next = makeAddr("nextMuseumSafe");
        bytes memory call = abi.encodeCall(economics.setMuseum, (1, next));
        bytes32 id = _schedule(hotAdmin, address(economics), call);
        vm.warp(block.timestamp + Roles.FUNDS - 1);
        vm.prank(hotAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, id));
        manager.execute(address(economics), call);
        vm.warp(block.timestamp + 1);
        vm.expectEmit(address(economics));
        emit IEconomicsResolver.MuseumSet(museum, next, 2);
        vm.prank(hotAdmin);
        manager.execute(address(economics), call);
        assertEq(economics.museum(), next);
        vm.expectRevert(abi.encodeWithSelector(VerifyV1.MuseumMismatch.selector, museum, next));
        this.checkMuseum(museum);

        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, collector)
        );
        economics.setMuseum(2, collector);
    }

    /// @dev The museum must hold what it receives: governance cannot name zero or a system
    ///      contract (the fee-recipient rule, CALLS-1). The execution reverts after its delay and
    ///      the museum is unchanged.
    function test_SetMuseum_RefusesZeroAndSystemContracts() public {
        address[13] memory refused = [
            address(0),
            address(escrow),
            address(claimRouter),
            address(auction),
            address(stream),
            address(editions),
            address(economics),
            address(allowlist),
            address(splitFactory),
            address(artists),
            address(registry),
            address(records),
            address(releaseVerifier)
        ];
        for (uint256 i; i < refused.length; ++i) {
            bytes memory call = abi.encodeCall(economics.setMuseum, (1, refused[i]));
            _schedule(hotAdmin, address(economics), call);
            vm.warp(block.timestamp + Roles.FUNDS);
            vm.prank(hotAdmin);
            vm.expectRevert(
                abi.encodeWithSelector(IEconomicsResolver.InvalidMuseum.selector, refused[i])
            );
            manager.execute(address(economics), call);
            assertEq(economics.museum(), museum);
        }
    }

    // ------------------------------------------------------------------ unbid works

    /// @dev D140: with no bid the work goes to the museum, not its artist; nothing is paid.
    ///      Stream records UNBID and moves the work itself (owner decision 17).
    function test_UnbidWorkGoesToTheMuseum() public {
        (uint256 saleId, uint256 tokenId) = _startItem(0);
        vm.warp(auction.auction(saleId).endTime);
        LockedTerms memory lt = auction.lockedTerms(saleId);
        vm.expectEmit(address(stream));
        emit IStream.PrimarySaleSettled(tokenId, PrimaryOutcome.UNBID, address(0), CURRENCY_ETH, 0);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.SaleSettled(
            saleId,
            address(stream),
            tokenId,
            address(0),
            museum,
            1,
            CURRENCY_ETH,
            0,
            lt.seller,
            0,
            lt.feeRecipient,
            0
        );
        auction.settle(saleId);
        assertEq(stream.ownerOf(tokenId), museum);
        assertEq(stream.balanceOf(artist), 0, "not the artist");
        assertEq(auction.auction(saleId).recipient, museum);
        assertTrue(stream.primarySaleSettled(tokenId));
        assertEq(address(auction).balance, 0);
        assertEq(auction.pendingDelivery(saleId), address(0), "nothing pending");
        (PrimaryOutcome outcome, address currency, uint256 price) = stream.primarySale(tokenId);
        assertEq(uint8(outcome), uint8(PrimaryOutcome.UNBID));
        assertEq(currency, address(0));
        assertEq(price, 0);
    }

    /// @dev The museum is read at settlement: a change that lands while the sale waits for its
    ///      settle sends the work to the new museum.
    function test_UnbidWorkGoesToTheMuseumNamedAtSettlement() public {
        (uint256 saleId, uint256 tokenId) = _startItem(0);
        address next = makeAddr("nextMuseumSafe");
        _setMuseum(next);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.ENDED));
        auction.settle(saleId);
        assertEq(stream.ownerOf(tokenId), next);
        assertEq(stream.balanceOf(museum), 0);
    }

    /// @dev A sold work is untouched by the rule: it goes to its winner. Stream records SOLD,
    ///      the currency and the price, and names the buyer in its event (owner decision 17).
    function test_ASoldWorkStillGoesToItsWinner() public {
        (uint256 saleId, uint256 tokenId) = _startItem(1);
        _ethBid(saleId, collector, 1 ether);
        vm.warp(auction.auction(saleId).endTime);
        vm.expectEmit(address(stream));
        emit IStream.PrimarySaleSettled(
            tokenId, PrimaryOutcome.SOLD, collector, CURRENCY_ETH, 1 ether
        );
        auction.settle(saleId);
        assertEq(stream.ownerOf(tokenId), collector);
        assertEq(stream.balanceOf(museum), 0);
        (PrimaryOutcome outcome, address currency, uint256 price) = stream.primarySale(tokenId);
        assertEq(uint8(outcome), uint8(PrimaryOutcome.SOLD));
        assertEq(currency, CURRENCY_ETH);
        assertEq(price, 1 ether);
    }

    /// @dev Owner decision 10: the 30-day currency-freeze exit takes the no-bid branch. The
    ///      standing bid is credited back in full and the work goes to the museum.
    function test_FreezeExitSendsTheWorkToTheMuseumAndCreditsTheBid() public {
        (uint256 saleId, uint256 tokenId) = _startItem(0);
        _ethBid(saleId, collector, 1 ether);
        uint256 frozenAt = _deprecateEth();
        vm.warp(frozenAt + 30 days - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.AssetNotActive.selector, CURRENCY_ETH)
        );
        auction.settle(saleId);

        vm.warp(frozenAt + 30 days);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Credited(collector, CURRENCY_ETH, saleId, 1 ether);
        vm.expectEmit(address(stream));
        emit IStream.PrimarySaleSettled(
            tokenId, PrimaryOutcome.FROZEN_OUT, address(0), CURRENCY_ETH, 0
        );
        auction.settle(saleId);
        assertEq(stream.ownerOf(tokenId), museum, "the work goes to the museum");
        (PrimaryOutcome outcome,,) = stream.primarySale(tokenId);
        assertEq(uint8(outcome), uint8(PrimaryOutcome.FROZEN_OUT));
        assertEq(stream.balanceOf(artist), 0, "not the artist");
        assertEq(auction.claimable(collector, CURRENCY_ETH), 1 ether, "the bid is credited back");
        assertEq(address(auction).balance, 1 ether, "only the credit is held");
        vm.prank(collector);
        auction.claim(CURRENCY_ETH, collector);
        assertEq(collector.balance, 1 ether, "refunded in full");
        assertEq(address(auction).balance, 0);
    }

    /// @dev Owner decision 17: Stream moves the work to the museum with no receiver callback, so
    ///      a museum contract that would reject a safe transfer still receives it. Nothing is
    ///      pending, so nobody (the artist, a collector, a later museum, the museum itself) has
    ///      anything to claim, and a later change of museum moves nothing.
    function test_AMuseumThatWouldRejectStillReceivesTheWork() public {
        HostileActor museumSafe = new HostileActor();
        museumSafe.configure(HostileActor.Behaviour.ACCEPT, HostileActor.Behaviour.REVERT);
        _setMuseum(address(museumSafe));
        (uint256 saleId, uint256 tokenId) = _startItem(0);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), address(museumSafe));
        assertEq(auction.pendingDelivery(saleId), address(0));

        address next = makeAddr("nextMuseumSafe");
        _setMuseum(next);
        address[4] memory refused = [artist, collector, next, address(museumSafe)];
        for (uint256 i; i < refused.length; ++i) {
            vm.prank(refused[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IEnglishAuction.NoPendingDelivery.selector, saleId)
            );
            auction.claimDelivery(saleId, refused[i]);
        }
        assertEq(stream.ownerOf(tokenId), address(museumSafe));
    }

    // ------------------------------------------------------------------ other listed tokens

    /// @dev Owner decision 9, enforced in code: 6529 Stream moves its own unbid works to the
    ///      museum (owner decision 17). A token governance lists later leaves its unbid works to
    ///      the auction, which delivers them to the artist, as for a federated token.
    function test_AnotherListedTokensUnbidWorkGoesToItsArtist() public {
        MockMintTarget other = _listedToken();
        uint256 saleId = auction.start(address(other), "");
        (uint256 streamSale, uint256 tokenId) = _startItem(0);
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(saleId);
        auction.settle(streamSale);
        assertEq(other.ownerOf(1), federatedArtist, "its artist");
        assertEq(other.balanceOf(museum), 0, "never the museum");
        assertEq(stream.ownerOf(tokenId), museum, "Stream's unbid work: the museum");
    }

    /// @dev Decision 10 with decision 9: another listed token's 30-day freeze exit takes its
    ///      no-bid branch, so the work goes to its artist, with the bid credited back in full.
    function test_AnotherListedTokensFreezeExitGoesToItsArtist() public {
        MockMintTarget other = _listedToken();
        uint256 saleId = auction.start(address(other), "");
        _ethBid(saleId, collector, 1 ether);
        uint256 frozenAt = _deprecateEth();
        vm.warp(frozenAt + 30 days);
        auction.settle(saleId);
        assertEq(other.ownerOf(1), federatedArtist, "its artist, not the museum");
        assertEq(auction.claimable(collector, CURRENCY_ETH), 1 ether, "the bid is credited back");
        vm.prank(collector);
        auction.claim(CURRENCY_ETH, collector);
        assertEq(collector.balance, 1 ether, "refunded in full");
    }

    // ------------------------------------------------------------------ federated works

    /// @dev Owner decision 9: an unbid federated work stays with its artist; the museum rule
    ///      covers the canonical 6529 Stream only.
    function test_UnbidFederatedWorkStaysWithItsArtist() public {
        MockMintTarget fed = _federatedToken();
        uint256 saleId = auction.start(address(fed), "");
        _settleAtEnd(saleId);
        assertEq(fed.ownerOf(1), federatedArtist);
        assertEq(fed.balanceOf(museum), 0, "never the museum");
    }

    /// @dev Owner decisions 9 and 10 together: a federated work's freeze exit takes its no-bid
    ///      branch too, so it goes to its artist, with the bid credited back.
    function test_FederatedFreezeExitGoesToItsArtist() public {
        MockMintTarget fed = _federatedToken();
        uint256 saleId = auction.start(address(fed), "");
        _ethBid(saleId, collector, 1 ether);
        uint256 frozenAt = _deprecateEth();
        vm.warp(frozenAt + 30 days);
        auction.settle(saleId);
        assertEq(fed.ownerOf(1), federatedArtist);
        assertEq(auction.claimable(collector, CURRENCY_ETH), 1 ether);
    }
}

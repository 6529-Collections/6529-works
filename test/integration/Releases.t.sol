// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IClaimRouter } from "src/economics/interfaces/IClaimRouter.sol";
import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { ISplitLedger } from "src/economics/interfaces/ISplitLedger.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import { SaleFlowBase } from "./SaleFlowBase.sol";

/// @notice Releases with the network paid in the same call, on the deployed split ledger after a
///         real sale. A work sold through `SaleStarter` has a seller vault (its payees) and a
///         royalty vault (the seller vault and the fee vault, 75/25). Royalties a marketplace pays
///         to the royalty vault are released by any path that pays the seller vault, and the
///         ledger pays the fee vault its share of the same receipts in that call. The seller
///         vault never names the network, so its releases pay its payees only. A share marked and
///         left unreleased for the unclaimed period goes to the network, with the network's own
///         share in the same call. A wallet that names an artist-resolved payee and the fee vault
///         pays the network on every release path (`release`, `releaseTo`, a signed release).
contract ReleasesTest is SaleFlowBase {
    address internal constant ETH = address(0);
    address internal artist;
    address internal collaborator;
    address internal collector = makeAddr("collector");
    address internal marketplace = makeAddr("marketplace");
    uint256 internal tokenId;
    WorkTerms internal t;
    /// @dev The sold work's seller vault payees, and its royalty vault payees.
    ISplitWallet.Payee[] internal sellerPayees;
    ISplitWallet.Payee[] internal royaltyPayees;

    function setUp() public override {
        super.setUp();
        artist = _actor("releaseArtist");
        collaborator = _actor("releaseCollaborator");
        Work[] memory works = _one(_collab(_work(artist, collectionId), collaborator, 20_000));
        bytes32 root = _publish(works);
        t = _terms(works[0]);
        uint256 saleId;
        (saleId, tokenId) = _startAndOpen(root, works, 0);
        _ethBid(saleId, collector, 4 ether);
        _settleAtEnd(saleId);
        for (uint256 i; i < works[0].item.payees.length; ++i) {
            sellerPayees.push(works[0].item.payees[i]);
        }
        ISplitWallet.Payee[] memory rp = _royaltyPayees(t);
        for (uint256 i; i < rp.length; ++i) {
            royaltyPayees.push(rp[i]);
        }
        assertEq(stream.ownerOf(tokenId), collector);
        assertEq(networkFee.balance, 1 ether, "the primary fee");
        assertEq(t.seller.balance, 3 ether, "the primary proceeds");
    }

    /// @dev A resale on a marketplace that pays the royalty `royaltyInfo` names.
    function _resale(uint256 price) internal returns (uint256 royalty) {
        address receiver;
        (receiver, royalty) = stream.royaltyInfo(tokenId, price);
        assertEq(receiver, t.royaltyReceiver);
        vm.deal(marketplace, royalty);
        vm.prank(marketplace);
        (bool ok,) = receiver.call{ value: royalty }("");
        assertTrue(ok, "the royalty vault takes ETH");
    }

    function _sellerIndex() internal view returns (uint256) {
        return _indexOf(royaltyPayees, t.seller);
    }

    function _feeIndex() internal view returns (uint256) {
        return _indexOf(royaltyPayees, networkFee);
    }

    // ------------------------------------------------------------------ the royalty vault

    function test_Releases_TheSellersRoyaltyReleasePaysTheNetworkInTheSameCall() public {
        assertEq(ledger.network(), networkFee, "the ledger's network is the fee vault");
        assertTrue(ledger.isWallet(t.royaltyReceiver), "deployed by SaleStarter");
        uint256 royalty = _resale(100 ether);
        assertEq(royalty, 6.529 ether);
        uint256 networkPart = royalty * 25_000 / DENOMINATOR;
        uint256 sellerPart = royalty * 75_000 / DENOMINATOR;
        uint256 feeBefore = networkFee.balance;
        uint256 sellerBefore = t.seller.balance;

        vm.expectEmit(address(ledger));
        emit ISplitWallet.Released(
            t.royaltyReceiver, ETH, t.seller, _sellerIndex(), t.seller, sellerPart, royalty
        );
        vm.expectEmit(address(ledger));
        emit ISplitWallet.Released(
            t.royaltyReceiver, ETH, networkFee, _feeIndex(), networkFee, networkPart, royalty
        );
        vm.prank(makeAddr("keeper"));
        assertEq(ledger.release(royaltyPayees, bytes32(0), ETH, _sellerIndex()), sellerPart);
        assertEq(t.seller.balance - sellerBefore, sellerPart, "75% to the seller vault");
        assertEq(networkFee.balance - feeBefore, networkPart, "25% to the network, same call");
        assertEq(ledger.released(t.royaltyReceiver, ETH, _feeIndex()), networkPart);
        assertEq(t.royaltyReceiver.balance, 0);

        // The seller vault's own releases pay its payees, never the network.
        uint256 feeNow = networkFee.balance;
        uint256 proceeds = 3 ether + sellerPart;
        vm.prank(artist);
        ledger.release(sellerPayees, bytes32(0), ETH, _indexOf(sellerPayees, artist));
        vm.prank(collaborator);
        ledger.release(sellerPayees, bytes32(0), ETH, _indexOf(sellerPayees, collaborator));
        assertEq(artist.balance, proceeds * 80_000 / DENOMINATOR, "sale and royalty, 80%");
        assertEq(collaborator.balance, proceeds * 20_000 / DENOMINATOR, "sale and royalty, 20%");
        assertEq(networkFee.balance, feeNow, "the seller vault does not name the network");
    }

    /// @dev Each later receipt is split the same way: the network's share follows every release.
    function test_Releases_EveryReceiptPaysTheNetworkItsShare() public {
        uint256 feeBefore = networkFee.balance;
        uint256 total;
        for (uint256 i = 1; i <= 3; ++i) {
            total += _resale(i * 10 ether);
            ledger.release(royaltyPayees, bytes32(0), ETH, _sellerIndex());
            assertEq(
                networkFee.balance - feeBefore,
                total - total * 75_000 / DENOMINATOR,
                "the network's cumulative share"
            );
        }
        assertLe(t.royaltyReceiver.balance, 1);
    }

    /// @dev The claim router's item for the seller pays the network in the same item.
    function test_Releases_TheClaimRouterPaysTheNetworkInTheSameItem() public {
        uint256 royalty = _resale(10 ether);
        IClaimRouter.Claim[] memory claims = new IClaimRouter.Claim[](1);
        claims[0] = IClaimRouter.Claim(royaltyPayees, bytes32(0), ETH, _sellerIndex());
        uint256 feeBefore = networkFee.balance;
        uint256[] memory amounts = claimRouter.claim(claims, false);
        assertEq(amounts[0], royalty * 75_000 / DENOMINATOR);
        assertEq(networkFee.balance - feeBefore, royalty - amounts[0]);
    }

    /// @dev The network's own release first pays the network only; the seller's later release
    ///      then pays the seller only (the network has nothing left to be paid).
    function test_Releases_TheNetworksOwnReleaseThenTheSellers() public {
        uint256 royalty = _resale(10 ether);
        uint256 feeBefore = networkFee.balance;
        uint256 networkPart = ledger.release(royaltyPayees, bytes32(0), ETH, _feeIndex());
        assertEq(networkPart, royalty * 25_000 / DENOMINATOR);
        assertEq(networkFee.balance - feeBefore, networkPart);
        vm.recordLogs();
        ledger.release(royaltyPayees, bytes32(0), ETH, _sellerIndex());
        assertEq(vm.getRecordedLogs().length, 1, "one Released: the seller's");
        assertEq(networkFee.balance - feeBefore, networkPart, "nothing more to the network");
    }

    /// @dev A seller share someone marked and left unreleased for the unclaimed period goes to
    ///      the network, and the forfeit also pays the network its own share.
    function test_Releases_AForfeitPaysTheMarkedShareAndTheNetworksOwn() public {
        uint256 royalty = _resale(10 ether);
        ledger.mark(royaltyPayees, bytes32(0), ETH, _sellerIndex());
        uint256 period = directory.unclaimedPeriod();
        assertEq(period, 180 days);
        vm.warp(block.timestamp + period - 1);
        (, uint256 markedAt) = ledger.markOf(t.royaltyReceiver, ETH, _sellerIndex());
        vm.expectRevert(
            abi.encodeWithSelector(
                ISplitLedger.MarkNotDue.selector,
                t.royaltyReceiver,
                ETH,
                _sellerIndex(),
                markedAt + period
            )
        );
        ledger.forfeit(royaltyPayees, bytes32(0), ETH, _sellerIndex());
        vm.warp(block.timestamp + 1);
        uint256 feeBefore = networkFee.balance;
        uint256 sellerBefore = t.seller.balance;
        uint256 forfeited = ledger.forfeit(royaltyPayees, bytes32(0), ETH, _sellerIndex());
        assertEq(forfeited, royalty * 75_000 / DENOMINATOR);
        assertEq(networkFee.balance - feeBefore, royalty, "the forfeited share and its own");
        assertEq(t.seller.balance, sellerBefore, "nothing to the seller");
    }

    // ------------------------------------------------------------------ every release path

    /// @dev A wallet anyone deploys on the ledger with the sold work's artist (artist-resolved,
    ///      75%) and the fee vault (25%): each release path the artist uses pays the network its
    ///      share in the same call.
    function test_Releases_EveryArtistReleasePathPaysTheNetwork() public {
        ISplitWallet.Payee[] memory payees = new ISplitWallet.Payee[](2);
        payees[0] = ISplitWallet.Payee(0, networkFee, 25_000);
        payees[1] = ISplitWallet.Payee(uint160(artist), address(0), 75_000);
        address wallet = ledger.createWallet(payees, keccak256("artist and network"));
        bytes32 salt = keccak256("artist and network");
        address to = makeAddr("artistColdWallet");

        // release
        vm.deal(wallet, 4 ether);
        uint256 feeBefore = networkFee.balance;
        vm.prank(artist);
        ledger.release(payees, salt, ETH, 1);
        assertEq(networkFee.balance - feeBefore, 1 ether, "release");
        assertEq(artist.balance, 3 ether);

        // releaseTo
        vm.deal(wallet, 4 ether);
        vm.prank(artist);
        ledger.releaseTo(payees, salt, ETH, 1, to);
        assertEq(networkFee.balance - feeBefore, 2 ether, "releaseTo");
        assertEq(to.balance, 3 ether);

        // a release signed by the artist, submitted by anyone
        vm.deal(wallet, 4 ether);
        IReleaseVerifier.Authorization memory a = IReleaseVerifier.Authorization(
            wallet, ETH, 1, artist, to, 3 ether, 0, block.timestamp + 1 hours
        );
        bytes memory signature = _sign(artist, ledger.releaseDigest(a));
        vm.prank(makeAddr("relayer"));
        ledger.releaseWithAuthorization(payees, salt, a, signature);
        assertEq(networkFee.balance - feeBefore, 3 ether, "signed release");
        assertEq(to.balance, 6 ether);
        assertEq(wallet.balance, 0);
    }
}

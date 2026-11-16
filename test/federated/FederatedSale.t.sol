// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { FederatedEditions } from "src/federated/FederatedEditions.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { IFederatedEditions } from "src/interfaces/IFederatedEditions.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederatedToken } from "src/interfaces/IFederatedToken.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { PrimaryOutcome } from "src/interfaces/types/SaleTypes.sol";
import { FederationBase } from "./FederationBase.sol";

/// @notice Federated 1/1s end to end on the real stack: joining, minting into the English
///         auction's custody, the network's locked 10% on every sold sale, the 90/10 royalty
///         vault, unsold works held and restarted by the template, exit and delisting.
contract FederatedSaleTest is FederationBase {
    address internal collector = makeAddr("collector");

    // ------------------------------------------------------------------ joining

    function test_Join_CreatesTheIdentityAndListsTheTokenWithItsTrueFacts() public {
        assertEq(artists.artistIdOf(fedArtist), 0);
        vm.expectEmit(address(artists));
        emit IArtistRegistry.FederatedContractListed(
            uint160(fedArtist),
            address(fed),
            streamHash,
            uint8(IFederationRegistry.Form.ERC721),
            address(0),
            FED_SHARE,
            networkFee
        );
        vm.expectEmit(address(fed));
        emit IFederatedToken.FederationJoined(
            uint160(fedArtist), address(fedRegistry), FED_SHARE, networkFee, address(0)
        );
        _joinedFed();
        assertEq(artists.artistIdOf(fedArtist), uint160(fedArtist), "identity created");
        (uint256 id, IArtistRegistry.FederationStatus status) =
            artists.federatedListing(address(fed));
        assertEq(id, uint160(fedArtist));
        assertEq(uint8(status), uint8(IArtistRegistry.FederationStatus.ACTIVE));
        IFederationRegistry.Entry memory e = fedRegistry.entry(address(fed));
        assertEq(e.codeHash, address(fed).codehash);
        assertEq(e.feeShare, FED_SHARE);
        assertEq(e.artistId, uint160(fedArtist));
        assertTrue(fedRegistry.isActive(address(fed)));
        assertTrue(auction.isTarget(address(fed)));
    }

    function test_Join_OnlyTheArtist() public {
        vm.prank(collector);
        vm.expectRevert(abi.encodeWithSelector(IFederatedToken.NotArtist.selector, collector));
        fed.joinFederation(_noJoin());
    }

    function test_Join_RefusesAnUnapprovedCopyAndWrongFeeTerms() public {
        // Different code: a template whose hash governance never approved.
        FederatedStream other = _deployStream(fedArtist);
        assertEq(address(other).codehash, streamHash, "every copy has one code hash");
        // Wrong fee terms: a copy locking 5%.
        IFederatedStream.Config memory c = _streamConfig(fedArtist);
        c.feeShare = 5_000;
        FederatedStream cheap = _deployStream(c);
        _join(
            address(cheap),
            fedArtist,
            abi.encodeWithSelector(IFederationRegistry.NotListable.selector, address(cheap))
        );
        c = _streamConfig(fedArtist);
        c.feeRecipient = makeAddr("artistWallet");
        FederatedStream redirected = _deployStream(c);
        _join(
            address(redirected),
            fedArtist,
            abi.encodeWithSelector(IFederationRegistry.NotListable.selector, address(redirected))
        );
    }

    function test_Join_AListingSomeoneElseMadeFirstIsNeverConfirmed() public {
        // A hostile registry lists the genuine token first, under the wrong artist.
        address hostile = address(new HostileLister(artists));
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(artists.setFederationRegistry, (address(fedRegistry), hostile))
        );
        address other = _actor("otherArtist");
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig =
            _sign(other, artists.registrationDigest(other, bytes32(0), bytes32(0), deadline));
        bytes memory consent = abi.encodePacked(
            other,
            _sign(
                other,
                _listingDigest(
                    IArtistRegistry.FederatedListing(
                        uint160(other), address(fed), 0, address(0), 0, address(0), deadline
                    )
                )
            )
        );
        HostileLister(hostile).listAs(address(fed), other, deadline, sig, consent);
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(artists.setFederationRegistry, (hostile, address(fedRegistry)))
        );
        vm.prank(fedArtist);
        vm.expectRevert(IFederatedToken.FederationStateInvalid.selector);
        fed.joinFederation(_noJoin());
        assertFalse(fed.isAdmittedMinter(address(auction)), "it never sells under that listing");
    }

    // ------------------------------------------------------------------ the templates

    /// @dev FED-1: the compiled runtime code is the deployed code (this only compiles for a
    ///      contract with no immutable), so every copy of a version has one code hash.
    function test_Template_EveryCopyRunsTheCompiledRuntimeCode() public {
        assertEq(keccak256(type(FederatedStream).runtimeCode), streamHash);
        assertEq(keccak256(type(FederatedEditions).runtimeCode), editionsHash);
        IFederatedStream.Config memory c = _streamConfig(collector);
        c.name = "Another";
        assertEq(address(_deployStream(c)).codehash, streamHash);
        emit log_named_bytes32("FederatedStream code hash", streamHash);
        emit log_named_bytes32("FederatedEditions code hash", editionsHash);
        emit log_named_bytes32("IFederatedToken id", bytes32(type(IFederatedToken).interfaceId));
        emit log_named_bytes32("IFederatedStream id", bytes32(type(IFederatedStream).interfaceId));
        emit log_named_bytes32(
            "IFederatedEditions id", bytes32(type(IFederatedEditions).interfaceId)
        );
        assertTrue(fed.supportsInterface(type(IFederatedStream).interfaceId));
        assertTrue(fed.supportsInterface(type(IMintTarget).interfaceId));
        assertTrue(fed.supportsInterface(0x2a55205a), "ERC-2981");
    }

    // ------------------------------------------------------------------ minting

    function test_Mint_OnlyAfterJoiningAndOnlyAnApprovedItem() public {
        Work memory w = _fedWork(fedArtist);
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(w), RATE);
        bytes memory data = _mintData(w);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(fed))
        );
        auction.start(address(fed), data);
        _joinedFed();
        Work memory unapproved = _fedWork(fedArtist);
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        auction.start(address(fed), _mintData(unapproved));
        uint256 saleId = auction.start(address(fed), data);
        assertEq(fed.ownerOf(1), address(auction), "minted into the adapter's custody");
        // The approval is used once.
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        auction.start(address(fed), data);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.ACTIVE));
    }

    function test_Mint_NeverDirectly() public {
        _joinedFed();
        Work memory w = _fedWork(fedArtist);
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(w), RATE);
        vm.prank(fedArtist);
        vm.expectRevert(abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, fedArtist));
        fed.mint(fedArtist, 0, 1, _mintData(w));
    }

    function test_Mint_DeploysThePayoutVaultsBeforeAnythingIsOwed() public {
        _joinedFed();
        Work memory w = _fedWork(fedArtist);
        address seller = splitFactory.walletFor(w.item.payees, 0);
        assertEq(seller.code.length, 0);
        _startFed(w);
        assertGt(seller.code.length, 0, "seller vault deployed at mint");
        (address receiver,) = fed.royaltyInfo(1, 1 ether);
        assertGt(receiver.code.length, 0, "royalty vault deployed at mint");
        assertEq(receiver, _royaltyVault(seller));
    }

    // ------------------------------------------------------------------ revenue

    function test_Sold_TheNetworkGetsItsLockedTenPercentAndTheSellerTheRest() public {
        _joinedFed();
        Work memory w = _fedWork(fedArtist);
        (uint256 saleId, uint256 tokenId) = _startFed(w);
        address seller = splitFactory.walletFor(w.item.payees, 0);
        uint256 feeBefore = networkFee.balance;
        _ethBid(saleId, collector, 1 ether);
        _settleAtEnd(saleId);
        assertEq(networkFee.balance - feeBefore, 0.1 ether, "network fee");
        assertEq(seller.balance, 0.9 ether, "seller vault");
        assertEq(fed.ownerOf(tokenId), collector);
        (PrimaryOutcome outcome, address currency, uint256 price) = fed.primarySale(tokenId);
        assertEq(uint8(outcome), uint8(PrimaryOutcome.SOLD));
        assertEq(currency, CURRENCY_ETH);
        assertEq(price, 1 ether);
    }

    function test_Royalty_RoutesNinetyTenThroughTheLedger() public {
        _joinedFed();
        Work memory w = _fedWork(fedArtist);
        (uint256 saleId, uint256 tokenId) = _startFed(w);
        _ethBid(saleId, collector, 1 ether);
        _settleAtEnd(saleId);
        (address vault, uint256 royalty) = fed.royaltyInfo(tokenId, 2 ether);
        assertEq(royalty, uint256(2 ether) * RATE / 100_000);
        vm.deal(address(this), royalty);
        (bool ok,) = vault.call{ value: royalty }("");
        assertTrue(ok);
        address seller = splitFactory.walletFor(w.item.payees, 0);
        ISplitWallet.Payee[] memory payees = Splits.royaltyPayees(seller, networkFee, FED_SHARE);
        uint256 networkIndex = payees[0].account == networkFee ? 0 : 1;
        uint256 before = networkFee.balance;
        splitFactory.release(payees, 0, CURRENCY_ETH, networkIndex);
        assertEq(networkFee.balance - before, royalty / 10, "the network's 10%");
        splitFactory.release(payees, 0, CURRENCY_ETH, 1 - networkIndex);
        assertEq(seller.balance, 0.9 ether + royalty - royalty / 10, "the artist's 90%");
    }

    function testFuzz_Sold_FeeIsExactlyTheLockedShare(uint96 price) public {
        price = uint96(bound(price, 0.05 ether, 1_000_000 ether));
        _joinedFed();
        Work memory w = _fedWork(fedArtist);
        (uint256 saleId,) = _startFed(w);
        uint256 before = networkFee.balance;
        _ethBid(saleId, collector, price);
        _settleAtEnd(saleId);
        assertEq(networkFee.balance - before, uint256(price) * FED_SHARE / 100_000);
        assertEq(
            splitFactory.walletFor(w.item.payees, 0).balance,
            price - uint256(price) * FED_SHARE / 100_000
        );
    }

    // ------------------------------------------------------------------ unsold and restart

    function test_Unbid_StaysInTheTemplatesCustodyAndRestarts() public {
        _joinedFed();
        Work memory w = _fedWork(fedArtist);
        (uint256 saleId, uint256 tokenId) = _startFed(w);
        _settleAtEnd(saleId);
        assertEq(fed.ownerOf(tokenId), address(fed), "never to a person");
        (PrimaryOutcome outcome,,) = fed.primarySale(tokenId);
        assertEq(uint8(outcome), uint8(PrimaryOutcome.UNBID));
        // A restart needs the artist's fresh approval.
        bytes memory data = _mintData(w);
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        auction.start(address(fed), data);
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(w), 0);
        uint256 again = auction.start(address(fed), data);
        uint256 next = auction.auction(again).tokenId;
        assertEq(next, tokenId + 1, "the next ID, for the same work");
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId)
        );
        fed.ownerOf(tokenId);
        assertEq(fed.liveTokenOf(1), next);
        (,,,,, uint32 rate) = fed.coreOf(next);
        assertEq(rate, RATE, "the work keeps its rate");
        _ethBid(again, collector, 1 ether);
        _settleAtEnd(again);
        assertEq(fed.ownerOf(next), collector);
    }

    function test_Restart_RefusedForASoldWork() public {
        _joinedFed();
        Work memory w = _fedWork(fedArtist);
        (uint256 saleId,) = _startFed(w);
        _ethBid(saleId, collector, 1 ether);
        _settleAtEnd(saleId);
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(w), RATE);
        vm.expectRevert(abi.encodeWithSelector(IFederatedStream.WorkNotRestartable.selector, 1));
        auction.start(address(fed), _mintData(w));
    }

    // ------------------------------------------------------------------ helpers

    function _royaltyVault(address seller) internal view returns (address) {
        return splitFactory.walletFor(Splits.royaltyPayees(seller, networkFee, FED_SHARE), 0);
    }
}

/// @dev A federation registry that lists whatever it is told: the residual a governance
///      failure could create, which the template refuses to confirm.
contract HostileLister {
    IArtistRegistry internal immutable _ar;

    constructor(IArtistRegistry ar) {
        _ar = ar;
    }

    function listAs(
        address token,
        address account,
        uint64 deadline,
        bytes calldata sig,
        bytes calldata consent
    ) external {
        uint256 artistId = _ar.registerFederated(account, 0, 0, deadline, sig);
        _ar.listFederatedContract(
            IArtistRegistry.FederatedListing(
                artistId, token, 0, address(0), 0, address(0), deadline
            ),
            consent
        );
    }

    function listUnder(uint256 artistId, address token, uint64 deadline, bytes calldata consent)
        external
    {
        _ar.listFederatedContract(
            IArtistRegistry.FederatedListing(
                artistId, token, 0, address(0), 0, address(0), deadline
            ),
            consent
        );
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IFederationRegistry).interfaceId || id == 0x01ffc9a7;
    }
}

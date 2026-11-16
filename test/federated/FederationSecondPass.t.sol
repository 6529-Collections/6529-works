// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { FederatedEditionAuction } from "src/federated/FederatedEditionAuction.sol";
import { FederatedEditionAuctionLens } from "src/federated/FederatedEditionAuctionLens.sol";
import { FederatedEditions } from "src/federated/FederatedEditions.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { FederationRegistry } from "src/federated/FederationRegistry.sol";
import { Roles } from "src/governance/Roles.sol";
import { IAccounts } from "src/interfaces/IAccounts.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IEntropyModule } from "src/interfaces/IEntropyModule.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederatedToken } from "src/interfaces/IFederatedToken.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { Party, PartyRole, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { MockVrfWrapper } from "../mocks/entropy/EntropyMocks.sol";
import { FederationBase } from "./FederationBase.sol";

/// @notice The second build pass on the federation: a joined contract has no way out and is
///         permanent per copy; delisted (by contract or by account) or suspended, it mints
///         nothing and opens no sale through any adapter, one admitted before included; a
///         replacement registry sells existing listings with no artist signature; works may
///         name collaborators, each consenting from any wallet of their account; VRF works take a
///         seed the requester pays for; the network's share can only fall; and the network can
///         reverse a template revocation.
contract FederationSecondPassTest is FederationBase {
    FederatedEditionAuction internal fea;
    FederatedStream internal pairStream;
    FederatedEditions internal pairEditions;
    MockVrfWrapper internal wrapper;
    address internal collector = makeAddr("collector");
    address internal collab;

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
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(fedRegistry.setAdapter, (address(fea), true))
        );
        (pairStream, pairEditions) = _pair(fedArtist);
        _joinedFed();
        collab = _actor("collaborator");
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = FederationRegistry.reinstateTemplate.selector;
        _mapRole(address(fedRegistry), selectors, Roles.SUCCESSOR_SETTER);
        selectors[0] = VrfEntropyModule.setWrapper.selector;
        _mapRole(address(entropy), selectors, Roles.SUCCESSOR_SETTER);
        wrapper = new MockVrfWrapper();
    }

    // ------------------------------------------------------------------ no way out

    /// @dev The token interface declares no exit (its ID is exactly these seven selectors), a
    ///      call to the removed `leaveFederation()` finds no function, and the `IMintTarget`
    ///      minter setter always refuses, before and after joining.
    function test_NoExit_TheTokenInterfacesHaveNoWayOut() public {
        bytes4 id = IFederatedToken.joinFederation.selector
            ^ IFederatedToken.federationTerms.selector ^ IFederatedToken.federationState.selector
            ^ IFederatedToken.setContractURI.selector ^ IFederatedToken.setOwner.selector
            ^ IFederatedToken.contractURI.selector ^ IFederatedToken.owner.selector;
        assertEq(type(IFederatedToken).interfaceId, id);
        assertEq(IFederatedToken.federationState.selector, bytes4(keccak256("federationState()")));
        address[3] memory tokens = [address(fed), address(pairStream), address(pairEditions)];
        for (uint256 i; i < 3; ++i) {
            vm.prank(fedArtist);
            (bool ok,) = tokens[i].call(abi.encodeWithSignature("leaveFederation()"));
            assertFalse(ok, "no exit");
            vm.prank(fedArtist);
            vm.expectRevert(IFederatedToken.FederationStateInvalid.selector);
            IMintTarget(tokens[i]).setAdmittedMinter(fedArtist, true);
            assertTrue(IFederatedToken(tokens[i]).federationState(), "joined for good");
        }
    }

    /// @dev A copy that never joined mints nothing, through any adapter or its artist.
    function test_NoExit_ANeverJoinedCopyMintsNothing() public {
        FederatedStream solo = _deployStream(fedArtist);
        assertFalse(solo.federationState());
        assertFalse(solo.isAdmittedMinter(address(auction)));
        vm.prank(fedArtist);
        vm.expectRevert(IFederatedToken.FederationStateInvalid.selector);
        solo.setAdmittedMinter(fedArtist, true);
        Work memory w = _fedWork(fedArtist);
        vm.prank(fedArtist);
        solo.approveItem(_itemHash(w), RATE);
        vm.prank(address(auction));
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(auction))
        );
        solo.mint(address(auction), 0, 1, _mintData(w));
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(solo))
        );
        auction.start(address(solo), _mintData(w));
    }

    // ------------------------------------------------------------------ C1

    /// @dev An unbid work back in the template's custody, ready to restart.
    function _unbid() internal returns (Work memory w) {
        w = _fedWork(fedArtist);
        (uint256 saleId,) = _startFed(w);
        _settleAtEnd(saleId);
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(w), RATE);
    }

    /// @dev Neither adapter mints `fed`'s new or restarted works, nor binds `pairEditions`, even
    ///      called directly from the adapter's own address (both were admitted before).
    function _assertNothingMints(Work memory restart) internal {
        Work memory fresh = _fedWork(fedArtist);
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(fresh), RATE);
        Work[2] memory ws = [fresh, restart];
        for (uint256 i; i < 2; ++i) {
            vm.prank(address(auction));
            vm.expectRevert(
                abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(auction))
            );
            fed.mint(address(auction), 0, 1, _mintData(ws[i]));
        }
        Work memory master = _fedMaster(fedArtist, 0);
        vm.prank(address(fea));
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(fea))
        );
        pairEditions.bindMinter(1, master.item);
    }

    function test_C1_ADelistedContractMintsRestartsAndBindsNothing() public {
        Work memory restart = _unbid();
        _setListing(address(fed), IFederationRegistry.Status.DELISTED);
        _setListing(address(pairEditions), IFederationRegistry.Status.DELISTED);
        _assertNothingMints(restart);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(fed))
        );
        auction.start(address(fed), _mintData(restart));
    }

    /// @dev The artist registry reports every contract of a delisted account DELISTED (the
    ///      account flag, `IAccounts.isFederationDelisted`); the templates and the registry need
    ///      nothing more to stop it.
    function test_C1_AnAccountDelistingStopsEveryContractOfTheAccount() public {
        Work memory restart = _unbid();
        address[3] memory tokens = [address(fed), address(pairStream), address(pairEditions)];
        for (uint256 i; i < 3; ++i) {
            vm.mockCall(
                address(artists),
                abi.encodeCall(IArtistRegistry.federatedListing, (tokens[i])),
                abi.encode(uint256(uint160(fedArtist)), IArtistRegistry.FederationStatus.DELISTED)
            );
            assertFalse(fedRegistry.isActive(tokens[i]));
        }
        _assertNothingMints(restart);
        Work memory master = _fedMaster(fedArtist, 0);
        vm.prank(fedArtist);
        pairStream.approveItem(_itemHash(master), RATE);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(pairStream))
        );
        auction.start(address(pairStream), _mintData(master));
    }

    /// @dev A suspended template still serves its running sales (`isActive`) but mints no work
    ///      and opens no edition sale: binding asks `canMint`, as a mint does.
    function test_C1_ASuspendedTemplateMintsNothingAndOpensNoSale() public {
        // Suspension is the network's at 24 hours: schedule both first, so the master's 1/1
        // sale started below is still running when they land.
        bytes memory s1 = abi.encodeCall(fedRegistry.suspendTemplate, (streamHash));
        bytes memory s2 = abi.encodeCall(fedRegistry.suspendTemplate, (editionsHash));
        vm.startPrank(hotAdmin);
        manager.schedule(address(fedRegistry), s1, 0);
        manager.schedule(address(fedRegistry), s2, 0);
        vm.stopPrank();
        Work memory restart = _unbid();
        vm.warp(block.timestamp + 24 hours);
        Work memory master = _fedMaster(fedArtist, 0);
        (, uint256 masterToken) = _startFed(pairStream, fedArtist, master, RATE);
        vm.startPrank(hotAdmin);
        manager.execute(address(fedRegistry), s1);
        manager.execute(address(fedRegistry), s2);
        vm.stopPrank();
        assertTrue(fedRegistry.isActive(address(fed)), "running sales are served");
        _assertNothingMints(restart);
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(auction))
        );
        auction.start(address(fed), _mintData(restart));
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(fea))
        );
        fea.open(address(pairEditions), masterToken, abi.encode(master.item));
    }

    // ------------------------------------------------------------------ C3

    /// @dev The network installs a replacement registry and re-approves the template versions
    ///      and the adapter; an item the artist approved before sells through it with no
    ///      signature or call by the artist, and the network is paid.
    function test_C3_AReplacementRegistrySellsAnExistingListing() public {
        Work memory w = _fedWork(fedArtist);
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(w), RATE);
        FederationRegistry next = new FederationRegistry(
            address(manager), address(artists), address(economics), address(store)
        );
        _mapRegistryRoles(address(next));
        _approveTemplates(next);
        _govern(hotAdmin, address(next), abi.encodeCall(next.setAdapter, (address(auction), true)));
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(artists.setFederationRegistry, (address(fedRegistry), address(next)))
        );
        IFederationRegistry.Entry memory e = next.entry(address(fed));
        assertEq(uint8(e.status), uint8(IFederationRegistry.Status.ACTIVE), "inherited listing");
        assertEq(e.feeShare, FED_SHARE);
        uint256 saleId = auction.start(address(fed), _mintData(w));
        _ethBid(saleId, collector, 1 ether);
        uint256 before = networkFee.balance;
        _settleAtEnd(saleId);
        assertEq(networkFee.balance - before, 0.1 ether);
    }

    // ------------------------------------------------------------------ collaborators

    /// @dev `w` with `collab` as a second party, paid at a fixed address.
    function _withCollaborator(Work memory w) internal view returns (Work memory) {
        w.item.parties = new Party[](2);
        w.item.parties[0] = Party(fedArtist, uint8(PartyRole.ARTIST));
        w.item.parties[1] = Party(collab, uint8(PartyRole.COLLABORATOR));
        w.item.payees = new ISplitWallet.Payee[](2);
        // The canonical order: ascending by (artist ID, account), so fixed payees first.
        w.item.payees[0] = ISplitWallet.Payee(0, collab, 40_000);
        w.item.payees[1] = ISplitWallet.Payee(uint160(fedArtist), address(0), 60_000);
        return w;
    }

    /// @dev `wallet`'s consent to `w` for `token`: its address, then its signature.
    function _consent(address wallet, address token, Work memory w)
        internal
        view
        returns (bytes[] memory c)
    {
        c = new bytes[](1);
        c[0] = abi.encodePacked(
            wallet, _sign(wallet, IAccounts(address(artists)).consentDigest(token, _itemHash(w)))
        );
    }

    function test_Collaborators_AWorkMintsOnlyWithEveryPartysConsent() public {
        Work memory w = _withCollaborator(_fedWork(fedArtist));
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(w), RATE);
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        auction.start(address(fed), _mintData(w));
        address stranger = _actor("stranger");
        bytes memory data = _mintData(w, _consent(stranger, address(fed), w));
        vm.expectRevert(
            abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, stranger)
        );
        auction.start(address(fed), data);
        data = _mintData(w, _consent(collab, address(fed), w));
        vm.expectEmit(true, true, false, true, address(fed));
        emit IFederatedStream.WorkOpened(
            1,
            _itemHash(w),
            splitFactory.walletFor(w.item.payees, 0),
            RATE,
            FED_SHARE,
            w.item,
            w.media
        );
        uint256 saleId = auction.start(address(fed), data);
        uint256 tokenId = auction.auction(saleId).tokenId;
        assertEq(fed.work(tokenId).seller, splitFactory.walletFor(w.item.payees, 0));
    }

    /// @dev Consent is counted by account: any wallet of the collaborator's consolidated account
    ///      signs (the artist registry answers `isWallet`).
    function test_Collaborators_AnyWalletOfTheAccountConsents() public {
        address second = _actor("collaboratorSecondWallet");
        // The collaborator is a registered account whose root is consolidated with `second`.
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _sign(collab, artists.registrationDigest(collab, 0, 0, deadline));
        vm.prank(address(fedRegistry));
        artists.registerFederated(collab, 0, 0, deadline, sig);
        address all = 0x8888888888888888888888888888888888888888;
        vm.prank(collab);
        delegation.registerDelegationAddress(all, second, type(uint64).max, 999, true, 0);
        vm.prank(second);
        delegation.registerDelegationAddress(all, collab, type(uint64).max, 999, true, 0);
        assertTrue(IAccounts(address(artists)).isWallet(uint256(uint160(collab)), second));
        Work memory w = _withCollaborator(_fedWork(fedArtist));
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(w), RATE);
        uint256 saleId =
            auction.start(address(fed), _mintData(w, _consent(second, address(fed), w)));
        assertGt(saleId, 0);
    }

    /// @dev A consent names the contract it is good for: one given for another contract of the
    ///      same artist is refused here.
    function test_Collaborators_AConsentForOneContractIsRefusedByAnother() public {
        Work memory w = _withCollaborator(_fedWork(fedArtist));
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(w), RATE);
        bytes memory data = _mintData(w, _consent(collab, address(pairStream), w));
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, collab));
        auction.start(address(fed), data);
    }

    /// @dev An artist-resolved payee must be a party whose payout resolves now: an unregistered
    ///      collaborator can be paid only at a fixed address.
    function test_Collaborators_ArtistResolvedPayeesNeedAPartyWithAPayout() public {
        Work memory w = _withCollaborator(_fedWork(fedArtist));
        (uint160 lo, uint160 hi) = uint160(collab) < uint160(fedArtist)
            ? (uint160(collab), uint160(fedArtist))
            : (uint160(fedArtist), uint160(collab));
        w.item.payees[0] = ISplitWallet.Payee(lo, address(0), 40_000);
        w.item.payees[1] = ISplitWallet.Payee(hi, address(0), 60_000);
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(w), RATE);
        bytes memory data = _mintData(w, _consent(collab, address(fed), w));
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        auction.start(address(fed), data);
    }

    // ------------------------------------------------------------------ the artist's wallets

    /// @dev Every artist power asks the artist registry: another wallet of the account acts, and
    ///      no wallet acts while the account is frozen.
    function test_Artist_AnyWalletOfTheAccountActsAndNoneWhileFrozen() public {
        address second = _actor("artistSecondWallet");
        vm.mockCall(
            address(artists),
            abi.encodeCall(IAccounts.isWallet, (uint256(uint160(fedArtist)), second)),
            abi.encode(true)
        );
        vm.prank(second);
        fed.approveItem(keccak256("item"), RATE);
        vm.mockCall(
            address(artists),
            abi.encodeCall(IAccounts.isWallet, (uint256(uint160(fedArtist)), fedArtist)),
            abi.encode(false)
        );
        vm.prank(fedArtist);
        vm.expectRevert(abi.encodeWithSelector(IFederatedToken.NotArtist.selector, fedArtist));
        fed.approveItem(keccak256("item"), RATE);
    }

    // ------------------------------------------------------------------ VRF

    function _vrfWork() internal returns (Work memory w) {
        w = _fedWork(fedArtist);
        w.item.seedPolicy = uint8(SeedPolicy.VRF);
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(w), RATE);
    }

    function _setWrapper() internal {
        _govern(
            hotAdmin,
            address(entropy),
            abi.encodeCall(
                entropy.setWrapper, (address(0), address(wrapper), address(wrapper).codehash)
            )
        );
    }

    /// @dev The artist requests `w`'s seed paying the quote: the provider gets it, the network's
    ///      subscription is not used.
    function _paidRequest(Work memory w) internal returns (uint256 requestId) {
        uint256 price = wrapper.price();
        uint256 subscriptionRequests = coordinator.nextId();
        vm.deal(fedArtist, price);
        bytes32 key = keccak256(abi.encode(address(fed), w.item.contentHash));
        vm.expectEmit(address(entropy));
        emit IEntropyModule.FederatedSeedRequested(address(fed), w.item.contentHash, key, 7001);
        vm.prank(fedArtist);
        requestId = entropy.requestFederatedSeed{ value: price }(address(fed), w.item);
        assertEq(wrapper.received(), price, "the requester paid the provider");
        assertEq(coordinator.nextId(), subscriptionRequests, "no subscription request");
    }

    /// @dev The wrapper delivers `word`: the seed is fixed for `fed` and the content only.
    function _deliver(Work memory w, uint256 requestId, uint256 word) internal {
        bytes32 key = keccak256(abi.encode(address(fed), w.item.contentHash));
        vm.expectEmit(address(entropy));
        emit IEntropyModule.SeedDelivered(key, requestId, bytes32(word));
        wrapper.fulfill(requestId, word);
        (bool delivered, bytes32 seed) = entropy.federatedSeedOf(address(fed), w.item.contentHash);
        assertTrue(delivered);
        assertEq(seed, bytes32(word));
        (bool other,) = entropy.federatedSeedOf(address(pairStream), w.item.contentHash);
        assertFalse(other, "keyed by contract");
    }

    /// @dev The artist requests and pays the provider's quote; no network subscription is used;
    ///      the work mints only once the seed is delivered and keeps it.
    function test_Vrf_AWorkMintsOnlyAfterDeliveryAndKeepsItsSeed() public {
        _setWrapper();
        Work memory w = _vrfWork();
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        auction.start(address(fed), _mintData(w));
        uint256 requestId = _paidRequest(w);
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        auction.start(address(fed), _mintData(w));
        uint256 word = uint256(keccak256("federated randomness"));
        _deliver(w, requestId, word);
        uint256 saleId = auction.start(address(fed), _mintData(w));
        uint256 tokenId = auction.auction(saleId).tokenId;
        (uint8 policy, bytes32 stored) = fed.seedOf(tokenId);
        assertEq(policy, uint8(SeedPolicy.VRF));
        assertEq(stored, bytes32(word));
        // A late delivery changes nothing.
        vm.expectRevert(
            abi.encodeWithSelector(IEntropyModule.SeedAlreadyDelivered.selector, _itemHash(w))
        );
        vm.prank(fedArtist);
        entropy.requestFederatedSeed(address(fed), w.item);
    }

    /// @dev The request gate: a provider set, a VRF item with content, the contract listed
    ///      ACTIVE, the caller a wallet of its artist, the quote paid; one request pending.
    function test_Vrf_OnlyAnArtistWalletOfAListedContractRequestsAndPays() public {
        Work memory w = _vrfWork();
        bytes32 h = _itemHash(w);
        uint256 price = wrapper.price();
        vm.deal(fedArtist, 10 * price);
        vm.prank(fedArtist);
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.NotRequestable.selector, h));
        entropy.requestFederatedSeed{ value: price }(address(fed), w.item);
        _setWrapper();
        vm.deal(collector, price);
        vm.prank(collector);
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.NotRequestable.selector, h));
        entropy.requestFederatedSeed{ value: price }(address(fed), w.item);
        vm.prank(fedArtist);
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.InsufficientPayment.selector, price));
        entropy.requestFederatedSeed{ value: price - 1 }(address(fed), w.item);
        Work memory plain = _fedWork(fedArtist);
        vm.prank(fedArtist);
        vm.expectRevert(
            abi.encodeWithSelector(IEntropyModule.NotRequestable.selector, _itemHash(plain))
        );
        entropy.requestFederatedSeed{ value: price }(address(fed), plain.item);
        vm.prank(fedArtist);
        entropy.requestFederatedSeed{ value: price }(address(fed), w.item);
        vm.prank(fedArtist);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEntropyModule.RequestPending.selector, h, uint64(block.timestamp + 3 days)
            )
        );
        entropy.requestFederatedSeed{ value: price }(address(fed), w.item);
        _setListing(address(fed), IFederationRegistry.Status.DELISTED);
        vm.warp(block.timestamp + 30 days);
        vm.prank(fedArtist);
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.NotRequestable.selector, h));
        entropy.requestFederatedSeed{ value: price }(address(fed), w.item);
    }

    /// @dev Only the wrapper delivers a federated request, and the coordinator cannot deliver
    ///      it; the wrapper setter is compare-and-set and governed.
    function test_Vrf_TheWrapperAloneDeliversItsRequests() public {
        vm.expectRevert();
        entropy.setWrapper(address(0), address(wrapper), address(wrapper).codehash);
        _setWrapper();
        assertEq(entropy.wrapper(), address(wrapper));
        Work memory w = _vrfWork();
        uint256 price = wrapper.price();
        vm.deal(fedArtist, price);
        vm.prank(fedArtist);
        uint256 requestId = entropy.requestFederatedSeed{ value: price }(address(fed), w.item);
        uint256[] memory words = new uint256[](1);
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.UnknownRequest.selector, requestId));
        coordinator.deliver(address(entropy), requestId, words);
        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEntropyModule.OnlyCoordinatorCanFulfill.selector, collector, address(coordinator)
            )
        );
        entropy.rawFulfillRandomWords(requestId, words);
    }

    // ------------------------------------------------------------------ R8

    function _record(uint32 share) internal {
        vm.mockCall(
            address(artists),
            abi.encodeCall(IAccounts.federatedFeeShare, (address(fed))),
            abi.encode(share)
        );
    }

    /// @dev The share in force is the smaller of the deployed share and the artist registry's
    ///      record: sales, terms and royalties all follow it.
    function _assertShareInForce(uint32 recorded, uint32 expected) internal {
        _record(recorded);
        assertEq(fedRegistry.entry(address(fed)).feeShare, expected);
        (uint256 saleId, uint256 tokenId) = _startFed(_fedWork(fedArtist));
        assertEq(fed.primaryTerms(tokenId, "").feeShare, expected);
        address seller = fed.work(tokenId).seller;
        (address receiver,) = fed.royaltyInfo(tokenId, 1 ether);
        address vault = expected == 0
            ? seller
            : splitFactory.walletFor(Splits.royaltyPayees(seller, networkFee, expected), 0);
        assertEq(receiver, vault);
        if (expected != 0) assertGt(vault.code.length, 0, "deployed at mint");
        _ethBid(saleId, collector, 1 ether);
        uint256 before = networkFee.balance;
        _settleAtEnd(saleId);
        assertEq(networkFee.balance - before, uint256(1 ether) * expected / Splits.DENOMINATOR);
    }

    function test_FeeShare_TheLoweredShareIsUsed() public {
        _assertShareInForce(5000, 5000);
    }

    function test_FeeShare_AHigherRecordChangesNothing() public {
        _assertShareInForce(20_000, FED_SHARE);
    }

    function test_FeeShare_AZeroShareRoutesRoyaltiesToTheSeller() public {
        _assertShareInForce(0, 0);
    }

    function testFuzz_FeeShare_NeverAboveTheDeployedShare(uint32 recorded) public {
        _record(recorded);
        uint32 expected = recorded < FED_SHARE ? recorded : FED_SHARE;
        assertEq(fedRegistry.entry(address(fed)).feeShare, expected);
    }

    // ------------------------------------------------------------------ C26

    function test_C26_AReinstatedTemplateMintsAgain() public {
        _govern(
            hotAdmin, address(fedRegistry), abi.encodeCall(fedRegistry.revokeTemplate, (streamHash))
        );
        address[] memory tokens = new address[](1);
        tokens[0] = address(fed);
        fedRegistry.propagateRevocation(tokens);
        Work memory w = _fedWork(fedArtist);
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(w), RATE);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(fed))
        );
        auction.start(address(fed), _mintData(w));
        bytes memory reinstate = abi.encodeCall(fedRegistry.reinstateTemplate, (streamHash));
        (, uint32 delay) = manager.canCall(hotAdmin, address(fedRegistry), bytes4(reinstate));
        vm.prank(hotAdmin);
        manager.schedule(address(fedRegistry), reinstate, 0);
        vm.warp(block.timestamp + delay);
        FederationRegistry.Template memory t = fedRegistry.templateOf(streamHash);
        vm.expectEmit(address(fedRegistry));
        emit FederationRegistry.TemplateSet(
            streamHash,
            t.deployer,
            keccak256(type(FederatedStream).creationCode),
            t.version,
            IFederationRegistry.Form.ERC721,
            FederationRegistry.TemplateStatus.APPROVED
        );
        vm.prank(hotAdmin);
        manager.execute(address(fedRegistry), reinstate);
        assertEq(
            uint8(fedRegistry.templateOf(streamHash).status),
            uint8(FederationRegistry.TemplateStatus.APPROVED)
        );
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(fed))
        );
        auction.start(address(fed), _mintData(w));
        _setListing(address(fed), IFederationRegistry.Status.ACTIVE);
        uint256 saleId = auction.start(address(fed), _mintData(w));
        assertGt(saleId, 0);
    }

    function test_C26_ReinstateOnlyAReverseOfARevocation() public {
        bytes memory call = abi.encodeCall(fedRegistry.reinstateTemplate, (streamHash));
        assertFalse(
            _governTry(hotAdmin, address(fedRegistry), call), "approved: nothing to reverse"
        );
        vm.prank(collector);
        vm.expectRevert();
        fedRegistry.reinstateTemplate(streamHash);
    }
}

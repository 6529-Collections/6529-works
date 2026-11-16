// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ContentStore } from "src/content/ContentStore.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { FederationRegistry } from "src/federated/FederationRegistry.sol";
import { Vm } from "forge-std/Vm.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { FederationBase } from "./FederationBase.sol";
import { HostileLister } from "./FederatedSale.t.sol";

/// @notice What a listing proves and what an exit cannot undo: a contract joins only as the
///         deterministic deployment proxy's deployment of an approved creation code with the
///         arguments it presents (so its starting storage is the constructor's), naming the
///         canonical content store; no federation registry lists a contract under an artist
///         who did not sign for it; an exit never serves more than the status it left; and an
///         adapter still pointing at a replaced registry answers as the current one.
contract FederationProvenanceTest is FederationBase {
    address internal collector = makeAddr("collector");

    // ------------------------------------------------------------------ provenance (F1)

    /// @dev The approved runtime code with storage its constructor never wrote (here the
    ///      English auction approves the artist as operator of everything it holds) is not the
    ///      proxy's deployment of the approved creation code with any arguments, so it never
    ///      joins; the genuine copy does.
    function test_Provenance_ACopyNotDeployedFromTheApprovedCodeNeverJoins() public {
        IFederatedStream.Config memory c = _streamConfig(fedArtist);
        FederatedStream copy = new FederatedStream(c);
        // ERC-721 `_operatorApprovals` is slot 5: owner the auction, operator the artist.
        bytes32 slot =
            keccak256(abi.encode(fedArtist, keccak256(abi.encode(address(auction), uint256(5)))));
        vm.store(address(copy), slot, bytes32(uint256(1)));
        assertTrue(copy.isApprovedForAll(address(auction), fedArtist));
        assertEq(address(copy).codehash, streamHash, "the approved runtime code");
        bytes memory refused =
            abi.encodeWithSelector(IFederationRegistry.NotListable.selector, address(copy));
        provenanceConfig[address(copy)] = abi.encode(c);
        _join(address(copy), fedArtist, refused);
        // Another copy's salt and arguments name that copy's address, not this one.
        provenanceSalt[address(copy)] = provenanceSalt[address(fed)];
        provenanceConfig[address(copy)] = provenanceConfig[address(fed)];
        _join(address(copy), fedArtist, refused);
        _join(address(fed), fedArtist);
        (, IArtistRegistry.FederationStatus status) = artists.federatedListing(address(copy));
        assertEq(uint8(status), uint8(IArtistRegistry.FederationStatus.NONE));
    }

    /// @dev A genuine copy must present exactly its salt and constructor arguments.
    function test_Provenance_TheSaltAndArgumentsMustBeTheDeployments() public {
        bytes memory refused =
            abi.encodeWithSelector(IFederationRegistry.NotListable.selector, address(fed));
        bytes32 salt = provenanceSalt[address(fed)];
        IFederatedStream.Config memory c = _streamConfig(fedArtist);
        c.name = "Other Works";
        provenanceConfig[address(fed)] = abi.encode(c);
        _join(address(fed), fedArtist, refused);
        provenanceConfig[address(fed)] = abi.encode(_streamConfig(fedArtist));
        provenanceSalt[address(fed)] = bytes32(uint256(salt) + 1);
        _join(address(fed), fedArtist, refused);
        provenanceSalt[address(fed)] = salt;
        vm.expectEmit(address(fedRegistry));
        emit IFederationRegistry.Registered(
            address(fed), uint160(fedArtist), streamHash, salt, abi.encode(_streamConfig(fedArtist))
        );
        _join(address(fed), fedArtist);
    }

    /// @dev Approval binds the creation code; until that code is published, nothing joins.
    function test_Provenance_UnpublishedCodeJoinsNothing() public {
        FederationRegistry next = new FederationRegistry(
            address(manager), address(artists), address(economics), address(store)
        );
        _mapRegistryRoles(address(next));
        _govern(
            hotAdmin,
            address(next),
            abi.encodeCall(
                next.approveTemplate,
                (
                    streamHash,
                    keccak256(type(FederatedStream).creationCode),
                    1,
                    IFederationRegistry.Form.ERC721
                )
            )
        );
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(artists.setFederationRegistry, (address(fedRegistry), address(next)))
        );
        _join(
            address(fed),
            fedArtist,
            abi.encodeWithSelector(IFederationRegistry.NotListable.selector, address(fed))
        );
        // Publication is permissionless and checked: the bytes are rehashed here.
        address[] memory pointers =
            fedRegistry.codeOf(keccak256(type(FederatedStream).creationCode));
        assertEq(next.publishCode(pointers), keccak256(type(FederatedStream).creationCode));
        _join(address(fed), fedArtist);
    }

    // ------------------------------------------------------------------ the content store (F6)

    function test_Join_RefusesAContentStoreOtherThanTheCanonicalOne() public {
        ContentStore other = new ContentStore();
        IFederatedStream.Config memory c = _streamConfig(fedArtist);
        c.contentStore = address(other);
        vm.recordLogs();
        FederatedStream copy = _deployStream(c);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IFederatedStream.ContentStoreSet.selector) {
                assertEq(logs[i].data, abi.encode(address(other)));
                seen = true;
            }
        }
        assertTrue(seen, "ContentStoreSet");
        assertEq(copy.contentStore(), address(other));
        assertEq(fed.contentStore(), address(store));
        assertEq(fedRegistry.contentStore(), address(store));
        _join(
            address(copy),
            fedArtist,
            abi.encodeWithSelector(IFederationRegistry.NotListable.selector, address(copy))
        );
    }

    // ------------------------------------------------------------------ consent (F4)

    /// @dev A registry swapped in by governance lists nothing under a canonical (curated)
    ///      artist without that artist's own signature for that contract, verified by the
    ///      permanent artist registry.
    function test_Directory_NoRegistryListsUnderAnArtistWhoDidNotSign() public {
        address curated = _actor("curatedArtist");
        Work[] memory works = new Work[](1);
        works[0] = _work(curated, 0);
        _publish(works);
        uint256 curatedId = artists.artistIdOf(curated);
        assertEq(curatedId, uint160(curated), "a canonical artist");
        HostileLister hostile = new HostileLister(artists);
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(artists.setFederationRegistry, (address(fedRegistry), address(hostile)))
        );
        address scam = address(_deployStream(curated));
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory refused =
            abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, curated);
        vm.expectRevert(refused);
        hostile.listUnder(curatedId, scam, deadline, "");
        bytes memory forged = _consent(fedArtist, curatedId, scam, deadline);
        vm.expectRevert(refused);
        hostile.listUnder(curatedId, scam, deadline, forged);
        bytes memory elsewhere = _consent(curated, curatedId, address(fed), deadline);
        vm.expectRevert(refused);
        hostile.listUnder(curatedId, scam, deadline, elsewhere);
        bytes memory expired = _consent(curated, curatedId, scam, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(
            abi.encodeWithSelector(SignatureVerifier.SignatureExpired.selector, deadline)
        );
        hostile.listUnder(curatedId, scam, deadline, expired);
        _assertStatus(scam, IArtistRegistry.FederationStatus.NONE);
        // The artist's own signature is the only way in.
        deadline = uint64(block.timestamp + 1 days);
        hostile.listUnder(curatedId, scam, deadline, _consent(curated, curatedId, scam, deadline));
        _assertStatus(scam, IArtistRegistry.FederationStatus.ACTIVE);
    }

    function _consent(address signer, uint256 artistId, address token, uint64 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(signer, artists.listingDigest(artistId, token, deadline));
    }

    function _assertStatus(address token, IArtistRegistry.FederationStatus expected) internal view {
        (, IArtistRegistry.FederationStatus status) = artists.federatedListing(token);
        assertEq(uint8(status), uint8(expected));
    }

    // ------------------------------------------------------------------ exits (F2)

    /// @dev Delisted, then left: LEFT_DELISTED, served by nothing, so the running sale ends
    ///      unsold with the bid refunded and the work back in the template's custody.
    function test_Exit_AfterADelistingRevivesNoSale() public {
        _joinedFed();
        (uint256 saleId, uint256 tokenId) = _startFed(_fedWork(fedArtist));
        _ethBid(saleId, collector, 1 ether);
        _delist(address(fed));
        assertFalse(auction.isTarget(address(fed)));
        vm.prank(fedArtist);
        fed.leaveFederation();
        (, IArtistRegistry.FederationStatus status) = artists.federatedListing(address(fed));
        assertEq(uint8(status), uint8(IArtistRegistry.FederationStatus.LEFT_DELISTED));
        assertFalse(fedRegistry.isActive(address(fed)), "not served");
        assertFalse(auction.isTarget(address(fed)), "no bid or settlement as sold");
        assertEq(uint8(fedRegistry.entry(address(fed)).status), 0, "no entry");
        _settleAtEnd(saleId);
        assertEq(auction.claimable(collector, CURRENCY_ETH), 1 ether, "refunded");
        assertEq(fed.ownerOf(tokenId), address(fed), "unsold, with the template");
    }

    /// @dev Left while ACTIVE, the running sale still finishes as sold (FED-8).
    function test_Exit_FromActiveLetsTheRunningSaleFinish() public {
        _joinedFed();
        (uint256 saleId, uint256 tokenId) = _startFed(_fedWork(fedArtist));
        _ethBid(saleId, collector, 1 ether);
        vm.prank(fedArtist);
        fed.leaveFederation();
        assertTrue(fedRegistry.isActive(address(fed)));
        _settleAtEnd(saleId);
        assertEq(fed.ownerOf(tokenId), collector);
    }

    // ------------------------------------------------------------------ one pointer (F7)

    /// @dev Only the artist registry's pointer is replaced: the English auction still names the
    ///      genesis registry, which answers as the current one, so a revocation there voids the
    ///      English auction's running sale too.
    function test_Replacement_TheEnglishAuctionAnswersAsTheCurrentRegistry() public {
        _joinedFed();
        (uint256 saleId, uint256 tokenId) = _startFed(_fedWork(fedArtist));
        _ethBid(saleId, collector, 1 ether);
        FederationRegistry next = new FederationRegistry(
            address(manager), address(artists), address(economics), address(store)
        );
        _mapRegistryRoles(address(next));
        _approveTemplates(next);
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(artists.setFederationRegistry, (address(fedRegistry), address(next)))
        );
        assertEq(
            ISaleAdapter(address(auction)).federationRegistry(),
            address(fedRegistry),
            "the auction's own pointer"
        );
        assertEq(fedRegistry.entry(address(fed)).templateVersion, 1);
        _govern(hotAdmin, address(next), abi.encodeCall(next.revokeTemplate, (streamHash)));
        assertFalse(next.isActive(address(fed)));
        assertFalse(fedRegistry.isActive(address(fed)), "the old registry answers as the new");
        assertFalse(fedRegistry.canMint(address(fed), address(auction)));
        assertFalse(auction.isTarget(address(fed)));
        _settleAtEnd(saleId);
        assertEq(auction.claimable(collector, CURRENCY_ETH), 1 ether, "refunded");
        assertEq(fed.ownerOf(tokenId), address(fed));
    }

    function _delist(address token) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(fedRegistry.setStatus, (tokens, IFederationRegistry.Status.DELISTED, 0))
        );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ContentStore } from "src/content/ContentStore.sol";
import { FederatedDeployer } from "src/federated/FederatedDeployer.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { FederationRegistry } from "src/federated/FederationRegistry.sol";
import { Vm } from "forge-std/Vm.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IFederatedDeployer } from "src/interfaces/IFederatedDeployer.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederatedToken } from "src/interfaces/IFederatedToken.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { SSTORE2 } from "src/libraries/SSTORE2.sol";
import { VerifyV1 } from "script/VerifyV1.sol";
import { FederationBase } from "./FederationBase.sol";
import { HostileLister } from "./FederatedSale.t.sol";

/// @notice What a listing proves and what an exit cannot undo: a contract joins only if its
///         version's approved deployer recorded it (so its starting storage is the
///         constructor's), naming the canonical content store; no federation registry lists a
///         contract under an artist who did not sign for it and its facts; neither an exit nor
///         its timing serves more than governance decided; and an adapter still pointing at a
///         replaced registry answers as the current one.
contract FederationProvenanceTest is FederationBase {
    address internal collector = makeAddr("collector");

    // ------------------------------------------------------------------ provenance (F1, G3)

    /// @dev The approved runtime code with storage its constructor never wrote (here the
    ///      English auction approves the artist as operator of everything it holds) was not
    ///      recorded by the version's deployer, so it never joins; the genuine copy does.
    function test_Provenance_ACopyNotRecordedByTheApprovedDeployerNeverJoins() public {
        IFederatedStream.Config memory c = _streamConfig(fedArtist);
        FederatedStream copy = new FederatedStream(c);
        // ERC-721 `_operatorApprovals` is slot 5: owner the auction, operator the artist.
        bytes32 slot =
            keccak256(abi.encode(fedArtist, keccak256(abi.encode(address(auction), uint256(5)))));
        vm.store(address(copy), slot, bytes32(uint256(1)));
        assertTrue(copy.isApprovedForAll(address(auction), fedArtist));
        assertEq(address(copy).codehash, streamHash, "the approved runtime code");
        assertFalse(deployment.federatedStreamDeployer.deployed(address(copy)));
        _join(
            address(copy),
            fedArtist,
            abi.encodeWithSelector(IFederationRegistry.NotListable.selector, address(copy))
        );
        _join(address(fed), fedArtist);
        _assertStatus(address(copy), IArtistRegistry.FederationStatus.NONE);
    }

    /// @dev Only the approved deployer counts: another deployer of the very same creation code
    ///      (genuine runtime, constructor storage) is not the approved one, so its copy never
    ///      joins.
    function test_Provenance_OnlyTheApprovedDeployersRecordCounts() public {
        FederatedDeployer other = new FederatedDeployer(type(FederatedStream).creationCode);
        assertEq(other.creationHash(), keccak256(type(FederatedStream).creationCode));
        address copy = other.deploy(bytes32(0), abi.encode(_streamConfig(fedArtist)));
        assertEq(copy.codehash, streamHash);
        assertTrue(other.deployed(copy));
        _join(
            copy, fedArtist, abi.encodeWithSelector(IFederationRegistry.NotListable.selector, copy)
        );
    }

    /// @dev The deployer: anyone may call; it deploys its one creation code with the caller's
    ///      arguments, under a salt bound to the caller, records and announces each copy, and
    ///      bubbles a constructor's refusal; a taken address reverts.
    function test_Deployer_DeploysOnlyItsCodeAndRecordsEveryCopy() public {
        FederatedDeployer d = deployment.federatedStreamDeployer;
        assertEq(address(d).codehash, keccak256(type(FederatedDeployer).runtimeCode));
        address[] memory pointers = d.codeOf();
        bytes memory code;
        for (uint256 i; i < pointers.length; ++i) {
            code = bytes.concat(code, SSTORE2.read(pointers[i]));
        }
        assertEq(keccak256(code), d.creationHash());
        assertEq(d.creationHash(), keccak256(type(FederatedStream).creationCode));
        bytes memory config = abi.encode(_streamConfig(fedArtist));
        address stranger = makeAddr("stranger");
        vm.recordLogs();
        vm.prank(stranger);
        address a = d.deploy(bytes32("s"), config);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory last = logs[logs.length - 1];
        assertEq(last.topics[0], IFederatedDeployer.Deployed.selector);
        assertEq(address(uint160(uint256(last.topics[1]))), a);
        assertEq(address(uint160(uint256(last.topics[2]))), stranger);
        assertEq(last.data, abi.encode(bytes32("s"), config));
        assertTrue(d.deployed(a));
        assertEq(a.codehash, streamHash);
        // The same salt from another caller is another address: no one takes the caller's.
        vm.prank(collector);
        address b = d.deploy(bytes32("s"), config);
        assertTrue(a != b && d.deployed(b));
        // The same caller and salt again: the address is taken (CREATE2 fails with no data).
        vm.prank(stranger);
        vm.expectRevert(bytes(""));
        d.deploy(bytes32("s"), config);
        // The constructor's own refusal comes back unchanged.
        IFederatedStream.Config memory bad = _streamConfig(fedArtist);
        bad.feeShare = 100_000;
        vm.expectRevert(IFederatedToken.InvalidConfig.selector);
        d.deploy(bytes32("t"), abi.encode(bad));
        vm.expectRevert(IFederatedDeployer.EmptyCreationCode.selector);
        new FederatedDeployer("");
    }

    /// @dev A copy deployed "for" an artist by anyone does nothing until that artist joins it.
    function test_Provenance_ACopyAnyoneDeploysIsInertUntilItsArtistJoins() public {
        vm.prank(collector);
        address copy = deployment.federatedStreamDeployer
            .deploy(bytes32("for"), abi.encode(_streamConfig(fedArtist)));
        assertFalse(IFederatedToken(copy).isAdmittedMinter(address(auction)));
        IFederationRegistry.Join memory j = _joinRequest(copy, fedArtist);
        vm.prank(collector);
        vm.expectRevert(abi.encodeWithSelector(IFederatedToken.NotArtist.selector, collector));
        IFederatedToken(copy).joinFederation(j);
        _join(copy, fedArtist);
        assertTrue(IFederatedToken(copy).isAdmittedMinter(address(auction)));
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
        _refusedConsents(hostile, curated, curatedId, scam, deadline);
        _assertStatus(scam, IArtistRegistry.FederationStatus.NONE);
        // The artist's own signature is the only way in.
        deadline = uint64(block.timestamp + 1 days);
        hostile.listUnder(curatedId, scam, deadline, _consent(curated, curatedId, scam, deadline));
        _assertStatus(scam, IArtistRegistry.FederationStatus.ACTIVE);
    }

    /// @dev No consent, a forged one, one for another token, one for other facts and an expired
    ///      one are each refused.
    function _refusedConsents(
        HostileLister hostile,
        address curated,
        uint256 curatedId,
        address scam,
        uint64 deadline
    ) internal {
        bytes memory refused = abi.encodeWithSelector(
            SignatureVerifier.InvalidSignature.selector, curated
        );
        vm.expectRevert(refused);
        hostile.listUnder(curatedId, scam, deadline, "");
        bytes memory forged = _consent(fedArtist, curatedId, scam, deadline);
        vm.expectRevert(refused);
        hostile.listUnder(curatedId, scam, deadline, forged);
        bytes memory elsewhere = _consent(curated, curatedId, address(fed), deadline);
        vm.expectRevert(refused);
        hostile.listUnder(curatedId, scam, deadline, elsewhere);
        // A consent to this token with other facts (a fee share) is not consent to these.
        bytes memory otherFacts = _sign(
            curated,
            _listingDigest(
                IArtistRegistry.FederatedListing(
                    curatedId, scam, 0, address(0), 10_000, address(0), deadline
                )
            )
        );
        vm.expectRevert(refused);
        hostile.listUnder(curatedId, scam, deadline, otherFacts);
        bytes memory expired = _consent(curated, curatedId, scam, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(
            abi.encodeWithSelector(SignatureVerifier.SignatureExpired.selector, deadline)
        );
        hostile.listUnder(curatedId, scam, deadline, expired);
    }

    function _consent(address signer, uint256 artistId, address token, uint64 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            signer,
            _listingDigest(
                IArtistRegistry.FederatedListing(
                    artistId, token, 0, address(0), 0, address(0), deadline
                )
            )
        );
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

    // ------------------------------------------------------------------ exit timing (G1)

    /// @dev A delisting scheduled before the artist leaves still lands at execution (LEFT
    ///      becomes LEFT_DELISTED): the running sale ends unsold with the bid refunded.
    function test_Delisting_ScheduledBeforeAnExitStillLands() public {
        _joinedFed();
        (uint256 saleId, uint256 tokenId) = _startFed(_fedWork(fedArtist));
        _ethBid(saleId, collector, 1 ether);
        address[] memory tokens = new address[](1);
        tokens[0] = address(fed);
        bytes memory call = abi.encodeCall(
            fedRegistry.setStatus, (tokens, IFederationRegistry.Status.DELISTED, "vote")
        );
        (, uint32 delay) = manager.canCall(hotAdmin, address(fedRegistry), bytes4(call));
        vm.prank(hotAdmin);
        manager.schedule(address(fedRegistry), call, 0);
        vm.prank(fedArtist);
        fed.leaveFederation();
        assertTrue(auction.isTarget(address(fed)), "served while the vote waits");
        vm.warp(block.timestamp + delay);
        vm.prank(hotAdmin);
        manager.execute(address(fedRegistry), call);
        _assertStatus(address(fed), IArtistRegistry.FederationStatus.LEFT_DELISTED);
        assertFalse(auction.isTarget(address(fed)));
        _settleAtEnd(saleId);
        assertEq(auction.claimable(collector, CURRENCY_ETH), 1 ether, "refunded");
        assertEq(fed.ownerOf(tokenId), address(fed));
    }

    /// @dev One member that left, or one never listed, does not revert a batch: the left one
    ///      is delisted too, the unlisted one skipped; a relisting skips exits.
    function test_Delisting_ABatchSkipsWhatItCannotChange() public {
        _joinedFed();
        address second = _actor("secondArtist");
        FederatedStream other = _deployStream(second);
        _join(address(other), second);
        FederatedStream unlisted = _deployStream(second);
        vm.prank(second);
        other.leaveFederation();
        address[] memory tokens = new address[](3);
        (tokens[0], tokens[1], tokens[2]) = (address(fed), address(other), address(unlisted));
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(
                fedRegistry.setStatus, (tokens, IFederationRegistry.Status.DELISTED, "vote")
            )
        );
        _assertStatus(address(fed), IArtistRegistry.FederationStatus.DELISTED);
        _assertStatus(address(other), IArtistRegistry.FederationStatus.LEFT_DELISTED);
        _assertStatus(address(unlisted), IArtistRegistry.FederationStatus.NONE);
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(fedRegistry.setStatus, (tokens, IFederationRegistry.Status.ACTIVE, "r"))
        );
        _assertStatus(address(fed), IArtistRegistry.FederationStatus.ACTIVE);
        _assertStatus(address(other), IArtistRegistry.FederationStatus.LEFT_DELISTED);
        assertFalse(fedRegistry.isActive(address(other)), "an exit is never relisted");
    }

    /// @dev A replacement registry swapped in before it approves the template versions serves
    ///      nothing, so the running sale freezes out with a refund: the procedure approves first.
    function test_Replacement_SwappedBeforeItsApprovalsFreezesRunningSales() public {
        _joinedFed();
        (uint256 saleId,) = _startFed(_fedWork(fedArtist));
        _ethBid(saleId, collector, 1 ether);
        FederationRegistry next = new FederationRegistry(
            address(manager), address(artists), address(economics), address(store)
        );
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(artists.setFederationRegistry, (address(fedRegistry), address(next)))
        );
        assertFalse(auction.isTarget(address(fed)), "no approval, nothing served");
        _settleAtEnd(saleId);
        assertEq(auction.claimable(collector, CURRENCY_ETH), 1 ether);
    }

    /// @dev `VerifyV1.checkSuccessorParity`, the runbook's last check before the switch: a
    ///      successor matching the predecessor passes; a revocation on the predecessor during the
    ///      switch's delay, or an adapter admitted by only one of them, fails it.
    function test_Replacement_ParityIsCheckedRightBeforeTheSwitch() public {
        FederationRegistry next = new FederationRegistry(
            address(manager), address(artists), address(economics), address(store)
        );
        _mapRegistryRoles(address(next));
        _approveTemplates(next);
        _govern(hotAdmin, address(next), abi.encodeCall(next.setAdapter, (address(auction), true)));
        bytes32[] memory hashes = new bytes32[](2);
        (hashes[0], hashes[1]) = (streamHash, editionsHash);
        address[] memory adapters = new address[](1);
        adapters[0] = address(auction);
        this.parity(fedRegistry, next, hashes, adapters);
        // The predecessor revokes during the switch's delay: the successor still approves it.
        _govern(
            hotAdmin, address(fedRegistry), abi.encodeCall(fedRegistry.revokeTemplate, (streamHash))
        );
        vm.expectRevert(abi.encodeWithSelector(VerifyV1.FederationMismatch.selector, "templateOf"));
        this.parity(fedRegistry, next, hashes, adapters);
        _govern(hotAdmin, address(next), abi.encodeCall(next.revokeTemplate, (streamHash)));
        this.parity(fedRegistry, next, hashes, adapters);
        // The predecessor removes an adapter the successor still admits.
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(fedRegistry.setAdapter, (address(auction), false))
        );
        vm.expectRevert(
            abi.encodeWithSelector(VerifyV1.FederationMismatch.selector, "isAdmittedAdapter")
        );
        this.parity(fedRegistry, next, hashes, adapters);
    }

    function parity(
        FederationRegistry predecessor,
        FederationRegistry successor,
        bytes32[] memory hashes,
        address[] memory adapters
    ) external view {
        VerifyV1.checkSuccessorParity(predecessor, successor, hashes, adapters);
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

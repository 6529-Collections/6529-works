// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IStreamViews } from "src/interfaces/IStreamViews.sol";
import { IWorkPowers, WorkPowers } from "src/interfaces/IWorkPowers.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { ItemKind, License, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { MockRenderer } from "../mocks/stream/StreamMocks.sol";
import { SignatureReverts } from "test/helpers/SignatureReverts.sol";
import { RecordsFixture } from "./RecordsFixture.sol";

/// @notice Royalty changes up or down and the lead artist's renounceable powers over a work
///         (`IWorkPowers`, ADR 0006 as amended by R10, C7 and C8; rules WS-14, WS-37 and WS-38
///         in Works and storage).
contract WorkPowersTest is RecordsFixture {
    event MetadataUpdate(uint256 _tokenId);

    uint16 internal constant ROYALTY = WorkPowers.ROYALTY_RATE;
    uint16 internal constant RELICENSE = WorkPowers.RELICENSE;
    uint16 internal constant REPIN = WorkPowers.RENDERER_REPIN;
    /// @dev The two powers renounceable before finalize.
    uint16 internal constant BOTH = ROYALTY | RELICENSE;

    // -------------------------------------------------------------------------------- helpers

    function _renounceHash(uint256 tokenId, uint16 powers, bytes32 state, uint64 deadline)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(Typehashes.RENOUNCE_POWERS, tokenId, powers, state, deadline));
    }

    /// @dev The lead artist signs a renunciation at the current state; the network relays it
    ///      when it names the royalty or licence power (C7), an outsider otherwise.
    function _renounce(uint256 tokenId, uint16 powers) internal {
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _sign(artistKey, _renounceHash(tokenId, powers, state, deadline));
        vm.prank(powers & BOTH != 0 ? governor : outsider);
        records.renounce(tokenId, powers, state, deadline, sig);
    }

    function _rateCall(uint256 tokenId, PackageItem memory item, uint32 rate)
        internal
        returns (bool ok, bytes memory reason)
    {
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 15 days);
        bytes[] memory sigs = _both(_royaltyHash(tokenId, rate, state, deadline));
        vm.prank(governor);
        (ok, reason) = address(records)
            .call(
                abi.encodeCall(records.setRoyaltyRate, (tokenId, rate, item, state, deadline, sigs))
            );
    }

    function _rerate(uint256 tokenId, PackageItem memory item, uint32 rate) internal {
        (bool ok,) = _rateCall(tokenId, item, rate);
        assertTrue(ok, "re-rate");
    }

    function _relicenseHash(uint256 tokenId, License memory next, bytes32 state, uint64 deadline)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                Typehashes.RELICENSE,
                tokenId,
                WorksHashing.licenseKey(next.spdxId),
                next.textFileId,
                state,
                deadline
            )
        );
    }

    function _relicenseCall(uint256 tokenId, PackageItem memory item, License memory next)
        internal
        returns (bool ok, bytes memory reason)
    {
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 3 days);
        bytes[] memory sigs = _both(_relicenseHash(tokenId, next, state, deadline));
        vm.prank(governor);
        (ok, reason) = address(records)
            .call(abi.encodeCall(records.relicense, (tokenId, next, item, state, deadline, sigs)));
    }

    /// @dev A work under CC BY 4.0, which (unlike CC0) can be relicensed.
    function _byWork(uint256 salt) internal returns (uint256 tokenId, PackageItem memory item) {
        MediaFile[] memory media = _single(salt, true);
        item = _recordsItem(salt, media);
        item.license = _license("cc-by-4.0");
        tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
    }

    /// @dev A linked edition master with an open record.
    function _master(uint256 salt) internal returns (uint256 tokenId, PackageItem memory item) {
        MediaFile[] memory media = _single(salt, true);
        item = _recordsItem(salt, media);
        item.kind = uint8(ItemKind.EDITION_MASTER);
        tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        auction.settle(IStream(address(stream)), tokenId);
        editionsMock.link(IStream(address(stream)), tokenId, tokenId);
    }

    function _version(uint256 tokenId) internal view returns (uint32) {
        return records.record(tokenId).version;
    }

    /// @dev WS-10's state hash of an unfinalized CC0 work at the default rate and `version`.
    function _stateAtVersion(uint256 tokenId, uint32 version) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("6529WORKS_WORK_STATE_V1"),
                tokenId,
                version,
                records.record(tokenId).recordFileId,
                WorksHashing.CC0_LICENSE_KEY,
                records.licenseOf(tokenId).textFileId,
                uint32(6_529),
                stream.defaultRenderer()
            )
        );
    }

    // --------------------------------------------------------- royalty changes, up and down

    /// Regression: ADD-PWR-1
    /// @dev A consented, governed change to a lower rate applies in Stream and reports the new
    ///      state hash.
    function test_setRoyaltyRate_lowersTheRate() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        vm.expectEmit(address(stream));
        emit IStream.RoyaltyRateChanged(tokenId, 6_529, 5_000);
        vm.expectEmit(true, false, false, false, address(records));
        emit IWorkRecords.RoyaltyRateSet(tokenId, 6_529, 5_000, bytes32(0));
        _rerate(tokenId, item, 5_000);
        (, uint256 amount) = stream.royaltyInfo(tokenId, 1 ether);
        assertEq(amount, 0.05 ether);
        assertEq(IStreamViews(address(stream)).work(tokenId).royaltyRate, 5_000);
        assertEq(_version(tokenId), 1);
        _rerate(tokenId, item, 0);
        assertEq(IStreamViews(address(stream)).work(tokenId).royaltyRate, 0);
    }

    /// @dev R10: with every party's consent and the network's action a rate rises, a lowered
    ///      rate can be restored, and 100% is the ceiling (`InvalidRoyaltyRate` above it).
    ///      Fails without the change: every rise reverted with `RoyaltyRateNotLowered`.
    function test_setRoyaltyRate_risesWithAgreement() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        vm.expectEmit(address(stream));
        emit IStream.RoyaltyRateChanged(tokenId, 6_529, 10_000);
        _rerate(tokenId, item, 10_000);
        assertEq(IStreamViews(address(stream)).work(tokenId).royaltyRate, 10_000);
        _rerate(tokenId, item, 5_000);
        _rerate(tokenId, item, 6_529);
        assertEq(IStreamViews(address(stream)).work(tokenId).royaltyRate, 6_529, "restored");
        _rerate(tokenId, item, 100_000);
        bytes32 before = records.workStateHash(tokenId);
        (bool ok, bytes memory reason) = _rateCall(tokenId, item, 100_001);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(IStream.InvalidRoyaltyRate.selector, 100_001));
        assertEq(records.workStateHash(tokenId), before);
    }

    /// @dev R10: a rise without one party's consent fails, whoever is missing; so does one
    ///      without the network (the artist and every party alone cannot call it).
    function test_setRoyaltyRate_aRiseNeedsEveryPartyAndTheNetwork() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 15 days);
        bytes32 structHash = _royaltyHash(tokenId, 10_000, state, deadline);
        bytes[] memory sigs = _both(structHash);
        for (uint256 i; i < 2; ++i) {
            bytes[] memory missing = new bytes[](2);
            (missing[0], missing[1]) = (sigs[0], sigs[1]);
            missing[i] = _sign(0xBAD, structHash);
            vm.prank(governor);
            vm.expectRevert(SignatureReverts.invalid(vm.addr(0xBAD)));
            records.setRoyaltyRate(tokenId, 10_000, item, state, deadline, missing);
        }
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, artist)
        );
        records.setRoyaltyRate(tokenId, 10_000, item, state, deadline, sigs);
        assertEq(IStreamViews(address(stream)).work(tokenId).royaltyRate, 6_529);
    }

    /// Regression: ADD-PWR-1
    /// @dev The current rate stays a no-op (WS-11), with no event and no version bump, so it
    ///      applies nothing.
    function test_setRoyaltyRate_anEqualRateChangesNothing() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        _rerate(tokenId, item, 5_000);
        vm.recordLogs();
        vm.prank(governor);
        records.setRoyaltyRate(tokenId, 5_000, item, bytes32(0), 0, new bytes[](0));
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(_version(tokenId), 1);
    }

    /// Regression: ADD-PWR-1
    /// @dev A linked edition follows its master's rate, down and up; a refused rate (above 100%)
    ///      moves neither.
    function test_setRoyaltyRate_theLinkedEditionFollowsBothWays() public {
        (uint256 tokenId, PackageItem memory item) = _master(1);
        _rerate(tokenId, item, 4_000);
        assertEq(IStreamViews(address(stream)).work(tokenId).royaltyRate, 4_000);
        assertEq(editionsMock.rateOf(tokenId), 4_000);
        _rerate(tokenId, item, 9_000);
        assertEq(editionsMock.rateOf(tokenId), 9_000);
        (bool ok,) = _rateCall(tokenId, item, 100_001);
        assertFalse(ok);
        assertEq(IStreamViews(address(stream)).work(tokenId).royaltyRate, 9_000);
        assertEq(editionsMock.rateOf(tokenId), 9_000);
    }

    /// Regression: ADD-PWR-1
    /// @dev The rate a work mints with is the economics resolver's, which the network sets for
    ///      new works; a change to it moves no existing work.
    function test_setRoyaltyRate_theMintRateIsUnaffected() public {
        (uint256 first, PackageItem memory firstItem) = _work(1);
        _rerate(first, firstItem, 5_000);
        WorkTerms memory terms = _defaultTerms();
        terms.royaltyRate = 10_000;
        econ.setTerms(terms);
        (uint256 second, PackageItem memory secondItem) = _work(2);
        assertEq(IStreamViews(address(stream)).work(second).royaltyRate, 10_000);
        assertEq(IStreamViews(address(stream)).work(first).royaltyRate, 5_000);
        _rerate(second, secondItem, 9_000);
        assertEq(IStreamViews(address(stream)).work(first).royaltyRate, 5_000);
    }

    /// @dev R10 fuzz: any rate up to 100% applies with every consent, above it nothing moves.
    function testFuzz_setRoyaltyRate_anyRateUpToTheCeiling(uint32 rate) public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        (bool ok,) = _rateCall(tokenId, item, rate);
        assertEq(ok, rate <= 100_000);
        assertEq(
            IStreamViews(address(stream)).work(tokenId).royaltyRate, rate <= 100_000 ? rate : 6_529
        );
    }

    // ------------------------------------------------------------------- renouncing a power

    /// Regression: ADD-PWR-2
    /// @dev Once the royalty power is renounced, every rate change reverts, a lower and an
    ///      unchanged rate included, with every consent; relicensing is untouched.
    function test_renounce_royaltyRateThenEveryRateChangeReverts() public {
        (uint256 tokenId, PackageItem memory item) = _byWork(1);
        _renounce(tokenId, ROYALTY);
        assertEq(records.renouncedPowers(tokenId), ROYALTY);
        bytes memory refused =
            abi.encodeWithSelector(IWorkPowers.PowerRenounced.selector, tokenId, ROYALTY);
        uint32[3] memory rates = [uint32(5_000), 6_529, 0];
        for (uint256 i; i < rates.length; ++i) {
            (bool ok, bytes memory reason) = _rateCall(tokenId, item, rates[i]);
            assertFalse(ok);
            assertEq(reason, refused);
        }
        assertEq(IStreamViews(address(stream)).work(tokenId).royaltyRate, 6_529);
        (bool relicensed,) = _relicenseCall(tokenId, item, _license("cc0-1.0"));
        assertTrue(relicensed);
        assertEq(records.licenseOf(tokenId).spdxId, "cc0-1.0");
    }

    /// Regression: ADD-PWR-2
    /// @dev Once relicensing is renounced, every relicense reverts, the current license
    ///      included; the royalty rate can still change.
    function test_renounce_relicenseThenEveryRelicenseReverts() public {
        (uint256 tokenId, PackageItem memory item) = _byWork(1);
        _renounce(tokenId, RELICENSE);
        assertEq(records.renouncedPowers(tokenId), RELICENSE);
        bytes memory refused =
            abi.encodeWithSelector(IWorkPowers.PowerRenounced.selector, tokenId, RELICENSE);
        License[3] memory nexts = [_license("cc0-1.0"), _license("mit"), _license("cc-by-4.0")];
        for (uint256 i; i < nexts.length; ++i) {
            (bool ok, bytes memory reason) = _relicenseCall(tokenId, item, nexts[i]);
            assertFalse(ok);
            assertEq(reason, refused);
        }
        assertEq(records.licenseOf(tokenId).spdxId, "cc-by-4.0");
        _rerate(tokenId, item, 5_000);
        assertEq(IStreamViews(address(stream)).work(tokenId).royaltyRate, 5_000);
    }

    /// Regression: ADD-PWR-2
    /// @dev Both powers at once; the mask then holds every renounceable bit.
    function test_renounce_bothAtOnce() public {
        (uint256 tokenId, PackageItem memory item) = _byWork(1);
        _renounce(tokenId, BOTH);
        assertEq(records.renouncedPowers(tokenId), BOTH);
        (bool rated, bytes memory r1) = _rateCall(tokenId, item, 1);
        assertFalse(rated);
        assertEq(r1, abi.encodeWithSelector(IWorkPowers.PowerRenounced.selector, tokenId, ROYALTY));
        (bool relicensed, bytes memory r2) = _relicenseCall(tokenId, item, _license("mit"));
        assertFalse(relicensed);
        assertEq(
            r2, abi.encodeWithSelector(IWorkPowers.PowerRenounced.selector, tokenId, RELICENSE)
        );
    }

    /// @dev C7: renouncing the royalty or the licence power needs the network's action: the
    ///      artist's signature relayed by anyone else (the artist included) is refused, alone or
    ///      beside the repin power. Renouncing the repin power alone stays the artist's: anyone
    ///      relays it. Fails without the change: anyone relayed any renunciation.
    function test_renounce_royaltyAndLicenceNeedTheNetwork() public {
        uint256 tokenId = _finalized(1);
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        uint16[4] memory masks = [ROYALTY, RELICENSE, BOTH, ROYALTY | REPIN];
        address[2] memory relays = [outsider, artist];
        for (uint256 i; i < masks.length; ++i) {
            bytes memory sig = _sign(artistKey, _renounceHash(tokenId, masks[i], state, deadline));
            for (uint256 j; j < relays.length; ++j) {
                vm.prank(relays[j]);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IAccessManaged.AccessManagedUnauthorized.selector, relays[j]
                    )
                );
                records.renounce(tokenId, masks[i], state, deadline, sig);
            }
        }
        assertEq(records.renouncedPowers(tokenId), 0);
        bytes memory repin = _sign(artistKey, _renounceHash(tokenId, REPIN, state, deadline));
        vm.prank(outsider);
        records.renounce(tokenId, REPIN, state, deadline, repin);
        assertEq(records.renouncedPowers(tokenId), REPIN);
        // The network relays the artist's royalty renunciation.
        _renounce(tokenId, ROYALTY);
        assertEq(records.renouncedPowers(tokenId), ROYALTY | REPIN);
    }

    /// @dev C7: the network alone cannot renounce: its relay still needs the signature of a
    ///      wallet of the lead artist's account.
    function test_renounce_theNetworkAloneCannot() public {
        (uint256 tokenId,) = _work(1);
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _sign(0xBAD, _renounceHash(tokenId, ROYALTY, state, deadline));
        vm.prank(governor);
        vm.expectRevert(SignatureReverts.invalid(vm.addr(0xBAD)));
        records.renounce(tokenId, ROYALTY, state, deadline, sig);
        assertEq(records.renouncedPowers(tokenId), 0);
    }

    /// Regression: ADD-PWR-2
    /// @dev `PowersRenounced` reports the signed bits, the whole mask and the new state hash;
    ///      the version bumps; no metadata event follows (nothing rendered changed).
    function test_renounce_emitsPowersRenouncedAndBumpsTheVersion() public {
        (uint256 tokenId,) = _work(1);
        bytes32 s0 = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _sign(artistKey, _renounceHash(tokenId, ROYALTY, s0, deadline));
        vm.recordLogs();
        vm.prank(governor);
        records.renounce(tokenId, ROYALTY, s0, deadline, sig);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 s1 = records.workStateHash(tokenId);
        assertTrue(s1 != s0);
        assertEq(logs.length, 1, "one event, no ERC-4906");
        assertEq(logs[0].emitter, address(records));
        assertEq(logs[0].topics[0], IWorkPowers.PowersRenounced.selector);
        assertEq(
            logs[0].topics[0], 0x1645831232817ad28692844e620258135b764cbc32106d9c36fc183ae2e4bd70
        );
        assertEq(logs[0].topics[1], bytes32(tokenId));
        assertEq(logs[0].data, abi.encode(ROYALTY, ROYALTY, s1));
        assertEq(_version(tokenId), 1);

        bytes32 state = records.workStateHash(tokenId);
        sig = _sign(artistKey, _renounceHash(tokenId, BOTH, state, deadline));
        bytes32 expected = _stateAtVersion(tokenId, 2);
        vm.expectEmit(address(records));
        emit IWorkPowers.PowersRenounced(tokenId, BOTH, BOTH, expected);
        vm.prank(governor);
        records.renounce(tokenId, BOTH, state, deadline, sig);
        assertEq(records.renouncedPowers(tokenId), BOTH);
        assertEq(_version(tokenId), 2);
    }

    /// Regression: ADD-PWR-2
    /// @dev Renouncing is open before finalize and after it, and does not stop finalize.
    function test_renounce_beforeAndAfterFinalize() public {
        (uint256 open,) = _work(1);
        _renounce(open, ROYALTY);
        bytes32 state = records.workStateHash(open);
        vm.prank(artist);
        records.finalize(open, state);
        _renounce(open, RELICENSE);
        assertEq(records.renouncedPowers(open), BOTH);
        _renounce(open, REPIN);
        assertEq(records.renouncedPowers(open), WorkPowers.ALL);
        assertTrue(records.record(open).finalized);
    }

    /// @dev `RENDERER_REPIN` (owner decision, 15 November 2026): refused before finalize, even
    ///      signed; after finalize the network repins alone (C8) until the artist renounces it,
    ///      and then every repin reverts for good, a no-op included.
    function test_renounce_rendererRepinOnlyAfterFinalizeThenRepinRevertsForGood() public {
        (uint256 tokenId,) = _work(1);
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 31 days);
        bytes memory early = _sign(artistKey, _renounceHash(tokenId, REPIN, state, deadline));
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.WorkNotFinalized.selector, tokenId));
        records.renounce(tokenId, REPIN, state, deadline, early);
        vm.prank(artist);
        records.finalize(tokenId, state);
        _renounce(tokenId, BOTH);

        MockRenderer next = new MockRenderer("errata");
        _repin(tokenId, address(next));
        assertEq(stream.rendererOf(tokenId), address(next));

        _renounce(tokenId, REPIN);
        assertEq(records.renouncedPowers(tokenId), WorkPowers.ALL);
        MockRenderer later = new MockRenderer("later");
        state = records.workStateHash(tokenId);
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IWorkPowers.PowerRenounced.selector, tokenId, REPIN));
        records.repinRenderer(tokenId, address(later), address(later).codehash, state);
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IWorkPowers.PowerRenounced.selector, tokenId, REPIN));
        records.repinRenderer(tokenId, address(next), address(next).codehash, state);
        assertEq(stream.rendererOf(tokenId), address(next));
    }

    function _finalized(uint256 salt) internal returns (uint256 tokenId) {
        (tokenId,) = _work(salt);
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
    }

    function _repin(uint256 tokenId, address r) internal {
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(governor);
        records.repinRenderer(tokenId, r, r.codehash, state);
    }

    /// Regression: ADD-PWR-2
    /// @dev Only a wallet of the lead artist's account signs: an outsider's or a collaborator's
    ///      signature is refused, as is an empty proof, and the lead artist alone suffices.
    function test_renounce_onlyTheLeadArtistSigns() public {
        (uint256 tokenId,) = _work(1);
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 structHash = _renounceHash(tokenId, ROYALTY, state, deadline);
        uint256[2] memory keys = [uint256(0xBAD), collaboratorKey];
        vm.startPrank(governor);
        for (uint256 i; i < keys.length; ++i) {
            vm.expectRevert(SignatureReverts.invalid(vm.addr(keys[i])));
            records.renounce(tokenId, ROYALTY, state, deadline, _sign(keys[i], structHash));
        }
        vm.expectRevert(SignatureReverts.invalid(address(0)));
        records.renounce(tokenId, ROYALTY, state, deadline, "");
        assertEq(records.renouncedPowers(tokenId), 0);
        records.renounce(tokenId, ROYALTY, state, deadline, _sign(artistKey, structHash));
        vm.stopPrank();
        assertEq(records.renouncedPowers(tokenId), ROYALTY);
    }

    /// @dev C6, C16: any wallet consolidated into the lead artist's account signs a
    ///      renunciation, at any time. Fails without the change: only the authority signed.
    function test_renounce_aSecondWalletOfTheArtistSigns() public {
        (uint256 tokenId,) = _work(1);
        uint256 secondKey = 0xC0FFEE;
        artists.setWallet(uint160(artist), vm.addr(secondKey), true);
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _sign(secondKey, _renounceHash(tokenId, ROYALTY, state, deadline));
        vm.prank(governor);
        records.renounce(tokenId, ROYALTY, state, deadline, sig);
        assertEq(records.renouncedPowers(tokenId), ROYALTY);
    }

    /// Regression: ADD-PWR-2
    /// @dev After the artist's root moves, the former key's signature is refused, one signed
    ///      before the move included, and the new root's is accepted.
    function test_renounce_aFormerAuthorityCannot() public {
        (uint256 tokenId,) = _work(1);
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 structHash = _renounceHash(tokenId, ROYALTY, state, deadline);
        bytes memory preSigned = _sign(artistKey, structHash);
        uint256 newKey = 0xA11CE2;
        artists.setAuthority(uint256(uint160(artist)), vm.addr(newKey));
        vm.startPrank(governor);
        vm.expectRevert(SignatureReverts.invalid(artist));
        records.renounce(tokenId, ROYALTY, state, deadline, preSigned);
        records.renounce(tokenId, ROYALTY, state, deadline, _sign(newKey, structHash));
        vm.stopPrank();
        assertEq(records.renouncedPowers(tokenId), ROYALTY);
    }

    /// Regression: ADD-PWR-2
    /// @dev While the network freezes the artist's account, no wallet of it renounces; after
    ///      the freeze the same signature applies.
    function test_renounce_nobodyWhileTheAccountIsFrozen() public {
        (uint256 tokenId,) = _work(1);
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _sign(artistKey, _renounceHash(tokenId, ROYALTY, state, deadline));
        artists.setFrozen(uint160(artist), true);
        vm.prank(governor);
        vm.expectRevert(SignatureReverts.invalid(artist));
        records.renounce(tokenId, ROYALTY, state, deadline, sig);
        artists.setFrozen(uint160(artist), false);
        vm.prank(governor);
        records.renounce(tokenId, ROYALTY, state, deadline, sig);
        assertEq(records.renouncedPowers(tokenId), ROYALTY);
    }

    /// Regression: ADD-PWR-2
    /// @dev An expired signature is refused; the deadline is inclusive.
    function test_renounce_refusesAnExpiredSignature() public {
        (uint256 tokenId,) = _work(1);
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _sign(artistKey, _renounceHash(tokenId, ROYALTY, state, deadline));
        vm.warp(deadline + 1);
        vm.prank(governor);
        vm.expectRevert(SignatureReverts.expired(deadline));
        records.renounce(tokenId, ROYALTY, state, deadline, sig);
        vm.warp(deadline);
        vm.prank(governor);
        records.renounce(tokenId, ROYALTY, state, deadline, sig);
        assertEq(records.renouncedPowers(tokenId), ROYALTY);
    }

    /// Regression: ADD-PWR-2
    /// @dev A signature over a state the work has left is refused (compare-and-set).
    function test_renounce_refusesAStaleStateHash() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        bytes32 stale = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _sign(artistKey, _renounceHash(tokenId, ROYALTY, stale, deadline));
        _rerate(tokenId, item, 5_000);
        bytes32 current = records.workStateHash(tokenId);
        vm.prank(governor);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.StateHashMismatch.selector, stale, current)
        );
        records.renounce(tokenId, ROYALTY, stale, deadline, sig);
    }

    /// Regression: ADD-PWR-2
    /// @dev A signature applies once: repeating it is a no-op, and another signed at the same
    ///      state is refused once the version moved.
    function test_renounce_aSignatureNeverAppliesTwice() public {
        (uint256 tokenId,) = _work(1);
        bytes32 s0 = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory one = _sign(artistKey, _renounceHash(tokenId, ROYALTY, s0, deadline));
        bytes memory both = _sign(artistKey, _renounceHash(tokenId, BOTH, s0, deadline));
        vm.startPrank(governor);
        records.renounce(tokenId, ROYALTY, s0, deadline, one);
        bytes32 s1 = records.workStateHash(tokenId);
        vm.recordLogs();
        records.renounce(tokenId, ROYALTY, s0, deadline, one);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(_version(tokenId), 1);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.StateHashMismatch.selector, s0, s1));
        records.renounce(tokenId, BOTH, s0, deadline, both);
        vm.stopPrank();
        assertEq(records.renouncedPowers(tokenId), ROYALTY);
    }

    /// Regression: ADD-PWR-2
    /// @dev A bit naming no renounceable power is refused, even with a valid signature.
    function test_renounce_refusesUnknownBits() public {
        (uint256 tokenId,) = _work(1);
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        uint16[4] memory masks = [uint16(8), 15, 0x8000, 0xffff];
        for (uint256 i; i < masks.length; ++i) {
            bytes memory sig = _sign(artistKey, _renounceHash(tokenId, masks[i], state, deadline));
            vm.prank(governor);
            vm.expectRevert(abi.encodeWithSelector(IWorkPowers.UnknownPower.selector, masks[i]));
            records.renounce(tokenId, masks[i], state, deadline, sig);
        }
        assertEq(records.renouncedPowers(tokenId), 0);
    }

    /// Regression: ADD-PWR-2
    /// @dev Renouncing again, or renouncing nothing, is a harmless no-op that checks nothing:
    ///      the bits are already set, so there is nothing to authorize and nothing to replay.
    function test_renounce_twiceIsAHarmlessNoOp() public {
        (uint256 tokenId,) = _work(1);
        _renounce(tokenId, BOTH);
        bytes32 state = records.workStateHash(tokenId);
        vm.recordLogs();
        vm.startPrank(outsider);
        records.renounce(tokenId, ROYALTY, bytes32(0), 0, "");
        records.renounce(tokenId, BOTH, bytes32(0), 0, "");
        records.renounce(tokenId, 0, bytes32(0), 0, "");
        vm.stopPrank();
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(records.workStateHash(tokenId), state);
        assertEq(records.renouncedPowers(tokenId), BOTH);
    }

    /// Regression: ADD-PWR-2
    /// @dev The mask lives in the record: both functions need an open record.
    function test_renounce_needsAnOpenRecord() public {
        (uint256 tokenId,,) = _minted(1, true);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.RecordNotOpen.selector, tokenId));
        records.renounce(tokenId, ROYALTY, bytes32(0), 0, "");
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.RecordNotOpen.selector, tokenId));
        records.renouncedPowers(tokenId);
    }

    /// Regression: ADD-PWR-2
    /// @dev A renunciation bumps the version, so consents collected before it lapse.
    function test_renounce_pendingConsentsLapse() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        bytes32 s0 = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 15 days);
        bytes[] memory sigs = _both(_royaltyHash(tokenId, 5_000, s0, deadline));
        _renounce(tokenId, RELICENSE);
        bytes32 s1 = records.workStateHash(tokenId);
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.StateHashMismatch.selector, s0, s1));
        records.setRoyaltyRate(tokenId, 5_000, item, s0, deadline, sigs);
    }

    /// Regression: ADD-PWR-2
    /// @dev The edition follows its master: renouncing the royalty power on the master fixes
    ///      the linked edition's rate too.
    function test_renounce_theLinkedEditionFollowsTheMaster() public {
        (uint256 tokenId, PackageItem memory item) = _master(1);
        _rerate(tokenId, item, 5_000);
        _renounce(tokenId, ROYALTY);
        (bool ok,) = _rateCall(tokenId, item, 4_000);
        assertFalse(ok);
        assertEq(IStreamViews(address(stream)).work(tokenId).royaltyRate, 5_000);
        assertEq(editionsMock.rateOf(tokenId), 5_000);
    }

    // -------------------------------------------------------------------- pins and ERC-165

    /// @dev `IWorkPowers` is advertised beside `IWorkRecords` (whose ID Stream and Editions
    ///      compile in, changed by this pass). `IWorkPowers` is `renounce(uint256,uint16,
    ///      bytes32,uint64,bytes)` (0x7dec8a35) xor `renouncedPowers(uint256)` (0xc0f4a8a9).
    function test_supportsInterface_advertisesIWorkPowers() public view {
        assertEq(type(IWorkPowers).interfaceId, bytes4(0xbd18229c));
        assertEq(type(IWorkRecords).interfaceId, bytes4(0x5a8252d9));
        assertTrue(records.supportsInterface(type(IWorkPowers).interfaceId));
        assertTrue(records.supportsInterface(type(IWorkRecords).interfaceId));
        assertTrue(records.supportsInterface(0x01ffc9a7));
        assertFalse(records.supportsInterface(0xffffffff));
    }

    /// @dev Golden value, computed independently with `cast keccak` over the type string, and
    ///      the power bits. A failure means the signed payload or the mask changed shape.
    function test_renouncePowers_golden() public pure {
        assertEq(
            Typehashes.RENOUNCE_POWERS,
            0xff8cc1b150cf1b390fd870b4a587d3c2632e80f32efbefe166b9f7b0131d3aff
        );
        assertEq(WorkPowers.ROYALTY_RATE, 1);
        assertEq(WorkPowers.RELICENSE, 2);
        assertEq(WorkPowers.RENDERER_REPIN, 4);
        assertEq(WorkPowers.ALL, 7);
    }

    /// @dev The mask shares the record's first storage word with the renderer pin, version,
    ///      media count and flags (`forge inspect WorkRecords storageLayout`: `_records` at slot
    ///      6, `renounced` at byte offset 30). Every later write to that word (sync, finalize, the
    ///      errata repin) keeps the mask, and the mask leaves the other fields intact.
    function test_renounce_theMaskSurvivesEveryWriteToItsWord() public {
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = _mediaFile(1, FileRole.PRIMARY, false);
        media[1] = _mediaFile(2, FileRole.AUXILIARY, false);
        PackageItem memory item = _recordsItem(1, media);
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        _renounce(tokenId, BOTH);
        assertEq(records.record(tokenId).version, 1);

        _upload(1);
        _upload(2);
        records.syncOnChain(tokenId, 0, type(uint256).max);
        assertEq(records.renouncedPowers(tokenId), BOTH, "after sync");
        assertTrue(records.record(tokenId).onChainComplete);
        assertEq(records.mediaOf(tokenId).length, 2);

        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
        assertEq(records.renouncedPowers(tokenId), BOTH, "after finalize");
        IWorkRecords.RecordInfo memory info = records.record(tokenId);
        assertEq(info.version, 2);
        assertTrue(info.finalized && info.onChainComplete);

        MockRenderer next = new MockRenderer("errata");
        _repin(tokenId, address(next));
        assertEq(records.renouncedPowers(tokenId), BOTH, "after repin");
        info = records.record(tokenId);
        assertEq(info.version, 3);
        assertEq(info.renderer, address(next));
        assertTrue(info.finalized && info.onChainComplete);
        assertEq(records.mediaOf(tokenId).length, 2);

        uint256 word =
            uint256(vm.load(address(records), keccak256(abi.encode(tokenId, uint256(6)))));
        assertEq(word >> 240, BOTH, "the mask is the word's top two bytes");
        assertEq(address(uint160(word)), address(next), "the renderer pin is its low 20 bytes");
    }
}

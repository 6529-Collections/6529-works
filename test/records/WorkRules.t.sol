// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IDeliveryHost } from "src/interfaces/IWorkDelivery.sol";
import { IWorkPowers, WorkPowers } from "src/interfaces/IWorkPowers.sol";
import { Facts, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { IWorkRules } from "src/interfaces/core/IWorkRules.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { WorkRules } from "src/records/WorkRules.sol";
import { WorkDelivery } from "src/stream/WorkDelivery.sol";
import { CodeRenderer, RulesChunkStore, SigningAccounts } from "../mocks/records/RulesMocks.sol";
import { RulesFixture } from "./RulesFixture.sol";

/// @notice `WorkRules`, the RECORDS module of 6529 Stream: who may change a work's record, and
///         when; consents, notices, renunciations, stores and the delivery pointer. Behaviour
///         carried over from `WorkRecords`.
contract WorkRulesTest is RulesFixture {
    address internal s;
    uint64 internal deadline;

    function setUp() public override {
        super.setUp();
        s = address(stream);
        deadline = uint64(block.timestamp + 1 days);
    }

    function _open(uint256 salt) internal returns (uint256 id, PackageItem memory item) {
        (id, item,) = _work(stream, salt);
    }

    function _relicenseHash(uint256 id, License memory next, bytes32 state, uint64 dl)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                rules.RELICENSE_TYPEHASH(),
                s,
                id,
                WorksHashing.licenseKey(next.spdxId),
                next.textFileId,
                state,
                dl
            )
        );
    }

    function _rateHash(uint256 id, uint24 rate, bytes32 state, uint64 dl)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(rules.ROYALTY_RATE_TYPEHASH(), s, id, rate, state, dl));
    }

    function _renounceHash(uint256 id, uint16 powers, bytes32 state, uint64 dl)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(rules.RENOUNCE_POWERS_TYPEHASH(), s, id, powers, state, dl));
    }

    /// @dev A work on MIT, so it can be relicensed in any direction.
    function _mitWork(uint256 salt) internal returns (uint256 id, PackageItem memory item) {
        MediaFile[] memory media = _single(salt);
        item = _item(salt, media);
        item.license = License("MIT", mitText);
        id = _mintItem(stream, item);
        facts.open(s, id, item, media);
    }

    function _relicense(uint256 id, PackageItem memory item, License memory next) internal {
        bytes32 state = _state(id);
        rules.relicense(
            s, id, next, item, state, deadline, _both(_relicenseHash(id, next, state, deadline))
        );
    }

    function _setRate(uint256 id, PackageItem memory item, uint24 rate) internal {
        bytes32 state = _state(id);
        rules.setRoyaltyRate(
            s, id, rate, item, state, deadline, _both(_rateHash(id, rate, state, deadline))
        );
    }

    function _renounce(uint256 id, uint16 powers) internal {
        bytes32 state = _state(id);
        rules.renounce(
            s,
            id,
            powers,
            state,
            deadline,
            _sign(artistKey, _renounceHash(id, powers, state, deadline))
        );
    }

    function _artistFinalize(uint256 id) internal {
        bytes32 state = _state(id);
        vm.prank(artist);
        rules.finalize(s, id, state);
    }

    // ---------------------------------------------------------------------- wiring

    function test_Constructor_Wiring() public view {
        assertEq(rules.facts(), address(facts));
        assertEq(rules.directory(), address(directory));
        assertEq(rules.delivery(), address(delivery));
        assertEq(rules.FINALIZE_NOTICE(), 14 days);
        assertEq(stream.moduleOf(Slots.RECORDS), address(rules));
        assertEq(stream.moduleOf(Slots.TERMS), address(streamTerms));
    }

    // ------------------------------------------------------------------- setRecord

    function test_SetRecord_TheArtistReplacesItAndTheVersionMoves() public {
        (uint256 id,) = _open(1);
        bytes32 next = _record(2);
        bytes32 before = _state(id);
        vm.expectEmit(address(facts));
        emit IWorkFacts.RecordSet(s, id, next);
        vm.expectEmit(address(rules));
        emit WorkRules.VersionBumped(s, id, 1);
        vm.expectEmit(s);
        emit IERC4906.MetadataUpdate(id);
        vm.prank(artist);
        rules.setRecord(s, id, next, before);
        assertEq(facts.factsOf(s, id).recordFileId, next);
        assertEq(rules.versionOf(s, id), 1);
        assertTrue(_state(id) != before);
    }

    function test_SetRecord_TheSameRecordIsANoOp() public {
        (uint256 id, PackageItem memory item) = _open(1);
        vm.prank(artist);
        rules.setRecord(s, id, item.recordFileId, bytes32(0));
        assertEq(rules.versionOf(s, id), 0);
    }

    function test_SetRecord_Refusals() public {
        (uint256 id,) = _open(1);
        bytes32 next = _record(2);
        bytes32 state = _state(id);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IWorkRules.NotWorkArtist.selector, s, id, stranger));
        rules.setRecord(s, id, next, state);
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRules.StateHashMismatch.selector, bytes32(0), state)
        );
        rules.setRecord(s, id, next, bytes32(0));
        bytes32 unstored = _file("{}", "application/json", false);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(WorkRules.InvalidRecordFile.selector, unstored));
        rules.setRecord(s, id, unstored, state);
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, bytes32(uint256(5)))
        );
        rules.setRecord(s, id, bytes32(uint256(5)), state);
        _artistFinalize(id);
        bytes32 later = _state(id);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.WorkIsFinalized.selector, s, id));
        rules.setRecord(s, id, next, later);
    }

    function test_SetRecord_NeedsAnOpenRecordAndALiveToken() public {
        uint256 id = _mintItem(stream, _item(1, _single(1)));
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.RecordNotOpen.selector, s, id));
        rules.setRecord(s, id, bytes32(0), bytes32(0));
        (uint256 opened,) = _open(2);
        bytes32 state = _state(opened);
        bytes32 next = _record(3);
        sale.burn(s, opened);
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, opened)
        );
        rules.setRecord(s, opened, next, state);
    }

    function test_SetRecord_FollowsTheAccountsWallets() public {
        (uint256 id,) = _open(1);
        address second = makeAddr("second wallet");
        signers.setWallet(uint160(artist), second, true);
        bytes32 first = _record(2);
        bytes32 state = _state(id);
        vm.prank(second);
        rules.setRecord(s, id, first, state);
        signers.setWallet(uint160(artist), artist, false);
        state = _state(id);
        bytes32 next = _record(3);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IWorkRules.NotWorkArtist.selector, s, id, artist));
        rules.setRecord(s, id, next, state);
    }

    // -------------------------------------------------------------------- finalize

    function test_Finalize_TheArtistAtAnyTimePinsTheRenderer() public {
        (uint256 id,) = _open(1);
        bytes32 state = _state(id);
        vm.expectEmit(address(facts));
        emit IWorkFacts.Finalized(s, id, address(renderer), address(renderer).codehash);
        vm.prank(artist);
        rules.finalize(s, id, state);
        assertTrue(facts.factsOf(s, id).finalized);
        assertEq(rules.versionOf(s, id), 1);
        bytes32 later = _state(id);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.WorkIsFinalized.selector, s, id));
        rules.finalize(s, id, later);
    }

    function test_Finalize_TheArtistsStateHashIsChecked() public {
        (uint256 id,) = _open(1);
        bytes32 state = _state(id);
        // A RENDERER change moves the state hash before finalize.
        CodeRenderer next = new CodeRenderer(1);
        _install(s, Slots.RENDERER, address(next));
        bytes32 moved = _state(id);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IWorkRules.StateHashMismatch.selector, state, moved));
        rules.finalize(s, id, state);
    }

    function test_Finalize_NobodyElseBeforeTheFirstSaleEnds() public {
        (uint256 id,) = _open(1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IWorkRules.NotWorkArtist.selector, s, id, stranger));
        rules.finalize(s, id, bytes32(0));
        assertEq(rules.finalizeNoticeAt(s, id), 0);
    }

    function test_Finalize_AnyoneFourteenDaysAfterANoticeOnceSold() public {
        (uint256 id,) = _open(1);
        sale.record(s, id, true, collector, 1 ether);
        vm.expectEmit(address(rules));
        emit IWorkRules.FinalizeNoticeRecorded(s, id, block.timestamp + 14 days);
        vm.prank(stranger);
        rules.finalize(s, id, bytes32(0));
        assertEq(rules.finalizeNoticeAt(s, id), block.timestamp);
        assertFalse(facts.factsOf(s, id).finalized);
        uint256 due = block.timestamp + 14 days;
        skip(14 days - 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IWorkRules.FinalizeNotDue.selector, s, id, due));
        rules.finalize(s, id, bytes32(0));
        // The artist changes the record meanwhile; the due call finalizes it as it stands.
        bytes32 next = _record(2);
        bytes32 seen = _state(id);
        vm.prank(artist);
        rules.setRecord(s, id, next, seen);
        skip(1);
        vm.prank(stranger);
        rules.finalize(s, id, keccak256("any state"));
        Facts memory f = facts.factsOf(s, id);
        assertTrue(f.finalized);
        assertEq(f.recordFileId, next);
    }

    function test_Finalize_ANoticeAlsoFollowsAnUnsoldOrRescuedOutcome() public {
        (uint256 unsold,) = _open(1);
        sale.record(s, unsold, false, address(0), 0);
        vm.prank(stranger);
        rules.finalize(s, unsold, 0);
        assertTrue(rules.finalizeNoticeAt(s, unsold) != 0);
        (uint256 rescued,) = _open(2);
        stream.removeMinter(address(sale));
        stream.setRescueDelay(0);
        stream.rescue(rescued, marketOwner);
        vm.prank(stranger);
        rules.finalize(s, rescued, 0);
        assertTrue(rules.finalizeNoticeAt(s, rescued) != 0);
    }

    function test_Finalize_TheArtistIsNeverHeldBackByANotice() public {
        (uint256 id,) = _open(1);
        sale.record(s, id, true, collector, 1);
        vm.prank(stranger);
        rules.finalize(s, id, 0);
        _artistFinalize(id);
        assertTrue(facts.factsOf(s, id).finalized);
    }

    /// @dev The notice waits exactly `FINALIZE_NOTICE`, whatever the time.
    function testFuzz_Finalize_RefusedBeforeTheNoticeHasRun(uint256 wait) public {
        wait = bound(wait, 0, 14 days - 1);
        (uint256 id,) = _open(1);
        sale.record(s, id, true, collector, 1);
        rules.finalize(s, id, 0);
        skip(wait);
        vm.expectRevert();
        rules.finalize(s, id, 0);
        skip(14 days - wait);
        rules.finalize(s, id, 0);
        assertTrue(facts.factsOf(s, id).finalized);
    }

    // ------------------------------------------------------------------- relicense

    function test_Relicense_WithEveryConsentAndTheNetwork() public {
        (uint256 id, PackageItem memory item) = _mitWork(1);
        License memory next = License("CC-BY-4.0", mitText);
        vm.expectEmit(address(facts));
        emit IWorkFacts.LicenseSet(s, id, next);
        _relicense(id, item, next);
        assertEq(facts.factsOf(s, id).licenseId, "CC-BY-4.0");
        assertEq(rules.versionOf(s, id), 1);
    }

    function test_Relicense_TheNetworkOnly() public {
        (uint256 id, PackageItem memory item) = _mitWork(1);
        License memory next = License("CC-BY-4.0", mitText);
        bytes32 state = _state(id);
        bytes[] memory sigs = _both(_relicenseHash(id, next, state, deadline));
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        rules.relicense(s, id, next, item, state, deadline, sigs);
    }

    function test_Relicense_TheSameKeyAndTextIsANoOp() public {
        (uint256 id, PackageItem memory item) = _mitWork(1);
        rules.relicense(s, id, License("mit", mitText), item, 0, 0, new bytes[](0));
        assertEq(rules.versionOf(s, id), 0);
        assertEq(facts.factsOf(s, id).licenseId, "MIT");
    }

    function test_Relicense_RefusesMissingOrBadConsents() public {
        (uint256 id, PackageItem memory item) = _mitWork(1);
        License memory next = License("CC-BY-4.0", mitText);
        bytes32 state = _state(id);
        bytes32 h = _relicenseHash(id, next, state, deadline);
        bytes[] memory one = new bytes[](1);
        one[0] = _sign(artistKey, h);
        vm.expectRevert(abi.encodeWithSelector(IWorkRules.InvalidConsent.selector, s, id));
        rules.relicense(s, id, next, item, state, deadline, one);
        bytes[] memory three = new bytes[](3);
        (three[0], three[1], three[2]) = (one[0], _sign(collaboratorKey, h), one[0]);
        vm.expectRevert(abi.encodeWithSelector(IWorkRules.InvalidConsent.selector, s, id));
        rules.relicense(s, id, next, item, state, deadline, three);
        // The collaborator signing in the artist's place is not a wallet of that account.
        bytes[] memory swapped = new bytes[](2);
        (swapped[0], swapped[1]) = (_sign(collaboratorKey, h), _sign(collaboratorKey, h));
        vm.expectRevert(
            abi.encodeWithSelector(
                SigningAccounts.NotAWallet.selector, uint160(artist), collaborator
            )
        );
        rules.relicense(s, id, next, item, state, deadline, swapped);
        // A signature over something else.
        bytes[] memory other = _both(_relicenseHash(id, next, state, deadline + 1));
        vm.expectRevert(abi.encodeWithSelector(SigningAccounts.BadSignature.selector, artist));
        rules.relicense(s, id, next, item, state, deadline, other);
        // Another item.
        PackageItem memory wrong = item;
        wrong.recordFileId = bytes32(uint256(1));
        vm.expectRevert(abi.encodeWithSelector(IWorkRules.InvalidConsent.selector, s, id));
        rules.relicense(s, id, next, wrong, state, deadline, _both(h));
    }

    function test_Relicense_RefusesAnExpiredDeadlineAndAStaleState() public {
        (uint256 id, PackageItem memory item) = _mitWork(1);
        License memory next = License("CC-BY-4.0", mitText);
        bytes32 state = _state(id);
        uint64 past = uint64(block.timestamp - 1);
        bytes[] memory sigs = _both(_relicenseHash(id, next, state, past));
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.SignatureExpired.selector, past));
        rules.relicense(s, id, next, item, state, past, sigs);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWorkRules.StateHashMismatch.selector, bytes32(uint256(1)), state
            )
        );
        rules.relicense(s, id, next, item, bytes32(uint256(1)), deadline, sigs);
    }

    function test_Relicense_ACc0WorkStaysCc0() public {
        (uint256 id, PackageItem memory item) = _open(1);
        License memory next = License("MIT", mitText);
        bytes32 state = _state(id);
        bytes[] memory sigs = _both(_relicenseHash(id, next, state, deadline));
        vm.expectRevert(IWorkFacts.InvalidLicense.selector);
        rules.relicense(s, id, next, item, state, deadline, sigs);
    }

    function test_Relicense_ARoundTripNeverReplaysConsents() public {
        (uint256 id, PackageItem memory item) = _mitWork(1);
        License memory a = License("MIT", mitText);
        License memory b = License("CC-BY-4.0", mitText);
        bytes32 first = _state(id);
        bytes[] memory toB = _both(_relicenseHash(id, b, first, deadline));
        rules.relicense(s, id, b, item, first, deadline, toB);
        _relicense(id, item, a);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRules.StateHashMismatch.selector, first, _state(id))
        );
        rules.relicense(s, id, b, item, first, deadline, toB);
    }

    function test_Relicense_ASecondWalletOfAnAccountConsents() public {
        (uint256 id, PackageItem memory item) = _mitWork(1);
        uint256 secondKey = 0x5EC0;
        signers.setWallet(uint160(collaborator), vm.addr(secondKey), true);
        License memory next = License("CC-BY-4.0", mitText);
        bytes32 state = _state(id);
        bytes32 h = _relicenseHash(id, next, state, deadline);
        bytes[] memory sigs = new bytes[](2);
        (sigs[0], sigs[1]) = (_sign(artistKey, h), _sign(secondKey, h));
        rules.relicense(s, id, next, item, state, deadline, sigs);
        assertEq(facts.factsOf(s, id).licenseId, "CC-BY-4.0");
    }

    // ------------------------------------------------------------- setRoyaltyRate

    function test_SetRoyaltyRate_WithEveryConsentUpOrDown() public {
        (uint256 id, PackageItem memory item) = _open(1);
        _setRate(id, item, 10_000);
        assertEq(stream.workOf(id).royaltyRate, 10_000);
        _setRate(id, item, 2_000);
        assertEq(stream.workOf(id).royaltyRate, 2_000);
        // The receiver is untouched.
        assertEq(stream.workOf(id).royaltyReceiver, address(0xFEE));
        assertEq(rules.versionOf(s, id), 2);
    }

    function test_SetRoyaltyRate_TheEditionFollows() public {
        (uint256 id, PackageItem memory item) = _open(1);
        sale.createEdition(address(editions), id, 10, address(0xED), 6529);
        _setRate(id, item, 3_000);
        assertEq(editions.editionOf(id).royaltyRate, 3_000);
        assertEq(editions.editionOf(id).royaltyReceiver, address(0xED));
    }

    function test_SetRoyaltyRate_TheSameRateIsANoOpAndTheNetworkOnly() public {
        (uint256 id, PackageItem memory item) = _open(1);
        rules.setRoyaltyRate(s, id, 6529, item, 0, 0, new bytes[](0));
        assertEq(rules.versionOf(s, id), 0);
        bytes32 state = _state(id);
        bytes[] memory sigs = _both(_rateHash(id, 1, state, deadline));
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        rules.setRoyaltyRate(s, id, 1, item, state, deadline, sigs);
    }

    function testFuzz_SetRoyaltyRate_AnyRateUpToTheCeiling(uint24 rate) public {
        (uint256 id, PackageItem memory item) = _open(1);
        vm.assume(rate != 6529);
        bytes32 state = _state(id);
        bytes[] memory sigs = _both(_rateHash(id, rate, state, deadline));
        if (rate > 100_000) vm.expectRevert(IStream.InvalidRoyalty.selector);
        rules.setRoyaltyRate(s, id, rate, item, state, deadline, sigs);
        if (rate <= 100_000) assertEq(stream.workOf(id).royaltyRate, rate);
    }

    function test_SetRoyaltyRate_ARoundTripNeverReplaysConsents() public {
        (uint256 id, PackageItem memory item) = _open(1);
        bytes32 first = _state(id);
        bytes[] memory up = _both(_rateHash(id, 9_000, first, deadline));
        rules.setRoyaltyRate(s, id, 9_000, item, first, deadline, up);
        _setRate(id, item, 6529);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRules.StateHashMismatch.selector, first, _state(id))
        );
        rules.setRoyaltyRate(s, id, 9_000, item, first, deadline, up);
    }

    // -------------------------------------------------------------- repinRenderer

    function test_RepinRenderer_TheNetworkAloneAfterFinalize() public {
        (uint256 id,) = _open(1);
        CodeRenderer next = new CodeRenderer(1);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.WorkNotFinalized.selector, s, id));
        rules.repinRenderer(s, id, address(next), 0);
        _artistFinalize(id);
        bytes32 state = _state(id);
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, artist)
        );
        rules.repinRenderer(s, id, address(next), state);
        // The current pin again is a no-op.
        rules.repinRenderer(s, id, address(renderer), 0);
        vm.expectEmit(address(facts));
        emit IWorkFacts.RendererRepinned(s, id, address(next), address(next).codehash);
        rules.repinRenderer(s, id, address(next), state);
        assertEq(stream.rendererOf(id), address(next));
        assertTrue(_state(id) != state);
    }

    // ------------------------------------------------------------------- renounce

    function test_Renounce_RefusesUnknownBits() public {
        (uint256 id,) = _open(1);
        vm.expectRevert(abi.encodeWithSelector(IWorkPowers.UnknownPower.selector, uint16(8)));
        rules.renounce(s, id, 8, 0, deadline, "");
    }

    function test_Renounce_TheRepinPowerByTheArtistsSignatureAloneAfterFinalize() public {
        (uint256 id,) = _open(1);
        bytes32 state = _state(id);
        bytes memory sig =
            _sign(artistKey, _renounceHash(id, WorkPowers.RENDERER_REPIN, state, deadline));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.WorkNotFinalized.selector, s, id));
        rules.renounce(s, id, WorkPowers.RENDERER_REPIN, state, deadline, sig);
        _artistFinalize(id);
        state = _state(id);
        sig = _sign(artistKey, _renounceHash(id, WorkPowers.RENDERER_REPIN, state, deadline));
        vm.expectEmit(address(rules));
        emit IWorkRules.PowersRenounced(s, id, WorkPowers.RENDERER_REPIN);
        vm.prank(stranger);
        rules.renounce(s, id, WorkPowers.RENDERER_REPIN, state, deadline, sig);
        assertTrue(facts.factsOf(s, id).repinLocked);
        assertEq(rules.renouncedPowers(s, id), WorkPowers.RENDERER_REPIN);
        address next = address(new CodeRenderer(2));
        bytes32 current = _state(id);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWorkPowers.PowerRenounced.selector, s, id, WorkPowers.RENDERER_REPIN
            )
        );
        rules.repinRenderer(s, id, next, current);
    }

    function test_Renounce_TheRoyaltyAndLicensePowersNeedTheNetwork() public {
        (uint256 id, PackageItem memory item) = _mitWork(1);
        uint16 both = WorkPowers.ROYALTY_RATE | WorkPowers.RELICENSE;
        bytes32 state = _state(id);
        bytes memory sig = _sign(artistKey, _renounceHash(id, both, state, deadline));
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        rules.renounce(s, id, both, state, deadline, sig);
        rules.renounce(s, id, both, state, deadline, sig);
        assertTrue(stream.workOf(id).royaltyRateLocked);
        assertTrue(facts.factsOf(s, id).licenseLocked);
        assertEq(rules.renouncedPowers(s, id), both);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkPowers.PowerRenounced.selector, s, id, WorkPowers.RELICENSE)
        );
        rules.relicense(s, id, License("CC-BY-4.0", mitText), item, 0, 0, new bytes[](0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IWorkPowers.PowerRenounced.selector, s, id, WorkPowers.ROYALTY_RATE
            )
        );
        rules.setRoyaltyRate(s, id, 1, item, 0, 0, new bytes[](0));
    }

    function test_Renounce_TheNetworkAloneCannot() public {
        (uint256 id,) = _open(1);
        bytes32 state = _state(id);
        bytes memory sig =
            _sign(collaboratorKey, _renounceHash(id, WorkPowers.RELICENSE, state, deadline));
        vm.expectRevert(
            abi.encodeWithSelector(
                SigningAccounts.NotAWallet.selector, uint160(artist), collaborator
            )
        );
        rules.renounce(s, id, WorkPowers.RELICENSE, state, deadline, sig);
    }

    function test_Renounce_RefusesAnExpiredOrStaleSignatureAndNeverAppliesTwice() public {
        (uint256 id,) = _open(1);
        _artistFinalize(id);
        bytes32 state = _state(id);
        uint64 past = uint64(block.timestamp - 1);
        bytes memory old = _sign(artistKey, _renounceHash(id, WorkPowers.RELICENSE, state, past));
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.SignatureExpired.selector, past));
        rules.renounce(s, id, WorkPowers.RELICENSE, state, past, old);
        uint16 all = WorkPowers.ALL;
        bytes memory sigAll = _sign(artistKey, _renounceHash(id, all, state, deadline));
        _renounce(id, WorkPowers.RELICENSE);
        assertEq(rules.versionOf(s, id), 2);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRules.StateHashMismatch.selector, state, _state(id))
        );
        rules.renounce(s, id, all, state, deadline, sigAll);
    }

    function test_Renounce_OnlyBitsAlreadyRenouncedIsANoOp() public {
        (uint256 id,) = _open(1);
        _renounce(id, WorkPowers.RELICENSE);
        uint32 version = rules.versionOf(s, id);
        vm.recordLogs();
        rules.renounce(s, id, WorkPowers.RELICENSE, 0, 0, "");
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(rules.versionOf(s, id), version);
    }

    function test_Renounce_TheEditionFollowsTheMastersLockedRate() public {
        (uint256 id, PackageItem memory item) = _open(1);
        sale.createEdition(address(editions), id, 10, address(0xED), 6529);
        _renounce(id, WorkPowers.ROYALTY_RATE);
        bytes32 state = _state(id);
        bytes[] memory sigs = _both(_rateHash(id, 1, state, deadline));
        vm.expectRevert(
            abi.encodeWithSelector(
                IWorkPowers.PowerRenounced.selector, s, id, WorkPowers.ROYALTY_RATE
            )
        );
        rules.setRoyaltyRate(s, id, 1, item, state, deadline, sigs);
        assertEq(editions.editionOf(id).royaltyRate, 6529);
    }

    /// @dev A renunciation lives in the permanent locks, so it survives a new RECORDS module and
    ///      binds even a module that passes every call straight through.
    function test_Renounce_SurvivesEveryReplacementOfTheModule() public {
        (uint256 id, PackageItem memory item) = _mitWork(1);
        _artistFinalize(id);
        _renounce(id, WorkPowers.ALL);
        WorkRules successor =
            new WorkRules(address(manager), address(facts), address(directory), address(0));
        _install(s, Slots.RECORDS, address(successor));
        assertEq(successor.renouncedPowers(s, id), WorkPowers.ALL);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkPowers.PowerRenounced.selector, s, id, WorkPowers.RELICENSE)
        );
        successor.relicense(s, id, License("CC-BY-4.0", mitText), item, 0, 0, new bytes[](0));
        _install(s, Slots.RECORDS, address(records));
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.LicenseIsLocked.selector, s, id));
        records.setLicense(s, id, License("CC-BY-4.0", mitText));
        address other = address(new CodeRenderer(3));
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.RepinIsLocked.selector, s, id));
        records.repin(s, id, other);
        _install(s, Slots.TERMS, address(terms));
        vm.expectRevert(IStream.InvalidRoyalty.selector);
        terms.setRoyalty(s, id, address(1), 1);
        // The pass-through TERMS module may still move the receiver at the locked rate.
        terms.setRoyalty(s, id, address(1), 6529);
        assertEq(stream.workOf(id).royaltyReceiver, address(1));
    }

    // ------------------------------------------------------------------- delivery

    function test_SetDelivery_TheNetworkSwapsToASuccessorThatNamesThisModule() public {
        WorkDelivery next =
            new WorkDelivery(address(manager), address(rules), address(facts), address(directory));
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        rules.setDelivery(address(delivery), address(next));
        vm.expectRevert(WorkRules.DeliveryMismatch.selector);
        rules.setDelivery(address(0), address(next));
        WorkDelivery foreign =
            new WorkDelivery(address(manager), address(1), address(facts), address(directory));
        vm.expectRevert(
            abi.encodeWithSelector(WorkRules.InvalidDelivery.selector, address(foreign))
        );
        rules.setDelivery(address(delivery), address(foreign));
        vm.expectRevert(abi.encodeWithSelector(WorkRules.InvalidDelivery.selector, address(0xBEEF)));
        rules.setDelivery(address(delivery), address(0xBEEF));
        vm.expectEmit(address(rules));
        emit IWorkRules.DeliverySet(address(delivery), address(next));
        rules.setDelivery(address(delivery), address(next));
        assertEq(rules.delivery(), address(next));
    }

    function test_RefreshHooks_OnlyTheDelivery() public {
        (uint256 id,) = _open(1);
        _open(2);
        vm.expectRevert(abi.encodeWithSelector(IDeliveryHost.NotDelivery.selector, address(this)));
        rules.refreshMetadata(s, id);
        vm.expectRevert(abi.encodeWithSelector(IDeliveryHost.NotDelivery.selector, address(this)));
        rules.refreshAllMetadata(s);
        vm.expectEmit(s);
        emit IERC4906.BatchMetadataUpdate(1, 2);
        vm.prank(address(delivery));
        rules.refreshAllMetadata(s);
    }

    // --------------------------------------------------------------------- stores

    function test_Stores_TheNetworkAddsAndRetires() public {
        RulesChunkStore cs = new RulesChunkStore();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        rules.addStore(address(cs), address(cs).codehash);
        vm.expectRevert(abi.encodeWithSelector(WorkRules.InvalidStore.selector, address(cs)));
        rules.addStore(address(cs), bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(WorkRules.InvalidStore.selector, address(0xC0DE)));
        rules.addStore(address(0xC0DE), bytes32(0));
        vm.expectEmit(address(rules));
        emit WorkRules.StoreAdded(1, address(cs), address(cs).codehash);
        rules.addStore(address(cs), address(cs).codehash);
        for (uint256 i = 2; i <= 15; ++i) {
            rules.addStore(address(cs), address(cs).codehash);
        }
        vm.expectRevert(abi.encodeWithSelector(WorkRules.InvalidStore.selector, address(cs)));
        rules.addStore(address(cs), address(cs).codehash);
        assertEq(rules.storeCount(), 15);
        vm.expectEmit(address(rules));
        emit WorkRules.StoreRetired(3);
        rules.retireStore(3);
        assertTrue(rules.store(3).retired);
        vm.expectRevert(abi.encodeWithSelector(WorkRules.UnknownStore.selector, 0));
        rules.retireStore(0);
        vm.expectRevert(abi.encodeWithSelector(WorkRules.UnknownStore.selector, 16));
        rules.retireStore(16);
    }

    function test_FileStore_TheArtistChoosesAStoreThatServesEveryChunk() public {
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = _mediaFile(1, FileRole.PRIMARY, true);
        media[1] = _mediaFile(2, FileRole.PREVIEW, false);
        PackageItem memory item = _item(1, media);
        uint256 id = _mintItem(stream, item);
        facts.open(s, id, item, media);
        RulesChunkStore cs = new RulesChunkStore();
        rules.addStore(address(cs), address(cs).codehash);
        bytes32 file = media[1].fileId;
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(WorkRules.FileNotServed.selector, file, 1));
        rules.setFileStore(s, id, file, 1);
        cs.put(_mediaBytes(2));
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        rules.setFileStore(s, id, file, 1);
        vm.expectEmit(address(rules));
        emit WorkRules.FileStoreSet(s, id, file, 1);
        vm.prank(artist);
        rules.setFileStore(s, id, file, 1);
        assertEq(rules.fileStore(s, id, file), 1);
        // A file outside the work, a retired store, an unknown store.
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(WorkRules.FileNotServed.selector, bytes32(0), 1));
        rules.setFileStore(s, id, bytes32(0), 1);
        rules.retireStore(1);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(WorkRules.UnknownStore.selector, 1));
        rules.setFileStore(s, id, file, 1);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(WorkRules.UnknownStore.selector, 2));
        rules.setFileStore(s, id, file, 2);
        // The network (storage operator) may set it back to the content store.
        rules.setFileStore(s, id, file, 0);
        assertEq(rules.fileStore(s, id, file), 0);
    }

    // ------------------------------------------------------------------ state hash

    function test_StateHash_FollowsTheRendererModuleOnlyBeforeFinalize() public {
        (uint256 id,) = _open(1);
        bytes32 before = _state(id);
        _install(s, Slots.RENDERER, address(new CodeRenderer(1)));
        bytes32 moved = _state(id);
        assertTrue(moved != before);
        _artistFinalize(id);
        bytes32 pinned = _state(id);
        _install(s, Slots.RENDERER, address(new CodeRenderer(2)));
        assertEq(_state(id), pinned);
    }

    function test_StateHash_IsThisModulesOwnAndIgnoresPermissionlessActions() public {
        (uint256 id,) = _open(1);
        bytes32 mine = _state(id);
        WorkRules other =
            new WorkRules(address(manager), address(facts), address(directory), address(0));
        assertTrue(other.workStateHash(s, id) != mine);
        facts.markOnChainComplete(s, id);
        assertEq(_state(id), mine);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.RecordNotOpen.selector, s, 99));
        rules.workStateHash(s, 99);
    }

    function test_Refresh_NotifiesTheEditionOfAMaster() public {
        (uint256 id,) = _open(1);
        sale.createEdition(address(editions), id, 10, address(0xED), 6529);
        bytes32 next = _record(2);
        bytes32 state = _state(id);
        vm.expectEmit(address(editions));
        emit IERC4906.MetadataUpdate(id);
        vm.prank(artist);
        rules.setRecord(s, id, next, state);
    }

    // ---------------------------------------------------- pinned by mutation testing

    /// @dev The first delivery contract is announced at deployment.
    function test_Constructor_AnnouncesTheFirstDelivery() public {
        vm.expectEmit();
        emit IWorkRules.DeliverySet(address(0), address(0xD311));
        new WorkRules(address(manager), address(facts), address(directory), address(0xD311));
    }

    /// @dev Once finalized, the refusal comes before the no-op and before the artist check.
    function test_SetRecord_AFinalizedWorkRefusesBeforeAnyOtherCheck() public {
        (uint256 id, PackageItem memory item) = _open(1);
        _artistFinalize(id);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.WorkIsFinalized.selector, s, id));
        rules.setRecord(s, id, item.recordFileId, bytes32(0));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.WorkIsFinalized.selector, s, id));
        rules.setRecord(s, id, bytes32(uint256(5)), bytes32(0));
    }

    /// @dev Renouncing the royalty power alone makes no call to the record's locks.
    function test_Renounce_TheRoyaltyPowerAloneNeverTouchesTheRecordLocks() public {
        (uint256 id,) = _open(1);
        vm.expectCall(address(facts), abi.encodeWithSelector(facts.lock.selector), 0);
        _renounce(id, WorkPowers.ROYALTY_RATE);
        assertEq(rules.renouncedPowers(s, id), WorkPowers.ROYALTY_RATE);
    }

    function test_Relicense_RefreshesTheMetadata() public {
        (uint256 id, PackageItem memory item) = _mitWork(1);
        vm.expectEmit(s);
        emit IERC4906.MetadataUpdate(id);
        _relicense(id, item, License("CC-BY-4.0", mitText));
    }

    /// @dev Not even the current rate, a no-op on an open record, passes before the record is
    ///      open; a token that was never minted has no open record either.
    function test_SetRoyaltyRate_NeedsAnOpenRecord() public {
        PackageItem memory item = _item(1, _single(1));
        uint256 id = _mintItem(stream, item);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.RecordNotOpen.selector, s, id));
        rules.setRoyaltyRate(s, id, 6529, item, 0, 0, new bytes[](0));
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.RecordNotOpen.selector, s, 99));
        rules.setRoyaltyRate(s, 99, 1, item, 0, 0, new bytes[](0));
    }

    function test_RepinRenderer_MovesTheVersionAndRefreshesTheMetadata() public {
        (uint256 id,) = _open(1);
        _artistFinalize(id);
        CodeRenderer next = new CodeRenderer(1);
        bytes32 state = _state(id);
        vm.expectEmit(address(rules));
        emit WorkRules.VersionBumped(s, id, 2);
        vm.expectEmit(s);
        emit IERC4906.MetadataUpdate(id);
        rules.repinRenderer(s, id, address(next), state);
        assertEq(rules.versionOf(s, id), 2);
    }

    /// @dev The code hash must be the store's own: one above it is refused as one below is.
    function test_Stores_ACodeHashAboveTheStoresOwnIsRefused() public {
        RulesChunkStore cs = new RulesChunkStore();
        vm.expectRevert(abi.encodeWithSelector(WorkRules.InvalidStore.selector, address(cs)));
        rules.addStore(address(cs), bytes32(type(uint256).max));
        assertEq(rules.storeCount(), 0);
    }

    function test_Stores_EachIdNamesItsOwnStore() public {
        RulesChunkStore first = new RulesChunkStore();
        RulesChunkStore second = new RulesChunkStore();
        rules.addStore(address(first), address(first).codehash);
        rules.addStore(address(second), address(second).codehash);
        assertEq(rules.store(1).source, address(first));
        assertEq(rules.store(2).source, address(second));
        rules.retireStore(2);
        assertFalse(rules.store(1).retired);
        assertTrue(rules.store(2).retired);
    }

    /// @dev A file ID above every media file of the work is still not one of its files; a
    ///      choice of store is announced and refreshes the token's metadata.
    function test_FileStore_OnlyTheWorksOwnFilesAndTheMetadataIsRefreshed() public {
        (uint256 id,, MediaFile[] memory media) = _work(stream, 1);
        bytes32 foreign = bytes32(type(uint256).max);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(WorkRules.FileNotServed.selector, foreign, 0));
        rules.setFileStore(s, id, foreign, 0);
        vm.expectEmit(address(rules));
        emit WorkRules.FileStoreSet(s, id, media[0].fileId, 0);
        vm.expectEmit(s);
        emit IERC4906.MetadataUpdate(id);
        vm.prank(artist);
        rules.setFileStore(s, id, media[0].fileId, 0);
    }

    /// @dev A token with no editions contract (here: no TERMS module) is refreshed alone.
    function test_RefreshAllMetadata_ATokenWithoutEditionsIsRefreshedAlone() public {
        _open(1);
        _open(2);
        stream.removeModule(Slots.TERMS);
        vm.expectEmit(s);
        emit IERC4906.BatchMetadataUpdate(1, 2);
        vm.prank(address(delivery));
        rules.refreshAllMetadata(s);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { IDeliveryHost, IWorkDelivery } from "src/interfaces/IWorkDelivery.sol";
import { ITerms } from "src/interfaces/core/ITerms.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { IWorkRules } from "src/interfaces/core/IWorkRules.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { WorkRules } from "src/records/WorkRules.sol";
import { ContentAddresses as CA } from "../helpers/ContentAddresses.sol";
import { HostileModule } from "../mocks/core/CoreMocks.sol";
import { CodeRenderer, SigningAccounts } from "../mocks/records/RulesMocks.sol";
import { RulesFixture } from "./RulesFixture.sol";

/// @notice Rules of `WorkRules` that the main suites pin only in part: a finalize notice
///         changes nothing a consent binds (WS-11), a royalty-rate change is unanimous by
///         account and reaches the token through the TERMS module (WS-14), every visible change
///         emits ERC-4906 through the token (WS-23), and a hostile delivery contract changes no
///         fact of a work (WS-39).
contract WorkRulesRulesTest is RulesFixture {
    uint24 internal constant NEW_RATE = 4_000;

    address internal s;
    uint64 internal deadline;
    /// @dev A contract that passes on any call, installed as the delivery contract.
    HostileModule internal hostile;

    function setUp() public override {
        super.setUp();
        s = address(stream);
        deadline = uint64(block.timestamp + 1 days);
    }

    function _rateHash(uint256 id, bytes32 state) internal view returns (bytes32) {
        return
            keccak256(abi.encode(rules.ROYALTY_RATE_TYPEHASH(), s, id, NEW_RATE, state, deadline));
    }

    function _setRate(uint256 id, PackageItem memory item, bytes32 state, bytes[] memory sigs)
        internal
    {
        rules.setRoyaltyRate(s, id, NEW_RATE, item, state, deadline, sigs);
    }

    function _pair(bytes memory first, bytes memory second)
        internal
        pure
        returns (bytes[] memory sigs)
    {
        sigs = new bytes[](2);
        (sigs[0], sigs[1]) = (first, second);
    }

    function _expectRefresh(uint256 id) internal {
        vm.expectEmit(s);
        emit IERC4906.MetadataUpdate(id);
    }

    // ---------------------------------------------------------------- finalize notice

    /// WS-11: recording a finalize notice, which anyone may do once the first sale has an
    /// outcome, leaves the version and the state hash as they were, so consents collected
    /// before it still apply; the finalize that follows the notice is an applied change and
    /// bumps the version.
    function test_Finalize_ANoticeLeavesTheVersionAndTheStateHash() public {
        (uint256 id, PackageItem memory item,) = _work(stream, 1);
        sale.record(s, id, true, collector, 1 ether);
        bytes32 state = _state(id);
        bytes[] memory consents = _both(_rateHash(id, state));
        vm.prank(stranger);
        rules.finalize(s, id, bytes32(0));
        assertEq(rules.finalizeNoticeAt(s, id), block.timestamp);
        assertEq(rules.versionOf(s, id), 0);
        assertEq(_state(id), state);
        _setRate(id, item, state, consents);
        assertEq(stream.workOf(id).royaltyRate, NEW_RATE);
        assertEq(rules.versionOf(s, id), 1);

        skip(rules.FINALIZE_NOTICE());
        bytes32 beforeFinalize = _state(id);
        vm.expectEmit(address(rules));
        emit WorkRules.VersionBumped(s, id, 2);
        vm.prank(stranger);
        rules.finalize(s, id, bytes32(0));
        assertTrue(facts.factsOf(s, id).finalized);
        assertTrue(_state(id) != beforeFinalize);
    }

    // ------------------------------------------------------------------ royalty rate

    /// WS-14: a royalty-rate change is refused without one party's consent and when one account
    /// signs for another; any wallet of a party's account consents for it; the new rate is
    /// written by a call to the token's TERMS module.
    function test_SetRoyaltyRate_EveryPartyByAccountThenThroughTheTermsModule() public {
        (uint256 id, PackageItem memory item,) = _work(stream, 1);
        bytes32 state = _state(id);
        bytes memory artistConsent = _sign(artistKey, _rateHash(id, state));

        bytes[] memory one = new bytes[](1);
        one[0] = artistConsent;
        vm.expectRevert(abi.encodeWithSelector(IWorkRules.InvalidConsent.selector, s, id));
        _setRate(id, item, state, one);

        vm.expectRevert(
            abi.encodeWithSelector(
                SigningAccounts.NotAWallet.selector, uint256(uint160(collaborator)), artist
            )
        );
        _setRate(id, item, state, _pair(artistConsent, artistConsent));
        assertEq(stream.workOf(id).royaltyRate, 6529);

        uint256 secondKey = 0x5EC0;
        signers.setWallet(uint160(collaborator), vm.addr(secondKey), true);
        bytes[] memory sigs = _pair(artistConsent, _sign(secondKey, _rateHash(id, state)));
        vm.expectCall(
            address(streamTerms), abi.encodeCall(ITerms.setRoyaltyRate, (s, id, NEW_RATE))
        );
        _setRate(id, item, state, sigs);
        assertEq(stream.workOf(id).royaltyRate, NEW_RATE);
    }

    // ----------------------------------------------------------------------- ERC-4906

    /// @dev A two-file work on MIT, every file stored, with its record open.
    function _storedMitWork() internal returns (uint256 id, PackageItem memory item, bytes32 file) {
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = _mediaFile(1, FileRole.PRIMARY, true);
        media[1] = _mediaFile(2, FileRole.PREVIEW, true);
        item = _item(1, media);
        item.license = License("MIT", mitText);
        id = _mintItem(stream, item);
        facts.open(s, id, item, media);
        file = media[1].fileId;
    }

    /// @dev Relicenses with every consent, expecting the refresh.
    function _relicenseExpectingRefresh(uint256 id, PackageItem memory item) internal {
        License memory next = License("CC-BY-4.0", mitText);
        bytes32 state = _state(id);
        bytes[] memory consents = _both(
            keccak256(
                abi.encode(
                    rules.RELICENSE_TYPEHASH(),
                    s,
                    id,
                    WorksHashing.licenseKey(next.spdxId),
                    next.textFileId,
                    state,
                    deadline
                )
            )
        );
        _expectRefresh(id);
        rules.relicense(s, id, next, item, state, deadline, consents);
    }

    /// WS-23: on-chain complete, a relicense, finalize, a repin, a file's store, a new locator,
    /// a file preference and a dead mark each emit `MetadataUpdate` for the work from the token
    /// contract.
    function test_Refresh_EveryVisibleChangeEmitsThroughTheToken() public {
        (uint256 id, PackageItem memory item, bytes32 file) = _storedMitWork();

        _expectRefresh(id);
        vm.prank(stranger);
        facts.markOnChainComplete(s, id);

        _relicenseExpectingRefresh(id, item);

        bytes32 state = _state(id);
        _expectRefresh(id);
        vm.prank(artist);
        rules.finalize(s, id, state);

        address nextRenderer = address(new CodeRenderer(1));
        state = _state(id);
        _expectRefresh(id);
        rules.repinRenderer(s, id, nextRenderer, state);

        _expectRefresh(id);
        rules.setFileStore(s, id, file, 0);

        _expectRefresh(id);
        delivery.addLocator(s, id, file, CA.ar("a0"));
        _expectRefresh(id);
        delivery.setFilePreference(s, id, file, 0);
        _expectRefresh(id);
        delivery.markLocatorDead(s, id, file, 0);
    }

    // ----------------------------------------------------------------------- delivery

    /// @dev The hostile delivery's call to `to` reverts with exactly `expected`.
    function _expectRefused(address to, bytes memory data, bytes memory expected) internal {
        (bool ok, bytes memory ret) = hostile.exec(to, data);
        assertFalse(ok, "a call of the hostile delivery went through");
        assertEq(ret, expected);
    }

    /// @dev Every write of the record contract, tried by the hostile delivery.
    function _tryEveryFactsWrite(uint256 id, bytes32 nextRecord) internal {
        bytes memory refused =
            abi.encodeWithSelector(IWorkFacts.NotRecordsModule.selector, s, address(hostile));
        address f = address(facts);
        _expectRefused(f, abi.encodeCall(IWorkFacts.setRecord, (s, id, nextRecord)), refused);
        _expectRefused(
            f, abi.encodeCall(IWorkFacts.setLicense, (s, id, License("cc0-1.0", cc0Text))), refused
        );
        _expectRefused(f, abi.encodeCall(IWorkFacts.finalize, (s, id)), refused);
        _expectRefused(f, abi.encodeCall(IWorkFacts.repin, (s, id, address(hostile))), refused);
        _expectRefused(f, abi.encodeCall(IWorkFacts.lock, (s, id, true, false)), refused);
    }

    /// @dev Every rule of this module, tried by the hostile delivery.
    function _tryEveryRule(uint256 id, PackageItem memory item, bytes32 state, bytes32 nextRecord)
        internal
    {
        address h = address(hostile);
        address r = address(rules);
        bytes memory notArtist = abi.encodeWithSelector(IWorkRules.NotWorkArtist.selector, s, id, h);
        _expectRefused(r, abi.encodeCall(rules.setRecord, (s, id, nextRecord, state)), notArtist);
        _expectRefused(r, abi.encodeCall(rules.finalize, (s, id, state)), notArtist);
        bytes memory unauthorized =
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, h);
        bytes[] memory none = new bytes[](0);
        _expectRefused(
            r,
            abi.encodeCall(
                rules.relicense, (s, id, License("cc0-1.0", cc0Text), item, state, deadline, none)
            ),
            unauthorized
        );
        _expectRefused(
            r,
            abi.encodeCall(rules.setRoyaltyRate, (s, id, 1, item, state, deadline, none)),
            unauthorized
        );
        _expectRefused(r, abi.encodeCall(rules.repinRenderer, (s, id, h, state)), unauthorized);
        _expectRefused(r, abi.encodeCall(rules.setDelivery, (h, address(delivery))), unauthorized);
    }

    /// WS-39: a delivery contract the network installed, however it behaves, can only ask for
    /// metadata refreshes: every write to the record contract and every rule of this module
    /// refuses it, and the work's facts, royalty terms and state hash stay as they were.
    function test_SetDelivery_AHostileDeliveryChangesNoFact() public {
        (uint256 id, PackageItem memory item,) = _work(stream, 1);
        hostile = new HostileModule();
        vm.mockCall(
            address(hostile), abi.encodeCall(IWorkDelivery.records, ()), abi.encode(address(rules))
        );
        vm.mockCall(
            address(hostile), abi.encodeCall(IWorkDelivery.facts, ()), abi.encode(address(facts))
        );
        rules.setDelivery(address(delivery), address(hostile));
        assertEq(rules.delivery(), address(hostile));

        bytes32 factsBefore = keccak256(abi.encode(facts.factsOf(s, id)));
        bytes32 workBefore = keccak256(abi.encode(stream.workOf(id)));
        bytes32 state = _state(id);
        bytes32 nextRecord = _record(2);
        _tryEveryFactsWrite(id, nextRecord);
        _tryEveryRule(id, item, state, nextRecord);

        // What it may do: ask the token for a metadata refresh.
        vm.expectEmit(s);
        emit IERC4906.MetadataUpdate(id);
        (bool refreshed,) =
            hostile.exec(address(rules), abi.encodeCall(IDeliveryHost.refreshMetadata, (s, id)));
        assertTrue(refreshed, "the refresh hook");

        assertEq(keccak256(abi.encode(facts.factsOf(s, id))), factsBefore);
        assertEq(keccak256(abi.encode(stream.workOf(id))), workBefore);
        assertEq(_state(id), state);
        assertEq(rules.versionOf(s, id), 0);
    }
}

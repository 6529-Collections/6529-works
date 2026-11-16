// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { RecordsFixture } from "./RecordsFixture.sol";
import { WorkPowersHandler } from "./WorkPowersHandler.sol";
import { MockRenderer } from "../mocks/stream/StreamMocks.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IStreamViews } from "src/interfaces/IStreamViews.sol";

/// @notice Stateful invariants of the renounceable powers and royalty changes (ADR 0006 as
///         amended by R10 and C7): a work's renounced mask never loses a bit, a renounced
///         power's function never succeeds again, and a work's royalty rate stays at most 100%
///         and never moves once its royalty power is renounced.
contract WorkPowersInvariantTest is RecordsFixture {
    uint256 internal constant WORKS = 4;

    WorkPowersHandler internal handler;
    mapping(uint256 tokenId => uint16) internal _seen;
    mapping(uint256 tokenId => uint256) internal _frozenRate;

    function setUp() public override {
        super.setUp();
        handler = new WorkPowersHandler(stream, records, artistKey, collaboratorKey, governor);
        handler.addLicense(_license("cc-by-4.0"));
        handler.addLicense(_license("cc-by-sa-4.0"));
        handler.addLicense(_license("mit"));
        handler.addRenderer(address(new MockRenderer("errata A")));
        handler.addRenderer(address(new MockRenderer("errata B")));
        for (uint256 i; i < WORKS; ++i) {
            MediaFile[] memory media = _single(i, true);
            PackageItem memory item = _recordsItem(i, media);
            item.license = _license("cc-by-4.0");
            uint256 tokenId = _mint(item);
            records.openRecord(tokenId, item, media);
            handler.addWork(tokenId, item);
        }
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.renounce.selector;
        selectors[1] = handler.changeRoyalty.selector;
        selectors[2] = handler.relicense.selector;
        selectors[3] = handler.finalize.selector;
        selectors[4] = handler.repin.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// Regression: ADD-PWR-2
    /// @dev The mask only gains bits: it equals the handler's OR of every applied
    ///      renunciation, and holds every bit it held at the previous check.
    function invariant_renouncedMaskNeverLosesABit() public {
        for (uint256 i; i < handler.workCount(); ++i) {
            uint256 tokenId = handler.tokenIds(i);
            uint16 mask = records.renouncedPowers(tokenId);
            assertEq(mask, handler.ghostMask(tokenId));
            assertEq(_seen[tokenId] & ~mask, 0, "a renounced bit came back");
            _seen[tokenId] = mask;
        }
    }

    /// Regression: ADD-PWR-2
    /// @dev No renounced power's function succeeded after the renunciation, every call the
    ///      rules allow succeeded, and the rate and license are the ones the handler applied.
    function invariant_aRenouncedPowerNeverSucceedsAgain() public view {
        assertEq(handler.violations(), 0);
        for (uint256 i; i < handler.workCount(); ++i) {
            uint256 tokenId = handler.tokenIds(i);
            assertEq(
                IStreamViews(address(stream)).work(tokenId).royaltyRate, handler.ghostRate(tokenId)
            );
            assertEq(
                abi.encode(records.licenseOf(tokenId)), abi.encode(handler.ghostLicenseOf(tokenId))
            );
            assertEq(records.pinnedRenderer(tokenId), handler.ghostRenderer(tokenId));
        }
    }

    /// Regression: ADD-PWR-1
    /// @dev R10: a work's royalty rate moves both ways but never past 100%, and once the royalty
    ///      power is renounced it never moves again (each step is checked in the handler).
    function invariant_royaltyRateWithinTheCeilingAndFixedOnceRenounced() public {
        for (uint256 i; i < handler.workCount(); ++i) {
            uint256 tokenId = handler.tokenIds(i);
            uint256 rate = IStreamViews(address(stream)).work(tokenId).royaltyRate;
            assertLe(rate, 100_000);
            if (records.renouncedPowers(tokenId) & 1 == 0) continue;
            // Stored plus one, so a frozen rate of zero is told from none recorded.
            if (_frozenRate[tokenId] == 0) _frozenRate[tokenId] = rate + 1;
            assertEq(rate + 1, _frozenRate[tokenId], "a renounced rate moved");
        }
        assertEq(handler.violations(), 0);
    }
}

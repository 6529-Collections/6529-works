// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { RecordsFixture } from "./RecordsFixture.sol";
import { WorkPowersHandler } from "./WorkPowersHandler.sol";

/// @notice Stateful invariants of the renounceable powers and lower-only royalty changes
///         (ADR 0006): a work's renounced mask never loses a bit, a renounced power's function
///         never succeeds again, and a work's royalty rate never rises.
contract WorkPowersInvariantTest is RecordsFixture {
    uint256 internal constant WORKS = 4;
    /// @dev Every work mints at the fixture's default rate.
    uint32 internal constant MINT_RATE = 6_529;

    WorkPowersHandler internal handler;
    mapping(uint256 tokenId => uint16) internal _seen;

    function setUp() public override {
        super.setUp();
        handler = new WorkPowersHandler(stream, records, artistKey, collaboratorKey, governor);
        handler.addLicense(_license("cc-by-4.0"));
        handler.addLicense(_license("cc-by-sa-4.0"));
        handler.addLicense(_license("mit"));
        for (uint256 i; i < WORKS; ++i) {
            MediaFile[] memory media = _single(i, true);
            PackageItem memory item = _recordsItem(i, media);
            item.license = _license("cc-by-4.0");
            uint256 tokenId = _mint(item);
            records.openRecord(tokenId, item, media);
            handler.addWork(tokenId, item);
        }
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.renounce.selector;
        selectors[1] = handler.changeRoyalty.selector;
        selectors[2] = handler.relicense.selector;
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
            assertEq(stream.work(tokenId).royaltyRate, handler.ghostRate(tokenId));
            assertEq(
                abi.encode(records.licenseOf(tokenId)), abi.encode(handler.ghostLicenseOf(tokenId))
            );
        }
    }

    /// Regression: ADD-PWR-1
    /// @dev A work's royalty rate never rises above the rate it minted with, and never rose at
    ///      any step (each step is checked in the handler).
    function invariant_royaltyRateNeverRises() public view {
        for (uint256 i; i < handler.workCount(); ++i) {
            assertLe(stream.work(handler.tokenIds(i)).royaltyRate, MINT_RATE);
        }
        assertEq(handler.violations(), 0);
    }
}

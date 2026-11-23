// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IWorkDelivery } from "src/interfaces/IWorkDelivery.sol";
import { Locator, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import { ContentAddresses as CA } from "../helpers/ContentAddresses.sol";
import { RulesFixture } from "../records/RulesFixture.sol";

/// @notice The locator quotas of `WorkDelivery` from the platform's side (WS-19): half of a
///         file's locators before finalize, and after finalize every slot the artist left.
contract WorkDeliveryRulesTest is RulesFixture {
    address internal s;

    function setUp() public override {
        super.setUp();
        s = address(stream);
    }

    function _platformAdds(uint256 id, bytes32 file, uint256 from, uint256 count) internal {
        for (uint256 i = from; i < from + count; ++i) {
            delivery.addLocator(s, id, file, CA.ipfsLocator(vm.toString(i)));
        }
    }

    /// WS-19: before finalize the platform adds half of `Limits.MAX_LOCATORS_PER_FILE` and no
    /// more, whatever the artist has added; after finalize the artist adds nothing and the
    /// platform fills the file up to the limit, the artist's unused half included.
    function test_AddLocator_ThePlatformHasHalfBeforeFinalizeAndTheRestAfter() public {
        (uint256 id,, MediaFile[] memory media) = _work(stream, 1);
        bytes32 file = media[0].fileId;
        uint256 most = Limits.MAX_LOCATORS_PER_FILE;
        uint256 half = most / 2;

        _platformAdds(id, file, 0, half);
        Locator memory extra = CA.ipfsLocator("platform-extra");
        vm.expectRevert(IWorkDelivery.InvalidLocator.selector);
        delivery.addLocator(s, id, file, extra);
        // The artist's half is its own.
        vm.prank(artist);
        delivery.addLocator(s, id, file, CA.ar("artist-0"));
        (uint256 byTheArtist, uint256 byThePlatform,) = delivery.locatorCounts(s, id, file);
        assertEq(byTheArtist, 1);
        assertEq(byThePlatform, half);

        bytes32 state = _state(id);
        vm.prank(artist);
        rules.finalize(s, id, state);
        Locator memory late = CA.ar("artist-late");
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, artist)
        );
        delivery.addLocator(s, id, file, late);

        _platformAdds(id, file, 100, most - half - 1);
        (byTheArtist, byThePlatform,) = delivery.locatorCounts(s, id, file);
        assertEq(byTheArtist, 1);
        assertEq(byThePlatform, most - 1, "the platform took the artist's unused slots");
        assertEq(delivery.locators(s, id, file).length, most);
        vm.expectRevert(IWorkDelivery.InvalidLocator.selector);
        delivery.addLocator(s, id, file, extra);
        assertEq(delivery.locators(s, id, file).length, most);
    }
}

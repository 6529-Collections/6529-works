// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ConsolidationAdapter, IDelegationManagement } from "src/identity/ConsolidationAdapter.sol";
import { IConsolidationSource } from "src/interfaces/IArtistRegistry.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { AccountsFixture } from "./AccountsFixture.sol";

/// @notice The v1 consolidation source: a live two-way all-collections consolidation, no age.
contract ConsolidationAdapterTest is AccountsFixture {
    function test_TwoWayAllCollectionsCounts() public {
        assertTrue(adapter.isConsolidated(artist, wallet));
        assertTrue(adapter.isConsolidated(wallet, artist));
        _delegate(artist, wallet2, FAR);
        assertFalse(adapter.isConsolidated(artist, wallet2), "one way");
        _delegate(wallet2, artist, FAR);
        assertTrue(adapter.isConsolidated(artist, wallet2), "no minimum age");
        assertFalse(adapter.isConsolidated(artist, artist), "a wallet with itself");
    }

    function test_RevocationAndExpiryEndIt() public {
        _revoke(artist, wallet);
        assertFalse(adapter.isConsolidated(artist, wallet));
        _delegate(artist, wallet, block.timestamp + 10);
        assertTrue(adapter.isConsolidated(artist, wallet));
        vm.warp(block.timestamp + 10);
        assertFalse(adapter.isConsolidated(artist, wallet));
    }

    /// @dev At most `MAX_REGISTRATIONS_READ` registrations are read per direction: a live one
    ///      within the bound counts, and one after that many lapsed ones does not.
    function test_ReadsAtMostTheBoundOfRegistrations() public {
        _delegate(wallet2, artist, FAR);
        uint256 bound = adapter.MAX_REGISTRATIONS_READ();
        for (uint256 i = 1; i < bound; ++i) {
            _delegate(artist, wallet2, block.timestamp); // expires at once
        }
        _delegate(artist, wallet2, FAR); // the last one read
        assertTrue(adapter.isConsolidated(artist, wallet2), "within the bound");

        _revoke(artist, wallet2);
        for (uint256 i; i < bound; ++i) {
            _delegate(artist, wallet2, block.timestamp);
        }
        _delegate(artist, wallet2, FAR); // past the bound
        assertFalse(adapter.isConsolidated(artist, wallet2), "past the bound");
    }

    function test_SpecificCollectionDoesNotCount() public {
        address collection = makeAddr("collection");
        vm.prank(artist);
        delegation.registerDelegationAddress(collection, wallet2, FAR, CONSOLIDATION, true, 0);
        vm.prank(wallet2);
        delegation.registerDelegationAddress(collection, artist, FAR, CONSOLIDATION, true, 0);
        assertFalse(adapter.isConsolidated(artist, wallet2));
    }

    function test_ADelegationWithoutCodeAnswersNo() public {
        vm.etch(address(delegation), hex"60006000fd");
        assertFalse(adapter.isConsolidated(artist, wallet));
    }

    function test_SupportsInterfaceAndConstructor() public {
        assertTrue(adapter.supportsInterface(type(IConsolidationSource).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
        assertFalse(adapter.supportsInterface(0xffffffff));
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, stranger));
        new ConsolidationAdapter(IDelegationManagement(stranger));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";
import { StreamTerms } from "src/terms/StreamTerms.sol";
import { IndSale, IndependentStreamFixture } from "../independent/IndependentStreamFixture.sol";

/// @notice `StreamTerms` pairs an Independent Stream token with its editions through the
///         Independent Stream module, without a network call per pair (review C L-4): a master's
///         rate change reaches its edition.
contract StreamTermsFixesTest is IndependentStreamFixture {
    StreamTerms internal streamTerms;
    IndSale internal editionSale;

    function setUp() public override {
        super.setUp();
        streamTerms = new StreamTerms(
            address(manager),
            address(ledger),
            address(stream),
            address(editions),
            address(indDirectory)
        );
        indDirectory.setModuleDelay(0);
        indDirectory.proposeModule(Slots.INDEPENDENT_TERMS, address(streamTerms));
        indDirectory.activateModule(Slots.INDEPENDENT_TERMS);
        editionSale = new IndSale();
        registry.setAdapter(address(editionSale), IIndependentStreamRegistry.Form.ERC1155, true);
    }

    function test_IndependentPair_IsKnownWithoutAPairingCall() public view {
        assertEq(streamTerms.editionsOf(address(fStream)), address(fEditions));
        assertEq(streamTerms.tokenOfEditions(address(fEditions)), address(fStream));
        assertEq(streamTerms.editionsOf(address(fEditions)), address(0));
        assertEq(streamTerms.tokenOfEditions(address(fStream)), address(0));
        // 6529 Stream keeps its own pairing.
        assertEq(streamTerms.editionsOf(address(stream)), address(editions));
    }

    function test_IndependentPair_AMastersRateChangeReachesItsEdition() public {
        uint256 id = _fedMint(1);
        editionSale.createEdition(address(fEditions), id, 0, address(0xFEE), RATE);
        vm.prank(address(records)); // the Independent Stream RECORDS module
        streamTerms.setRoyaltyRate(address(fStream), id, 7_000);
        assertEq(fStream.workOf(id).royaltyRate, 7_000);
        assertEq(fEditions.editionOf(id).royaltyRate, 7_000);
    }
}

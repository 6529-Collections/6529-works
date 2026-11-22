// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { StreamTerms } from "src/terms/StreamTerms.sol";
import { FedSale, FederationFixture } from "../federated/FederationFixture.sol";

/// @notice `StreamTerms` pairs a federated token with its editions through the federation
///         module, without a network call per pair (review C L-4): a master's rate change reaches
///         its edition.
contract StreamTermsFixesTest is FederationFixture {
    StreamTerms internal streamTerms;
    FedSale internal editionSale;

    function setUp() public override {
        super.setUp();
        streamTerms = new StreamTerms(
            address(manager),
            address(ledger),
            address(stream),
            address(editions),
            address(fedDirectory)
        );
        fedDirectory.setModuleDelay(0);
        fedDirectory.proposeModule(Slots.FEDERATED_TERMS, address(streamTerms));
        fedDirectory.activateModule(Slots.FEDERATED_TERMS);
        editionSale = new FedSale();
        registry.setAdapter(address(editionSale), IFederationRegistry.Form.ERC1155, true);
    }

    function test_FederatedPair_IsKnownWithoutAPairingCall() public view {
        assertEq(streamTerms.editionsOf(address(fStream)), address(fEditions));
        assertEq(streamTerms.tokenOfEditions(address(fEditions)), address(fStream));
        assertEq(streamTerms.editionsOf(address(fEditions)), address(0));
        assertEq(streamTerms.tokenOfEditions(address(fStream)), address(0));
        // 6529 Stream keeps its own pairing.
        assertEq(streamTerms.editionsOf(address(stream)), address(editions));
    }

    function test_FederatedPair_AMastersRateChangeReachesItsEdition() public {
        uint256 id = _fedMint(1);
        editionSale.createEdition(address(fEditions), id, 0, address(0xFEE), RATE);
        vm.prank(address(records)); // the federated RECORDS module
        streamTerms.setRoyaltyRate(address(fStream), id, 7_000);
        assertEq(fStream.workOf(id).royaltyRate, 7_000);
        assertEq(fEditions.editionOf(id).royaltyRate, 7_000);
    }
}

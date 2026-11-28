// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";
import { StreamTerms } from "src/terms/StreamTerms.sol";
import { IndSale, IndependentStreamFixture } from "../independent/IndependentStreamFixture.sol";

/// @dev An Independent Stream module that lists whatever pair it is told, true or not.
contract LyingGate {
    mapping(address token => IIndependentStreamRegistry.Entry) internal _entries;

    function list(address token, IIndependentStreamRegistry.Form form, address partner) external {
        _entries[token].form = form;
        _entries[token].partner = partner;
    }

    function entry(address token) external view returns (IIndependentStreamRegistry.Entry memory) {
        return _entries[token];
    }
}

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

    /// @dev A partner counts only if the editions contract names the token as its `stream()`:
    ///      an Independent Stream module that lists 6529 Stream Editions as another token's
    ///      partner gives that token's RECORDS module no reach into 6529 Stream Editions.
    function test_IndependentPair_AListedPartnerThatNamesAnotherTokenIsNotAPair() public {
        uint256 id = _fedMint(1);
        LyingGate gate = new LyingGate();
        indDirectory.proposeModule(Slots.INDEPENDENT_STREAM, address(gate));
        indDirectory.activateModule(Slots.INDEPENDENT_STREAM);

        gate.list(address(fStream), IIndependentStreamRegistry.Form.ERC721, address(editions));
        assertEq(streamTerms.editionsOf(address(fStream)), address(0), "another token's editions");
        // The rate change stays on the token: no call reaches 6529 Stream Editions.
        vm.expectCall(address(editions), abi.encodeWithSelector(editions.setRoyalty.selector), 0);
        vm.prank(address(records));
        streamTerms.setRoyaltyRate(address(fStream), id, 7_000);
        assertEq(fStream.workOf(id).royaltyRate, 7_000);

        // The mirror: an editions contract listed with a token it does not name.
        gate.list(address(fEditions), IIndependentStreamRegistry.Form.ERC1155, address(stream));
        assertEq(streamTerms.tokenOfEditions(address(fEditions)), address(0), "not its token");

        // A true pair is still known both ways.
        gate.list(address(fStream), IIndependentStreamRegistry.Form.ERC721, address(fEditions));
        gate.list(address(fEditions), IIndependentStreamRegistry.Form.ERC1155, address(fStream));
        assertEq(streamTerms.editionsOf(address(fStream)), address(fEditions));
        assertEq(streamTerms.tokenOfEditions(address(fEditions)), address(fStream));
    }

    /// @dev Only a listing of form ERC1155 names the token an editions contract belongs to.
    function test_IndependentPair_OnlyAnErc1155ListingNamesTheTokenOfEditions() public {
        LyingGate gate = new LyingGate();
        indDirectory.proposeModule(Slots.INDEPENDENT_STREAM, address(gate));
        indDirectory.activateModule(Slots.INDEPENDENT_STREAM);
        gate.list(address(fEditions), IIndependentStreamRegistry.Form.PAIR, address(fStream));
        assertEq(streamTerms.tokenOfEditions(address(fEditions)), address(0));
    }
}

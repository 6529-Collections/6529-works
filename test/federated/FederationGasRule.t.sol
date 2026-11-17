// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { FederationRegistry } from "src/federated/FederationRegistry.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { Burner, GasRuleAssertions } from "../helpers/GasRule.sol";
import { FederationBase } from "./FederationBase.sol";

/// @notice The gas rule for the federated templates (a deployed copy is permanent for its
///         artist): every call out is a plain call that forwards all the gas EIP-150 allows and
///         reverts the whole transaction on any failure. With a dependency burning 1x to 100x its
///         base, the outcome never changes; with too little gas, the call reverts and never
///         answers: neither a different success nor the template's own refusal.
contract FederationGasRuleTest is FederationBase, GasRuleAssertions {
    function setUp() public override {
        super.setUp();
        _joinedFed();
    }

    /// @dev Every gas limit below the least that reproduces the ample-gas outcome gives that
    ///      outcome or a revert that carries no answer: empty, or the split ledger's starved
    ///      CREATE2 (`_starvedWallet`); any other error fails, so a starved read reported as a
    ///      refusal of its own is caught.
    function _assertNeverAnswersShort(address from, address target, bytes memory data)
        internal
        returns (uint256 least)
    {
        Outcome memory full = _try(from, target, data, 0);
        uint256 low = 0;
        uint256 high = 30_000_000;
        while (low + 1 < high) {
            uint256 mid = (low + high) / 2;
            Outcome memory o = _try(from, target, data, mid);
            if (o.ok == full.ok && keccak256(o.data) == keccak256(full.data)) high = mid;
            else low = mid;
        }
        least = high;
        for (uint256 i = 1; i <= GAS_RULE_SAMPLES; ++i) {
            uint256 g = least - (least * i) / (GAS_RULE_SAMPLES + 1);
            Outcome memory o = _try(from, target, data, g);
            if (o.ok == full.ok && keccak256(o.data) == keccak256(full.data)) continue;
            // Never a different success, and never any refusal but those a shortfall makes: the
            // caller's own out-of-gas (empty, which a template's plain call passes on), or the
            // split ledger's starved CREATE2 (`WalletAddressMismatch` with nothing deployed). A
            // starved read is never reported as an answer, a template refusal included.
            assertFalse(o.ok, string.concat("an answer at gas ", vm.toString(g)));
            assertTrue(
                o.data.length == 0 || _starvedWallet(o.data),
                string.concat("a refusal at gas ", vm.toString(g), ": ", vm.toString(o.data))
            );
        }
    }

    /// @dev The split ledger's CREATE2 run out of gas: `WalletAddressMismatch(predicted, 0)`.
    function _starvedWallet(bytes memory data) internal pure returns (bool) {
        if (data.length != 68 || bytes4(data) != ISplitFactory.WalletAddressMismatch.selector) {
            return false;
        }
        uint256 deployed;
        assembly ("memory-safe") {
            deployed := mload(add(data, 68))
        }
        return deployed == 0;
    }

    function test_GasRule_MintReadsTheRegistryWithAllGas() public {
        Burner burner = new Burner(address(fedRegistry), 10_000);
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(artists.setFederationRegistry, (address(fedRegistry), address(burner)))
        );
        Work memory w = _fedWork(fedArtist);
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(w), RATE);
        bytes memory start = abi.encodeCall(auction.start, (address(fed), _mintData(w)));
        Outcome memory o =
            _assertSameAtEveryMultiple(burner, address(this), address(auction), start);
        assertTrue(o.ok, "the start succeeds at every multiple");
        burner.burnerSetMultiple(10);
        _assertNeverAnswersShort(address(this), address(auction), start);
    }

    function test_GasRule_MintReadsTheContentStoreWithAllGas() public {
        Burner burner = new Burner(address(store), 10_000);
        IFederatedStream.Config memory c = _streamConfig(fedArtist);
        c.contentStore = address(burner);
        FederatedStream other = _deployStream(c);
        // The registry lists only a copy naming its canonical store, so this one joins through
        // a replacement registry whose canonical store is the burner.
        _join(
            address(other),
            fedArtist,
            abi.encodeWithSelector(IFederationRegistry.NotListable.selector, address(other))
        );
        FederationRegistry next = new FederationRegistry(
            address(manager), address(artists), address(economics), address(burner)
        );
        _mapRegistryRoles(address(next));
        _approveTemplates(next);
        _govern(hotAdmin, address(next), abi.encodeCall(next.setAdapter, (address(auction), true)));
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(artists.setFederationRegistry, (address(fedRegistry), address(next)))
        );
        _join(address(other), fedArtist);
        Work memory w = _fedWork(fedArtist);
        vm.prank(fedArtist);
        other.approveItem(_itemHash(w), RATE);
        bytes memory start = abi.encodeCall(auction.start, (address(other), _mintData(w)));
        Outcome memory o =
            _assertSameAtEveryMultiple(burner, address(this), address(auction), start);
        assertTrue(o.ok);
        burner.burnerSetMultiple(4);
        _assertNeverAnswersShort(address(this), address(auction), start);
    }

    function test_GasRule_TokenUriReadsTheRendererWithAllGas() public {
        (, uint256 tokenId) = _startFed(_fedWork(fedArtist));
        Burner burner = new Burner(address(renderer), 50_000);
        vm.prank(fedArtist);
        fed.setDefaultRenderer(address(renderer), address(burner), address(burner).codehash);
        bytes memory call = abi.encodeCall(fed.tokenURI, (tokenId));
        Outcome memory o = _assertSameAtEveryMultiple(burner, address(this), address(fed), call);
        assertTrue(o.ok, "metadata at every multiple");
        burner.burnerSetMultiple(2);
        _assertNeverAnswersShort(address(this), address(fed), call);
    }

    function test_GasRule_ArtistActionsReadTheArtistRegistryWithAllGas() public {
        Burner burner = new Burner(address(artists), 10_000);
        IFederatedStream.Config memory c = _streamConfig(fedArtist);
        c.artistRegistry = address(burner);
        FederatedStream other = _deployStream(c);
        bytes memory call = abi.encodeCall(other.approveItem, (keccak256("item"), RATE));
        Outcome memory o = _assertSameAtEveryMultiple(burner, fedArtist, address(other), call);
        assertTrue(o.ok, "the artist acts at every multiple");
        burner.burnerSetMultiple(10);
        _assertNeverAnswersShort(fedArtist, address(other), call);
    }
}

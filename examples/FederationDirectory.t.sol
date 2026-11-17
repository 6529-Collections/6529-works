// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Example: read the federation directory, a federated contract's listing and its network share.
//
// An artist may deploy their own 6529 Stream-compatible contracts from the network's approved
// templates and join the federation. The directory lives in the artist registry (one entry per
// token contract: its artist and status) and the federation registry (the full entry the sale
// adapters read). There is no on-chain list of every federated contract: discover them from
// the artist registry's FederatedContractListed events, then read each one.

import { Vm } from "forge-std/Vm.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IFederatedToken } from "src/interfaces/IFederatedToken.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { FederationBase } from "test/federated/FederationBase.sol";

contract ExampleFederationDirectory is FederationBase {
    function test_ReadTheDirectory() public {
        // An artist deploys a linked pair (a 1/1 contract and its editions) and joins both.
        vm.recordLogs();
        _pair(fedArtist);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // 1. Discover: every FederatedContractListed the artist registry emitted.
        address[] memory found = new address[](logs.length);
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(artists)
                    && logs[i].topics[0] == IArtistRegistry.FederatedContractListed.selector
            ) found[n++] = address(uint160(uint256(logs[i].topics[2])));
        }
        assertEq(n, 2, "both halves of the pair are listed");

        for (uint256 i; i < n; ++i) {
            address token = found[i];

            // 2. The artist registry's entry: whose contract it is, and its status. DELISTED
            //    also covers an account the network delisted as a whole.
            (uint256 artistId, IArtistRegistry.FederationStatus status) =
                artists.federatedListing(token);
            assertEq(artistId, artists.artistIdOf(fedArtist));
            assertEq(uint8(status), uint8(IArtistRegistry.FederationStatus.ACTIVE));

            // 3. The federation registry's entry, as the sale adapters read it: form, partner,
            //    template version and code hash, the network share in force, and the status.
            IFederationRegistry.Entry memory e = fedRegistry.entry(token);
            assertEq(e.artistId, artistId);
            assertEq(e.codeHash, token.codehash, "runs an approved template's code");
            assertTrue(fedRegistry.isActive(token));
            // Whether a given sale adapter may mint and sell it now.
            assertTrue(
                fedRegistry.canMint(token, address(auction))
                    || e.form == IFederationRegistry.Form.ERC1155
            );

            // 4. The network's share: the token fixed one at deployment; the network can only
            //    lower it later in the artist registry. The share in force is the smaller.
            (,,, uint32 deployedShare, address feeRecipient, address partner) =
                IFederatedToken(token).federationTerms();
            uint32 recorded = artists.federatedFeeShare(token);
            uint32 inForce = recorded < deployedShare ? recorded : deployedShare;
            assertEq(e.feeShare, inForce);
            assertEq(feeRecipient, networkFee, "the network fee recipient locked in the token");
            assertEq(e.partner, partner, "the other half of the pair");

            // 5. Joining is for good: there is no way to leave the federation.
            assertTrue(IFederatedToken(token).federationState());
        }
    }
}

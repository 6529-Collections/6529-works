// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FederatedStream } from "src/federated/FederatedStream.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederatedToken } from "src/interfaces/IFederatedToken.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { FederationBase } from "./FederationBase.sol";

/// @notice The terms every federated template locks at deployment (`FederatedMembership`), each
///         bound checked at its edge, on the stream template constructed directly.
contract FederatedMembershipConfigTest is FederationBase {
    function _refused(IFederatedStream.Config memory c, bytes memory reason) internal {
        vm.expectRevert(reason);
        new FederatedStream(c);
    }

    function test_Constructor_TheArtistIdIsANonzeroAddress() public {
        bytes memory invalid = abi.encodeWithSelector(IFederatedToken.InvalidConfig.selector);
        IFederatedStream.Config memory c = _streamConfig(fedArtist);
        c.artistId = 0;
        _refused(c, invalid);
        c.artistId = uint256(type(uint160).max) + 1;
        _refused(c, invalid);
        c.artistId = type(uint160).max;
        new FederatedStream(c);
        c.artistId = 1;
        new FederatedStream(c);
    }

    function test_Constructor_TheFeeShareIsBelowTheDenominatorWithARecipient() public {
        bytes memory invalid = abi.encodeWithSelector(IFederatedToken.InvalidConfig.selector);
        IFederatedStream.Config memory c = _streamConfig(fedArtist);
        c.feeShare = 100_000;
        _refused(c, invalid);
        c.feeShare = 100_001;
        _refused(c, invalid);
        c.feeShare = 99_999;
        new FederatedStream(c);
        c.feeShare = 1;
        c.feeRecipient = address(0);
        _refused(c, invalid);
        c.feeShare = 0;
        new FederatedStream(c);
    }

    function test_Constructor_TheRegistryAndLedgerHaveCode() public {
        address eoa = makeAddr("noCode");
        IFederatedStream.Config memory c = _streamConfig(fedArtist);
        c.artistRegistry = eoa;
        _refused(c, abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        c = _streamConfig(fedArtist);
        c.splitLedger = eoa;
        _refused(c, abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
    }
}

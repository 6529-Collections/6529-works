// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";

/// @notice The revert data of the shared signature checks, for `vm.expectRevert`.
library SignatureReverts {
    /// @notice `SignatureVerifier.InvalidSignature(signer)`.
    function invalid(address signer) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, signer);
    }

    /// @notice `SignatureVerifier.SignatureExpired(deadline)`.
    function expired(uint256 deadline) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(SignatureVerifier.SignatureExpired.selector, deadline);
    }
}

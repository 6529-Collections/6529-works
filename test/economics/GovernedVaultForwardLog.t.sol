// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IGovernedVault } from "src/economics/interfaces/IGovernedVault.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

/// @dev Accepts any `safeTransferFrom` and moves nothing.
contract NoOpToken {
    function safeTransferFrom(address, address, uint256) external { }
}

/// @notice `GovernedVault.forwardERC721` is permissionless and emits `TokenForwarded` before it
///         calls the token. The token address is the caller's: a contract that accepts the call
///         without moving anything yields a `TokenForwarded` log from the vault for a token it
///         never held. Nothing in the vault changes; an indexer must key the log on the token
///         address and confirm the token's own `Transfer`.
contract GovernedVaultForwardLogTest is EconomicsBase {
    function test_ForwardERC721_AnyoneCanLogAForwardOfATokenTheVaultNeverHeld() public {
        NoOpToken fake = new NoOpToken();
        vm.expectEmit(address(feeVault));
        emit IGovernedVault.TokenForwarded(address(fake), 42, feeSafe, 1);
        vm.prank(makeAddr("anyone"));
        feeVault.forwardERC721(address(fake), 42);
    }
}

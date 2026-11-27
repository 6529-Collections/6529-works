// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { console2 } from "forge-std/console2.sol";
import { Script } from "forge-std/Script.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { CheckReplacement } from "./CheckReplacement.sol";

/// @title CheckReplacementScript
/// @notice Compares a candidate accounts module, a candidate mint policy, or both, with the
///         ones in force, read-only, before the network announces the replacement
///         (`CheckReplacement`). It sends no transaction and reverts on the first difference.
/// @dev `forge script script/CheckReplacement.s.sol --rpc-url <rpc>` with, for the accounts
///      module, `LIVE_ACCOUNTS`, `NEXT_ACCOUNTS`, `ACCOUNT_IDS` (comma-separated artist IDs) and
///      optionally `WALLETS` (comma-separated addresses: former roots, consolidated wallets,
///      addresses that must have no power); for the mint policy, `LIVE_POLICY`, `NEXT_POLICY`
///      and `ROOTS` (comma-separated package roots). A pair that is not set is skipped.
contract CheckReplacementScript is Script {
    /// @notice Neither pair of modules was given: nothing was checked.
    error NothingToCheck();
    /// @notice A pair of modules was given with an empty list.
    error EmptyList(string name);

    function run() external view {
        address liveAccounts = vm.envOr("LIVE_ACCOUNTS", address(0));
        address livePolicy = vm.envOr("LIVE_POLICY", address(0));
        if (liveAccounts == address(0) && livePolicy == address(0)) revert NothingToCheck();
        if (liveAccounts != address(0)) {
            uint256[] memory ids = vm.envOr("ACCOUNT_IDS", ",", new uint256[](0));
            address[] memory wallets = vm.envOr("WALLETS", ",", new address[](0));
            if (ids.length == 0) revert EmptyList("ACCOUNT_IDS");
            CheckReplacement.accounts(
                IArtistRegistry(liveAccounts),
                IArtistRegistry(vm.envAddress("NEXT_ACCOUNTS")),
                ids,
                wallets
            );
            console2.log("accounts answered alike:", ids.length);
            console2.log("addresses answered alike:", wallets.length);
        }
        if (livePolicy != address(0)) {
            bytes32[] memory roots = vm.envOr("ROOTS", ",", new bytes32[](0));
            if (roots.length == 0) revert EmptyList("ROOTS");
            uint256 revoked = CheckReplacement.mintPolicy(
                IPackageRegistry(livePolicy), IPackageRegistry(vm.envAddress("NEXT_POLICY")), roots
            );
            console2.log("roots compared:", roots.length);
            console2.log("revoked in force and refused by the candidate:", revoked);
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { DelegatedEOA } from "src/libraries/DelegatedEOA.sol";
import { DeployV1 } from "./DeployV1.sol";

/// @title DeployGuards
/// @notice The off-anvil checks `Deploy.s.sol` runs before anything is broadcast and
///         `Verify.s.sol` repeats against the chain. Each one exists because the configurator
///         renounces ADMIN in the genesis transaction: after that, nothing the genesis got wrong
///         can be fixed except through the governance it installed.
/// @dev Pure functions of their inputs (the genesis JSON, the committed example JSON, the
///      deployment), so the tests drive them directly.
library DeployGuards {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Holder addresses at or below this are placeholders (the example's `0x…b0xx`) or
    ///         precompiles, never a Safe or a key.
    uint160 internal constant MAX_PLACEHOLDER = 0xFFFF;
    /// @notice Off anvil, at least three guardian Safes (`GovernanceConfig` alone requires two).
    uint256 internal constant MIN_GUARDIANS = 3;
    /// @notice Off anvil, at least two curation signer keys.
    uint256 internal constant MIN_CURATION_SIGNERS = 2;
    /// @notice The 6529 delegation contract on Ethereum mainnet.
    address internal constant CANONICAL_DELEGATION = 0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d;
    /// @notice Foundry's and the scripts' CREATE2 deployer.
    address internal constant CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 internal constant MAINNET_CHAIN_ID = 1;

    /// @notice The genesis file is the committed example, whose holders are all placeholders.
    error ExampleGenesisOffAnvil();
    error PlaceholderHolder(string role, address account);
    /// @notice A holder is a system contract, a precompile-range address, the CREATE2 deployer,
    ///         Permit2 or the delegation contract: no key can act for it.
    error ForbiddenHolder(string role, address account);
    /// @notice An ADMIN or GUARDIAN holder is not a deployed Safe: no code, an EIP-7702
    ///         delegated EOA, or no nonzero `getThreshold()`.
    error HolderNotASafe(string role, address account);
    error TooFewGuardians(uint256 count);
    error TooFewCurationSigners(uint256 count);
    /// @notice A holder is a contract of this deployment or one of its dependencies.
    error HolderIsADeploymentContract(uint64 role, address account);
    /// @notice The genesis file's governed targets or wiring differ from what the committed
    ///         `config/genesis.example.json` produces for the same deployment.
    error PolicyMismatch(string what);
    /// @notice The genesis names something this deployment does not have.
    error DroppedFromGenesis(string what);

    // ------------------------------------------------------------------ the genesis file

    /// @notice Off-anvil checks of the genesis file alone: not the example itself, and every
    ///         holder reachable (M-1). ADMIN and GUARDIAN holders must be deployed Safes (code,
    ///         not an EIP-7702 delegated EOA, a nonzero `getThreshold()`); no holder may be a
    ///         placeholder or a system address; at least `MIN_GUARDIANS` guardians and
    ///         `MIN_CURATION_SIGNERS` curation signers. `GovernanceConfig` rejects duplicate
    ///         grants, so the counts are of distinct accounts.
    function checkHolders(string memory json, string memory example) internal view {
        if (keccak256(bytes(json)) == keccak256(bytes(example))) revert ExampleGenesisOffAnvil();
        uint256 guardians;
        uint256 signers;
        for (uint256 i; vm.keyExistsJson(json, _holder(i, "")); ++i) {
            string memory role = vm.parseJsonString(json, _holder(i, ".role"));
            address account = vm.parseJsonAddress(json, _holder(i, ".account"));
            if (uint160(account) <= MAX_PLACEHOLDER) revert PlaceholderHolder(role, account);
            if (isSystemAddress(account)) revert ForbiddenHolder(role, account);
            bytes32 r = keccak256(bytes(role));
            if (r == keccak256("ADMIN") || r == keccak256("GUARDIAN")) requireSafe(role, account);
            if (r == keccak256("GUARDIAN")) ++guardians;
            if (r == keccak256("CURATION_SIGNER")) ++signers;
        }
        if (guardians < MIN_GUARDIANS) revert TooFewGuardians(guardians);
        if (signers < MIN_CURATION_SIGNERS) revert TooFewCurationSigners(signers);
    }

    /// @notice Reverts unless `account` looks like a deployed Safe: code that is not an EIP-7702
    ///         delegation, and `getThreshold()` returning one nonzero word.
    function requireSafe(string memory role, address account) internal view {
        if (account.code.length == 0 || DelegatedEOA.isDelegated(account)) {
            revert HolderNotASafe(role, account);
        }
        (bool ok, bytes memory ret) = account.staticcall(abi.encodeWithSignature("getThreshold()"));
        if (!ok || ret.length != 32 || abi.decode(ret, (uint256)) == 0) {
            revert HolderNotASafe(role, account);
        }
    }

    /// @notice Addresses no key controls that a typo could still name: the system contracts
    ///         (EIP-4788 beacon roots, EIP-2935 block hashes, EIP-7002 withdrawals, EIP-7251
    ///         consolidations, the deposit contract), the CREATE2 deployer, Permit2 and the 6529
    ///         delegation contract. The precompile range is `MAX_PLACEHOLDER`.
    function isSystemAddress(address account) internal pure returns (bool) {
        return account == 0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02
            || account == 0x0000F90827F1C53a10cb7A02335B175320002935
            || account == 0x00000961Ef480Eb55e80D19ad83579A64c007002
            || account == 0x0000BBdDc7CE488642fb579F8B00f3a590007251
            || account == 0x00000000219ab540356cBB839Cbe05303d7705Fa || account == CREATE2_FACTORY
            || account == DeployV1.CANONICAL_PERMIT2 || account == CANONICAL_DELEGATION;
    }

    // ------------------------------------------------------------------ against the deployment

    /// @notice No holder is a contract of `d` or a dependency it was deployed with (M-1).
    function checkHoldersAgainst(
        DeployV1.Deployment memory d,
        DeployV1.Params memory p,
        GovernanceConfig.Config memory cfg
    ) internal pure {
        string[] memory names = DeployV1.names();
        for (uint256 i; i < cfg.grants.length; ++i) {
            address account = cfg.grants[i].account;
            bool forbidden =
                account == p.delegation || account == p.permit2 || account == p.vrfCoordinator;
            for (uint256 j; j < names.length && !forbidden; ++j) {
                forbidden = account == DeployV1.addressOf(d, names[j]);
            }
            if (forbidden) revert HolderIsADeploymentContract(cfg.grants[i].role, account);
        }
    }

    /// @notice The genesis file's policy is the committed one (M-2): for the same deployment and
    ///         manifest, its governed targets (every selector, role and target) and its wiring
    ///         equal what `example` (config/genesis.example.json) produces. Only the holders, and
    ///         addresses that `DeployV1` substitutes by name, may differ.
    function checkPolicy(
        DeployV1.Deployment memory d,
        string memory json,
        string memory example,
        DeployV1.Manifest memory manifest
    ) internal view {
        GovernanceConfig.Config memory cfg = DeployV1.config(d, json);
        GovernanceConfig.Config memory pinned = DeployV1.config(d, example);
        if (keccak256(abi.encode(cfg.targets)) != keccak256(abi.encode(pinned.targets))) {
            revert PolicyMismatch("targets");
        }
        if (
            keccak256(abi.encode(DeployV1.wiring(d, json, manifest)))
                != keccak256(abi.encode(DeployV1.wiring(d, example, manifest)))
        ) revert PolicyMismatch("wiring");
    }

    /// @notice Nothing the genesis names is silently left out (M-4): every governed contract
    ///         and every wiring call applies, except the entropy module when it was declined
    ///         (`noVrf`, recorded as `"entropy": "none"`).
    function checkNothingDropped(DeployV1.Deployment memory d, string memory json, bool noVrf)
        internal
        view
    {
        string[] memory gone = DeployV1.dropped(d, json);
        for (uint256 i; i < gone.length; ++i) {
            if (!(noVrf && keccak256(bytes(gone[i])) == keccak256("EntropyModule"))) {
                revert DroppedFromGenesis(gone[i]);
            }
        }
    }

    function _holder(uint256 i, string memory field) private pure returns (string memory) {
        return string.concat(".holders[", vm.toString(i), "]", field);
    }
}

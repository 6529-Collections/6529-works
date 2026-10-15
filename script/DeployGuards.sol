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
    /// @notice Off anvil, at least two admin Safes: the hot admin and the cold recovery admin.
    uint256 internal constant MIN_ADMINS = 2;
    /// @notice Off anvil, at least three guardian Safes (`GovernanceConfig` alone requires two).
    uint256 internal constant MIN_GUARDIANS = 3;
    /// @notice Off anvil, at least two curation signer keys.
    uint256 internal constant MIN_CURATION_SIGNERS = 2;
    /// @notice Off anvil, every admin and guardian Safe needs at least two signatures.
    uint256 internal constant MIN_THRESHOLD = 2;
    /// @notice A Safe's transaction guard slot (`GuardManager`:
    ///         `keccak256("guard_manager.guard.address")`).
    bytes32 internal constant SAFE_GUARD_SLOT =
        0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;
    /// @notice The start (and end) of a Safe's module list (`ModuleManager.SENTINEL_MODULES`).
    address internal constant SAFE_SENTINEL = address(1);
    /// @notice The canonical Safe singletons a holder's proxy may point to (storage slot 0), from
    ///         safe-global/safe-deployments. Runtime code hashes read on mainnet and Sepolia on
    ///         15 October 2026 (identical on both). Safe 1.3.0, L1 and L2, at the canonical and
    ///         the EIP-155 deployment addresses (same code):
    address internal constant SAFE_130_L1 = 0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552;
    address internal constant SAFE_130_L1_EIP155 = 0x69f4D1788e39c87893C980c06EdF4b7f686e2938;
    address internal constant SAFE_130_L2 = 0x3E5c63644E683549055b9Be8653de26E0B4CD36E;
    address internal constant SAFE_130_L2_EIP155 = 0xfb1bffC9d739B8D520DaF37dF666da4C687191EA;
    bytes32 internal constant SAFE_130_L1_CODEHASH =
        0xbba688fbdb21ad2bb58bc320638b43d94e7d100f6f3ebaab0a4e4de6304b1c2e;
    bytes32 internal constant SAFE_130_L2_CODEHASH =
        0x21842597390c4c6e3c1239e434a682b054bd9548eee5e9b1d6a4482731023c0f;
    /// @notice ...and Safe 1.4.1, L1 and L2.
    address internal constant SAFE_141_L1 = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address internal constant SAFE_141_L2 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    bytes32 internal constant SAFE_141_L1_CODEHASH =
        0x1fe2df852ba3299d6534ef416eefa406e56ced995bca886ab7a553e6d0c5e1c4;
    bytes32 internal constant SAFE_141_L2_CODEHASH =
        0xb1f926978a0f44a2c0ec8fe822418ae969bd8c3f18d61e5103100339894f81ff;
    /// @notice The 6529 delegation contract on Ethereum mainnet (`DelegationManagementContract`,
    ///         github.com/6529-Collections/nftdelegation).
    address internal constant CANONICAL_DELEGATION = 0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d;
    /// @notice Its runtime code hash (20,766 bytes). Read on 11 October 2026 from mainnet and from
    ///         the official Sepolia deployment, whose runtime code is byte-identical.
    bytes32 internal constant CANONICAL_DELEGATION_CODEHASH =
        0x28e32b740f699e25d2a1afac207a84e31197c0d4b87c1432c9c5c52c4c1e74e0;
    /// @notice The Chainlink VRF v2.5 coordinator on Ethereum mainnet (docs.chain.link, "VRF
    ///         v2.5 supported networks").
    address internal constant CANONICAL_VRF_COORDINATOR =
        0xD7f86b4b8Cae7D942340FF628F82735b7a20893a;
    /// @notice Its runtime code hash (24,094 bytes), read from mainnet on 14 October 2026.
    bytes32 internal constant CANONICAL_VRF_COORDINATOR_CODEHASH =
        0xbe4ae0321fb1c74c80eea0c14c9c7b28c69ce17df15222e27b1e934cc98f5f61;
    /// @notice The official 6529 delegation deployment on Sepolia (the nftdelegation README).
    address internal constant SEPOLIA_DELEGATION = 0x8f86c644f845A077999939C69Bc787662377d915;
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;
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
    ///         delegated EOA, no nonzero `getThreshold()`, or no `getOwners()`.
    error HolderNotASafe(string role, address account);
    error TooFewAdmins(uint256 count);
    error TooFewGuardians(uint256 count);
    /// @notice Two of the admin and guardian Safes share a signer: the cold admin must be able
    ///         to recover from a lost hot admin, the guardians must be able to veto the admins,
    ///         and each guardian must be independent of the others.
    error SharedSigner(address safe, address other, address signer);
    /// @notice An admin or guardian Safe needs fewer than `MIN_THRESHOLD` signatures.
    error ThresholdTooLow(string role, address safe, uint256 threshold);
    /// @notice An admin or guardian Safe's proxy does not point to a canonical Safe singleton
    ///         with its pinned code (`canonicalSafeSingletons`).
    error NotACanonicalSafe(string role, address safe, address singleton);
    /// @notice An admin or guardian Safe has an enabled module, which can act without the
    ///         owners' signatures.
    error SafeHasModules(string role, address safe, address module);
    /// @notice An admin or guardian Safe has a transaction guard, which can block its
    ///         transactions.
    error SafeHasGuard(string role, address safe, address guard);
    /// @notice An owner of an admin or guardian Safe has code (a nested Safe, another contract
    ///         or an EIP-7702 delegated EOA), so its signers cannot be compared.
    error NestedOwner(address safe, address owner);
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
    ///         holder reachable (M-1).
    ///         - ADMIN and GUARDIAN holders must be deployed Safes (code, not an EIP-7702
    ///           delegated EOA, a `getThreshold()` of at least `MIN_THRESHOLD`, a
    ///           `getOwners()` list of keys without code) whose proxy points to one of
    ///           `singletons` (a canonical Safe singleton, with its code hash), with no
    ///           enabled module and no transaction guard.
    ///         - No holder may be a placeholder or a system address.
    ///         - At least `MIN_ADMINS` admins (hot and cold), `MIN_GUARDIANS` guardians and
    ///           `MIN_CURATION_SIGNERS` curation signers. `GovernanceConfig` rejects duplicate
    ///           grants, so the counts are of distinct accounts.
    ///         - No signer is shared between any two of the admin and guardian Safes (owner
    ///           decisions 2 and 3).
    function checkHolders(
        string memory json,
        string memory example,
        address[] memory singletons,
        bytes32[] memory codehashes
    ) internal view {
        if (keccak256(bytes(json)) == keccak256(bytes(example))) {
            revert ExampleGenesisOffAnvil();
        }
        uint256 holders;
        while (vm.keyExistsJson(json, _holder(holders, ""))) ++holders;
        address[] memory admins = new address[](holders);
        address[] memory guardians = new address[](holders);
        uint256 nAdmins;
        uint256 nGuardians;
        uint256 signers;
        for (uint256 i; i < holders; ++i) {
            string memory role = vm.parseJsonString(json, _holder(i, ".role"));
            address account = vm.parseJsonAddress(json, _holder(i, ".account"));
            if (uint160(account) <= MAX_PLACEHOLDER) revert PlaceholderHolder(role, account);
            if (isSystemAddress(account)) revert ForbiddenHolder(role, account);
            bytes32 r = keccak256(bytes(role));
            if (r == keccak256("ADMIN") || r == keccak256("GUARDIAN")) {
                requireSafe(role, account);
                requireBareSafe(role, account, singletons, codehashes);
            }
            if (r == keccak256("ADMIN")) admins[nAdmins++] = account;
            if (r == keccak256("GUARDIAN")) guardians[nGuardians++] = account;
            if (r == keccak256("CURATION_SIGNER")) ++signers;
        }
        if (nAdmins < MIN_ADMINS) revert TooFewAdmins(nAdmins);
        if (nGuardians < MIN_GUARDIANS) revert TooFewGuardians(nGuardians);
        if (signers < MIN_CURATION_SIGNERS) revert TooFewCurationSigners(signers);
        _requireSeparateSigners(admins, nAdmins, guardians, nGuardians);
    }

    /// @dev The signers of every admin and guardian Safe are pairwise disjoint: admins with
    ///      admins, admins with guardians, and guardians with guardians.
    function _requireSeparateSigners(
        address[] memory admins,
        uint256 nAdmins,
        address[] memory guardians,
        uint256 nGuardians
    ) private view {
        uint256 n = nAdmins + nGuardians;
        for (uint256 i; i < n; ++i) {
            (string memory role, address safe) = _safeAt(admins, nAdmins, guardians, i);
            address[] memory mine = ownersOf(role, safe);
            for (uint256 j = i + 1; j < n; ++j) {
                (string memory otherRole, address other) = _safeAt(admins, nAdmins, guardians, j);
                _disjoint(safe, mine, other, ownersOf(otherRole, other));
            }
        }
    }

    function _safeAt(
        address[] memory admins,
        uint256 nAdmins,
        address[] memory guardians,
        uint256 i
    ) private pure returns (string memory role, address safe) {
        return i < nAdmins ? ("ADMIN", admins[i]) : ("GUARDIAN", guardians[i - nAdmins]);
    }

    function _disjoint(address a, address[] memory ownersA, address b, address[] memory ownersB)
        private
        pure
    {
        for (uint256 i; i < ownersA.length; ++i) {
            for (uint256 j; j < ownersB.length; ++j) {
                if (ownersA[i] == ownersB[j]) revert SharedSigner(a, b, ownersA[i]);
            }
        }
    }

    /// @notice A Safe's `getOwners()`; fails closed (`HolderNotASafe`) when it has none, and
    ///         refuses an owner with code (`NestedOwner`).
    function ownersOf(string memory role, address safe)
        internal
        view
        returns (address[] memory owners)
    {
        (bool ok, bytes memory ret) = safe.staticcall(abi.encodeWithSignature("getOwners()"));
        if (!ok || ret.length < 64) revert HolderNotASafe(role, safe);
        owners = abi.decode(ret, (address[]));
        if (owners.length == 0) revert HolderNotASafe(role, safe);
        for (uint256 i; i < owners.length; ++i) {
            if (owners[i].code.length != 0) revert NestedOwner(safe, owners[i]);
        }
    }

    /// @notice Reverts unless `account` looks like a deployed Safe: code that is not an EIP-7702
    ///         delegation, and `getThreshold()` returning one word of at least `MIN_THRESHOLD`.
    function requireSafe(string memory role, address account) internal view {
        if (account.code.length == 0 || DelegatedEOA.isDelegated(account)) {
            revert HolderNotASafe(role, account);
        }
        (bool ok, bytes memory ret) = account.staticcall(abi.encodeWithSignature("getThreshold()"));
        if (!ok || ret.length != 32) revert HolderNotASafe(role, account);
        uint256 threshold = abi.decode(ret, (uint256));
        if (threshold == 0) revert HolderNotASafe(role, account);
        if (threshold < MIN_THRESHOLD) revert ThresholdTooLow(role, account, threshold);
    }

    /// @notice Reverts unless the Safe `safe` runs a canonical singleton (`singletons`, with
    ///         the matching `codehashes`) and has no module and no guard: only its owners'
    ///         signatures can act for it.
    function requireBareSafe(
        string memory role,
        address safe,
        address[] memory singletons,
        bytes32[] memory codehashes
    ) internal view {
        address singleton = address(uint160(uint256(vm.load(safe, bytes32(0)))));
        bool canonical;
        for (uint256 i; i < singletons.length && !canonical; ++i) {
            canonical = singleton == singletons[i] && singleton.codehash == codehashes[i];
        }
        if (!canonical) revert NotACanonicalSafe(role, safe, singleton);
        (bool ok, bytes memory ret) = safe.staticcall(
            abi.encodeWithSignature("getModulesPaginated(address,uint256)", SAFE_SENTINEL, 1)
        );
        if (!ok || ret.length < 96) revert HolderNotASafe(role, safe);
        (address[] memory modules,) = abi.decode(ret, (address[], address));
        if (modules.length != 0) revert SafeHasModules(role, safe, modules[0]);
        address guard = address(uint160(uint256(vm.load(safe, SAFE_GUARD_SLOT))));
        if (guard != address(0)) revert SafeHasGuard(role, safe, guard);
    }

    /// @notice The canonical Safe singletons and their runtime code hashes.
    function canonicalSafeSingletons()
        internal
        pure
        returns (address[] memory singletons, bytes32[] memory codehashes)
    {
        singletons = new address[](6);
        codehashes = new bytes32[](6);
        (singletons[0], codehashes[0]) = (SAFE_130_L1, SAFE_130_L1_CODEHASH);
        (singletons[1], codehashes[1]) = (SAFE_130_L1_EIP155, SAFE_130_L1_CODEHASH);
        (singletons[2], codehashes[2]) = (SAFE_130_L2, SAFE_130_L2_CODEHASH);
        (singletons[3], codehashes[3]) = (SAFE_130_L2_EIP155, SAFE_130_L2_CODEHASH);
        (singletons[4], codehashes[4]) = (SAFE_141_L1, SAFE_141_L1_CODEHASH);
        (singletons[5], codehashes[5]) = (SAFE_141_L2, SAFE_141_L2_CODEHASH);
    }

    /// @notice Addresses no key controls that a typo could still name: the system contracts
    ///         (EIP-4788 beacon roots, EIP-2935 block hashes, EIP-7002 withdrawals, EIP-7251
    ///         consolidations, the deposit contract), the CREATE2 deployer, Permit2 and the 6529
    ///         delegation contract (mainnet and Sepolia). The precompile range is
    ///         `MAX_PLACEHOLDER`; the configured delegation contract, wherever it is, is checked
    ///         against the deployment (`checkHoldersAgainst`).
    function isSystemAddress(address account) internal pure returns (bool) {
        return account == 0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02
            || account == 0x0000F90827F1C53a10cb7A02335B175320002935
            || account == 0x00000961Ef480Eb55e80D19ad83579A64c007002
            || account == 0x0000BBdDc7CE488642fb579F8B00f3a590007251
            || account == 0x00000000219ab540356cBB839Cbe05303d7705Fa || account == CREATE2_FACTORY
            || account == DeployV1.CANONICAL_PERMIT2 || account == CANONICAL_DELEGATION
            || account == SEPOLIA_DELEGATION;
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

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { Script } from "forge-std/Script.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { DeployGuards } from "./DeployGuards.sol";
import { DeployCore } from "./DeployCore.sol";

/// @title ScriptIO
/// @notice What the deploy and verify scripts read from outside the EVM: environment
///         variables, files under ./config and ./deployments, the RPC's chain ID, the pinned
///         CC0 digest, the canonical Safe singletons and proxies and the official delegation
///         contract. Each read is one virtual function, so the tests run the scripts with
///         their own inputs instead of the process environment.
abstract contract ScriptIO is Script {
    /// @notice The committed genesis policy: the default on anvil, and the reference off anvil.
    string internal constant CORE_GENESIS = "config/genesis.core.example.json";
    /// @notice The CC0 1.0 Universal legal code every deployment stores.
    string internal constant CC0_FIXTURE = "test/fixtures/cc0-legalcode.txt";

    /// @notice The RPC endpoint reports a different chain than the script runs on.
    error ChainIdMismatch(uint256 evm, uint256 rpc);
    /// @notice A required environment variable is unset off anvil.
    error MissingParameter(string name);
    /// @notice The deployment record names a delegation contract that is not this chain's
    ///         official one.
    error DelegationMismatch(address recorded, address expected);
    /// @notice This chain's official delegation contract does not have the pinned code.
    error DelegationCodeMismatch(address delegation, bytes32 codehash);
    /// @notice The CC0 fixture is not the pinned legal code.
    error Cc0TextMismatch(bytes32 actual);

    /// @notice Reverts unless the RPC endpoint's `eth_chainId` is `block.chainid`.
    function checkChain() public {
        uint256 rpc = rpcChainId();
        if (rpc != block.chainid) revert ChainIdMismatch(block.chainid, rpc);
    }

    /// @notice `eth_chainId` from the RPC endpoint.
    function rpcChainId() public virtual returns (uint256 id) {
        bytes memory quantity = vm.rpc("eth_chainId", "[]");
        for (uint256 i; i < quantity.length; ++i) {
            id = (id << 8) | uint8(quantity[i]);
        }
    }

    /// @notice The canonical CC0 legal code digest that off-anvil runs require.
    function cc0Digest() public view virtual returns (bytes32) {
        return DeployCore.CC0_LEGALCODE_SHA256;
    }

    /// @notice The Safe singletons (with their runtime code hashes) that the off-anvil network
    ///         Safe may run: the canonical Safe 1.3.0 and 1.4.1 deployments.
    function safeSingletons()
        public
        view
        virtual
        returns (address[] memory singletons, bytes32[] memory codehashes)
    {
        return DeployGuards.canonicalSafeSingletons();
    }

    /// @notice The runtime code hashes the off-anvil network Safe's own code may have: the
    ///         Safe 1.3.0 and 1.4.1 proxies.
    function safeProxies() public view virtual returns (bytes32[] memory) {
        return DeployGuards.canonicalSafeProxies();
    }

    /// @notice The delegation contract this chain's deployments are built on, with its runtime
    ///         code hash: the official 6529 deployment on mainnet and on Sepolia (the same
    ///         code), or zero on a chain that has none (anvil, where the record names a mock).
    function canonicalDelegation() public view virtual returns (address account, bytes32 codehash) {
        if (block.chainid == DeployGuards.MAINNET_CHAIN_ID) {
            return (DeployGuards.CANONICAL_DELEGATION, DeployGuards.CANONICAL_DELEGATION_CODEHASH);
        }
        if (block.chainid == DeployGuards.SEPOLIA_CHAIN_ID) {
            return (DeployGuards.SEPOLIA_DELEGATION, DeployGuards.CANONICAL_DELEGATION_CODEHASH);
        }
    }

    /// @notice The delegation contract a deployment record may be read back against: on a
    ///         chain with an official deployment, that contract and no other, with its pinned
    ///         code; elsewhere, the one the record names.
    /// @param recorded The record's `delegation`.
    function checkedDelegation(address recorded) public view returns (address) {
        (address expected, bytes32 codehash) = canonicalDelegation();
        if (expected == address(0)) return recorded;
        if (recorded != expected) revert DelegationMismatch(recorded, expected);
        if (expected.codehash != codehash) {
            // The error carries the hash found on chain, not the pinned one.
            revert DelegationCodeMismatch(expected, expected.codehash);
        }
        return expected;
    }

    /// @dev An environment variable; unset and empty are the same.
    function _env(string memory name) internal view virtual returns (string memory) {
        return vm.envOr(name, string(""));
    }

    function _envString(string memory name, string memory byDefault)
        internal
        view
        returns (string memory value)
    {
        value = _env(name);
        if (bytes(value).length == 0) value = byDefault;
    }

    function _envAddress(string memory name, address byDefault) internal view returns (address) {
        string memory value = _env(name);
        return bytes(value).length == 0 ? byDefault : vm.parseAddress(value);
    }

    function _envUint(string memory name, uint256 byDefault) internal view returns (uint256) {
        string memory value = _env(name);
        return bytes(value).length == 0 ? byDefault : vm.parseUint(value);
    }

    function _envBytes32(string memory name, bytes32 byDefault) internal view returns (bytes32) {
        string memory value = _env(name);
        return bytes(value).length == 0 ? byDefault : vm.parseBytes32(value);
    }

    function _read(string memory path) internal view virtual returns (string memory) {
        return vm.readFile(path);
    }

    function _readBinary(string memory path) internal view virtual returns (bytes memory) {
        return vm.readFileBinary(path);
    }

    /// @notice The deployment parameters from the environment; placeholders only on anvil.
    /// @notice The epoch-0 governance manifest from the environment: `MANIFEST_PATH` (the file,
    ///         hashed with SHA-256) or `MANIFEST_DIGEST`, and `MANIFEST_URI`. The deploy appends
    ///         it and the verification expects it.
    function manifestFromEnv(bool local) public view returns (DeployCore.Manifest memory m) {
        m = DeployCore.Manifest(
            _envBytes32("MANIFEST_DIGEST", local ? keccak256("local manifest") : bytes32(0)),
            _envString("MANIFEST_URI", local ? "ar://local-manifest" : "")
        );
        string memory path = _envString("MANIFEST_PATH", "");
        if (bytes(path).length != 0) m.digest = sha256(_readBinary(path));
        if (m.digest == 0) revert MissingParameter("MANIFEST_DIGEST");
    }

    function params(bool local) public view returns (DeployCore.Params memory p) {
        p.deployer = msg.sender;
        p.namespace =
            _envBytes32("DEPLOY_NAMESPACE", local ? keccak256("6529-stream/core") : bytes32(0));
        if (p.namespace == 0) revert MissingParameter("DEPLOY_NAMESPACE");
        p.feeRecipient = _envAddress("NETWORK_FEE_RECIPIENT", local ? address(0xC001) : address(0));
        p.museum = _envAddress("MUSEUM", local ? address(0xC003) : address(0));
        p.marketOwner = _envAddress("MARKETPLACE_OWNER", local ? address(0xC002) : address(0));
        if (p.feeRecipient == address(0)) revert MissingParameter("NETWORK_FEE_RECIPIENT");
        if (p.museum == address(0)) revert MissingParameter("MUSEUM");
        if (p.marketOwner == address(0)) revert MissingParameter("MARKETPLACE_OWNER");
        p.delegation = block.chainid == DeployGuards.SEPOLIA_CHAIN_ID
            ? DeployGuards.SEPOLIA_DELEGATION
            : _envAddress("DELEGATION_CONTRACT", address(0));
        p.cc0Text = _readBinary(CC0_FIXTURE);
        if (sha256(p.cc0Text) != cc0Digest()) revert Cc0TextMismatch(sha256(p.cc0Text));
        p.ethIncrementFloor = 0.001 ether;
        // AUCTION_DURATION: a testnet round may shorten the 1/1 auction (at least 1 hour, the
        // auction's own minimum); every other genesis value is the launch default.
        p.auctionConfig = DeployCore.auctionConfig();
        uint256 duration = _envUint("AUCTION_DURATION", 0);
        if (duration != 0) {
            IEnglishAuction.AuctionConfig memory c =
                abi.decode(p.auctionConfig, (IEnglishAuction.AuctionConfig));
            c.duration = SafeCast.toUint32(duration);
            p.auctionConfig = abi.encode(c);
        }
        p.editionAuctionConfig = DeployCore.editionAuctionConfig();
        p.vrfCoordinator = _envAddress("VRF_COORDINATOR", address(0));
        if (p.vrfCoordinator != address(0)) {
            p.vrfCoordinatorCodeHash = p.vrfCoordinator.codehash;
            uint256 subscription = _envUint("VRF_SUBSCRIPTION_ID", 0);
            bytes32 keyHash = _envBytes32("VRF_KEY_HASH", bytes32(0));
            if (subscription == 0) revert MissingParameter("VRF_SUBSCRIPTION_ID");
            if (keyHash == 0) revert MissingParameter("VRF_KEY_HASH");
            uint256 nativePayment = _envUint("VRF_NATIVE_PAYMENT", 0);
            if (nativePayment > 1) revert MissingParameter("VRF_NATIVE_PAYMENT");
            p.vrf = VrfEntropyModule.VrfConfig(
                subscription,
                keyHash,
                SafeCast.toUint32(_envUint("VRF_CALLBACK_GAS_LIMIT", 200_000)),
                SafeCast.toUint16(_envUint("VRF_CONFIRMATIONS", 3)),
                nativePayment == 1
            );
            p.vrfRetryDelay = SafeCast.toUint64(_envUint("VRF_RETRY_DELAY", 3 days));
        }
    }
}

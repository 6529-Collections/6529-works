// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { DeployGuards } from "script/DeployGuards.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { Forks, WorksForkBase } from "./WorksForkBase.sol";

/// @dev The parts of Safe v1.4.1 these tests call, declared here so the repository takes no
///      dependency on the Safe contracts.
interface ISafe {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);

    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) external view returns (bytes32);

    function swapOwner(address prevOwner, address oldOwner, address newOwner) external;
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function domainSeparator() external view returns (bytes32);
    function nonce() external view returns (uint256);
    function VERSION() external view returns (string memory);
}

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface IMultiSendCallOnly {
    function multiSend(bytes memory transactions) external payable;
}

/// @notice The v1 system deployed by the deploy library on an Ethereum mainnet fork with real
///         Safe v1.4.1 wallets in the roles the network and institutions hold: the network
///         itself is a 2-of-3 Safe that accepts the network role by a Safe transaction, and the
///         network fee recipient's vault forwards to a second Safe. Concrete suites add Safes
///         as an artist's wallet, a bidder and a museum.
/// @dev Opt-in, like every fork suite: without `FORK_MAINNET_RPC` nothing is deployed and each
///      test skips (`onFork`). `FORK_MAINNET_RPC_BLOCK` pins the block. Safe v1.4.1's singleton,
///      proxy factory, `MultiSendCallOnly` and `CompatibilityFallbackHandler` are used at their
///      canonical addresses (github.com/safe-global/safe-deployments, v1.4.1). Every Safe
///      transaction is signed by owner keys this test holds and executed by an ordinary caller
///      (a relayer), so the Safe is `msg.sender` of every call it makes.
abstract contract SafeForkBase is WorksForkBase {
    /// @dev The deploy guards' pinned v1.4.1 singleton (`DeployGuards.SAFE_141_L1`).
    address internal constant SAFE_SINGLETON = DeployGuards.SAFE_141_L1;
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant MULTI_SEND_CALL_ONLY = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    address internal constant FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    /// @dev Runtime code hashes of the three v1.4.1 helpers, read from mainnet and Sepolia
    ///      (identical on both) on 17 November 2026, so another version's contract at a mistyped
    ///      address (v1.3.0's `MultiSendCallOnly` behaves alike) cannot stand in.
    bytes32 internal constant SAFE_PROXY_FACTORY_CODEHASH =
        0x50c3cdc4074750a7a974204a716c999edd37482f907608d960b2b025ee0b3317;
    bytes32 internal constant MULTI_SEND_CALL_ONLY_CODEHASH =
        0xecd5bd14a08c5d2122379900b2f272bdf107a7e92423c10dd5fe3254386c9939;
    bytes32 internal constant FALLBACK_HANDLER_CODEHASH =
        0x7c6007a5d711cea8dfd5d91f5940ec29c7f200fe511eb1fc1397b367af3c42f9;
    /// @dev `keccak256("SafeMessage(bytes message)")`, the type of a message a Safe signs for
    ///      ERC-1271 (`CompatibilityFallbackHandler.SAFE_MSG_TYPEHASH`).
    bytes32 internal constant SAFE_MSG_TYPEHASH =
        0x60b3cbf8b4a223d68d641b3b6ddf9a298e7f33710cf3d3a9d1146b5a6150fbca;
    uint8 internal constant CALL = 0;
    uint8 internal constant DELEGATECALL = 1;
    /// @dev Every Safe here is 2-of-3.
    uint256 internal constant THRESHOLD = 2;

    /// @dev One call of a MultiSend batch.
    struct SafeCall {
        address to;
        uint256 value;
        bytes data;
    }

    /// @dev The network: holds every network role once it accepts at genesis.
    ISafe internal networkSafe;
    /// @dev The network fee Safe: the fee recipient vault's first destination.
    ISafe internal feeSafe;
    /// @dev Each Safe's owner keys, in the order its owners were set up.
    mapping(address safe => uint256[]) internal safeKeys;

    function _rpcVar() internal pure virtual override returns (string memory) {
        return "FORK_MAINNET_RPC";
    }

    function _chainId() internal pure virtual override returns (uint256) {
        return MAINNET;
    }

    /// @dev Replaces `IntegrationBase.setUp`: the network and the fee recipient's destination
    ///      are Safes before anything is deployed, genesis is installed by the deployer, and
    ///      the network Safe accepts by a Safe transaction instead of a prank.
    function setUp() public virtual override {
        string memory rpc = vm.envOr(_rpcVar(), string(""));
        if (bytes(rpc).length == 0) return;
        Forks.select(vm, rpc, vm.envOr(string.concat(_rpcVar(), "_BLOCK"), uint256(0)));
        require(block.chainid == _chainId(), "the RPC serves another chain");
        forked = true;
        assertEq(SAFE_SINGLETON.codehash, DeployGuards.SAFE_141_L1_CODEHASH, "Safe singleton");
        assertEq(SAFE_PROXY_FACTORY.codehash, SAFE_PROXY_FACTORY_CODEHASH, "Safe proxy factory");
        assertEq(MULTI_SEND_CALL_ONLY.codehash, MULTI_SEND_CALL_ONLY_CODEHASH, "MultiSendCallOnly");
        assertEq(FALLBACK_HANDLER.codehash, FALLBACK_HANDLER_CODEHASH, "fallback handler");
        assertEq(ISafe(SAFE_SINGLETON).VERSION(), "1.4.1");

        networkSafe = _newSafe("network");
        feeSafe = _newSafe("network fee");
        hotAdmin = address(networkSafe);
        networkFeeSafe = address(feeSafe);

        deferGenesis = true;
        _deployWorks();
        DeployV1.install(deployment, _genesisConfig(), manifest, _genesisWiring());
        assertEq(manager.pendingNetwork(), address(networkSafe), "genesis proposes the Safe");
        assertEq(manager.network(), address(0));
        assertTrue(
            _safeCall(networkSafe, address(manager), abi.encodeCall(manager.acceptNetwork, ())),
            "the Safe accepts the network"
        );

        keyOf[signer1] = signer1Pk;
        keyOf[signer2] = signer2Pk;
        vm.prank(platform);
        collectionId = stream.createCollection("Genesis", keccak256("genesis collection"));
    }

    // ------------------------------------------------------------------ Safes

    /// @dev A new 2-of-3 Safe v1.4.1 proxy with the canonical fallback handler; owners are
    ///      `makeAddrAndKey("<label> owner <i>")`.
    function _newSafe(string memory label) internal returns (ISafe safe) {
        address[] memory owners = new address[](3);
        uint256[] memory keys = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            (owners[i], keys[i]) = makeAddrAndKey(string.concat(label, " owner ", vm.toString(i)));
        }
        bytes memory init = abi.encodeCall(
            ISafe.setup,
            (
                owners,
                THRESHOLD,
                address(0),
                "",
                FALLBACK_HANDLER,
                address(0),
                0,
                payable(address(0))
            )
        );
        safe = ISafe(
            ISafeProxyFactory(SAFE_PROXY_FACTORY)
                .createProxyWithNonce(SAFE_SINGLETON, init, uint256(keccak256(bytes(label))))
        );
        vm.label(address(safe), string.concat(label, " Safe"));
        safeKeys[address(safe)] = keys;
    }

    /// @dev Signs and executes one Safe transaction with the first `signers` owner keys.
    ///      Returns false when the Safe reverts (a failed inner call reverts the transaction,
    ///      since `safeTxGas` and `gasPrice` are zero).
    function _execSafe(
        ISafe safe,
        address to,
        uint256 value,
        bytes memory data,
        uint8 operation,
        uint256 signers
    ) internal returns (bool) {
        bytes memory signatures = _ownerSignatures(
            safe, _txHash(safe, to, value, data, operation), _firstKeys(safe, signers)
        );
        return _submit(safe, to, value, data, operation, signatures);
    }

    /// @dev The hash of a Safe transaction with no gas refund, at the Safe's current nonce.
    function _txHash(ISafe safe, address to, uint256 value, bytes memory data, uint8 operation)
        internal
        view
        returns (bytes32)
    {
        uint256 n = safe.nonce();
        return
            safe.getTransactionHash(to, value, data, operation, 0, 0, 0, address(0), address(0), n);
    }

    function _submit(
        ISafe safe,
        address to,
        uint256 value,
        bytes memory data,
        uint8 operation,
        bytes memory signatures
    ) internal returns (bool) {
        try safe.execTransaction(
            to, value, data, operation, 0, 0, 0, address(0), payable(address(0)), signatures
        ) returns (
            bool ok
        ) {
            return ok;
        } catch {
            return false;
        }
    }

    /// @dev One call from `safe`, signed by the threshold.
    function _safeCall(ISafe safe, address to, bytes memory data) internal returns (bool) {
        return _execSafe(safe, to, 0, data, CALL, THRESHOLD);
    }

    /// @dev One call carrying `value` of the Safe's own ETH, signed by the threshold.
    function _safeCallValue(ISafe safe, address to, uint256 value, bytes memory data)
        internal
        returns (bool)
    {
        return _execSafe(safe, to, value, data, CALL, THRESHOLD);
    }

    /// @dev One Safe transaction that delegatecalls `MultiSendCallOnly` with a CALL for each
    ///      entry of `calls`, signed by the first `signers` owners.
    function _safeBatch(ISafe safe, SafeCall[] memory calls, uint256 signers)
        internal
        returns (bool)
    {
        bytes memory packed;
        for (uint256 i; i < calls.length; ++i) {
            packed = abi.encodePacked(
                packed, CALL, calls[i].to, calls[i].value, calls[i].data.length, calls[i].data
            );
        }
        return _execSafe(
            safe,
            MULTI_SEND_CALL_ONLY,
            0,
            abi.encodeCall(IMultiSendCallOnly.multiSend, (packed)),
            DELEGATECALL,
            signers
        );
    }

    /// @dev The first `count` owner keys of `safe`.
    function _firstKeys(ISafe safe, uint256 count) internal view returns (uint256[] memory keys) {
        keys = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            keys[i] = safeKeys[address(safe)][i];
        }
    }

    /// @dev ECDSA signatures of `hash` by `keys`, sorted by signer address as Safe requires.
    function _ownerSignatures(ISafe, bytes32 hash, uint256[] memory keys)
        internal
        pure
        returns (bytes memory signatures)
    {
        for (uint256 i; i < keys.length; ++i) {
            for (uint256 j = i + 1; j < keys.length; ++j) {
                if (vm.addr(keys[j]) < vm.addr(keys[i])) (keys[i], keys[j]) = (keys[j], keys[i]);
            }
        }
        for (uint256 i; i < keys.length; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], hash);
            signatures = abi.encodePacked(signatures, r, s, v);
        }
    }

    /// @dev The hash a Safe's owners sign for its ERC-1271 approval of `digest`, computed here
    ///      from the 1.4.1 definition (`CompatibilityFallbackHandler.encodeMessageDataForSafe`
    ///      of `abi.encode(digest)`), not read from the handler.
    function _safeMessageHash(ISafe safe, bytes32 digest) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                bytes1(0x19),
                bytes1(0x01),
                safe.domainSeparator(),
                keccak256(abi.encode(SAFE_MSG_TYPEHASH, keccak256(abi.encode(digest))))
            )
        );
    }

    /// @dev `safe`'s ERC-1271 signature of `digest` by `keys`.
    function _safeSignatureBy(ISafe safe, bytes32 digest, uint256[] memory keys)
        internal
        view
        returns (bytes memory)
    {
        return _ownerSignatures(safe, _safeMessageHash(safe, digest), keys);
    }

    /// @dev `safe`'s ERC-1271 signature of `digest` by its first `THRESHOLD` owners.
    function _safeSignature(ISafe safe, bytes32 digest) internal view returns (bytes memory) {
        return _safeSignatureBy(safe, digest, _firstKeys(safe, THRESHOLD));
    }

    /// @dev A wallet-prefixed proof (`abi.encodePacked(wallet, signature)`) by `safe`.
    function _safeProof(ISafe safe, bytes32 digest) internal view returns (bytes memory) {
        return abi.encodePacked(address(safe), _safeSignature(safe, digest));
    }

    // ------------------------------------------------------------------ governed actions

    function _scheduleCall(address target, bytes memory data)
        internal
        view
        returns (SafeCall memory)
    {
        return SafeCall(address(manager), 0, abi.encodeCall(manager.schedule, (target, data, 0)));
    }

    function _executeCall(address target, bytes memory data)
        internal
        view
        returns (SafeCall memory)
    {
        return SafeCall(address(manager), 0, abi.encodeCall(manager.execute, (target, data)));
    }

    /// @dev Runs a delayed governed call as `safe` through the manager: a scheduling Safe
    ///      transaction, the class delay, then an executing Safe transaction.
    function _safeGovern(ISafe safe, address target, bytes memory data) internal {
        (bool immediate, uint32 delay) = manager.canCall(address(safe), target, bytes4(data));
        require(!immediate && delay != 0, "not a delayed action of this Safe");
        require(
            _safeCall(safe, address(manager), abi.encodeCall(manager.schedule, (target, data, 0))),
            "schedule"
        );
        vm.warp(block.timestamp + delay);
        require(
            _safeCall(safe, address(manager), abi.encodeCall(manager.execute, (target, data))),
            "execute"
        );
    }

    function _opId(ISafe safe, address target, bytes memory data) internal view returns (bytes32) {
        return manager.hashOperation(address(safe), target, data);
    }
}

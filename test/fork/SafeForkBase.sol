// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { DeployGuards } from "script/DeployGuards.sol";
import { CoreForkBase } from "./WorksForkBase.sol";

/// @dev The parts of Safe v1.4.1 these suites call, declared here so the repository takes no
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

/// @dev Safe 1.3.0's proxy factory answers the runtime code of the proxies it creates.
interface ISafe130ProxyFactory {
    function proxyRuntimeCode() external pure returns (bytes memory);
}

interface IMultiSendCallOnly {
    function multiSend(bytes memory transactions) external payable;
}

/// @notice The plain-core stack on an Ethereum mainnet fork with real Safe v1.4.1 wallets in
///         the accounts the network and the institutions hold: the network is a 2-of-3 Safe,
///         and the fee recipient's and the museum's vaults forward to two more Safes. Suites
///         add Safes as an artist's wallet and a bidder.
/// @dev Safe v1.4.1's singleton, proxy factory, `MultiSendCallOnly` and
///      `CompatibilityFallbackHandler` are used at their canonical addresses
///      (github.com/safe-global/safe-deployments, v1.4.1), each code-hash pinned. Every Safe
///      transaction is signed by owner keys this test holds and executed by a relayer, so the
///      Safe is `msg.sender` of every call it makes. The genesis acceptance is the base's
///      (`acceptNetwork` from the Safe's address); `SafeNetwork.t.sol` checks an acceptance by
///      a Safe transaction in the handover to a second Safe.
abstract contract SafeForkBase is CoreForkBase {
    address internal constant SAFE_SINGLETON = DeployGuards.SAFE_141_L1;
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant MULTI_SEND_CALL_ONLY = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    address internal constant FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    /// @dev Runtime code hashes of the three v1.4.1 helpers, read from mainnet and Sepolia
    ///      (identical on both) on 17 November 2026, so another version's contract at a mistyped
    ///      address cannot stand in.
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

    ISafe internal networkSafe;
    ISafe internal feeDestination;
    ISafe internal museumDestination;
    address internal relayer = makeAddr("relayer");
    /// @dev Each Safe's owner keys, in the order its owners were set up.
    mapping(address safe => uint256[]) internal safeKeys;

    function _rpcVar() internal pure virtual override returns (string memory) {
        return "FORK_MAINNET_RPC";
    }

    function _chainId() internal pure virtual override returns (uint256) {
        return MAINNET;
    }

    /// @dev The Safe helpers are the canonical v1.4.1 code; the network and the two vault
    ///      destinations are Safes before anything is deployed.
    function _beforeDeploy() internal virtual override {
        assertEq(SAFE_SINGLETON.codehash, DeployGuards.SAFE_141_L1_CODEHASH, "Safe singleton");
        assertEq(SAFE_PROXY_FACTORY.codehash, SAFE_PROXY_FACTORY_CODEHASH, "Safe proxy factory");
        assertEq(MULTI_SEND_CALL_ONLY.codehash, MULTI_SEND_CALL_ONLY_CODEHASH, "MultiSendCallOnly");
        assertEq(FALLBACK_HANDLER.codehash, FALLBACK_HANDLER_CODEHASH, "fallback handler");
        assertEq(ISafe(SAFE_SINGLETON).VERSION(), "1.4.1");
        networkSafe = _newSafe("network");
        feeDestination = _newSafe("network fee");
        museumDestination = _newSafe("museum");
        network = address(networkSafe);
        feeSafe = address(feeDestination);
        museumSafe = address(museumDestination);
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

    /// @dev One Safe transaction signed by the first `signers` owner keys and executed by the
    ///      relayer. Reverts as the Safe does: "GS013" when the inner call fails (no
    ///      `safeTxGas`, no gas price), "GS020" when fewer signatures than the threshold.
    function _execSafe(
        ISafe safe,
        address to,
        uint256 value,
        bytes memory data,
        uint8 operation,
        uint256 signers
    ) internal {
        bytes memory signatures = _ownerSignatures(
            _txHash(safe, to, value, data, operation), _firstKeys(safe, signers)
        );
        vm.prank(relayer);
        safe.execTransaction(
            to, value, data, operation, 0, 0, 0, address(0), payable(address(0)), signatures
        );
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

    /// @dev One call from `safe`, signed by the threshold.
    function _safeCall(ISafe safe, address to, bytes memory data) internal {
        _execSafe(safe, to, 0, data, CALL, THRESHOLD);
    }

    /// @dev One call carrying `value` of the Safe's own ETH, signed by the threshold.
    function _safeCallValue(ISafe safe, address to, uint256 value, bytes memory data) internal {
        _execSafe(safe, to, value, data, CALL, THRESHOLD);
    }

    /// @dev One Safe transaction whose inner call must fail: the Safe reverts with "GS013" and
    ///      its nonce is not spent. `reason` is the target's own revert, checked by repeating
    ///      the call as a prank of the Safe (the Safe does not pass it on).
    function _safeCallFails(ISafe safe, address to, bytes memory data, bytes memory reason)
        internal
    {
        uint256 nonceBefore = safe.nonce();
        vm.expectRevert(bytes("GS013"));
        this.execSafeExternal(safe, to, 0, data, CALL, THRESHOLD);
        assertEq(safe.nonce(), nonceBefore, "a refused transaction spends no Safe nonce");
        vm.prank(address(safe));
        vm.expectRevert(reason);
        (bool ok,) = to.call(data);
        ok;
    }

    /// @dev `_execSafe`, external so a test can expect its revert.
    function execSafeExternal(
        ISafe safe,
        address to,
        uint256 value,
        bytes memory data,
        uint8 operation,
        uint256 signers
    ) external {
        _execSafe(safe, to, value, data, operation, signers);
    }

    /// @dev The MultiSend payload of `calls`, each a CALL.
    function _multiSend(SafeCall[] memory calls) internal pure returns (bytes memory) {
        bytes memory packed;
        for (uint256 i; i < calls.length; ++i) {
            packed = abi.encodePacked(
                packed, CALL, calls[i].to, calls[i].value, calls[i].data.length, calls[i].data
            );
        }
        return abi.encodeCall(IMultiSendCallOnly.multiSend, (packed));
    }

    /// @dev One Safe transaction that delegatecalls `MultiSendCallOnly` with a CALL for each
    ///      entry of `calls`, signed by the threshold. Any failing call reverts it whole.
    function _safeBatch(ISafe safe, SafeCall[] memory calls) internal {
        _execSafe(safe, MULTI_SEND_CALL_ONLY, 0, _multiSend(calls), DELEGATECALL, THRESHOLD);
    }

    /// @dev The first `count` owner keys of `safe`.
    function _firstKeys(ISafe safe, uint256 count) internal view returns (uint256[] memory keys) {
        keys = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            keys[i] = safeKeys[address(safe)][i];
        }
    }

    /// @dev The owner addresses of `safe` this test holds keys for.
    function _ownerOf(ISafe safe, uint256 index) internal view returns (address) {
        return vm.addr(safeKeys[address(safe)][index]);
    }

    /// @dev ECDSA signatures of `hash` by `keys`, sorted by signer address as Safe requires.
    function _ownerSignatures(bytes32 hash, uint256[] memory keys)
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
        return _ownerSignatures(_safeMessageHash(safe, digest), keys);
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
    ///      transaction, the class delay read from the manager, then an executing one.
    function _safeGovern(ISafe safe, address target, bytes memory data) internal {
        (bool immediate, uint32 delay) = manager.canCall(address(safe), target, bytes4(data));
        require(!immediate && delay != 0, "not a delayed action of this Safe");
        _safeCall(safe, address(manager), abi.encodeCall(manager.schedule, (target, data, 0)));
        vm.warp(block.timestamp + delay);
        _safeCall(safe, address(manager), abi.encodeCall(manager.execute, (target, data)));
    }

    function _opId(ISafe safe, address target, bytes memory data) internal view returns (bytes32) {
        return manager.hashOperation(address(safe), target, data);
    }
}

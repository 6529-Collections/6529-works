// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { Roles } from "src/governance/Roles.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { CURRENCY_ETH, PRODUCT_FEDERATED } from "src/interfaces/types/EconomicsTypes.sol";
import { Payment, PaymentMethod, PrimaryTerms } from "src/interfaces/types/SaleTypes.sol";
import { ISignatureTransfer } from "src/interfaces/external/ISignatureTransfer.sol";
import { MintSaleBase } from "src/sales/MintSaleBase.sol";
import {
    MockAssetAllowlist,
    MockEconomicsResolver,
    MockEditionTarget,
    MockPermit2,
    MockRevenueEscrow,
    PermitToken
} from "../mocks/sales/SaleMocks.sol";

/// @notice Shared setup for the fixed-price and Dutch adapter tests: an AccessManager with the
///         PLATFORM and SUCCESSOR_SETTER roles, an edition-like mint target, the escrow and
///         allowlist stand-ins, a canonical-hashing Permit2, an EIP-2612 token, OpenZeppelin
///         sorted-pair Merkle trees, and signing helpers.
abstract contract SaleFixture is Test {
    uint64 internal constant PLATFORM_ROLE = Roles.PLATFORM;
    uint64 internal constant SUCCESSOR_SETTER_ROLE = Roles.SUCCESSOR_SETTER;
    uint64 internal constant PAUSER_ROLE = Roles.PAUSER;
    uint64 internal constant UNPAUSER_ROLE = Roles.UNPAUSER;
    uint32 internal constant FEE_SHARE = 25_000;
    uint256 internal constant SIZE = 1000;

    AccessManager internal manager;
    MockEditionTarget internal editions;
    MockRevenueEscrow internal escrow;
    MockAssetAllowlist internal allowlist;
    MockPermit2 internal permit2;
    PermitToken internal usd;
    MockEconomicsResolver internal resolver;

    address internal admin = makeAddr("admin");
    address internal platform = makeAddr("platform");
    address internal pauser = makeAddr("pauser");
    address internal unpauser = makeAddr("unpauser");
    address internal stranger = makeAddr("stranger");
    address internal relayer = makeAddr("relayer");
    address internal seller = makeAddr("predictedSplitWallet");
    address internal network = makeAddr("network");
    address internal federatedNetwork = makeAddr("federatedNetwork");
    address internal creator;
    uint256 internal creatorKey;
    address internal alice;
    uint256 internal aliceKey;
    address internal bob;
    uint256 internal bobKey;

    function _setUpBase() internal {
        vm.warp(1_800_000_000);
        (creator, creatorKey) = makeAddrAndKey("creator");
        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey) = makeAddrAndKey("bob");
        manager = new AccessManager(admin);
        editions = new MockEditionTarget();
        escrow = new MockRevenueEscrow();
        allowlist = new MockAssetAllowlist();
        permit2 = new MockPermit2();
        usd = new PermitToken();
        resolver = new MockEconomicsResolver(allowlist);
        resolver.set(PRODUCT_FEDERATED, federatedNetwork, 10_000);
        allowlist.set(CURRENCY_ETH, true);
        allowlist.set(address(usd), true);
    }

    function _deps()
        internal
        view
        returns (IRevenueEscrow, ISignatureTransfer, IEconomicsResolver)
    {
        return (
            IRevenueEscrow(address(escrow)),
            ISignatureTransfer(address(permit2)),
            IEconomicsResolver(address(resolver))
        );
    }

    /// @dev Maps the managing selectors to PLATFORM and the two setters to SUCCESSOR_SETTER,
    ///      grants both with no delay, lists the edition target and makes the adapter a minter.
    function _wire(address adapter, bytes4[] memory platformSelectors) internal {
        bytes4[] memory setter = new bytes4[](2);
        setter[0] = ISaleAdapter.setTarget.selector;
        setter[1] = ISaleAdapter.setFederationRegistry.selector;
        vm.startPrank(admin);
        manager.setTargetFunctionRole(adapter, platformSelectors, PLATFORM_ROLE);
        manager.setTargetFunctionRole(adapter, setter, SUCCESSOR_SETTER_ROLE);
        manager.grantRole(PLATFORM_ROLE, platform, 0);
        manager.grantRole(SUCCESSOR_SETTER_ROLE, admin, 0);
        bytes4[] memory pausing = new bytes4[](1);
        pausing[0] = MintSaleBase.pause.selector;
        manager.setTargetFunctionRole(adapter, pausing, PAUSER_ROLE);
        pausing[0] = MintSaleBase.unpause.selector;
        manager.setTargetFunctionRole(adapter, pausing, UNPAUSER_ROLE);
        manager.grantRole(PAUSER_ROLE, pauser, 0);
        manager.grantRole(UNPAUSER_ROLE, unpauser, 0);
        ISaleAdapter(adapter).setTarget(address(editions), true);
        vm.stopPrank();
        editions.setAdmittedMinter(adapter, true);
    }

    function _terms(bytes32 kind, address currency, uint256 price, bytes memory params)
        internal
        view
        returns (PrimaryTerms memory)
    {
        return PrimaryTerms(kind, currency, price, params, seller, network, FEE_SHARE, creator);
    }

    function _eth(address payer, uint256 amount) internal pure returns (Payment memory p) {
        p.method = PaymentMethod.DIRECT;
        p.payer = payer;
        p.amount = amount;
    }

    function _fee(uint256 total) internal pure returns (uint256) {
        return total * FEE_SHARE / 100_000;
    }

    // ------------------------------------------------------------------ signatures

    function _sig(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev An EIP-2612 permit payment for `value`, spent by `spender`.
    function _permitPayment(
        uint256 key,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (Payment memory p) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                owner,
                spender,
                value,
                usd.nonces(owner),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usd.DOMAIN_SEPARATOR(), structHash));
        p = Payment(PaymentMethod.PERMIT, owner, value, deadline, 0, _sig(key, digest));
    }

    /// @dev A Permit2 witness payment of up to `amount` of `token`, spent by `spender`.
    function _permit2Payment(
        uint256 key,
        address owner,
        address spender,
        address token,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes32 witness,
        string memory witnessType
    ) internal view returns (Payment memory p) {
        ISignatureTransfer.PermitTransferFrom memory permit =
            ISignatureTransfer.PermitTransferFrom(
                ISignatureTransfer.TokenPermissions(token, amount), nonce, deadline
            );
        bytes32 digest = permit2.witnessDigest(spender, permit, witness, witnessType);
        p = Payment(PaymentMethod.PERMIT2, owner, amount, deadline, nonce, _sig(key, digest));
    }

    // ------------------------------------------------------------------ gas cap

    /// @dev Fusaka's per-transaction gas cap (EIP-7825).
    uint256 internal constant TX_GAS_CAP = 16_777_216;

    /// @dev Asserts intrinsic 21,000 + EIP-2028 calldata + `execution` (never below the EIP-7623
    ///      floor) stays within 75% of the cap. Foundry runs `prague`, which does not enforce it.
    function _assertFits(string memory label, bytes memory data, uint256 execution) internal {
        uint256 zeros;
        for (uint256 i; i < data.length; ++i) {
            if (data[i] == 0) ++zeros;
        }
        uint256 nonZeros = data.length - zeros;
        uint256 standard = 21_000 + zeros * 4 + nonZeros * 16 + execution;
        uint256 floor = 21_000 + 10 * (zeros + 4 * nonZeros);
        uint256 total = standard > floor ? standard : floor;
        emit log_named_uint(string.concat(label, ": transaction gas"), total);
        assertLe(total, TX_GAS_CAP * 3 / 4, label);
    }

    /// @dev A proof of `depth` arbitrary siblings and the root it proves for `leaf`.
    function _deepProof(bytes32 leaf, uint256 depth)
        internal
        pure
        returns (bytes32 root, bytes32[] memory proof)
    {
        proof = new bytes32[](depth);
        root = leaf;
        for (uint256 i; i < depth; ++i) {
            proof[i] = keccak256(abi.encode("sibling", i));
            (bytes32 a, bytes32 b) = root < proof[i] ? (root, proof[i]) : (proof[i], root);
            root = keccak256(abi.encode(a, b));
        }
    }

    // ------------------------------------------------------------------ Merkle trees

    function _root(bytes32[] memory leaves) internal pure returns (bytes32) {
        return SaleMerkle.root(leaves);
    }

    function _proof(bytes32[] memory leaves, uint256 index)
        internal
        pure
        returns (bytes32[] memory)
    {
        return SaleMerkle.proof(leaves, index);
    }
}

/// @notice OpenZeppelin `MerkleProof` trees (sorted pairs, an odd node promoted) for tests.
library SaleMerkle {
    /// @dev The root of `leaves`.
    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            level = _up(level);
        }
        return level[0];
    }

    /// @dev The proof of `leaves[index]` against {root}.
    function proof(bytes32[] memory leaves, uint256 index)
        internal
        pure
        returns (bytes32[] memory nodes)
    {
        bytes32[] memory buffer = new bytes32[](64);
        uint256 n;
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            uint256 sibling = index ^ 1;
            if (sibling < level.length) buffer[n++] = level[sibling];
            level = _up(level);
            index >>= 1;
        }
        nodes = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            nodes[i] = buffer[i];
        }
    }

    function _up(bytes32[] memory level) private pure returns (bytes32[] memory next) {
        next = new bytes32[]((level.length + 1) / 2);
        for (uint256 i; i < next.length; ++i) {
            uint256 j = 2 * i;
            if (j + 1 == level.length) {
                next[i] = level[j];
            } else {
                (bytes32 a, bytes32 b) =
                    level[j] < level[j + 1] ? (level[j], level[j + 1]) : (level[j + 1], level[j]);
                next[i] = keccak256(abi.encode(a, b));
            }
        }
    }
}

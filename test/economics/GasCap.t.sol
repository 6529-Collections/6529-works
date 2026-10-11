// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SplitWallet } from "src/economics/SplitWallet.sol";
import { IClaimRouter } from "src/economics/interfaces/IClaimRouter.sol";
import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { BlocklistToken, Mock1271Account } from "../mocks/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

/// @notice Every bounded loop fits Fusaka's per-transaction gas cap (EIP-7825, 16,777,216 gas)
///         with a wide margin. Foundry runs the `prague` EVM, which does not enforce the cap, so
///         these tests measure the worst case with cold state and add the intrinsic 21,000 and
///         the calldata cost (EIP-2028, with the EIP-7623 floor).
contract GasCapTest is EconomicsBase {
    uint256 internal constant TX_GAS_CAP = 16_777_216;
    /// @dev "Well under": at most 75% of the cap.
    uint256 internal constant BUDGET = TX_GAS_CAP * 3 / 4;
    /// @dev An ERC-1271 check that spends its whole 200,000-gas allowance.
    uint256 internal constant SMART_ACCOUNT_BURN = 190_000;

    BlocklistToken internal usdc;
    IClaimRouter.Claim[] internal worstClaims;
    IClaimRouter.SignedClaim[] internal worstSigned;
    address[] internal touched;
    ISplitWallet.Payee[] internal maxPayees;

    function setUp() public override {
        super.setUp();
        usdc = new BlocklistToken();
        // Worst plain items: a distinct wallet each, an ERC-20 with extra checks, a first release
        // (fresh storage) to a fresh account.
        uint256 max = router.MAX_CLAIMS();
        for (uint256 i; i < max; ++i) {
            SplitWallet w = _wallet(
                _list(_fixed(address(uint160(0xE00000 + i)), D - 1), _artist(1000 + i, 1))
            );
            usdc.mint(address(w), 1e24);
            worstClaims.push(IClaimRouter.Claim(address(w), address(usdc), 0));
            touched.push(address(w));
        }
        // Worst signed items: artist pulls by a 4 KiB ERC-1271 signature from a smart account
        // that spends its whole check allowance, to a fresh recipient.
        bytes memory signature = new bytes(4096);
        for (uint256 i; i < signature.length; ++i) {
            signature[i] = 0xff;
        }
        for (uint256 i; i < router.MAX_SIGNED_CLAIMS(); ++i) {
            Mock1271Account safe = new Mock1271Account();
            safe.setBurn(SMART_ACCOUNT_BURN);
            resolver.set(2000 + i, address(safe));
            SplitWallet w = _wallet(
                _list(_fixed(address(uint160(0xC00000 + i)), 1), _artist(2000 + i, D - 1))
            );
            usdc.mint(address(w), 1e24);
            IReleaseVerifier.Authorization memory a = _auth(
                w,
                address(usdc),
                1,
                address(safe),
                address(uint160(0xB00000 + i)),
                type(uint256).max,
                i
            );
            safe.accept(verifier.releaseDigest(a));
            worstSigned.push(IClaimRouter.SignedClaim(a, signature));
            touched.push(address(w));
            touched.push(address(safe));
        }
        // The largest wallet: 64 artist-resolved payees, two storage slots each.
        for (uint256 i; i < 64; ++i) {
            maxPayees.push(_artist(5000 + i, i == 0 ? D - 63 : 1));
        }
    }

    function test_WorstCaseAtomicClaimBatchFitsTheCap() public {
        IClaimRouter.Claim[] memory claims = worstClaims;
        _cool();
        uint256 start = gasleft();
        uint256[] memory amounts = router.claim(claims, false);
        uint256 used = start - gasleft();
        assertGt(amounts[claims.length - 1], 0);
        _assertFits("atomic claim batch", abi.encodeCall(IClaimRouter.claim, (claims, false)), used);
    }

    function test_WorstCaseAtomicSignedBatchFitsTheCap() public {
        IClaimRouter.SignedClaim[] memory claims = worstSigned;
        _cool();
        uint256 start = gasleft();
        uint256[] memory amounts = router.claimSigned(claims, false);
        uint256 used = start - gasleft();
        assertGt(amounts[claims.length - 1], 0);
        _assertFits(
            "atomic signed batch", abi.encodeCall(IClaimRouter.claimSigned, (claims, false)), used
        );
    }

    /// @dev Ported from the review's gas PoC: binary-search the least gas at which a full
    ///      continue-mode batch succeeds, as `eth_estimateGas` would, and require every worst-case
    ///      item to be paid there and the total to fit the cap.
    function test_ContinueClaimBatchAtItsEstimatedGasPaysEveryItem() public {
        bytes memory input = abi.encodeCall(IClaimRouter.claim, (worstClaims, true));
        (uint256 estimate, uint256 paid) = _estimate(input, 1_000_000, 16_000_000);
        assertEq(paid, worstClaims.length, "every item paid at the estimate");
        _assertFits("continue claim batch at its estimate", input, estimate);
    }

    function test_ContinueSignedBatchAtItsEstimatedGasPaysEveryItem() public {
        bytes memory input = abi.encodeCall(IClaimRouter.claimSigned, (worstSigned, true));
        (uint256 estimate, uint256 paid) = _estimate(input, 1_000_000, 16_000_000);
        assertEq(paid, worstSigned.length, "every item paid at the estimate");
        _assertFits("continue signed batch at its estimate", input, estimate);
    }

    function test_MaximumWalletDeploymentFitsTheCap() public {
        ISplitWallet.Payee[] memory payees = maxPayees;
        vm.cool(address(factory));
        uint256 start = gasleft();
        factory.createWallet(payees, bytes32(0));
        uint256 used = start - gasleft();
        _assertFits(
            "64-payee wallet deployment",
            abi.encodeCall(ISplitFactory.createWallet, (payees, bytes32(0))),
            used
        );
    }

    function _estimate(bytes memory input, uint256 lo, uint256 hi)
        internal
        returns (uint256 estimate, uint256 paid)
    {
        while (hi - lo > 1000) {
            uint256 mid = (lo + hi) / 2;
            (bool ok,) = _tryAt(input, mid);
            if (ok) hi = mid;
            else lo = mid;
        }
        bool okHi;
        (okHi, paid) = _tryAt(input, hi);
        assertTrue(okHi);
        estimate = hi;
    }

    function _tryAt(bytes memory input, uint256 gasLimit) internal returns (bool ok, uint256 paid) {
        uint256 snap = vm.snapshotState();
        _cool();
        bytes memory output;
        (ok, output) = address(router).call{ gas: gasLimit }(input);
        if (ok) {
            uint256[] memory amounts = abi.decode(output, (uint256[]));
            for (uint256 i; i < amounts.length; ++i) {
                if (amounts[i] > 0) ++paid;
            }
        }
        vm.revertToState(snap);
    }

    function _cool() internal {
        vm.cool(address(router));
        vm.cool(address(usdc));
        vm.cool(address(resolver));
        vm.cool(address(verifier));
        for (uint256 i; i < touched.length; ++i) {
            vm.cool(touched[i]);
        }
    }

    /// @dev Intrinsic 21,000 + EIP-2028 calldata + execution, never below the EIP-7623 floor.
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
        assertLe(total, BUDGET, label);
    }
}

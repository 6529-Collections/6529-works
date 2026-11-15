// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IClaimRouter } from "src/economics/interfaces/IClaimRouter.sol";
import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { BlocklistToken, Mock1271Account } from "../mocks/economics/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

/// @notice Every bounded loop fits Fusaka's per-transaction gas cap (EIP-7825, 16,777,216 gas)
///         with a wide margin. Foundry runs the `prague` EVM, which does not enforce the cap, so
///         these tests measure the worst case with cold state and add the intrinsic 21,000 and
///         the calldata cost (EIP-2028, with the EIP-7623 floor).
contract GasCapTest is EconomicsBase {
    uint256 internal constant TX_GAS_CAP = 16_777_216;
    /// @dev "Well under": at most 75% of the cap.
    uint256 internal constant BUDGET = TX_GAS_CAP * 3 / 4;
    /// @dev An ERC-1271 check that spends nearly the whole of today's 200,000-gas allowance.
    uint256 internal constant SMART_ACCOUNT_BURN = 190_000;
    /// @dev Payees per worst-case item: every item carries its wallet's payee list in calldata,
    ///      and the router and the ledger copy and hash it, so the longest list allowed
    ///      (`Splits.MAX_PAYEES`) is the worst case.
    uint256 internal constant WORST_PAYEES = 64;

    BlocklistToken internal usdc;
    address[] internal plainWallets;
    address[] internal signedWallets;
    IReleaseVerifier.Authorization[] internal signedAuths;
    bytes internal signature;
    address[] internal touched;
    ISplitWallet.Payee[] internal maxPayees;

    function setUp() public override {
        super.setUp();
        usdc = new BlocklistToken();
        // Worst plain items: a distinct 64-payee wallet each, an ERC-20 with extra checks, a
        // first release (fresh storage) to a fresh account.
        uint256 max = router.MAX_CLAIMS();
        for (uint256 i; i < max; ++i) {
            address w = _wallet(_longList(address(uint160(0xE00000 + i)), 0, 1000 + i * 100));
            usdc.mint(address(w), 1e24);
            plainWallets.push(w);
            touched.push(address(w));
        }
        // Worst signed items: artist pulls by a 4 KiB ERC-1271 signature from a smart account
        // that spends its whole check allowance, to a fresh recipient.
        signature = new bytes(4096);
        for (uint256 i; i < 4096; ++i) {
            signature[i] = 0xff;
        }
        for (uint256 i; i < router.MAX_SIGNED_CLAIMS(); ++i) {
            Mock1271Account safe = new Mock1271Account();
            safe.setBurn(SMART_ACCOUNT_BURN);
            resolver.set(2000 + i, address(safe));
            address w =
                _wallet(_longList(address(uint160(0xC00000 + i)), 2000 + i, 100_000 + i * 100));
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
            signedWallets.push(w);
            signedAuths.push(a);
            touched.push(address(w));
            touched.push(address(safe));
        }
        // The largest wallet: 64 artist-resolved payees (one storage slot for the whole wallet).
        for (uint256 i; i < 64; ++i) {
            maxPayees.push(_artist(5000 + i, i == 0 ? D - 63 : 1));
        }
    }

    function _worstClaims() internal view returns (IClaimRouter.Claim[] memory claims) {
        claims = new IClaimRouter.Claim[](plainWallets.length);
        for (uint256 i; i < claims.length; ++i) {
            address w = plainWallets[i];
            claims[i] = IClaimRouter.Claim(_payeesOf(w), _salts[w], address(usdc), 0);
        }
    }

    function _worstSigned() internal view returns (IClaimRouter.SignedClaim[] memory claims) {
        claims = new IClaimRouter.SignedClaim[](signedWallets.length);
        for (uint256 i; i < claims.length; ++i) {
            address w = signedWallets[i];
            claims[i] = IClaimRouter.SignedClaim(signedAuths[i], signature, _payeesOf(w), _salts[w]);
        }
    }

    function test_WorstCaseAtomicClaimBatchFitsTheCap() public {
        IClaimRouter.Claim[] memory claims = _worstClaims();
        _cool();
        uint256 start = gasleft();
        uint256[] memory amounts = router.claim(claims, false);
        uint256 used = start - gasleft();
        assertGt(amounts[claims.length - 1], 0);
        _assertFits("atomic claim batch", abi.encodeCall(IClaimRouter.claim, (claims, false)), used);
    }

    function test_WorstCaseAtomicSignedBatchFitsTheCap() public {
        IClaimRouter.SignedClaim[] memory claims = _worstSigned();
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
    ///      continue-mode batch (`MAX_CONTINUE_CLAIMS` worst-case items) succeeds, as
    ///      `eth_estimateGas` would, and require every item to be paid there and the total to fit
    ///      the cap.
    function test_ContinueClaimBatchAtItsEstimatedGasPaysEveryItem() public {
        IClaimRouter.Claim[] memory claims = _worstClaims();
        uint256 n = router.MAX_CONTINUE_CLAIMS();
        assembly ("memory-safe") {
            mstore(claims, n)
        }
        bytes memory input = abi.encodeCall(IClaimRouter.claim, (claims, true));
        (uint256 estimate, uint256 paid) = _estimate(input, 1_000_000, 16_000_000);
        assertEq(paid, n, "every item paid at the estimate");
        _assertFits("continue claim batch at its estimate", input, estimate);
    }

    function test_ContinueSignedBatchAtItsEstimatedGasPaysEveryItem() public {
        IClaimRouter.SignedClaim[] memory claims = _worstSigned();
        uint256 n = router.MAX_CONTINUE_CLAIMS();
        assembly ("memory-safe") {
            mstore(claims, n)
        }
        bytes memory input = abi.encodeCall(IClaimRouter.claimSigned, (claims, true));
        (uint256 estimate, uint256 paid) = _estimate(input, 1_000_000, 16_000_000);
        assertEq(paid, n, "every item paid at the estimate");
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

    /// @dev A canonical `WORST_PAYEES`-payee list: fixed payee `first` at index 0 (the item's
    ///      payee in plain claims), then, if `signer` is non-zero, artist `signer` at index 1 with
    ///      the bulk share (the signed claims' payee), then one-unit artists from `filler` up.
    function _longList(address first, uint256 signer, uint256 filler)
        internal
        pure
        returns (ISplitWallet.Payee[] memory payees)
    {
        payees = new ISplitWallet.Payee[](WORST_PAYEES);
        uint256 rest = WORST_PAYEES - (signer == 0 ? 1 : 2);
        payees[0] = _fixed(first, signer == 0 ? uint32(D - rest) : 1);
        uint256 k = 1;
        if (signer != 0) payees[k++] = _artist(signer, uint32(D - 1 - rest));
        for (uint256 j; j < rest; ++j) {
            payees[k++] = _artist(filler + j, 1);
        }
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

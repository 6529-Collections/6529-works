// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SplitWallet } from "src/economics/SplitWallet.sol";
import { IClaimRouter } from "src/economics/interfaces/IClaimRouter.sol";
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

    BlocklistToken internal usdc;
    IClaimRouter.Claim[] internal worstClaims;
    ISplitWallet.Payee[] internal maxPayees;
    SplitWallet internal contractPayeeWallet;
    Mock1271Account internal safe;

    function setUp() public override {
        super.setUp();
        usdc = new BlocklistToken();
        // Worst-case claim items: a distinct wallet each, an artist-resolved payee (one resolver
        // call), an ERC-20 with extra checks, a first release (fresh storage) to a fresh address.
        uint256 max = router.MAX_CLAIMS();
        for (uint256 i; i < max; ++i) {
            uint256 artistId = 1000 + i;
            resolver.set(artistId, address(uint160(0xF00000 + i)));
            SplitWallet w = _wallet(
                _list(_fixed(address(uint160(0xE00000 + i)), 1), _artist(artistId, D - 1))
            );
            usdc.mint(address(w), 1e24);
            worstClaims.push(IClaimRouter.Claim(address(w), address(usdc), 1));
        }
        // The largest wallet: 64 artist-resolved payees, two storage slots each.
        for (uint256 i; i < 64; ++i) {
            maxPayees.push(_artist(5000 + i, i == 0 ? D - 63 : 1));
        }
        safe = new Mock1271Account();
        contractPayeeWallet = _solo(address(safe));
        usdc.mint(address(contractPayeeWallet), 1e24);
    }

    function test_WorstCaseAtomicClaimBatchFitsTheCap() public {
        IClaimRouter.Claim[] memory claims = worstClaims;
        _coolClaims(claims);
        uint256 start = gasleft();
        uint256[] memory amounts = router.claim(claims, false);
        uint256 used = start - gasleft();
        assertEq(amounts.length, router.MAX_CLAIMS());
        assertGt(amounts[claims.length - 1], 0);
        _assertFits("atomic claim batch", abi.encodeCall(IClaimRouter.claim, (claims, false)), used);
    }

    function test_WorstCaseContinueClaimBatchFitsTheCapAtItsMinimumGas() public {
        IClaimRouter.Claim[] memory claims = worstClaims;
        _coolClaims(claims);
        // The floor continue mode demands, plus room for the router's own work.
        uint256 limit = (claims.length + 1) * router.MIN_ITEM_GAS() + 500_000;
        uint256[] memory amounts = router.claim{ gas: limit }(claims, true);
        for (uint256 i; i < amounts.length; ++i) {
            assertGt(amounts[i], 0, "every worst-case item succeeds at the floor");
        }
        _assertFits(
            "continue claim batch", abi.encodeCall(IClaimRouter.claim, (claims, true)), limit
        );
    }

    function test_MaximumWalletDeploymentFitsTheCap() public {
        ISplitWallet.Payee[] memory payees = maxPayees;
        vm.cool(address(factory));
        uint256 start = gasleft();
        factory.createWallet(payees);
        uint256 used = start - gasleft();
        _assertFits(
            "64-payee wallet deployment", abi.encodeCall(ISplitFactory.createWallet, (payees)), used
        );
    }

    function test_MaximumSignatureReleaseFitsTheCap() public {
        ISplitWallet.Authorization memory a = ISplitWallet.Authorization(
            address(usdc), 0, address(safe), alice, type(uint256).max, 1, block.timestamp
        );
        safe.accept(contractPayeeWallet.releaseDigest(a));
        bytes memory signature = new bytes(4096);
        vm.cool(address(contractPayeeWallet));
        vm.cool(address(usdc));
        vm.cool(address(safe));
        uint256 start = gasleft();
        contractPayeeWallet.releaseWithAuthorization(a, signature);
        uint256 used = start - gasleft();
        _assertFits(
            "4 KiB ERC-1271 signed release",
            abi.encodeCall(ISplitWallet.releaseWithAuthorization, (a, signature)),
            used
        );
    }

    function _coolClaims(IClaimRouter.Claim[] memory claims) internal {
        vm.cool(address(router));
        vm.cool(address(usdc));
        vm.cool(address(resolver));
        for (uint256 i; i < claims.length; ++i) {
            vm.cool(claims[i].wallet);
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

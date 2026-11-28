// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { TokenTransfer } from "src/economics/TokenTransfer.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ClaimRouter } from "src/economics/ClaimRouter.sol";
import { IClaimRouter } from "src/economics/interfaces/IClaimRouter.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { ISplitLedger } from "src/economics/interfaces/ISplitLedger.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import {
    BlocklistToken,
    ClaimReentrantRecipient,
    ArmablePayee,
    GasHungryPayee,
    Mock1271Account
} from "../mocks/economics/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

/// @dev Ported from 6529Stream PR #744 `StreamClaimRouter.t.sol` (adversarial claim batches),
///      adapted to index-addressed payees and the artist-resolved payee kind.
/// @dev A split ledger stand-in for a second claim router, so one batch can mix hostile items
///      with real ones. A plain item whose salt has a mode set behaves as that mode says, in its
///      own frame; any other call is forwarded to the real ledger and its result returned.
///      Modes: 1 reverts with a custom error; 2 returns nothing; 3 returns 31 bytes; 4 returns 64
///      bytes; 5 returns 64 KiB; 6 reverts with 64 KiB; 7 burns all gas; 8 returns a canonical
///      zero; 9 returns 77; 10 burns `burn` gas, then reverts with `failure` if set or returns 1;
///      11 reverts with the error selector 0xffffffff, above every selector the router treats
///      as a shortfall.
contract RoutingLedger {
    address public immutable real;
    mapping(bytes32 salt => uint8) public modeOf;
    uint256 public burn;
    bytes public failure;
    uint256 public releaseCalls;
    uint256 public lastPayee;
    uint256 public releases;

    error WalletFailure(uint256 marker);

    constructor(address real_) {
        real = real_;
    }

    function setMode(bytes32 salt, uint8 mode) external {
        modeOf[salt] = mode;
    }

    function setBurn(uint256 burn_) external {
        burn = burn_;
    }

    function setFailure(bytes calldata failure_) external {
        failure = failure_;
    }

    fallback() external {
        uint8 m;
        uint256 payee;
        if (msg.sig == ISplitWallet.release.selector) {
            bytes32 salt;
            (, salt,, payee) =
                abi.decode(msg.data[4:], (ISplitWallet.Payee[], bytes32, address, uint256));
            m = modeOf[salt];
        }
        if (m == 0) {
            (bool ok, bytes memory result) = real.call(msg.data);
            assembly ("memory-safe") {
                switch ok
                case 0 { revert(add(result, 0x20), mload(result)) }
                default { return(add(result, 0x20), mload(result)) }
            }
        }
        ++releaseCalls;
        lastPayee = payee;
        if (m == 1) revert WalletFailure(123);
        if (m == 7) {
            assembly {
                invalid()
            }
        }
        if (m == 10) {
            uint256 start = gasleft();
            while (start - gasleft() < burn) { }
            bytes memory f = failure;
            if (f.length != 0) {
                assembly ("memory-safe") {
                    revert(add(f, 0x20), mload(f))
                }
            }
            ++releases;
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 32)
            }
        }
        if (m == 11) {
            assembly ("memory-safe") {
                mstore(0, shl(224, 0xffffffff))
                revert(0, 4)
            }
        }
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 77)
            switch m
            case 2 { return(ptr, 0) }
            case 3 { return(ptr, 31) }
            case 4 { return(ptr, 64) }
            case 5 { return(ptr, 65536) }
            case 6 { revert(ptr, 65536) }
            case 8 { mstore(ptr, 0) }
            default { }
            return(ptr, 32)
        }
    }
}

contract ClaimRouterTest is EconomicsBase {
    bytes32 internal constant FAILED =
        keccak256("ClaimFailed(address,address,uint256,uint256,uint256,bytes)");

    struct Failure {
        address wallet;
        address asset;
        uint256 payee;
        uint256 index;
        uint256 size;
        bytes reason;
    }

    address internal caller = makeAddr("caller");
    /// @dev The second router, built on `routing`, for batches with hostile items.
    RoutingLedger internal routing;
    ClaimRouter internal hostileRouter;
    uint256 internal hostileCount;

    function setUp() public override {
        super.setUp();
        routing = new RoutingLedger(address(ledger));
        hostileRouter = new ClaimRouter(ISplitLedger(address(routing)));
    }

    /// @dev The plain claim for payee `payeeIndex` of `wallet` in `asset`.
    function _claim(address wallet, address asset, uint256 payeeIndex)
        internal
        view
        returns (IClaimRouter.Claim memory)
    {
        return IClaimRouter.Claim(_payeesOf(wallet), _salts[wallet], asset, payeeIndex);
    }

    /// @dev A plain item that `routing` answers with `mode` (see {RoutingLedger}).
    function _hostile(uint8 mode) internal returns (IClaimRouter.Claim memory c) {
        bytes32 salt = keccak256(abi.encode("hostile", ++hostileCount));
        routing.setMode(salt, mode);
        c = IClaimRouter.Claim(_list(_fixed(alice, D)), salt, ETH, 0);
    }

    /// @dev The wallet the hostile router names for claim `c`: the documented derivation over
    ///      its ledger, the routing stand-in.
    function _viaWallet(IClaimRouter.Claim memory c) internal view returns (address) {
        return vm.computeCreate2Address(
            keccak256(abi.encode(keccak256(abi.encode(c.payees)), c.salt)),
            ledger.walletInitCodeHash(),
            address(routing)
        );
    }

    function _pair(IClaimRouter.Claim memory a, IClaimRouter.Claim memory b)
        internal
        pure
        returns (IClaimRouter.Claim[] memory claims)
    {
        claims = new IClaimRouter.Claim[](2);
        (claims[0], claims[1]) = (a, b);
    }

    function _single(IClaimRouter.Claim memory a)
        internal
        pure
        returns (IClaimRouter.Claim[] memory claims)
    {
        claims = new IClaimRouter.Claim[](1);
        claims[0] = a;
    }

    /// @dev A one-payee wallet for `account`, made distinct per `salt` by a second payee holding a
    ///      single unit, so many wallets can pay the same account.
    function _walletFor(uint256 salt, address account) internal returns (address w) {
        address filler = address(uint160(uint256(keccak256(abi.encode("filler", salt)))));
        w = _wallet(_list(_fixed(account, D - 1), _fixed(filler, 1)));
    }

    function _one(address wallet, address asset, uint256 payeeIndex)
        internal
        view
        returns (IClaimRouter.Claim[] memory)
    {
        return _single(_claim(wallet, asset, payeeIndex));
    }

    function _two(address first, uint256 firstPayee, address second, uint256 secondPayee)
        internal
        view
        returns (IClaimRouter.Claim[] memory)
    {
        return _pair(_claim(first, ETH, firstPayee), _claim(second, ETH, secondPayee));
    }

    /// Regression: MONEY-4, CALLS-1 (docs/security/internal-review-2026-10.md)
    /// @dev The router declares itself (ERC-165), so the registry and the resolver can refuse it
    ///      as a payout or fee recipient (MONEY-4, CALLS-1).
    function test_SupportsInterface() public view {
        assertTrue(router.supportsInterface(type(IClaimRouter).interfaceId));
        assertTrue(router.supportsInterface(type(IERC165).interfaceId));
        assertFalse(router.supportsInterface(0xffffffff));
        assertFalse(router.supportsInterface(type(IRevenueEscrow).interfaceId));
    }

    function test_ExactSelectorAndEmptyBatches() public {
        assertEq(
            IClaimRouter.claim.selector,
            bytes4(keccak256("claim(((uint256,address,uint32)[],bytes32,address,uint256)[],bool)"))
        );
        IClaimRouter.Claim[] memory empty = new IClaimRouter.Claim[](0);
        assertEq(router.claim(empty, false).length, 0);
        assertEq(router.claim(empty, true).length, 0);
    }

    function test_TwentyEventDiscoveredWalletsClaimETH() public {
        vm.recordLogs();
        for (uint256 i; i < 20; ++i) {
            _walletFor(i, alice);
        }
        (IClaimRouter.Claim[] memory claims, address[] memory wallets) =
            _discover(vm.getRecordedLogs(), alice, ETH);
        assertEq(claims.length, 20);
        for (uint256 i; i < 20; ++i) {
            vm.deal(wallets[i], (i + 1) * 1 ether);
        }
        vm.prank(caller);
        uint256 before = gasleft();
        uint256[] memory amounts = router.claim{ gas: 16_000_000 }(claims, false);
        emit log_named_uint("20-wallet ETH claim gas", before - gasleft());
        uint256 total;
        for (uint256 i; i < 20; ++i) {
            uint256 expected = _share((i + 1) * 1 ether, D - 1, D);
            assertEq(amounts[i], expected);
            assertEq(ledger.released(wallets[i], ETH, claims[i].payee), expected);
            total += expected;
        }
        assertEq(alice.balance, total);
        assertEq(caller.balance, 0);
        assertEq(address(router).balance, 0);
    }

    function test_TwentyWalletsClaimERC20() public {
        vm.recordLogs();
        for (uint256 i; i < 20; ++i) {
            _walletFor(i, alice);
        }
        (IClaimRouter.Claim[] memory claims, address[] memory wallets) =
            _discover(vm.getRecordedLogs(), alice, address(token));
        for (uint256 i; i < 20; ++i) {
            token.mint(wallets[i], (i + 1) * D);
        }
        uint256[] memory amounts = router.claim{ gas: 16_000_000 }(claims, false);
        uint256 total;
        for (uint256 i; i < 20; ++i) {
            assertEq(amounts[i], (i + 1) * (D - 1));
            total += amounts[i];
        }
        assertEq(token.balanceOf(alice), total);
        assertEq(token.balanceOf(address(router)), 0);
    }

    /// @dev A release of 2**128 or more is reported in full (found by mutation testing).
    function test_Claim_ReportsAReleaseOf2To128OrMore() public {
        address w = _solo(alice);
        uint256 amount = (uint256(1) << 128) + 5;
        token.mint(address(w), amount);
        uint256[] memory amounts = router.claim(_one(address(w), address(token), 0), false);
        assertEq(amounts[0], amount);
        assertEq(token.balanceOf(alice), amount);
    }

    function test_BatchesUpToMaxClaimsAndRejectsMore() public {
        uint256 max = router.MAX_CLAIMS();
        assertEq(max, 50);
        IClaimRouter.Claim[] memory claims = new IClaimRouter.Claim[](max);
        IClaimRouter.Claim memory c = _hostile(9);
        c.payee = 5;
        for (uint256 i; i < max; ++i) {
            claims[i] = c;
        }
        uint256[] memory amounts = hostileRouter.claim(claims, false);
        assertEq(amounts.length, max);
        assertEq(routing.releaseCalls(), max);
        assertEq(routing.lastPayee(), 5);
        assertEq(amounts[max - 1], 77);

        IClaimRouter.Claim[] memory tooMany = new IClaimRouter.Claim[](max + 1);
        vm.expectRevert(abi.encodeWithSelector(IClaimRouter.TooManyClaims.selector, max + 1));
        router.claim(tooMany, true);
    }

    /// @dev Review C F5: continue mode carries at most 8 items, so the first item can be offered
    ///      the ceiling within the EIP-7825 cap. Nine are refused; with eight, a gas-burning
    ///      co-payee in the first item is skipped at a 2^24 transaction gas limit (intrinsic and
    ///      calldata gas taken off) and the seven other releases are paid. Fails without the
    ///      change: nine items are accepted, and from eleven no includable limit lets the first
    ///      item reach the ceiling.
    function test_ContinueModeBoundKeepsTheCeilingWithinTheTransactionCap() public {
        assertEq(router.MAX_CONTINUE_CLAIMS(), 8);
        assertLe((router.MAX_CONTINUE_CLAIMS() + 1) * router.SHORTFALL_REVERT_CEILING(), 16_777_216);
        ArmablePayee payee = new ArmablePayee();
        payee.arm(true);
        IClaimRouter.Claim[] memory claims = new IClaimRouter.Claim[](9);
        address shared = _wallet(_list(_fixed(address(payee), 50_000), _fixed(bob, 50_000)));
        vm.deal(address(shared), 1 ether);
        claims[0] = _claim(shared, ETH, _indexOf(shared, address(payee)));
        for (uint256 i = 1; i < 9; ++i) {
            address s = _wallet(_list(_fixed(alice, D)), bytes32(i));
            vm.deal(address(s), 1 ether);
            claims[i] = _claim(s, ETH, 0);
        }
        vm.expectRevert(abi.encodeWithSelector(IClaimRouter.TooManyClaims.selector, 9));
        router.claim(claims, true);
        IReleaseVerifier.Authorization memory a;
        IClaimRouter.SignedClaim[] memory signed = new IClaimRouter.SignedClaim[](9);
        for (uint256 i; i < 9; ++i) {
            signed[i] = IClaimRouter.SignedClaim(a, "", claims[i].payees, claims[i].salt);
        }
        vm.expectRevert(abi.encodeWithSelector(IClaimRouter.TooManyClaims.selector, 9));
        router.claimSigned(signed, true);

        assembly ("memory-safe") {
            mstore(claims, 8)
        }
        bytes memory input = abi.encodeCall(IClaimRouter.claim, (claims, true));
        uint256 intrinsic = 21_000;
        for (uint256 i; i < input.length; ++i) {
            intrinsic += input[i] == 0 ? 4 : 16;
        }
        uint256[] memory amounts = router.claim{ gas: 16_777_216 - intrinsic }(claims, true);
        assertEq(amounts[0], 0, "the burner is skipped");
        for (uint256 i = 1; i < 8; ++i) {
            assertEq(amounts[i], 1 ether);
        }
        assertEq(alice.balance, 7 ether);
    }

    /// @dev Pins the per-item gas floors: a signed item adds the verifier's capped ERC-1271 check
    ///      on top of a plain release, so its floor covers both, and each full batch can be offered
    ///      its floors within the EIP-7825 cap.
    function test_PerItemGasFloorsAreConsistent() public view {
        assertEq(router.MIN_ITEM_GAS(), 200_000);
        assertEq(router.MIN_SIGNED_ITEM_GAS(), 450_000);
        // The ERC-1271 check now forwards all gas (no cap); the floor still covers the 200,000
        // it was sized for on top of a plain release.
        assertGe(router.MIN_SIGNED_ITEM_GAS(), router.MIN_ITEM_GAS() + 200_000);
        assertLe((router.MAX_CLAIMS() + 1) * router.MIN_ITEM_GAS(), 16_777_216);
        assertLe((router.MAX_SIGNED_CLAIMS() + 1) * router.MIN_SIGNED_ITEM_GAS(), 16_777_216);
    }

    function test_ContinueModeRevertsWhenItemsWouldBeStarved() public {
        address first = _solo(alice);
        address second = _solo(bob);
        vm.deal(address(first), 1 ether);
        vm.deal(address(second), 1 ether);
        IClaimRouter.Claim[] memory claims = _two(address(first), 0, address(second), 0);
        // Three shares of about 100k each: below the 200k per-item floor, so the batch reverts rather
        // than "succeeding" with every item out of gas.
        (bool ok, bytes memory data) =
            address(router).call{ gas: 300_000 }(abi.encodeCall(IClaimRouter.claim, (claims, true)));
        assertFalse(ok);
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(data, 32))
        }
        assertEq(selector, IClaimRouter.ClaimInsufficientGas.selector);
        assertEq(alice.balance, 0);
        uint256[] memory amounts = router.claim{ gas: 1_000_000 }(claims, true);
        assertEq(amounts[0] + amounts[1], 2 ether);
    }

    function test_FailedItemContinuesToLaterClaimWithExactReason() public {
        BlocklistToken usdc = new BlocklistToken();
        address first = _solo(alice);
        address later = _solo(bob);
        usdc.mint(address(first), 500);
        vm.deal(address(later), 2 ether);
        usdc.setBlocked(alice, true);
        IClaimRouter.Claim[] memory claims = _two(address(first), 0, address(later), 0);
        claims[0].asset = address(usdc);
        bytes memory reason = abi.encodeWithSelector(
            TokenTransfer.TokenCallFailed.selector, address(usdc), usdc.transfer.selector
        );
        vm.expectEmit(true, true, true, true, address(router));
        emit IClaimRouter.ClaimFailed(address(first), address(usdc), 0, 0, reason.length, reason);
        uint256[] memory amounts = router.claim(claims, true);
        assertEq(amounts[0], 0);
        assertEq(amounts[1], 2 ether);
        assertEq(usdc.balanceOf(address(first)), 500);
        assertEq(bob.balance, 2 ether);
    }

    function test_AtomicLateFailureRollsBackETH() public {
        address first = _solo(alice);
        address empty = _solo(bob);
        vm.deal(address(first), 1 ether);
        bytes memory reason =
            abi.encodeWithSelector(ISplitWallet.NothingToRelease.selector, ETH, uint256(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimRouter.ClaimCallFailed.selector, 1, address(empty), reason.length, reason
            )
        );
        router.claim(_two(address(first), 0, address(empty), 0), false);
        assertEq(address(first).balance, 1 ether);
        assertEq(alice.balance, 0);
        assertEq(ledger.totalReleased(first, ETH), 0);
        assertEq(ledger.recordedObserved(first, ETH), 0);
    }

    function test_AtomicLateFailureRollsBackToken() public {
        address first = _solo(alice);
        address empty = _solo(bob);
        token.mint(address(first), 900);
        IClaimRouter.Claim[] memory claims = _two(address(first), 0, address(empty), 0);
        claims[0].asset = address(token);
        claims[1].asset = address(token);
        bytes memory reason =
            abi.encodeWithSelector(ISplitWallet.NothingToRelease.selector, address(token), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimRouter.ClaimCallFailed.selector, 1, address(empty), reason.length, reason
            )
        );
        router.claim(claims, false);
        assertEq(token.balanceOf(address(first)), 900);
        assertEq(token.balanceOf(alice), 0);
        assertEq(ledger.totalReleased(first, address(token)), 0);
    }

    /// @dev A claim for a wallet nobody has deployed yet fails as an item (the ledger's
    ///      `WalletNotDeployed`, named with the wallet its payees and salt derive), and pays
    ///      nothing, even with funds waiting at the predicted address.
    function test_UndeployedWalletIsAFailure() public {
        address predicted = _remember(_list(_fixed(bob, D)), bytes32(uint256(77)));
        vm.deal(predicted, 1 ether);
        address real = _solo(alice);
        vm.deal(real, 1 ether);
        bytes memory reason =
            abi.encodeWithSelector(ISplitWallet.WalletNotDeployed.selector, predicted);
        vm.expectEmit(true, true, true, true, address(router));
        emit IClaimRouter.ClaimFailed(predicted, ETH, 0, 0, reason.length, reason);
        uint256[] memory amounts = router.claim(_two(predicted, 0, real, 0), true);
        assertEq(amounts[0], 0);
        assertEq(amounts[1], 1 ether);
        assertEq(predicted.balance, 1 ether);
        assertEq(bob.balance, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimRouter.ClaimCallFailed.selector, 0, predicted, reason.length, reason
            )
        );
        router.claim(_one(predicted, ETH, 0), false);
    }

    function test_MalformedSuccessfulReturnsNeverCountAsRelease() public {
        for (uint8 mode = 2; mode <= 5; ++mode) {
            uint256 calls = routing.releaseCalls();
            vm.recordLogs();
            uint256[] memory amounts = hostileRouter.claim(_single(_hostile(mode)), true);
            assertEq(amounts[0], 0);
            Failure memory f = _onlyFailure(vm.getRecordedLogs(), address(hostileRouter));
            uint256 size = mode == 2 ? 0 : mode == 3 ? 31 : mode == 4 ? 64 : 65536;
            assertEq(f.size, size);
            assertEq(
                f.reason, abi.encodeWithSelector(IClaimRouter.InvalidClaimReturnData.selector, size)
            );
            // The callee's own side effect stands; only the reported amount is refused.
            assertEq(routing.releaseCalls(), calls + 1);
        }
    }

    function test_AtomicMalformedReturnRollsBackEarlierMoneyAndCalleeState() public {
        address first = _solo(alice);
        vm.deal(address(first), 1 ether);
        IClaimRouter.Claim memory hostile = _hostile(4);
        bytes memory reason =
            abi.encodeWithSelector(IClaimRouter.InvalidClaimReturnData.selector, 64);
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimRouter.ClaimCallFailed.selector, 1, _viaWallet(hostile), 64, reason
            )
        );
        hostileRouter.claim(_pair(_claim(first, ETH, 0), hostile), false);
        assertEq(address(first).balance, 1 ether);
        assertEq(alice.balance, 0);
        assertEq(routing.releaseCalls(), 0);
    }

    function test_RevertBombReasonIsBoundedAndLaterClaimSucceeds() public {
        _hostileThenReal(6);
    }

    function test_ReturnBombIsBoundedAndLaterClaimSucceeds() public {
        _hostileThenReal(5);
    }

    /// Regression: MONEY-3 (docs/security/internal-review-2026-10.md)
    /// @dev A target that burns all the gas it gets (`INVALID`) cannot be told apart from an item
    ///      that needs more gas: offered less than the shortfall ceiling, it reverts the
    ///      continue-mode batch and names its index (MONEY-3). It never starves a later item
    ///      silently, and without it the batch pays.
    function test_GasBurnerRevertsAContinueBatchAndNamesItsIndex() public {
        IClaimRouter.Claim memory hostile = _hostile(7);
        address real = _solo(alice);
        vm.deal(address(real), 1 ether);
        (bool ok, bytes memory data) = address(hostileRouter).call{ gas: 1_500_000 }(
            abi.encodeCall(IClaimRouter.claim, (_pair(hostile, _claim(real, ETH, 0)), true))
        );
        assertFalse(ok);
        assertEq(_selector(data), IClaimRouter.ClaimInsufficientGas.selector);
        (uint256 index,) = abi.decode(_args(data), (uint256, uint256));
        assertEq(index, 0);
        assertEq(alice.balance, 0);
        assertEq(router.claim{ gas: 1_500_000 }(_one(address(real), ETH, 0), true)[0], 1 ether);
    }

    function test_AtomicRevertBombHasBoundedErrorAndRollsBack() public {
        address first = _solo(alice);
        vm.deal(address(first), 1 ether);
        (bool ok, bytes memory data) = address(hostileRouter)
            .call(
                abi.encodeCall(
                    IClaimRouter.claim, (_pair(_claim(first, ETH, 0), _hostile(6)), false)
                )
            );
        assertFalse(ok);
        // selector + index, wallet, size, offset + length + 256 bytes of reason
        assertEq(data.length, 4 + 4 * 32 + 32 + 256);
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(data, 32))
        }
        assertEq(selector, IClaimRouter.ClaimCallFailed.selector);
        assertEq(address(first).balance, 1 ether);
        assertEq(alice.balance, 0);
    }

    function test_AtomicGasBurnerRevertsTheWholeBatch() public {
        address first = _solo(alice);
        vm.deal(address(first), 1 ether);
        (bool ok,) = address(hostileRouter).call{ gas: 2_000_000 }(
            abi.encodeCall(IClaimRouter.claim, (_pair(_claim(first, ETH, 0), _hostile(7)), false))
        );
        assertFalse(ok);
        assertEq(address(first).balance, 1 ether);
    }

    /// @dev An atomic batch forwards all the gas left to its item, not the continue-mode share:
    ///      at a limit where that share (about half the gas) is short of the item's need and
    ///      continue mode reverts, the atomic batch pays (found by mutation testing).
    function test_Claim_AtomicModeGivesAnItemAllTheGasLeft() public {
        routing.setBurn(400_000);
        IClaimRouter.Claim[] memory claims = _single(_hostile(10));

        (bool ok, bytes memory data) = address(hostileRouter).call{ gas: 600_000 }(
            abi.encodeCall(IClaimRouter.claim, (claims, true))
        );
        assertFalse(ok, "continue mode: the share is short");
        assertEq(_selector(data), IClaimRouter.ClaimInsufficientGas.selector);

        (ok, data) = address(hostileRouter).call{ gas: 600_000 }(
            abi.encodeCall(IClaimRouter.claim, (claims, false))
        );
        assertTrue(ok, "atomic mode: all the gas left is enough");
        assertEq(abi.decode(data, (uint256[]))[0], 1);
        assertEq(routing.releases(), 1);
    }

    // ------------------------------------------------------------------ gas estimation (MONEY-3)

    /// @dev The least gas at which `input` does not revert, found by binary search as
    ///      `eth_estimateGas` does, and the output at that gas. Every probe runs from the same
    ///      state.
    function _estimate(bytes memory input)
        internal
        returns (uint256 estimate, bytes memory output)
    {
        return _estimate(address(router), input);
    }

    function _estimate(address target, bytes memory input)
        internal
        returns (uint256 estimate, bytes memory output)
    {
        uint256 lo = 21_000;
        uint256 hi = 10_000_000;
        while (hi - lo > 500) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            (bool ok,) = target.call{ gas: mid }(input);
            vm.revertToStateAndDelete(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
        bool success;
        (success, output) = target.call{ gas: hi }(input);
        assertTrue(success, "the batch succeeds at its estimate");
        estimate = hi;
    }

    function _selector(bytes memory data) internal pure returns (bytes4 selector) {
        assembly ("memory-safe") {
            selector := mload(add(data, 32))
        }
    }

    /// Regression: MONEY-3 (docs/security/internal-review-2026-10.md)
    /// @dev MONEY-3 regression (the review's PoC): an item that needs more gas than its minimum
    ///      share, as a first release does under Glamsterdam, is paid at the gas limit estimation
    ///      settles on. It used to fail silently there (`ClaimFailed`, the batch succeeding).
    function test_ContinueModeAtItsEstimatePaysAnItemAboveItsMinimum() public {
        GasHungryPayee payee = new GasHungryPayee();
        payee.setBurn(426_000); // 3 slots and an account under Glamsterdam, minus Prague
        address w = _wallet(_list(_fixed(address(payee), 20_000), _artist(ARTIST, 80_000)));
        vm.deal(address(w), 1 ether);
        bytes memory input = abi.encodeCall(
            IClaimRouter.claim, (_one(address(w), ETH, _indexOf(w, address(payee))), true)
        );
        vm.recordLogs();
        (uint256 estimate, bytes memory output) = _estimate(input);
        assertEq(abi.decode(output, (uint256[]))[0], 0.2 ether, "paid at the estimate");
        assertEq(address(payee).balance, 0.2 ether);
        assertGt(estimate, 2 * router.MIN_ITEM_GAS(), "above what the minimum alone asks");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != FAILED, "no item failed at the estimate");
        }
    }

    /// Regression: MONEY-3 (docs/security/internal-review-2026-10.md)
    /// @dev MONEY-3: an item whose wallet frame runs out of the gas it was given reverts the
    ///      continue-mode batch with `ClaimInsufficientGas`, so estimation raises the limit,
    ///      instead of reporting a failure the caller paid for. Given enough, it is paid.
    function test_ContinueModeRevertsWhenAnItemRunsOutOfGas() public {
        routing.setBurn(400_000);
        address real = _solo(alice);
        vm.deal(address(real), 1 ether);
        bytes memory input =
            abi.encodeCall(IClaimRouter.claim, (_pair(_claim(real, ETH, 0), _hostile(10)), true));
        // About 340,000 for the second item: above the 200,000 minimum, below its need.
        (bool ok, bytes memory data) = address(hostileRouter).call{ gas: 800_000 }(input);
        assertFalse(ok);
        assertEq(_selector(data), IClaimRouter.ClaimInsufficientGas.selector);
        (uint256 index, uint256 available) = abi.decode(_args(data), (uint256, uint256));
        assertEq(index, 1);
        assertGe(available, router.MIN_ITEM_GAS());
        assertLt(available, 400_000);
        assertEq(alice.balance, 0, "the whole batch reverted");

        (, bytes memory output) = _estimate(address(hostileRouter), input);
        uint256[] memory amounts = abi.decode(output, (uint256[]));
        assertEq(amounts[0], 1 ether);
        assertEq(amounts[1], 1);
        assertEq(routing.releases(), 1);
    }

    /// Regression: MONEY-3 (docs/security/internal-review-2026-10.md)
    /// @dev MONEY-3, signed items: the same holds for a signed release whose recipient's receipt
    ///      costs more than the signed minimum leaves.
    function test_ContinueSignedAtItsEstimatePaysAnItemAboveItsMinimum() public {
        GasHungryPayee payee = new GasHungryPayee();
        payee.setBurn(426_000);
        address w = _solo(alice);
        vm.deal(address(w), 1 ether);
        IReleaseVerifier.Authorization memory a =
            _auth(w, ETH, 0, alice, address(payee), type(uint256).max, 3);
        IClaimRouter.SignedClaim[] memory one = new IClaimRouter.SignedClaim[](1);
        one[0] = IClaimRouter.SignedClaim(a, _sign(alicePk, a), _payeesOf(w), _salts[w]);
        (, bytes memory output) = _estimate(abi.encodeCall(IClaimRouter.claimSigned, (one, true)));
        assertEq(abi.decode(output, (uint256[]))[0], 1 ether);
        assertEq(address(payee).balance, 1 ether);
        assertTrue(verifier.nonceUsed(alice, 3));
    }

    /// @dev A failure that leaves the item's gas unspent is not a gas shortfall: continue mode
    ///      reports it and goes on, at any gas that offers each item its minimum.
    function test_ContinueModeStillSkipsAnItemThatFailsWithGasLeft() public {
        address empty = _solo(bob);
        address real = _solo(alice);
        vm.deal(address(real), 1 ether);
        bytes memory reason = abi.encodeWithSelector(ISplitWallet.NothingToRelease.selector, ETH, 0);
        vm.expectEmit(true, true, true, true, address(router));
        emit IClaimRouter.ClaimFailed(address(empty), ETH, 0, 0, reason.length, reason);
        uint256[] memory amounts =
            router.claim{ gas: 700_000 }(_two(address(empty), 0, address(real), 0), true);
        assertEq(amounts[0], 0);
        assertEq(amounts[1], 1 ether);
    }

    /// @dev Only `BoundedCallInsufficientGas` marks a shortfall; an item failing with any other
    ///      error, whatever its selector, is skipped.
    function test_ContinueModeSkipsAnItemFailingWithAHighSelector() public {
        IClaimRouter.Claim memory odd = _hostile(11);
        address real = _solo(alice);
        vm.deal(address(real), 1 ether);
        bytes memory reason = hex"ffffffff";
        vm.expectEmit(true, true, true, true, address(hostileRouter));
        emit IClaimRouter.ClaimFailed(_viaWallet(odd), ETH, 0, 0, reason.length, reason);
        uint256[] memory amounts =
            hostileRouter.claim{ gas: 700_000 }(_pair(odd, _claim(real, ETH, 0)), true);
        assertEq(amounts[0], 0);
        assertEq(amounts[1], 1 ether);
    }

    // ------------------------------------------------------------------ the shortfall ceiling

    /// @dev `real` (alice, 1 ETH) first, then a target that burns everything it is given.
    function _realThenBurner() internal returns (bytes memory input, address real) {
        real = _solo(alice);
        vm.deal(address(real), 1 ether);
        input = abi.encodeCall(IClaimRouter.claim, (_pair(_claim(real, ETH, 0), _hostile(7)), true));
    }

    /// @dev Below the ceiling, a burnt item reverts the batch (estimation raises the limit);
    ///      offered at least the ceiling, it is skipped as any other failure and the rest pays.
    function test_ShortfallRevertsOnlyBelowTheCeiling() public {
        assertEq(router.SHORTFALL_REVERT_CEILING(), 1_500_000);
        (bytes memory input,) = _realThenBurner();
        // The burner, second of two, is offered about half of what is left: about 1.27M here.
        (bool ok, bytes memory data) = address(hostileRouter).call{ gas: 2_600_000 }(input);
        assertFalse(ok);
        assertEq(_selector(data), IClaimRouter.ClaimInsufficientGas.selector);
        (uint256 index, uint256 available) = abi.decode(_args(data), (uint256, uint256));
        assertEq(index, 1);
        assertLt(available, router.SHORTFALL_REVERT_CEILING());
        assertEq(alice.balance, 0);

        // About 1.67M: at least the ceiling, so the burner is skipped and alice is paid.
        vm.recordLogs();
        (ok, data) = address(hostileRouter).call{ gas: 3_400_000 }(input);
        assertTrue(ok);
        uint256[] memory amounts = abi.decode(data, (uint256[]));
        assertEq(amounts[0], 1 ether);
        assertEq(amounts[1], 0);
        assertEq(alice.balance, 1 ether);
        Failure memory f = _onlyFailure(vm.getRecordedLogs(), address(hostileRouter));
        assertEq(f.index, 1);
        assertEq(f.size, 0, "INVALID returns no data");
    }

    /// @dev Review L-1 regression (the reviewer's PoC): a fixed co-payee arms a gas-burning
    ///      `receive` after the keeper estimated. Offered at least the ceiling, its item is
    ///      skipped and the seven unrelated releases in the batch are paid; the batch's own
    ///      estimate does the same. Below the ceiling it still reverts the batch: the documented
    ///      residual that keepers handle by simulating privately and splitting batches.
    function test_ArmedCoPayeeIsSkippedOnceItsItemGetsTheCeiling() public {
        ArmablePayee payee = new ArmablePayee();
        IClaimRouter.Claim[] memory claims = new IClaimRouter.Claim[](8);
        for (uint256 i; i < 7; ++i) {
            address s = _wallet(_list(_fixed(alice, D)), bytes32(i + 1));
            vm.deal(address(s), 1 ether);
            claims[i] = _claim(s, ETH, 0);
        }
        address shared = _wallet(_list(_fixed(address(payee), 50_000), _fixed(bob, 50_000)));
        vm.deal(address(shared), 1 ether);
        claims[7] = _claim(shared, ETH, _indexOf(shared, address(payee)));
        bytes memory input = abi.encodeCall(IClaimRouter.claim, (claims, true));

        // Unarmed, the keeper's estimate pays every item.
        uint256 snap = vm.snapshotState();
        (uint256 unarmedEstimate, bytes memory output) = _estimate(input);
        assertEq(abi.decode(output, (uint256[]))[7], 0.5 ether);
        vm.revertToStateAndDelete(snap);

        payee.arm(true);
        // The residual: at the unarmed estimate, the armed item is below the ceiling.
        snap = vm.snapshotState();
        (bool ok, bytes memory data) = address(router).call{ gas: unarmedEstimate }(input);
        assertFalse(ok);
        assertEq(_selector(data), IClaimRouter.ClaimInsufficientGas.selector);
        vm.revertToStateAndDelete(snap);

        // With 5M, the armed item is offered more than the ceiling: skipped, the rest paid.
        snap = vm.snapshotState();
        uint256[] memory amounts = router.claim{ gas: 5_000_000 }(claims, true);
        assertEq(amounts[7], 0);
        assertEq(alice.balance, 7 ether, "seven unrelated releases paid");
        assertEq(address(payee).balance, 0);
        vm.revertToStateAndDelete(snap);

        // Re-estimated with the item armed, the batch settles where the item is skipped.
        (, output) = _estimate(input);
        amounts = abi.decode(output, (uint256[]));
        assertEq(amounts[7], 0);
        assertEq(alice.balance, 7 ether);
    }

    /// @dev An item that fails after spending most of its gas, but not all but the 1/64
    ///      reserve, failed with gas to spare: it is skipped, never a shortfall.
    function test_ItemThatSpendsMostButNotAllOfItsGasIsSkipped() public {
        routing.setBurn(400_000);
        routing.setFailure(abi.encodeWithSignature("Error(string)", "refused"));
        address real = _solo(alice);
        vm.deal(address(real), 1 ether);
        // The hungry item, second of two, is offered about 490,000 and spends about 82% of it.
        vm.recordLogs();
        uint256[] memory amounts =
            hostileRouter.claim{ gas: 1_000_000 }(_pair(_claim(real, ETH, 0), _hostile(10)), true);
        assertEq(amounts[0], 1 ether);
        assertEq(amounts[1], 0);
        Failure memory f = _onlyFailure(vm.getRecordedLogs(), address(hostileRouter));
        assertEq(f.index, 1);
        assertEq(f.reason, abi.encodeWithSignature("Error(string)", "refused"));
    }

    /// @dev Review L-2: an item whose ERC-1271 check could not get its gas
    ///      (`BoundedCallInsufficientGas`) spent little, yet ran short: below the ceiling it
    ///      reverts the batch so estimation raises the limit; from the ceiling up it is skipped.
    function test_ERC1271ShortfallRevertsBelowTheCeiling() public {
        // The error's argument (the gas the check asked for) is not read; only its selector is.
        bytes memory failure =
            abi.encodeWithSelector(BoundedCall.BoundedCallInsufficientGas.selector, 200_000);
        routing.setFailure(failure);
        IClaimRouter.Claim memory starved = _hostile(10);
        bytes memory input = abi.encodeCall(IClaimRouter.claim, (_single(starved), true));
        (bool ok, bytes memory data) = address(hostileRouter).call{ gas: 1_000_000 }(input);
        assertFalse(ok);
        assertEq(_selector(data), IClaimRouter.ClaimInsufficientGas.selector);

        vm.expectEmit(true, true, true, true, address(hostileRouter));
        emit IClaimRouter.ClaimFailed(_viaWallet(starved), ETH, 0, 0, failure.length, failure);
        uint256[] memory amounts = hostileRouter.claim{ gas: 3_200_000 }(_single(starved), true);
        assertEq(amounts[0], 0);
    }

    function _args(bytes memory data) internal pure returns (bytes memory args) {
        args = new bytes(data.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = data[i + 4];
        }
    }

    function test_ZeroSuccessIsNotAFailureAndRepeatPaysOnce() public {
        vm.recordLogs();
        uint256[] memory zero = hostileRouter.claim(_single(_hostile(8)), true);
        assertEq(zero[0], 0);
        assertEq(vm.getRecordedLogs().length, 0);

        address real = _solo(alice);
        vm.deal(address(real), 1 ether);
        vm.recordLogs();
        uint256[] memory repeated = router.claim(_two(address(real), 0, address(real), 0), true);
        assertEq(repeated[0], 1 ether);
        assertEq(repeated[1], 0);
        assertEq(_onlyFailure(vm.getRecordedLogs()).index, 1);
        assertEq(alice.balance, 1 ether);
    }

    function test_ReentrantRecipientCannotDoubleClaimOrRedirect() public {
        ClaimReentrantRecipient recipient = new ClaimReentrantRecipient(router);
        address first = _solo(address(recipient));
        // The recipient sorts first, so it is payee 0 in both wallets.
        address second = _wallet(
            _list(_fixed(address(recipient), D - 1), _fixed(address(type(uint160).max), 1))
        );
        recipient.configure(_payeesOf(first), _payeesOf(second));
        vm.deal(address(first), 1 ether);
        vm.deal(address(second), 2 ether);
        assertEq(_indexOf(second, address(recipient)), 0);
        uint256[] memory amounts = router.claim(_one(address(first), ETH, 0), false);
        assertEq(amounts[0], 1 ether);
        // The first wallet's guard refuses the nested claim; the second is an independent
        // entitlement and pays the same account.
        assertEq(recipient.nestedFirst(), 0);
        assertEq(recipient.nestedSecond(), _share(2 ether, D - 1, D));
        assertEq(address(recipient).balance, 1 ether + _share(2 ether, D - 1, D));
        assertEq(address(router).balance, 0);
        assertEq(ledger.totalReleased(first, ETH), 1 ether);
    }

    function test_RejectsValueUnknownSelectorsAndRecipientChoice() public {
        vm.deal(address(this), 1 ether);
        (bool received,) = address(router).call{ value: 1 }("");
        assertFalse(received);
        (bool owner,) = address(router).call(abi.encodeWithSignature("owner()"));
        assertFalse(owner);
        (bool redirect,) = address(router)
            .call(abi.encodeWithSignature("releaseTo(address,uint256,address)", ETH, 0, caller));
        assertFalse(redirect);
        IClaimRouter.Claim[] memory empty = new IClaimRouter.Claim[](0);
        (bool payableClaim,) =
            address(router).call{ value: 1 }(abi.encodeCall(IClaimRouter.claim, (empty, false)));
        assertFalse(payableClaim);
        assertEq(address(router).balance, 0);
    }

    function test_PlainArtistItemsFailAndContinueModeSkipsThem() public {
        address w = _trio();
        uint256 iArtist = _artistIndex(w, ARTIST);
        vm.deal(address(w), 10 ether);
        IClaimRouter.Claim[] memory claims = new IClaimRouter.Claim[](2);
        claims[0] = _claim(w, ETH, iArtist);
        claims[1] = _claim(w, ETH, _indexOf(w, bob));
        bytes memory reason = abi.encodeWithSelector(
            ISplitWallet.NotPayoutAddress.selector, address(router), artistPayout
        );
        vm.expectEmit(true, true, true, true, address(router));
        emit IClaimRouter.ClaimFailed(address(w), ETH, iArtist, 0, reason.length, reason);
        vm.prank(caller);
        uint256[] memory amounts = router.claim(claims, true);
        assertEq(amounts[0], 0);
        assertEq(amounts[1], 3 ether);
        assertEq(artistPayout.balance, 0);
    }

    function test_SignedClaimsPayTheCurrentResolvedArtistAcrossWallets() public {
        address recovered = vm.addr(0xBEEF);
        resolver.set(ARTIST, recovered);
        IClaimRouter.SignedClaim[] memory claims = new IClaimRouter.SignedClaim[](3);
        for (uint256 i; i < 3; ++i) {
            address w = _wallet(
                _list(_fixed(address(uint160(0xD00 + i)), 50_000), _artist(ARTIST, 50_000))
            );
            vm.deal(address(w), 2 ether);
            IReleaseVerifier.Authorization memory a = _auth(
                w, ETH, _artistIndex(w, ARTIST), recovered, recovered, type(uint256).max, i
            );
            claims[i] = IClaimRouter.SignedClaim(a, _sign(0xBEEF, a), _payeesOf(w), _salts[w]);
        }
        vm.prank(caller);
        uint256[] memory amounts = router.claimSigned(claims, false);
        assertEq(amounts[0] + amounts[1] + amounts[2], 3 ether);
        assertEq(recovered.balance, 3 ether);
        assertEq(caller.balance, 0);
        assertEq(address(router).balance, 0);
    }

    function test_SignedClaimFailuresFollowTheMode() public {
        address w = _trio();
        vm.deal(address(w), 10 ether);
        IReleaseVerifier.Authorization memory a =
            _auth(w, ETH, _artistIndex(w, ARTIST), artistPayout, artistPayout, 1 ether, 1);
        IClaimRouter.SignedClaim[] memory claims = new IClaimRouter.SignedClaim[](2);
        claims[0] = IClaimRouter.SignedClaim(a, _sign(bobPk, a), _payeesOf(w), _salts[w]);
        claims[1] = IClaimRouter.SignedClaim(a, _sign(artistPk, a), _payeesOf(w), _salts[w]);
        bytes memory reason =
            abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, artistPayout);
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimRouter.ClaimCallFailed.selector, 0, address(w), reason.length, reason
            )
        );
        router.claimSigned(claims, false);
        vm.expectEmit(true, true, true, true, address(router));
        emit IClaimRouter.ClaimFailed(address(w), ETH, a.payee, 0, reason.length, reason);
        uint256[] memory amounts = router.claimSigned(claims, true);
        assertEq(amounts[0], 0);
        assertEq(amounts[1], 1 ether);
    }

    function test_SignedBatchesAreCappedAndNeedTheirMinimumGas() public {
        uint256 max = router.MAX_SIGNED_CLAIMS();
        assertEq(max, 20);
        IClaimRouter.SignedClaim[] memory tooMany = new IClaimRouter.SignedClaim[](max + 1);
        vm.expectRevert(abi.encodeWithSelector(IClaimRouter.TooManyClaims.selector, max + 1));
        router.claimSigned(tooMany, true);

        address w = _solo(alice);
        vm.deal(address(w), 1 ether);
        IReleaseVerifier.Authorization memory a = _auth(w, ETH, 0, alice, alice, 1 ether, 1);
        IClaimRouter.SignedClaim[] memory one = new IClaimRouter.SignedClaim[](1);
        one[0] = IClaimRouter.SignedClaim(a, _sign(alicePk, a), _payeesOf(w), _salts[w]);
        (bool ok, bytes memory data) = address(router).call{ gas: 600_000 }(
            abi.encodeCall(IClaimRouter.claimSigned, (one, true))
        );
        assertFalse(ok);
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(data, 32))
        }
        assertEq(selector, IClaimRouter.ClaimInsufficientGas.selector);
        assertEq(router.claimSigned{ gas: 1_200_000 }(one, true)[0], 1 ether);
    }

    /// @dev Ported from the review: a resolver answer only ever steers the artist's own index. A
    ///      gas-burning artist payout cannot block fixed payees in the same batch.
    function test_ResolverOnlyReachesTheArtistIndex() public {
        address w = _trio();
        uint256 iArtist = _artistIndex(w, ARTIST);
        vm.deal(address(w), 10 ether);
        // Point the artist at alice: alice pulls the artist's 20% on top, never more.
        resolver.set(ARTIST, alice);
        vm.prank(alice);
        assertEq(_release(w, ETH, iArtist), 2 ether);
        assertEq(_release(w, ETH, _indexOf(w, alice)), 5 ether);
        assertEq(alice.balance, 7 ether);

        Mock1271Account burner = new Mock1271Account();
        burner.setBurn(10_000_000);
        resolver.set(ARTIST, address(burner));
        vm.deal(address(w), address(w).balance + 10 ether);
        IReleaseVerifier.Authorization memory a =
            _auth(w, ETH, iArtist, address(burner), address(burner), 1 ether, 1);
        IClaimRouter.SignedClaim[] memory signed = new IClaimRouter.SignedClaim[](1);
        signed[0] = IClaimRouter.SignedClaim(a, "", _payeesOf(w), _salts[w]);
        // 4M gas offers the item 2M, above the shortfall ceiling, so the burner is skipped
        // whether its check is capped (it then fails with gas to spare) or given all the gas.
        assertEq(router.claimSigned{ gas: 4_000_000 }(signed, true)[0], 0);
        assertEq(router.claim(_one(address(w), ETH, _indexOf(w, bob)), true)[0], 6 ether);
    }

    function test_UnknownPayeeFailsOnlyItsItem() public {
        address w = _solo(alice);
        vm.deal(address(w), 1 ether);
        IClaimRouter.Claim[] memory claims = _two(address(w), 4, address(w), 0);
        bytes memory reason = abi.encodeWithSelector(ISplitWallet.UnknownPayee.selector, 4);
        vm.expectEmit(true, true, true, true, address(router));
        emit IClaimRouter.ClaimFailed(address(w), ETH, 4, 0, reason.length, reason);
        uint256[] memory amounts = router.claim(claims, true);
        assertEq(amounts[1], 1 ether);
    }

    function test_MixedAssetsAndPayeesInOneBatch() public {
        address w = _trio();
        vm.deal(address(w), 10 ether);
        token.mint(address(w), 1000);
        IClaimRouter.Claim[] memory claims = new IClaimRouter.Claim[](4);
        claims[0] = _claim(w, ETH, _indexOf(w, alice));
        claims[1] = _claim(w, address(token), _indexOf(w, alice));
        claims[2] = _claim(w, ETH, _indexOf(w, bob));
        claims[3] = _claim(w, address(token), _indexOf(w, bob));
        uint256[] memory amounts = router.claim(claims, false);
        assertEq(amounts[0], 5 ether);
        assertEq(amounts[1], 500);
        assertEq(amounts[2], 3 ether);
        assertEq(amounts[3], 300);
        assertEq(token.balanceOf(bob), 300);
    }

    function _hostileThenReal(uint8 mode) internal {
        IClaimRouter.Claim memory hostile = _hostile(mode);
        address real = _solo(alice);
        vm.deal(address(real), 1 ether);
        bytes memory input =
            abi.encodeCall(IClaimRouter.claim, (_pair(hostile, _claim(real, ETH, 0)), true));
        vm.recordLogs();
        (bool success, bytes memory output) = address(hostileRouter).call{ gas: 1_500_000 }(input);
        assertTrue(success);
        uint256[] memory amounts = abi.decode(output, (uint256[]));
        assertEq(amounts[0], 0);
        assertEq(amounts[1], 1 ether);
        assertEq(alice.balance, 1 ether);
        Failure memory f = _onlyFailure(vm.getRecordedLogs(), address(hostileRouter));
        assertEq(f.index, 0);
        assertEq(f.wallet, _viaWallet(hostile));
        if (mode == 6) {
            assertEq(f.size, 65536);
            assertEq(f.reason.length, 256);
            uint256 firstWord;
            bytes memory reason = f.reason;
            assembly ("memory-safe") {
                firstWord := mload(add(reason, 32))
            }
            assertEq(firstWord, 77);
        }
        if (mode == 5) {
            assertEq(f.size, 65536);
            assertEq(f.reason.length, 36);
        }
        if (mode == 7) {
            assertEq(f.size, 0);
            assertEq(f.reason.length, 0);
        }
    }

    /// @dev Builds claims from `WalletCreated` events alone: the event carries the salt and the
    ///      payee list, everything a claim needs.
    function _discover(Vm.Log[] memory logs, address account, address asset)
        internal
        view
        returns (IClaimRouter.Claim[] memory claims, address[] memory wallets)
    {
        bytes32 created = ISplitFactory.WalletCreated.selector;
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == created) ++count;
        }
        claims = new IClaimRouter.Claim[](count);
        wallets = new address[](count);
        uint256 cursor;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(factory) || logs[i].topics[0] != created) continue;
            (bytes32 salt, ISplitWallet.Payee[] memory payees) =
                abi.decode(logs[i].data, (bytes32, ISplitWallet.Payee[]));
            uint256 index = type(uint256).max;
            for (uint256 j; j < payees.length; ++j) {
                if (payees[j].account == account) index = j;
            }
            require(index != type(uint256).max, "event-discovered entitlement");
            wallets[cursor] = address(uint160(uint256(logs[i].topics[1])));
            claims[cursor++] = IClaimRouter.Claim(payees, salt, asset, index);
        }
    }

    function _onlyFailure(Vm.Log[] memory logs) internal view returns (Failure memory result) {
        return _onlyFailure(logs, address(router));
    }

    function _onlyFailure(Vm.Log[] memory logs, address emitter)
        internal
        pure
        returns (Failure memory result)
    {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == FAILED) {
                result = _failure(logs[i], emitter);
                ++count;
            }
        }
        assertEq(count, 1, "exactly one router failure event");
    }

    function _failure(Vm.Log memory log) internal view returns (Failure memory f) {
        return _failure(log, address(router));
    }

    function _failure(Vm.Log memory log, address emitter) internal pure returns (Failure memory f) {
        assertEq(log.emitter, emitter);
        assertEq(log.topics.length, 4);
        assertEq(log.topics[0], FAILED);
        f.wallet = address(uint160(uint256(log.topics[1])));
        f.asset = address(uint160(uint256(log.topics[2])));
        f.payee = uint256(log.topics[3]);
        (f.index, f.size, f.reason) = abi.decode(log.data, (uint256, uint256, bytes));
    }

    function _share(uint256 amount, uint256 share, uint256 denominator)
        internal
        pure
        returns (uint256)
    {
        return amount * share / denominator;
    }
}

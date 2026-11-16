// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SplitLedger } from "src/economics/SplitLedger.sol";
import { IArtistPayoutResolver } from "src/economics/interfaces/IArtistPayoutResolver.sol";
import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { ISplitLedger } from "src/economics/interfaces/ISplitLedger.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { Burner, GasRuleAssertions } from "../helpers/GasRule.sol";
import {
    MockArtistResolver,
    MockERC20,
    Mock1271Account,
    RejectingRecipient
} from "../mocks/economics/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

/// @dev A contract with neither `receive` nor `fallback`: it can neither take ETH nor call.
contract MutePayee { }

/// @dev An ERC-20 whose `transfer` first burns `burn` gas (out of gas for real if it cannot).
contract BurningToken is MockERC20("Burn", "BRN") {
    uint256 public burn;

    function setBurn(uint256 burn_) external {
        burn = burn_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 b = burn;
        if (gasleft() < b) {
            assembly ("memory-safe") {
                invalid()
            }
        }
        uint256 stop = gasleft() - b;
        while (gasleft() > stop) { }
        return super.transfer(to, amount);
    }
}

/// @notice The split ledger under the gas rule (PLAN rule 2): every dependency of a release (a
///         payee, a token, the payout resolver, a signer's ERC-1271 check) costing 1x to 100x its
///         base gives the same release, and running short reverts with a shortfall, never with a
///         refusal (`ETHTransferFailed`, `TokenCallFailed`, `PayoutUnresolved`,
///         `InvalidSignature`) that would read as the dependency's answer. Also: payees that
///         revert, cannot receive, or are fresh accounts, each affecting only their own share.
/// @dev Fails on the factory-and-wallet design: there a release reached the payee directly, so a
///      payee running short gave `ETHTransferFailed`, the resolver's code-hash pin and a capped
///      ERC-1271 check (200,000 gas) refused the 100x cases, and nothing reported a shortfall.
contract SplitLedgerStressTest is EconomicsBase, GasRuleAssertions {
    /// @dev About what a Safe's `receive` costs; 10x is 63,000.
    uint256 internal constant SAFE_RECEIVE = 6_300;

    address internal sink = makeAddr("stressSink");

    /// @dev Every gas limit from 1/8 of the least that pays, up to it, gives the full outcome or
    ///      one of `allowed` (shortfall errors) or an empty revert (the ledger's own out-of-gas),
    ///      and at least one gives an allowed shortfall.
    function _sweep(address from, address target, bytes memory data, bytes[] memory allowed)
        internal
    {
        Outcome memory full = _try(from, target, data, 0);
        assertTrue(full.ok, "the release pays with ample gas");
        uint256 low;
        uint256 high = 30_000_000;
        while (low + 1 < high) {
            uint256 mid = (low + high) / 2;
            if (_try(from, target, data, mid).ok) high = mid;
            else low = mid;
        }
        uint256 shortfalls;
        for (uint256 i = 1; i <= GAS_RULE_SAMPLES; ++i) {
            uint256 g = high - (high * i * i) / (GAS_RULE_SAMPLES * GAS_RULE_SAMPLES * 8 / 7);
            if (g >= high) g = high - 1;
            Outcome memory o = _try(from, target, data, g);
            if (o.ok) {
                assertEq(o.data, full.data, "a different amount");
                continue;
            }
            bool known = o.data.length == 0;
            for (uint256 k; k < allowed.length && !known; ++k) {
                if (keccak256(o.data) == keccak256(allowed[k])) {
                    known = true;
                    ++shortfalls;
                }
            }
            assertTrue(known, string.concat("a refusal-shaped revert at gas ", vm.toString(g)));
        }
        assertGt(shortfalls, 0, "no gas limit produced a shortfall error");
    }

    function _one(bytes memory a) internal pure returns (bytes[] memory l) {
        l = new bytes[](1);
        l[0] = a;
    }

    function _two(bytes memory a, bytes memory b) internal pure returns (bytes[] memory l) {
        l = new bytes[](2);
        (l[0], l[1]) = (a, b);
    }

    function _releaseData(address wallet, address asset, uint256 index)
        internal
        view
        returns (bytes memory)
    {
        return
            abi.encodeCall(ISplitWallet.release, (_payeesOf(wallet), _salts[wallet], asset, index));
    }

    // ------------------------------------------------------------------ a payee costing more

    function test_GasRule_FixedPayeeCostingMoreIsPaidTheSame() public {
        Burner payee = new Burner(sink, SAFE_RECEIVE);
        payee.burnerSetMutating(true);
        address wallet = _wallet(_list(_fixed(address(payee), 60_000), _fixed(bob, 40_000)));
        vm.deal(wallet, 1 ether);
        bytes memory data = _releaseData(wallet, ETH, _indexOf(wallet, address(payee)));
        Outcome memory o = _assertSameAtEveryMultiple(payee, alice, address(ledger), data);
        assertTrue(o.ok);
        assertEq(abi.decode(o.data, (uint256)), 0.6 ether);
    }

    function test_GasRule_PayeeRunningShortIsAShortfallNotARefusal() public {
        Burner payee = new Burner(sink, SAFE_RECEIVE);
        payee.burnerSetMutating(true);
        payee.burnerSetMultiple(10);
        address wallet = _wallet(_list(_fixed(address(payee), D)));
        vm.deal(wallet, 1 ether);
        _sweep(alice, address(ledger), _releaseData(wallet, ETH, 0), _one(_shortfall(wallet)));
    }

    // ------------------------------------------------------------------ a token costing more

    function test_GasRule_TokenCostingMoreReleasesTheSame() public {
        BurningToken t = new BurningToken();
        address wallet = _wallet(_list(_fixed(alice, 50_000), _fixed(bob, 50_000)));
        t.mint(wallet, 1_000);
        bytes memory data = _releaseData(wallet, address(t), _indexOf(wallet, bob));
        for (uint256 i; i < gasRuleMultiples.length; ++i) {
            t.setBurn(30_000 * gasRuleMultiples[i]);
            Outcome memory o = _try(alice, address(ledger), data, 0);
            assertTrue(o.ok, vm.toString(gasRuleMultiples[i]));
            assertEq(abi.decode(o.data, (uint256)), 500);
        }
        t.setBurn(300_000);
        _sweep(alice, address(ledger), data, _one(_shortfall(wallet)));
    }

    // ------------------------------------------------------------------ the resolver costing more

    function test_GasRule_ResolverCostingMoreResolvesTheSame() public {
        Burner slow = new Burner(address(resolver), 10_000);
        SplitLedger l = new SplitLedger(IArtistPayoutResolver(address(slow)));
        ISplitWallet.Payee[] memory payees = _list(_fixed(alice, 50_000), _artist(ARTIST, 50_000));
        address wallet = l.createWallet(payees, bytes32(0));
        vm.deal(wallet, 1 ether);
        uint256 index = payees[0].artistId == ARTIST ? 0 : 1;
        bytes memory data = abi.encodeCall(ISplitWallet.release, (payees, bytes32(0), ETH, index));
        Outcome memory o = _assertSameAtEveryMultiple(slow, artistPayout, address(l), data);
        assertTrue(o.ok);
        assertEq(abi.decode(o.data, (uint256)), 0.5 ether);
        slow.burnerSetMultiple(10);
        _sweep(artistPayout, address(l), data, _two(_shortfall(address(slow)), _shortfall(wallet)));
    }

    // ------------------------------------------------------------------ a signer costing more

    function test_GasRule_SmartAccountSignerCostingMoreReleasesTheSame() public {
        Mock1271Account account = new Mock1271Account();
        Burner signer = new Burner(address(account), 20_000);
        resolver.set(ARTIST, address(signer));
        address wallet = _wallet(_list(_artist(ARTIST, D)));
        vm.deal(wallet, 1 ether);
        IReleaseVerifier.Authorization memory a =
            _auth(wallet, ETH, 0, address(signer), bob, type(uint256).max, 1);
        account.accept(ledger.releaseDigest(a));
        bytes memory data = abi.encodeCall(
            ISplitLedger.releaseWithAuthorization, (_payeesOf(wallet), bytes32(0), a, hex"01")
        );
        Outcome memory o = _assertSameAtEveryMultiple(signer, alice, address(ledger), data);
        assertTrue(o.ok, "a 2,000,000-gas signature check releases: no compiled cap");
        assertEq(abi.decode(o.data, (uint256)), 1 ether);
        signer.burnerSetMultiple(10);
        _sweep(alice, address(ledger), data, _two(_shortfall(address(signer)), _shortfall(wallet)));
    }

    // ------------------------------------------------------------------ hostile and fresh payees

    /// @dev A payee that reverts, one that can neither receive nor call, and one that burns all
    ///      the gas it gets each fail alone; every other payee still releases in full, and the
    ///      failed shares stay in the wallet for their own payees.
    function test_HostilePayeesBlockOnlyTheirOwnShares() public {
        address rejecting = address(new RejectingRecipient());
        address mute = address(new MutePayee());
        Burner hog = new Burner(sink, 1);
        hog.burnerSetMutating(true);
        hog.burnerSetMultiple(type(uint64).max); // more than any block holds
        Burner tenTimesASafe = new Burner(sink, SAFE_RECEIVE * 10);
        tenTimesASafe.burnerSetMutating(true);
        ISplitWallet.Payee[] memory payees = new ISplitWallet.Payee[](6);
        payees[0] = _fixed(alice, 20_000);
        payees[1] = _fixed(rejecting, 10_000);
        payees[2] = _fixed(mute, 10_000);
        payees[3] = _fixed(address(hog), 10_000);
        payees[4] = _fixed(address(tenTimesASafe), 30_000);
        payees[5] = _artist(ARTIST, 20_000);
        address wallet = _wallet(_sorted(payees));
        vm.deal(wallet, 10 ether);

        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.ETHTransferFailed.selector, rejecting, 1 ether)
        );
        _release(wallet, ETH, _indexOf(wallet, rejecting));
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.ETHTransferFailed.selector, mute, 1 ether)
        );
        _release(wallet, ETH, _indexOf(wallet, mute));
        vm.expectRevert(abi.encodeWithSelector(BoundedCall.BoundedCallShortfall.selector, wallet));
        _release(wallet, ETH, _indexOf(wallet, address(hog)));

        assertEq(_release(wallet, ETH, _indexOf(wallet, alice)), 2 ether);
        assertEq(_release(wallet, ETH, _indexOf(wallet, address(tenTimesASafe))), 3 ether);
        vm.prank(artistPayout);
        assertEq(_release(wallet, ETH, _artistIndex(wallet, ARTIST)), 2 ether);
        assertEq(sink.balance, 3 ether);
        assertEq(wallet.balance, 3 ether, "the three failed shares stay for their own payees");
        assertEq(_releasable(wallet, ETH, _indexOf(wallet, mute)), 1 ether);
    }

    /// @dev A release to an account that has never existed creates it; nothing refuses it. Under
    ///      Glamsterdam the releaser pays for the account (about 184,000 gas on Sepolia), a cost,
    ///      never a condition.
    function test_FreshRecipientsArePaid() public {
        address fresh = address(uint160(uint256(keccak256("never used"))));
        address freshToo = address(uint160(uint256(keccak256("never used either"))));
        assertEq(fresh.code.length + fresh.balance + vm.getNonce(fresh), 0);
        address wallet = _wallet(_list(_fixed(fresh, 50_000), _artist(ARTIST, 50_000)));
        vm.deal(wallet, 2 ether);
        uint256 before = gasleft();
        _release(wallet, ETH, _indexOf(wallet, fresh));
        emit log_named_uint("release to a fresh account, Prague gas", before - gasleft());
        assertEq(fresh.balance, 1 ether);
        vm.prank(artistPayout);
        _releaseTo(wallet, ETH, _artistIndex(wallet, ARTIST), freshToo);
        assertEq(freshToo.balance, 1 ether);
    }

    /// @dev The payout resolver answering garbage (a word that is not an address) leaves the
    ///      artist payee unresolved rather than paying a truncated address.
    function test_ResolverAnsweringANonAddressIsUnresolved() public {
        GarbageResolver garbage = new GarbageResolver();
        SplitLedger l = new SplitLedger(IArtistPayoutResolver(address(garbage)));
        ISplitWallet.Payee[] memory payees = _list(_artist(ARTIST, D));
        address wallet = l.createWallet(payees, bytes32(0));
        vm.deal(wallet, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayoutUnresolved.selector, ARTIST));
        l.release(payees, bytes32(0), ETH, 0);
        assertEq(wallet.balance, 1 ether);
    }
}

/// @dev Answers `payoutAddress` with a word whose high bits are set.
contract GarbageResolver {
    fallback() external {
        assembly {
            mstore(0, not(0))
            return(0, 32)
        }
    }
}

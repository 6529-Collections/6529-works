// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { SplitFactory } from "src/economics/SplitFactory.sol";
import { SplitWallet } from "src/economics/SplitWallet.sol";
import { IArtistPayoutResolver } from "src/economics/interfaces/IArtistPayoutResolver.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { MockArtistResolver } from "../mocks/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

contract SplitFactoryTest is EconomicsBase {
    function test_ConstructorRejectsResolverWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(ISplitFactory.InvalidResolver.selector, alice));
        new SplitFactory(IArtistPayoutResolver(alice));
    }

    function test_CreateWalletDeploysAtPredictedAddressWithConfiguration() public {
        ISplitWallet.Payee[] memory payees =
            _list(_fixed(alice, 50_000), _fixed(bob, 30_000), _artist(ARTIST, 20_000));
        address predicted = factory.walletFor(payees);
        assertEq(predicted.code.length, 0);
        assertFalse(factory.isWallet(predicted));

        vm.expectEmit(true, true, false, true, address(factory));
        emit ISplitFactory.WalletCreated(predicted, keccak256(abi.encode(payees)), payees);
        address wallet = factory.createWallet(payees);

        assertEq(wallet, predicted);
        assertTrue(factory.isWallet(wallet));
        SplitWallet w = SplitWallet(payable(wallet));
        assertEq(w.factory(), address(factory));
        assertEq(address(w.resolver()), address(resolver));
        assertEq(w.payeeCount(), 3);
        assertEq(keccak256(abi.encode(w.payees())), keccak256(abi.encode(payees)));
        for (uint256 i; i < 3; ++i) {
            assertEq(keccak256(abi.encode(w.payee(i))), keccak256(abi.encode(payees[i])));
        }
    }

    function test_CreateWalletIsIdempotentAndSilentOnRepeat() public {
        ISplitWallet.Payee[] memory payees = _list(_fixed(alice, 60_000), _fixed(bob, 40_000));
        address first = factory.createWallet(payees);
        vm.recordLogs();
        address second = factory.createWallet(payees);
        assertEq(second, first);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_AddressCommitsToSharesKindsAndResolver() public {
        address a = factory.walletFor(_list(_fixed(alice, 60_000), _fixed(bob, 40_000)));
        address b = factory.walletFor(_list(_fixed(alice, 40_000), _fixed(bob, 60_000)));
        address c = factory.walletFor(_list(_fixed(alice, 60_000), _artist(ARTIST, 40_000)));
        assertTrue(a != b && a != c && b != c);
        SplitFactory other = new SplitFactory(new MockArtistResolver());
        assertTrue(other.walletFor(_list(_fixed(alice, 60_000), _fixed(bob, 40_000))) != a);
    }

    function test_RejectsEmptyAndOversizedPayeeLists() public {
        ISplitWallet.Payee[] memory none = new ISplitWallet.Payee[](0);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayeeCountOutOfRange.selector, 0));
        factory.createWallet(none);

        ISplitWallet.Payee[] memory many = new ISplitWallet.Payee[](65);
        for (uint256 i; i < 65; ++i) {
            many[i] = _fixed(address(uint160(i + 1)), i == 0 ? D - 64 : 1);
        }
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayeeCountOutOfRange.selector, 65));
        factory.createWallet(many);
    }

    function test_RejectsZeroShare() public {
        ISplitWallet.Payee[] memory payees = _list(_fixed(alice, D), _fixed(bob, 0));
        uint256 zeroAt = payees[0].share == 0 ? 0 : 1;
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.InvalidPayee.selector, zeroAt));
        factory.createWallet(payees);
    }

    function test_RejectsPayeesThatAreBothOrNeitherKind() public {
        ISplitWallet.Payee[] memory both = _list(ISplitWallet.Payee(ARTIST, alice, D));
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.InvalidPayee.selector, 0));
        factory.createWallet(both);

        ISplitWallet.Payee[] memory neither = _list(ISplitWallet.Payee(0, address(0), D));
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.InvalidPayee.selector, 0));
        factory.walletFor(neither);
    }

    function test_RejectsUnsortedAndDuplicatePayees() public {
        ISplitWallet.Payee[] memory payees = _list(_fixed(alice, 50_000), _fixed(bob, 50_000));
        (payees[0], payees[1]) = (payees[1], payees[0]);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayeesNotCanonical.selector, 1));
        factory.createWallet(payees);

        ISplitWallet.Payee[] memory dup = new ISplitWallet.Payee[](2);
        dup[0] = _fixed(alice, 50_000);
        dup[1] = _fixed(alice, 50_000);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayeesNotCanonical.selector, 1));
        factory.createWallet(dup);

        ISplitWallet.Payee[] memory artists = new ISplitWallet.Payee[](2);
        artists[0] = _artist(9, 50_000);
        artists[1] = _artist(8, 50_000);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayeesNotCanonical.selector, 1));
        factory.createWallet(artists);

        ISplitWallet.Payee[] memory artistFirst = new ISplitWallet.Payee[](2);
        artistFirst[0] = _artist(ARTIST, 50_000);
        artistFirst[1] = _fixed(alice, 50_000);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayeesNotCanonical.selector, 1));
        factory.createWallet(artistFirst);
    }

    function test_RejectsSharesNotSummingToDenominator() public {
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.SharesDoNotSum.selector, 99_999));
        factory.createWallet(_list(_fixed(alice, 50_000), _fixed(bob, 49_999)));
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.SharesDoNotSum.selector, 100_001));
        factory.walletFor(_list(_fixed(alice, 50_000), _fixed(bob, 50_001)));
    }

    function test_MaximumPayeeListDeploys() public {
        ISplitWallet.Payee[] memory many = new ISplitWallet.Payee[](64);
        for (uint256 i; i < 64; ++i) {
            many[i] = _fixed(address(uint160(i + 1)), i == 0 ? D - 63 : 1);
        }
        uint256 before = gasleft();
        address wallet = factory.createWallet(many);
        emit log_named_uint("64-payee wallet deployment gas", before - gasleft());
        assertEq(SplitWallet(payable(wallet)).payeeCount(), 64);
    }

    function test_FundsSentBeforeDeploymentAreSplitAfterwards() public {
        ISplitWallet.Payee[] memory payees = _list(_fixed(alice, 75_000), _fixed(bob, 25_000));
        address predicted = factory.walletFor(payees);
        vm.deal(predicted, 4 ether);
        token.mint(predicted, 400);
        SplitWallet wallet = _wallet(payees);
        wallet.release(ETH, _indexOf(wallet, alice));
        wallet.release(address(token), _indexOf(wallet, bob));
        assertEq(alice.balance, 3 ether);
        assertEq(token.balanceOf(bob), 100);
    }

    function test_DirectDeploymentValidatesAndRecordsDeployer() public {
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.SharesDoNotSum.selector, 1));
        new SplitWallet(resolver, _list(_fixed(alice, 1)));
        vm.prank(bob);
        SplitWallet direct = new SplitWallet(resolver, _list(_fixed(alice, D)));
        assertEq(direct.factory(), bob);
        assertFalse(factory.isWallet(address(direct)));
    }

    function testFuzz_PredictionMatchesDeployment(uint32 share, uint160 x, uint160 y) public {
        share = uint32(bound(share, 1, D - 1));
        address a = address(uint160(bound(x, 1, type(uint160).max)));
        address b = address(uint160(bound(y, 1, type(uint160).max)));
        vm.assume(a != b);
        ISplitWallet.Payee[] memory payees = _list(_fixed(a, share), _fixed(b, D - share));
        address predicted = factory.walletFor(payees);
        vm.recordLogs();
        assertEq(factory.createWallet(payees), predicted);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(predicted))));
    }
}

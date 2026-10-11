// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { ReleaseVerifier } from "src/economics/ReleaseVerifier.sol";
import { SplitFactory } from "src/economics/SplitFactory.sol";
import { SplitWallet } from "src/economics/SplitWallet.sol";
import { IArtistPayoutResolver } from "src/economics/interfaces/IArtistPayoutResolver.sol";
import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { MockArtistResolver } from "../mocks/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

contract SplitFactoryTest is EconomicsBase {
    bytes32 internal constant ZERO_SALT = bytes32(0);

    function test_ConstructorPinsDependencies() public view {
        assertEq(address(factory.resolver()), address(resolver));
        assertEq(factory.resolverCodeHash(), address(resolver).codehash);
        assertEq(address(factory.verifier()), address(verifier));
        assertEq(factory.verifierCodeHash(), address(verifier).codehash);
    }

    function test_ConstructorRejectsDependenciesWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(ISplitFactory.InvalidDependency.selector, alice));
        new SplitFactory(IArtistPayoutResolver(alice), verifier);
        vm.expectRevert(abi.encodeWithSelector(ISplitFactory.InvalidDependency.selector, bob));
        new SplitFactory(resolver, IReleaseVerifier(bob));
    }

    /// @dev Regression for review L-1 (ported from `test_PoC_FactoryAcceptsDelegatedEOAResolver`,
    ///      inverted): an EIP-7702 delegated EOA could be re-delegated to any code later.
    function test_ConstructorRejectsDelegatedEOADependencies() public {
        address eoa = makeAddr("delegated-eoa");
        vm.etch(eoa, abi.encodePacked(hex"ef0100", address(resolver)));
        vm.expectRevert(abi.encodeWithSelector(ISplitFactory.InvalidDependency.selector, eoa));
        new SplitFactory(IArtistPayoutResolver(eoa), verifier);
        vm.expectRevert(abi.encodeWithSelector(ISplitFactory.InvalidDependency.selector, eoa));
        new SplitFactory(resolver, IReleaseVerifier(eoa));
    }

    function test_CreateWalletFailsClosedIfAPinnedDependencyChanges() public {
        vm.etch(address(resolver), address(router).code);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitFactory.DependencyCodeChanged.selector, address(resolver))
        );
        factory.createWallet(_list(_fixed(alice, D)), ZERO_SALT);
        SplitFactory fresh = new SplitFactory(new MockArtistResolver(), verifier);
        vm.etch(address(verifier), address(router).code);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitFactory.DependencyCodeChanged.selector, address(verifier))
        );
        fresh.createWallet(_list(_fixed(alice, D)), ZERO_SALT);
    }

    function test_CreateWalletDeploysAtPredictedAddressWithConfiguration() public {
        ISplitWallet.Payee[] memory payees =
            _list(_fixed(alice, 50_000), _fixed(bob, 30_000), _artist(ARTIST, 20_000));
        address predicted = factory.walletFor(payees, ZERO_SALT);
        bytes32 config = keccak256(abi.encode(payees));
        assertEq(predicted.code.length, 0);
        assertFalse(factory.isWallet(predicted));
        assertEq(factory.configOf(predicted), bytes32(0));

        vm.expectEmit(true, true, false, true, address(factory));
        emit ISplitFactory.WalletCreated(predicted, config, ZERO_SALT, payees);
        address wallet = factory.createWallet(payees, ZERO_SALT);

        assertEq(wallet, predicted);
        assertTrue(factory.isWallet(wallet));
        assertEq(factory.configOf(wallet), config);
        SplitWallet w = SplitWallet(payable(wallet));
        assertEq(w.factory(), address(factory));
        assertEq(address(w.resolver()), address(resolver));
        assertEq(w.resolverCodeHash(), address(resolver).codehash);
        assertEq(address(w.verifier()), address(verifier));
        assertEq(w.payeeCount(), 3);
        assertEq(keccak256(abi.encode(w.payees())), config);
        for (uint256 i; i < 3; ++i) {
            assertEq(keccak256(abi.encode(w.payee(i))), keccak256(abi.encode(payees[i])));
        }
    }

    function test_SaltGivesAnEquivalentWalletWithTheSameConfigHash() public {
        ISplitWallet.Payee[] memory payees = _list(_fixed(alice, 60_000), _fixed(bob, 40_000));
        address original = factory.createWallet(payees, ZERO_SALT);
        address replacement = factory.createWallet(payees, bytes32(uint256(1)));
        assertTrue(original != replacement);
        assertEq(factory.configOf(original), factory.configOf(replacement));
        assertEq(replacement, factory.walletFor(payees, bytes32(uint256(1))));
    }

    function test_CreateWalletIsIdempotentAndSilentOnRepeat() public {
        ISplitWallet.Payee[] memory payees = _list(_fixed(alice, 60_000), _fixed(bob, 40_000));
        address first = factory.createWallet(payees, ZERO_SALT);
        vm.recordLogs();
        address second = factory.createWallet(payees, ZERO_SALT);
        assertEq(second, first);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_AddressCommitsToSharesKindsDependenciesAndSalt() public {
        ISplitWallet.Payee[] memory base = _list(_fixed(alice, 60_000), _fixed(bob, 40_000));
        address a = factory.walletFor(base, ZERO_SALT);
        address b = factory.walletFor(_list(_fixed(alice, 40_000), _fixed(bob, 60_000)), ZERO_SALT);
        address c =
            factory.walletFor(_list(_fixed(alice, 60_000), _artist(ARTIST, 40_000)), ZERO_SALT);
        address d = factory.walletFor(base, bytes32(uint256(7)));
        assertTrue(a != b && a != c && b != c && a != d);
        SplitFactory otherResolver = new SplitFactory(new MockArtistResolver(), verifier);
        assertTrue(otherResolver.walletFor(base, ZERO_SALT) != a);
        SplitFactory otherVerifier = new SplitFactory(resolver, new ReleaseVerifier());
        assertTrue(otherVerifier.walletFor(base, ZERO_SALT) != a);
    }

    function test_RejectsEmptyAndOversizedPayeeLists() public {
        ISplitWallet.Payee[] memory none = new ISplitWallet.Payee[](0);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayeeCountOutOfRange.selector, 0));
        factory.createWallet(none, ZERO_SALT);

        ISplitWallet.Payee[] memory many = new ISplitWallet.Payee[](65);
        for (uint256 i; i < 65; ++i) {
            many[i] = _fixed(address(uint160(i + 1)), i == 0 ? D - 64 : 1);
        }
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayeeCountOutOfRange.selector, 65));
        factory.createWallet(many, ZERO_SALT);
    }

    function test_RejectsZeroShare() public {
        ISplitWallet.Payee[] memory payees = _list(_fixed(alice, D), _fixed(bob, 0));
        uint256 zeroAt = payees[0].share == 0 ? 0 : 1;
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.InvalidPayee.selector, zeroAt));
        factory.createWallet(payees, ZERO_SALT);
    }

    function test_RejectsPayeesThatAreBothOrNeitherKind() public {
        ISplitWallet.Payee[] memory both = _list(ISplitWallet.Payee(ARTIST, alice, D));
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.InvalidPayee.selector, 0));
        factory.createWallet(both, ZERO_SALT);

        ISplitWallet.Payee[] memory neither = _list(ISplitWallet.Payee(0, address(0), D));
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.InvalidPayee.selector, 0));
        factory.walletFor(neither, ZERO_SALT);
    }

    function test_RejectsUnsortedAndDuplicatePayees() public {
        ISplitWallet.Payee[] memory payees = _list(_fixed(alice, 50_000), _fixed(bob, 50_000));
        (payees[0], payees[1]) = (payees[1], payees[0]);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayeesNotCanonical.selector, 1));
        factory.createWallet(payees, ZERO_SALT);

        ISplitWallet.Payee[] memory dup = new ISplitWallet.Payee[](2);
        dup[0] = _fixed(alice, 50_000);
        dup[1] = _fixed(alice, 50_000);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayeesNotCanonical.selector, 1));
        factory.createWallet(dup, ZERO_SALT);

        ISplitWallet.Payee[] memory artists = new ISplitWallet.Payee[](2);
        artists[0] = _artist(9, 50_000);
        artists[1] = _artist(8, 50_000);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayeesNotCanonical.selector, 1));
        factory.createWallet(artists, ZERO_SALT);

        ISplitWallet.Payee[] memory artistFirst = new ISplitWallet.Payee[](2);
        artistFirst[0] = _artist(ARTIST, 50_000);
        artistFirst[1] = _fixed(alice, 50_000);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayeesNotCanonical.selector, 1));
        factory.createWallet(artistFirst, ZERO_SALT);
    }

    function test_RejectsSharesNotSummingToDenominator() public {
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.SharesDoNotSum.selector, 99_999));
        factory.createWallet(_list(_fixed(alice, 50_000), _fixed(bob, 49_999)), ZERO_SALT);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.SharesDoNotSum.selector, 100_001));
        factory.walletFor(_list(_fixed(alice, 50_000), _fixed(bob, 50_001)), ZERO_SALT);
    }

    function test_MaximumPayeeListDeploys() public {
        ISplitWallet.Payee[] memory many = new ISplitWallet.Payee[](64);
        for (uint256 i; i < 64; ++i) {
            many[i] = _fixed(address(uint160(i + 1)), i == 0 ? D - 63 : 1);
        }
        uint256 before = gasleft();
        address wallet = factory.createWallet(many, ZERO_SALT);
        emit log_named_uint("64-payee wallet deployment gas", before - gasleft());
        assertEq(SplitWallet(payable(wallet)).payeeCount(), 64);
        before = gasleft();
        _wallet(_list(_fixed(alice, 75_000), _artist(ARTIST, 25_000)));
        emit log_named_uint("2-payee wallet deployment gas", before - gasleft());
    }

    function test_FundsSentBeforeDeploymentAreSplitAfterwards() public {
        ISplitWallet.Payee[] memory payees = _list(_fixed(alice, 75_000), _fixed(bob, 25_000));
        address predicted = factory.walletFor(payees, ZERO_SALT);
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
        new SplitWallet(resolver, verifier, _list(_fixed(alice, 1)));
        vm.prank(bob);
        SplitWallet direct = new SplitWallet(resolver, verifier, _list(_fixed(alice, D)));
        assertEq(direct.factory(), bob);
        assertFalse(factory.isWallet(address(direct)));
    }

    function testFuzz_PredictionMatchesDeployment(uint32 share, uint160 x, uint160 y, bytes32 salt)
        public
    {
        share = uint32(bound(share, 1, D - 1));
        address a = address(uint160(bound(x, 1, type(uint160).max)));
        address b = address(uint160(bound(y, 1, type(uint160).max)));
        vm.assume(a != b);
        ISplitWallet.Payee[] memory payees = _list(_fixed(a, share), _fixed(b, D - share));
        address predicted = factory.walletFor(payees, salt);
        vm.recordLogs();
        assertEq(factory.createWallet(payees, salt), predicted);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(predicted))));
        assertEq(logs[0].topics[2], keccak256(abi.encode(payees)));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { GovernedVault } from "src/economics/GovernedVault.sol";
import { SplitLedger } from "src/economics/SplitLedger.sol";
import { SplitVault } from "src/economics/SplitVault.sol";
import { Splits } from "src/economics/Splits.sol";
import { IArtistPayoutResolver } from "src/economics/interfaces/IArtistPayoutResolver.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { MockArtistResolver } from "../mocks/economics/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";
import { Dependency } from "src/libraries/Dependency.sol";

/// @notice The split ledger's wallet side: prediction, deployment and the payee-list rules.
contract SplitFactoryTest is EconomicsBase {
    bytes32 internal constant ZERO_SALT = bytes32(0);

    function test_ConstructorRecordsTheResolverAndTheVaultInitCode() public view {
        assertEq(address(factory.resolver()), address(resolver));
        assertEq(factory.walletInitCodeHash(), keccak256(SplitVault.INIT_CODE));
    }

    function test_ConstructorRejectsDependenciesWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, alice));
        new SplitLedger(IArtistPayoutResolver(alice), address(feeVault));
    }

    /// @dev Regression for review L-1 (ported from `test_PoC_FactoryAcceptsDelegatedEOAResolver`,
    ///      inverted): an EIP-7702 delegated EOA could be re-delegated to any code later.
    function test_ConstructorRejectsDelegatedEOADependencies() public {
        address eoa = makeAddr("delegated-eoa");
        vm.etch(eoa, abi.encodePacked(hex"ef0100", address(resolver)));
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        new SplitLedger(IArtistPayoutResolver(eoa), address(feeVault));
    }

    /// @dev No code-hash pin: after EIP-6780 the resolver's code cannot change, and a pin would
    ///      only freeze every deployment if code-hash semantics ever changed. The old factory
    ///      reverted here with `DependencyCodeChanged`.
    function test_CreateWalletIgnoresTheResolversCodeHash() public {
        vm.etch(address(resolver), address(router).code);
        address wallet = factory.createWallet(_list(_fixed(alice, D)), ZERO_SALT);
        assertTrue(factory.isWallet(wallet));
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
        assertEq(wallet.code, abi.encodePacked(hex"73", address(ledger), SplitVault.RUNTIME_TAIL));
    }

    function test_SaltGivesAnEquivalentWalletWithTheSameConfigHash() public {
        ISplitWallet.Payee[] memory payees = _list(_fixed(alice, 60_000), _fixed(bob, 40_000));
        address original = _wallet(payees, ZERO_SALT);
        address replacement = _wallet(payees, bytes32(uint256(1)));
        assertTrue(original != replacement);
        assertEq(factory.configOf(original), factory.configOf(replacement));
        assertEq(replacement, factory.walletFor(payees, bytes32(uint256(1))));
        // Each keeps its own accounting.
        vm.deal(replacement, 1 ether);
        _release(replacement, ETH, _indexOf(replacement, alice));
        assertEq(alice.balance, 0.6 ether);
        assertEq(ledger.totalReleased(original, ETH), 0);
    }

    function test_CreateWalletIsIdempotentAndSilentOnRepeat() public {
        ISplitWallet.Payee[] memory payees = _list(_fixed(alice, 60_000), _fixed(bob, 40_000));
        address first = factory.createWallet(payees, ZERO_SALT);
        vm.recordLogs();
        address second = factory.createWallet(payees, ZERO_SALT);
        assertEq(second, first);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    /// @dev Permissionless: any caller may create a wallet for any canonical list, the 90/10
    ///      configurations of federated contracts included.
    function test_AnyoneCreatesAWalletForAnyCanonicalList() public {
        address stranger = makeAddr("stranger");
        ISplitWallet.Payee[] memory federated = _list(_fixed(bob, 10_000), _artist(ARTIST, 90_000));
        vm.prank(stranger);
        address wallet = factory.createWallet(federated, ZERO_SALT);
        assertEq(wallet, factory.walletFor(federated, ZERO_SALT));
        assertTrue(factory.isWallet(wallet));
    }

    function test_AddressCommitsToSharesKindsLedgerAndSalt() public {
        ISplitWallet.Payee[] memory base = _list(_fixed(alice, 60_000), _fixed(bob, 40_000));
        address a = factory.walletFor(base, ZERO_SALT);
        address b = factory.walletFor(_list(_fixed(alice, 40_000), _fixed(bob, 60_000)), ZERO_SALT);
        address c =
            factory.walletFor(_list(_fixed(alice, 60_000), _artist(ARTIST, 40_000)), ZERO_SALT);
        address d = factory.walletFor(base, bytes32(uint256(7)));
        assertTrue(a != b && a != c && b != c && a != d);
        SplitLedger otherLedger = new SplitLedger(new MockArtistResolver(), address(feeVault));
        assertTrue(otherLedger.walletFor(base, ZERO_SALT) != a);
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

    /// @dev Review C F9: a payee that could never be paid is refused wherever a list is validated
    ///      (`walletFor` and `createWallet` alike): an artist ID no account can have (2^160 or
    ///      more) and the ledger itself as a fixed payee. The largest real artist ID, a royalty
    ///      pair whose fee recipient is a contract (the governed fee vault) and a nested split
    ///      wallet as fixed payee still pass. Fails without the change: both lists are accepted.
    function test_RejectsPayeesThatCanNeverBePaid() public {
        ISplitWallet.Payee[] memory badId =
            _list(_fixed(alice, 50_000), _artist(uint256(type(uint160).max) + 1, 50_000));
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.InvalidPayee.selector, 1));
        factory.walletFor(badId, ZERO_SALT);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.InvalidPayee.selector, 1));
        factory.createWallet(badId, ZERO_SALT);

        ISplitWallet.Payee[] memory toLedger =
            _list(_fixed(alice, 50_000), _fixed(address(ledger), 50_000));
        uint256 at = toLedger[0].account == address(ledger) ? 0 : 1;
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.InvalidPayee.selector, at));
        factory.walletFor(toLedger, ZERO_SALT);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.InvalidPayee.selector, at));
        factory.createWallet(toLedger, ZERO_SALT);

        // Still accepted: the largest artist ID, a contract fee recipient, a nested wallet.
        factory.createWallet(
            _list(_fixed(alice, 50_000), _artist(type(uint160).max, 50_000)), ZERO_SALT
        );
        address nested = _wallet(_list(_fixed(alice, 50_000), _fixed(bob, 50_000)));
        address otherVault = address(new GovernedVault(address(manager), alice));
        factory.createWallet(Splits.royaltyPayees(nested, otherVault, 10_000), ZERO_SALT);
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

        // Each payee sorts after the one before it, not only after the first.
        ISplitWallet.Payee[] memory third = new ISplitWallet.Payee[](3);
        third[0] = _artist(1, 30_000);
        third[1] = _artist(3, 30_000);
        third[2] = _artist(2, 40_000);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayeesNotCanonical.selector, 2));
        factory.createWallet(third, ZERO_SALT);

        // The same artist twice is a duplicate too.
        ISplitWallet.Payee[] memory sameArtist = new ISplitWallet.Payee[](2);
        sameArtist[0] = _artist(4, 50_000);
        sameArtist[1] = _artist(4, 50_000);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayeesNotCanonical.selector, 1));
        factory.walletFor(sameArtist, ZERO_SALT);
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
        factory.createWallet(many, ZERO_SALT);
        emit log_named_uint("64-payee wallet deployment gas", before - gasleft());
        address wallet = _remember(many, ZERO_SALT);
        assertTrue(factory.isWallet(wallet));
        vm.deal(wallet, 1 ether);
        assertEq(_release(wallet, ETH, 63), Splits.entitlement(1 ether, 1));
    }

    function test_FundsSentBeforeDeploymentAreSplitAfterwards() public {
        ISplitWallet.Payee[] memory payees = _list(_fixed(alice, 75_000), _fixed(bob, 25_000));
        address predicted = factory.walletFor(payees, ZERO_SALT);
        vm.deal(predicted, 4 ether);
        token.mint(predicted, 400);
        address wallet = _wallet(payees);
        _release(wallet, ETH, _indexOf(wallet, alice));
        _release(wallet, address(token), _indexOf(wallet, bob));
        assertEq(alice.balance, 3 ether);
        assertEq(token.balanceOf(bob), 100);
    }

    /// @dev QUALITY-12: every wallet has the same init code, and the address is the documented
    ///      CREATE2 derivation over the ledger, the configuration hash and the salt.
    function test_AddressIsTheDocumentedCreate2Derivation() public {
        assertEq(factory.walletInitCodeHash(), keccak256(SplitVault.INIT_CODE));
        ISplitWallet.Payee[] memory payees =
            _list(_fixed(alice, 50_000), _fixed(bob, 30_000), _artist(ARTIST, 20_000));
        bytes32 salt = bytes32(uint256(42));
        bytes32 walletSalt = keccak256(abi.encode(keccak256(abi.encode(payees)), salt));
        address expected = vm.computeCreate2Address(
            walletSalt, keccak256(SplitVault.INIT_CODE), address(factory)
        );
        assertEq(factory.walletFor(payees, salt), expected);
        assertEq(factory.createWallet(payees, salt), expected);
        SplitLedger other = new SplitLedger(resolver, address(feeVault));
        assertEq(other.walletInitCodeHash(), factory.walletInitCodeHash());
        assertTrue(other.walletFor(payees, salt) != expected, "the ledger is in the address");
    }

    /// @dev Wallets created back to back each record their own payee hash.
    function test_ConfigOfRecordsEachWalletsPayeeHash() public {
        ISplitWallet.Payee[] memory three =
            _list(_fixed(alice, 50_000), _fixed(bob, 30_000), _artist(ARTIST, 20_000));
        ISplitWallet.Payee[] memory one = _list(_artist(ARTIST, D));
        address a = factory.createWallet(three, ZERO_SALT);
        address b = factory.createWallet(one, ZERO_SALT);
        assertEq(factory.configOf(a), keccak256(abi.encode(three)));
        assertEq(factory.configOf(b), keccak256(abi.encode(one)));
    }

    /// @dev Predicting hashes a few words, never the wallet's code.
    function test_WalletForIsCheap() public {
        ISplitWallet.Payee[] memory one = _list(_artist(ARTIST, D));
        factory.walletFor(one, ZERO_SALT);
        uint256 before = gasleft();
        factory.walletFor(one, ZERO_SALT);
        uint256 used = before - gasleft();
        emit log_named_uint("walletFor, one payee (warm)", used);
        assertLt(used, 5_000);
    }

    /// @dev The ledger checks that CREATE2 put the wallet where it predicted: with the
    ///      prediction's hash forced to differ from the real init code, deployment reverts.
    function test_CreateWalletRevertsIfTheDeployedAddressDiffers() public {
        ISplitWallet.Payee[] memory payees = _list(_fixed(alice, D));
        bytes32 slot = bytes32(0);
        // `walletInitCodeHash` is an immutable: patch it in a copy of the ledger's runtime code.
        bytes memory code = address(factory).code;
        bytes32 real = factory.walletInitCodeHash();
        uint256 hits;
        for (uint256 i; i + 32 <= code.length; ++i) {
            bytes32 word;
            assembly ("memory-safe") {
                word := mload(add(add(code, 0x20), i))
            }
            if (word == real) {
                bytes32 wrong = keccak256("not the wallet init code");
                assembly ("memory-safe") {
                    mstore(add(add(code, 0x20), i), wrong)
                }
                ++hits;
            }
        }
        assertGt(hits, 0, "the immutable is in the runtime code");
        vm.etch(address(factory), code);
        address predicted = factory.walletFor(payees, slot);
        address deployed = vm.computeCreate2Address(
            keccak256(abi.encode(keccak256(abi.encode(payees)), slot)), real, address(factory)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                ISplitFactory.WalletAddressMismatch.selector, predicted, deployed
            )
        );
        factory.createWallet(payees, slot);
    }

    /// @dev The largest payee list, with extreme field values, is logged exactly, and the logged
    ///      list is the one a release names the wallet by.
    function test_MaximumPayeeListIsLoggedExactly() public {
        ISplitWallet.Payee[] memory many = new ISplitWallet.Payee[](64);
        for (uint256 i; i < 32; ++i) {
            many[i] = _fixed(address(uint160(type(uint160).max - 31 + i)), i == 0 ? D - 63 : 1);
        }
        for (uint256 i = 32; i < 64; ++i) {
            many[i] = _artist(uint256(type(uint160).max) - 63 + i, 1);
        }
        vm.recordLogs();
        address w = factory.createWallet(many, ZERO_SALT);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (, ISplitWallet.Payee[] memory logged) =
            abi.decode(logs[0].data, (bytes32, ISplitWallet.Payee[]));
        assertEq(keccak256(abi.encode(logged)), keccak256(abi.encode(many)));
        assertEq(logged[0].share, D - 63);
        assertEq(logged[63].artistId, type(uint160).max);
        vm.deal(w, 1 ether);
        assertEq(ledger.release(logged, ZERO_SALT, ETH, 0), Splits.entitlement(1 ether, D - 63));
    }

    function testFuzz_PredictionMatchesDeployment(uint32 share, uint160 x, uint160 y, bytes32 salt)
        public
    {
        share = uint32(bound(share, 1, D - 1));
        address a = address(uint160(bound(x, 1, type(uint160).max)));
        address b = address(uint160(bound(y, 1, type(uint160).max)));
        vm.assume(a != b);
        // The ledger refuses itself as a fixed payee: a share it could never pay out.
        vm.assume(a != address(factory) && b != address(factory));
        ISplitWallet.Payee[] memory payees = _list(_fixed(a, share), _fixed(b, D - share));
        address predicted = factory.walletFor(payees, salt);
        vm.recordLogs();
        assertEq(factory.createWallet(payees, salt), predicted);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(predicted))));
        assertEq(logs[0].topics[2], keccak256(abi.encode(payees)));
        assertEq(predicted.code.length, 66);
    }
}

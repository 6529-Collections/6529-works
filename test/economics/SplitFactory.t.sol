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
import { MockArtistResolver } from "../mocks/economics/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";
import { Dependency } from "src/libraries/Dependency.sol";

/// @dev Another contract that deploys a `SplitWallet` itself, answering the wallet's constructor
///      the way the factory does.
contract SelfDeployer {
    IArtistPayoutResolver public immutable resolver;
    IReleaseVerifier public immutable verifier;
    ISplitWallet.Payee[] internal _pending;

    constructor(IArtistPayoutResolver resolver_, IReleaseVerifier verifier_) {
        resolver = resolver_;
        verifier = verifier_;
    }

    function pendingPayees() external view returns (ISplitWallet.Payee[] memory) {
        return _pending;
    }

    function deploy(ISplitWallet.Payee[] calldata payees) external returns (SplitWallet) {
        for (uint256 i; i < payees.length; ++i) {
            _pending.push(payees[i]);
        }
        return new SplitWallet();
    }
}

contract SplitFactoryTest is EconomicsBase {
    bytes32 internal constant ZERO_SALT = bytes32(0);

    function test_ConstructorPinsDependencies() public view {
        assertEq(address(factory.resolver()), address(resolver));
        assertEq(factory.resolverCodeHash(), address(resolver).codehash);
        assertEq(address(factory.verifier()), address(verifier));
        assertEq(factory.verifierCodeHash(), address(verifier).codehash);
    }

    function test_ConstructorRejectsDependenciesWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, alice));
        new SplitFactory(IArtistPayoutResolver(alice), verifier);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, bob));
        new SplitFactory(resolver, IReleaseVerifier(bob));
    }

    /// @dev Regression for review L-1 (ported from `test_PoC_FactoryAcceptsDelegatedEOAResolver`,
    ///      inverted): an EIP-7702 delegated EOA could be re-delegated to any code later.
    function test_ConstructorRejectsDelegatedEOADependencies() public {
        address eoa = makeAddr("delegated-eoa");
        vm.etch(eoa, abi.encodePacked(hex"ef0100", address(resolver)));
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        new SplitFactory(IArtistPayoutResolver(eoa), verifier);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        new SplitFactory(resolver, IReleaseVerifier(eoa));
    }

    function test_CreateWalletFailsClosedIfAPinnedDependencyChanges() public {
        vm.etch(address(resolver), address(router).code);
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.DependencyCodeChanged.selector, address(resolver))
        );
        factory.createWallet(_list(_fixed(alice, D)), ZERO_SALT);
        SplitFactory fresh = new SplitFactory(new MockArtistResolver(), verifier);
        vm.etch(address(verifier), address(router).code);
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.DependencyCodeChanged.selector, address(verifier))
        );
        fresh.createWallet(_list(_fixed(alice, D)), ZERO_SALT);
    }

    /// @dev Code whose hash sorts below the pinned one, as well as above: any change fails.
    function test_CreateWalletFailsClosedWhicheverWayADependencyHashMoves() public {
        address[2] memory deps = [address(resolver), address(verifier)];
        for (uint256 d; d < 2; ++d) {
            bytes32 pinned = deps[d].codehash;
            bytes memory lower;
            for (uint256 i; lower.length == 0; ++i) {
                bytes memory code = abi.encodePacked(bytes1(0x60), bytes1(uint8(i)), bytes1(0x00));
                if (keccak256(code) < pinned) lower = code;
            }
            SplitFactory fresh = new SplitFactory(new MockArtistResolver(), verifier);
            if (d == 1) fresh = new SplitFactory(resolver, new ReleaseVerifier());
            address dep = d == 0 ? address(fresh.resolver()) : address(fresh.verifier());
            vm.etch(dep, lower);
            vm.expectRevert(abi.encodeWithSelector(Dependency.DependencyCodeChanged.selector, dep));
            fresh.createWallet(_list(_fixed(alice, D)), ZERO_SALT);
        }
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

        // Each payee sorts after the one before it, not only after the first.
        ISplitWallet.Payee[] memory third = new ISplitWallet.Payee[](3);
        third[0] = _artist(1, 30_000);
        third[1] = _artist(3, 30_000);
        third[2] = _artist(2, 40_000);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayeesNotCanonical.selector, 2));
        factory.createWallet(third, ZERO_SALT);
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

    /// @dev Anyone can deploy a `SplitWallet` elsewhere, but only by answering its constructor
    ///      like the factory, which then records it as the wallet's factory; the split factory
    ///      never recognises it. An account without code cannot deploy one at all.
    function test_DirectDeploymentValidatesAndRecordsDeployer() public {
        SelfDeployer deployer = new SelfDeployer(resolver, verifier);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.SharesDoNotSum.selector, 1));
        deployer.deploy(_list(_fixed(alice, 1)));
        SplitWallet direct = deployer.deploy(_list(_fixed(alice, D)));
        assertEq(direct.factory(), address(deployer));
        assertEq(direct.payeeCount(), 1);
        assertFalse(factory.isWallet(address(direct)));
        vm.prank(bob);
        vm.expectRevert();
        new SplitWallet();
    }

    /// @dev QUALITY-12: every wallet has the same init code, and the address is the documented
    ///      CREATE2 derivation over the configuration hash and the salt.
    function test_AddressIsTheDocumentedCreate2Derivation() public {
        assertEq(factory.walletInitCodeHash(), keccak256(type(SplitWallet).creationCode));
        ISplitWallet.Payee[] memory payees =
            _list(_fixed(alice, 50_000), _fixed(bob, 30_000), _artist(ARTIST, 20_000));
        bytes32 salt = bytes32(uint256(42));
        bytes32 walletSalt = keccak256(abi.encode(keccak256(abi.encode(payees)), salt));
        address expected =
            vm.computeCreate2Address(walletSalt, factory.walletInitCodeHash(), address(factory));
        assertEq(factory.walletFor(payees, salt), expected);
        assertEq(factory.createWallet(payees, salt), expected);
        SplitFactory other = new SplitFactory(resolver, verifier);
        assertEq(other.walletInitCodeHash(), factory.walletInitCodeHash());
        assertTrue(other.walletFor(payees, salt) != expected, "the factory is in the address");
    }

    /// @dev The pending list exists only while `createWallet` deploys: before and after, even
    ///      within one transaction, it is empty, and wallets created back to back each get their
    ///      own list.
    function test_PendingPayeesExistOnlyDuringCreation() public {
        assertEq(factory.pendingPayees().length, 0);
        ISplitWallet.Payee[] memory three =
            _list(_fixed(alice, 50_000), _fixed(bob, 30_000), _artist(ARTIST, 20_000));
        ISplitWallet.Payee[] memory one = _list(_artist(ARTIST, D));
        SplitWallet a = SplitWallet(payable(factory.createWallet(three, ZERO_SALT)));
        assertEq(factory.pendingPayees().length, 0);
        SplitWallet b = SplitWallet(payable(factory.createWallet(one, ZERO_SALT)));
        assertEq(factory.pendingPayees().length, 0);
        assertEq(keccak256(abi.encode(a.payees())), keccak256(abi.encode(three)));
        assertEq(keccak256(abi.encode(b.payees())), keccak256(abi.encode(one)));
        assertEq(factory.configOf(address(a)), keccak256(abi.encode(three)));
        assertEq(factory.configOf(address(b)), keccak256(abi.encode(one)));
    }

    /// @dev Predicting no longer hashes the wallet's creation code: `walletFor` costs a few
    ///      thousand gas, whatever the wallet's size (it was about 7,900 for one payee).
    function test_WalletForIsCheap() public {
        ISplitWallet.Payee[] memory one = _list(_artist(ARTIST, D));
        factory.walletFor(one, ZERO_SALT);
        uint256 before = gasleft();
        factory.walletFor(one, ZERO_SALT);
        uint256 used = before - gasleft();
        emit log_named_uint("walletFor, one payee (warm)", used);
        assertLt(used, 5_000);
    }

    /// @dev The factory checks that CREATE2 put the wallet where it predicted: with the
    ///      prediction's hash forced to differ from the real init code, deployment reverts.
    function test_CreateWalletRevertsIfTheDeployedAddressDiffers() public {
        ISplitWallet.Payee[] memory payees = _list(_fixed(alice, D));
        bytes32 slot = bytes32(0);
        // `walletInitCodeHash` is an immutable: patch it in a copy of the factory's runtime code.
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

    /// @dev The largest payee list, with extreme field values, survives the transient hand-off
    ///      to the wallet's constructor exactly.
    function test_PayeeListSurvivesTheHandOffExactly() public {
        ISplitWallet.Payee[] memory many = new ISplitWallet.Payee[](64);
        for (uint256 i; i < 32; ++i) {
            many[i] = _fixed(address(uint160(type(uint160).max - 31 + i)), i == 0 ? D - 63 : 1);
        }
        for (uint256 i = 32; i < 64; ++i) {
            many[i] = _artist(type(uint256).max - 63 + i, 1);
        }
        SplitWallet w = SplitWallet(payable(factory.createWallet(many, ZERO_SALT)));
        assertEq(keccak256(abi.encode(w.payees())), keccak256(abi.encode(many)));
        assertEq(w.payee(0).share, D - 63);
        assertEq(w.payee(63).artistId, type(uint256).max);
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

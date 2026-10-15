// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { EconomicsResolver } from "src/economics/EconomicsResolver.sol";
import { SplitWallet } from "src/economics/SplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Roles } from "src/governance/Roles.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import {
    CURRENCY_DEFAULT,
    PRODUCT_EDITIONS,
    PRODUCT_FEDERATED,
    PRODUCT_STREAM,
    ProductEconomics,
    WorkTerms
} from "src/interfaces/types/EconomicsTypes.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { MockERC20 } from "../mocks/economics/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";
import { Dependency } from "src/libraries/Dependency.sol";

contract EconomicsResolverTest is EconomicsBase {
    bytes32 internal constant CC0_TEXT = keccak256("CC0 1.0 Universal legal code");
    bytes32 internal constant UNKNOWN = keccak256("PRODUCT_UNKNOWN");

    EconomicsResolver internal econ;
    address internal network = makeAddr("network");
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        econ = new EconomicsResolver(address(manager), allowlist, factory, network, CC0_TEXT);
    }

    function _artistPayees() internal view returns (ISplitWallet.Payee[] memory) {
        return _list(_fixed(bob, 20_000), _artist(ARTIST, 80_000));
    }

    function _econ(bytes32 product) internal view returns (ProductEconomics memory) {
        return econ.economics(product);
    }

    // ------------------------------------------------------------------ launch defaults

    function test_LaunchDefaults() public view {
        _assertEconomics(_econ(PRODUCT_STREAM), network, 25_000, 6_529);
        _assertEconomics(_econ(PRODUCT_EDITIONS), network, 25_000, 6_529);
        _assertEconomics(_econ(PRODUCT_FEDERATED), network, 10_000, 6_529);
        assertEq(econ.networkFeeRecipient(PRODUCT_STREAM), network);
        bytes32[3] memory products = [PRODUCT_STREAM, PRODUCT_EDITIONS, PRODUCT_FEDERATED];
        for (uint256 i; i < 3; ++i) {
            License memory license = econ.defaultLicense(products[i]);
            assertEq(license.spdxId, "CC0-1.0");
            assertEq(WorksHashing.licenseKey(license.spdxId), WorksHashing.CC0_LICENSE_KEY);
            assertEq(license.textFileId, CC0_TEXT);
            (uint64 fee, uint64 royalty, uint64 lic) = econ.revisions(products[i]);
            assertEq(fee + royalty + lic, 3);
        }
        assertEq(econ.assetAllowlist(), address(allowlist));
        assertEq(econ.splitFactory(), address(factory));
        assertEq(econ.authority(), address(manager));
    }

    function test_ConstructorEmitsAndValidates() public {
        vm.expectEmit(true, false, false, true);
        emit IEconomicsResolver.EconomicsSet(
            PRODUCT_STREAM,
            ProductEconomics(address(0), 0, 0),
            ProductEconomics(network, 25_000, 6_529),
            1
        );
        vm.expectEmit(true, false, false, true);
        emit IEconomicsResolver.DefaultLicenseSet(
            PRODUCT_STREAM, License("", bytes32(0)), License("CC0-1.0", CC0_TEXT), 1
        );
        new EconomicsResolver(address(manager), allowlist, factory, network, CC0_TEXT);

        vm.expectRevert(IEconomicsResolver.InvalidEconomics.selector);
        new EconomicsResolver(address(manager), allowlist, factory, address(0), CC0_TEXT);
        vm.expectRevert(IEconomicsResolver.InvalidLicense.selector);
        new EconomicsResolver(address(manager), allowlist, factory, network, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, alice));
        new EconomicsResolver(address(manager), IAssetAllowlist(alice), factory, network, CC0_TEXT);
        address delegated = makeAddr("delegated");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(factory)));
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, delegated));
        new EconomicsResolver(
            address(manager), allowlist, ISplitFactory(delegated), network, CC0_TEXT
        );
    }

    function test_SupportsInterface() public view {
        assertTrue(econ.supportsInterface(type(IEconomicsResolver).interfaceId));
        assertTrue(econ.supportsInterface(type(IERC165).interfaceId));
        assertFalse(econ.supportsInterface(0xffffffff));
    }

    function test_UnknownProductReverts() public {
        bytes memory unknown =
            abi.encodeWithSelector(IEconomicsResolver.UnknownProduct.selector, UNKNOWN);
        vm.expectRevert(unknown);
        econ.economics(UNKNOWN);
        vm.expectRevert(unknown);
        econ.networkFeeRecipient(UNKNOWN);
        vm.expectRevert(unknown);
        econ.defaultLicense(UNKNOWN);
        vm.expectRevert(unknown);
        econ.revisions(UNKNOWN);
        vm.expectRevert(unknown);
        econ.newWorkTerms(UNKNOWN, _artistPayees());
        vm.expectRevert(unknown);
        econ.resolveCurrency(UNKNOWN, ETH);
        vm.expectRevert(unknown);
        econ.setFeeTerms(UNKNOWN, 1, network, 1);
        vm.expectRevert(unknown);
        econ.setRoyaltyRate(UNKNOWN, 1, 1);
        vm.expectRevert(unknown);
        econ.setDefaultLicense(UNKNOWN, 1, License("MIT", CC0_TEXT));
    }

    // ------------------------------------------------------------------ governed setters

    function test_SetFeeTermsIsCompareAndSet() public {
        address treasury = makeAddr("treasury");
        vm.expectEmit(true, false, false, true, address(econ));
        emit IEconomicsResolver.EconomicsSet(
            PRODUCT_STREAM,
            ProductEconomics(network, 25_000, 6_529),
            ProductEconomics(treasury, 20_000, 6_529),
            2
        );
        econ.setFeeTerms(PRODUCT_STREAM, 1, treasury, 20_000);
        _assertEconomics(_econ(PRODUCT_STREAM), treasury, 20_000, 6_529);
        _assertEconomics(_econ(PRODUCT_EDITIONS), network, 25_000, 6_529);
        vm.expectRevert(abi.encodeWithSelector(IEconomicsResolver.RevisionMismatch.selector, 1, 2));
        econ.setFeeTerms(PRODUCT_STREAM, 1, network, 25_000);

        vm.expectRevert(IEconomicsResolver.InvalidEconomics.selector);
        econ.setFeeTerms(PRODUCT_STREAM, 2, treasury, D);
        vm.expectRevert(IEconomicsResolver.InvalidEconomics.selector);
        econ.setFeeTerms(PRODUCT_STREAM, 2, address(0), 1);
        // No fee needs no recipient.
        econ.setFeeTerms(PRODUCT_STREAM, 2, address(0), 0);
        assertEq(econ.networkFeeRecipient(PRODUCT_STREAM), address(0));
    }

    /// @dev CALLS-1 (resolver side): a recipient that could never be paid is refused, because
    ///      works lock their fee recipient at mint.
    function test_FeeRecipientMustBePayable() public {
        address[6] memory refused = [
            address(escrow),
            address(router),
            address(econ),
            address(allowlist),
            address(factory),
            address(verifier)
        ];
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(IEconomicsResolver.InvalidFeeRecipient.selector, refused[i])
            );
            econ.setFeeTerms(PRODUCT_STREAM, 1, refused[i], 25_000);
            // Even with no fee: the adapters pay (or skip) the locked recipient at settlement.
            vm.expectRevert(
                abi.encodeWithSelector(IEconomicsResolver.InvalidFeeRecipient.selector, refused[i])
            );
            econ.setFeeTerms(PRODUCT_STREAM, 1, refused[i], 0);
        }
        vm.expectRevert(
            abi.encodeWithSelector(IEconomicsResolver.InvalidFeeRecipient.selector, address(escrow))
        );
        new EconomicsResolver(address(manager), allowlist, factory, address(escrow), CC0_TEXT);
        _assertEconomics(_econ(PRODUCT_STREAM), network, 25_000, 6_529);

        // Accounts that accept payments stay allowed: a split wallet (its `receive` is empty) and
        // an existing account.
        address split = address(_solo(alice));
        vm.expectEmit(true, false, false, true, address(econ));
        emit IEconomicsResolver.EconomicsSet(
            PRODUCT_STREAM,
            ProductEconomics(network, 25_000, 6_529),
            ProductEconomics(split, 25_000, 6_529),
            2
        );
        econ.setFeeTerms(PRODUCT_STREAM, 1, split, 25_000);
        econ.setFeeTerms(PRODUCT_STREAM, 2, stranger, 25_000);
        assertEq(econ.networkFeeRecipient(PRODUCT_STREAM), stranger);
    }

    function test_SetRoyaltyRateIsCompareAndSetOnItsOwnRevision() public {
        // A fee change does not invalidate a royalty change queued against revision 1.
        econ.setFeeTerms(PRODUCT_EDITIONS, 1, network, 30_000);
        vm.expectEmit(true, false, false, true, address(econ));
        emit IEconomicsResolver.EconomicsSet(
            PRODUCT_EDITIONS,
            ProductEconomics(network, 30_000, 6_529),
            ProductEconomics(network, 30_000, 10_000),
            2
        );
        econ.setRoyaltyRate(PRODUCT_EDITIONS, 1, 10_000);
        _assertEconomics(_econ(PRODUCT_EDITIONS), network, 30_000, 10_000);
        vm.expectRevert(abi.encodeWithSelector(IEconomicsResolver.RevisionMismatch.selector, 1, 2));
        econ.setRoyaltyRate(PRODUCT_EDITIONS, 1, 0);
        vm.expectRevert(IEconomicsResolver.InvalidEconomics.selector);
        econ.setRoyaltyRate(PRODUCT_EDITIONS, 2, D + 1);
        econ.setRoyaltyRate(PRODUCT_EDITIONS, 2, 0);
        (uint64 fee, uint64 royalty, uint64 license) = econ.revisions(PRODUCT_EDITIONS);
        assertEq(fee, 2);
        assertEq(royalty, 3);
        assertEq(license, 1);
    }

    function test_SetDefaultLicenseIsCompareAndSetAndValidated() public {
        License memory custom = License("LicenseRef-6529-Custom+1.0", keccak256("custom text"));
        vm.expectEmit(true, false, false, true, address(econ));
        emit IEconomicsResolver.DefaultLicenseSet(
            PRODUCT_FEDERATED, License("CC0-1.0", CC0_TEXT), custom, 2
        );
        econ.setDefaultLicense(PRODUCT_FEDERATED, 1, custom);
        assertEq(econ.defaultLicense(PRODUCT_FEDERATED).spdxId, custom.spdxId);
        assertEq(econ.defaultLicense(PRODUCT_STREAM).spdxId, "CC0-1.0");
        vm.expectRevert(abi.encodeWithSelector(IEconomicsResolver.RevisionMismatch.selector, 1, 2));
        econ.setDefaultLicense(PRODUCT_FEDERATED, 1, custom);

        string[4] memory bad = ["", "CC0 1.0", "GPL/2.0", string(new bytes(65))];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(IEconomicsResolver.InvalidLicense.selector);
            econ.setDefaultLicense(PRODUCT_FEDERATED, 2, License(bad[i], CC0_TEXT));
        }
        vm.expectRevert(IEconomicsResolver.InvalidLicense.selector);
        econ.setDefaultLicense(PRODUCT_FEDERATED, 2, License("MIT", bytes32(0)));
    }

    /// @dev A default license whose key is CC0 names the CC0 text the resolver was deployed
    ///      with, in any casing of the identifier: `WorkRecords.openRecord` refuses a CC0
    ///      license with another text, so such a default would leave every new work unopenable.
    function test_ACc0DefaultLicenseNamesThePinnedText() public {
        bytes32 other = keccak256("another CC0 text");
        vm.expectRevert(IEconomicsResolver.InvalidLicense.selector);
        econ.setDefaultLicense(PRODUCT_STREAM, 1, License("CC0-1.0", other));
        vm.expectRevert(IEconomicsResolver.InvalidLicense.selector);
        econ.setDefaultLicense(PRODUCT_STREAM, 1, License("cc0-1.0", other));
        // Another text on either side of the pinned one (mutation testing).
        vm.expectRevert(IEconomicsResolver.InvalidLicense.selector);
        econ.setDefaultLicense(PRODUCT_STREAM, 1, License("CC0-1.0", bytes32(uint256(1))));
        vm.expectRevert(IEconomicsResolver.InvalidLicense.selector);
        econ.setDefaultLicense(PRODUCT_STREAM, 1, License("CC0-1.0", bytes32(type(uint256).max)));
        econ.setDefaultLicense(PRODUCT_STREAM, 1, License("MIT", other));
        econ.setDefaultLicense(PRODUCT_STREAM, 2, License("cc0-1.0", CC0_TEXT));
        assertEq(econ.defaultLicense(PRODUCT_STREAM).textFileId, CC0_TEXT);
        assertEq(econ.cc0TextFileId(), CC0_TEXT);
    }

    /// @dev The bounds exactly, each side of each (mutation testing: the existing cases stood at
    ///      the bound, so `>=` read as `==`, or `!=` as `<`, still passed).
    function test_BoundsAreExactOnEachSide() public {
        // A fee share above the whole, not only equal to it, is refused; a royalty rate of
        // exactly the whole is allowed.
        vm.expectRevert(IEconomicsResolver.InvalidEconomics.selector);
        econ.setFeeTerms(PRODUCT_STREAM, 1, network, D + 1);
        econ.setRoyaltyRate(PRODUCT_STREAM, 1, D);
        assertEq(_econ(PRODUCT_STREAM).royaltyRate, D);
        // A stale revision ahead of the current one is refused too.
        vm.expectRevert(abi.encodeWithSelector(IEconomicsResolver.RevisionMismatch.selector, 3, 1));
        econ.setFeeTerms(PRODUCT_STREAM, 3, network, 1);
        // A license ID of exactly the maximum length is accepted, one byte more is refused.
        bytes memory longest = new bytes(Limits.MAX_LICENSE_ID_BYTES);
        for (uint256 i; i < longest.length; ++i) {
            longest[i] = "a";
        }
        econ.setDefaultLicense(PRODUCT_FEDERATED, 1, License(string(longest), CC0_TEXT));
        vm.expectRevert(IEconomicsResolver.InvalidLicense.selector);
        econ.setDefaultLicense(
            PRODUCT_FEDERATED, 2, License(string(bytes.concat(longest, "a")), CC0_TEXT)
        );
    }

    /// @dev Only the CC0 key needs the pinned text: a key that sorts above it does not
    ///      (`GPL-3.0`'s does), whatever the text.
    function test_OnlyTheCc0KeyNeedsThePinnedText() public {
        assertGt(uint256(WorksHashing.licenseKey("GPL-3.0")), uint256(WorksHashing.CC0_LICENSE_KEY));
        econ.setDefaultLicense(PRODUCT_STREAM, 1, License("GPL-3.0", keccak256("GPL text")));
        assertEq(econ.defaultLicense(PRODUCT_STREAM).spdxId, "GPL-3.0");
    }

    function test_SettersAreRestrictedAndNonPayable() public {
        vm.startPrank(stranger);
        bytes memory denied =
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger);
        vm.expectRevert(denied);
        econ.setFeeTerms(PRODUCT_STREAM, 1, stranger, 1);
        vm.expectRevert(denied);
        econ.setRoyaltyRate(PRODUCT_STREAM, 1, 1);
        vm.expectRevert(denied);
        econ.setDefaultLicense(PRODUCT_STREAM, 1, License("MIT", CC0_TEXT));
        vm.stopPrank();
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(econ).call{ value: 1 }(
            abi.encodeCall(IEconomicsResolver.setRoyaltyRate, (PRODUCT_STREAM, 1, 1))
        );
        assertFalse(ok);
    }

    /// @dev Fee terms are FUNDS (14 days); royalty and license defaults are STANDARD (48 hours).
    ///      A fee change queued against revision 1 cannot apply after the fee terms changed and
    ///      changed back (ABA).
    function test_RolesAndDelaysThroughAccessManager() public {
        bytes4[] memory funds = new bytes4[](1);
        funds[0] = IEconomicsResolver.setFeeTerms.selector;
        bytes4[] memory standard = new bytes4[](2);
        standard[0] = IEconomicsResolver.setRoyaltyRate.selector;
        standard[1] = IEconomicsResolver.setDefaultLicense.selector;
        manager.setTargetFunctionRole(address(econ), funds, Roles.FUNDS_SETTER);
        manager.setTargetFunctionRole(address(econ), standard, Roles.PARAMETER_SETTER);
        address gov = makeAddr("gov");
        manager.grantRole(Roles.FUNDS_SETTER, gov, Roles.FUNDS);
        manager.grantRole(Roles.PARAMETER_SETTER, gov, Roles.STANDARD);

        bytes memory royalty =
            abi.encodeCall(IEconomicsResolver.setRoyaltyRate, (PRODUCT_STREAM, 1, 5_000));
        bytes memory feeA =
            abi.encodeCall(IEconomicsResolver.setFeeTerms, (PRODUCT_STREAM, 1, network, 20_000));
        bytes memory feeB =
            abi.encodeCall(IEconomicsResolver.setFeeTerms, (PRODUCT_STREAM, 2, network, 25_000));
        bytes memory staleA =
            abi.encodeCall(IEconomicsResolver.setFeeTerms, (PRODUCT_STREAM, 1, network, 15_000));
        vm.startPrank(gov);
        manager.schedule(address(econ), royalty, 0);
        manager.schedule(address(econ), feeA, 0);
        manager.schedule(address(econ), feeB, 0);
        manager.schedule(address(econ), staleA, 0);
        vm.warp(block.timestamp + Roles.STANDARD);
        manager.execute(address(econ), royalty);
        vm.warp(block.timestamp + Roles.FUNDS);
        manager.execute(address(econ), feeA);
        manager.execute(address(econ), feeB);
        // Back at 25,000, the same value staleA saw, but at revision 3.
        vm.expectRevert(abi.encodeWithSelector(IEconomicsResolver.RevisionMismatch.selector, 1, 3));
        manager.execute(address(econ), staleA);
        vm.stopPrank();
        _assertEconomics(_econ(PRODUCT_STREAM), network, 25_000, 5_000);
    }

    // ------------------------------------------------------------------ currency

    function test_ResolveCurrencyThroughTheAllowlist() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC");
        assertEq(econ.resolveCurrency(PRODUCT_STREAM, ETH), ETH);
        vm.expectRevert(
            abi.encodeWithSelector(IEconomicsResolver.CurrencyNotAllowed.selector, address(usdc))
        );
        econ.resolveCurrency(PRODUCT_EDITIONS, address(usdc));
        vm.expectRevert(
            abi.encodeWithSelector(IEconomicsResolver.CurrencyNotAllowed.selector, CURRENCY_DEFAULT)
        );
        econ.resolveCurrency(PRODUCT_STREAM, CURRENCY_DEFAULT);

        allowlist.setDefaultCurrency(PRODUCT_STREAM, 0, ETH);
        assertEq(econ.resolveCurrency(PRODUCT_STREAM, CURRENCY_DEFAULT), ETH);
        allowlist.admitAsset(address(usdc), 0, 1e6);
        allowlist.setDefaultCurrency(PRODUCT_EDITIONS, 0, address(usdc));
        assertEq(econ.resolveCurrency(PRODUCT_EDITIONS, CURRENCY_DEFAULT), address(usdc));
        assertEq(econ.resolveCurrency(PRODUCT_EDITIONS, address(usdc)), address(usdc));
        allowlist.deprecateAsset(address(usdc));
        vm.expectRevert(
            abi.encodeWithSelector(IEconomicsResolver.CurrencyNotAllowed.selector, address(usdc))
        );
        econ.resolveCurrency(PRODUCT_EDITIONS, CURRENCY_DEFAULT);
    }

    // ------------------------------------------------------------------ new work terms

    /// @dev The terms are exactly the wallets the split factory deploys for the payee lists the
    ///      adapters build: the item's payees for the seller, and `Splits.royaltyPayees` for the
    ///      royalty receiver. Money then flows 75/25 and onward to the artist portion.
    function test_NewWorkTermsMatchTheFactoryAndAdapters() public {
        ISplitWallet.Payee[] memory payees = _artistPayees();
        WorkTerms memory t = econ.newWorkTerms(PRODUCT_STREAM, payees);
        assertEq(t.feeRecipient, network);
        assertEq(t.feeShare, 25_000);
        assertEq(t.royaltyRate, 6_529);
        assertEq(t.seller, factory.walletFor(payees, bytes32(0)));
        assertEq(t.seller.code.length, 0, "nothing deployed at start");

        ISplitWallet.Payee[] memory royalty = Splits.royaltyPayees(t.seller, network, t.feeShare);
        assertEq(factory.createWallet(royalty, bytes32(0)), t.royaltyReceiver);
        assertEq(factory.createWallet(payees, bytes32(0)), t.seller);

        // A 1 ether royalty: 25% to the network, 75% to the seller wallet, split onward.
        vm.deal(t.royaltyReceiver, 1 ether);
        SplitWallet r = SplitWallet(payable(t.royaltyReceiver));
        r.release(ETH, _indexOf(r, network));
        r.release(ETH, _indexOf(r, t.seller));
        assertEq(network.balance, 0.25 ether);
        SplitWallet s = SplitWallet(payable(t.seller));
        s.release(ETH, _indexOf(s, bob));
        uint256 iArtist = _artistIndex(s, ARTIST);
        vm.prank(artistPayout);
        s.release(ETH, iArtist);
        assertEq(bob.balance, 0.15 ether);
        assertEq(artistPayout.balance, 0.6 ether);

        WorkTerms memory fed = econ.newWorkTerms(PRODUCT_FEDERATED, payees);
        assertEq(fed.seller, t.seller);
        assertEq(fed.feeShare, 10_000);
        assertEq(
            fed.royaltyReceiver,
            factory.walletFor(Splits.royaltyPayees(t.seller, network, 10_000), bytes32(0))
        );
    }

    /// @dev Stream's review requirement: the receiver the resolver computes equals what Stream
    ///      derives from the seller and the fee terms alone, built here by hand against the real
    ///      factory: salt zero, the two payees sorted ascending by address, or the seller itself
    ///      for a zero fee. Both sort orders are exercised.
    function test_RoyaltyReceiverMatchesTheSharedDerivation() public {
        ISplitWallet.Payee[] memory payees = _artistPayees();
        address seller = factory.walletFor(payees, bytes32(0));
        address[2] memory recipients = [address(1), address(type(uint160).max)];
        for (uint256 i; i < 2; ++i) {
            (uint64 revision,,) = econ.revisions(PRODUCT_STREAM);
            econ.setFeeTerms(PRODUCT_STREAM, revision, recipients[i], 25_000);
            WorkTerms memory t = econ.newWorkTerms(PRODUCT_STREAM, payees);
            ISplitWallet.Payee[] memory list = new ISplitWallet.Payee[](2);
            ISplitWallet.Payee memory s = _fixed(seller, D - 25_000);
            ISplitWallet.Payee memory f = _fixed(recipients[i], 25_000);
            (list[0], list[1]) = uint160(seller) < uint160(recipients[i]) ? (s, f) : (f, s);
            assertEq(t.seller, seller);
            assertEq(t.royaltyReceiver, factory.walletFor(list, bytes32(0)), "non-zero fee");
            assertEq(factory.createWallet(list, bytes32(0)), t.royaltyReceiver);
        }
        (uint64 rev,,) = econ.revisions(PRODUCT_STREAM);
        econ.setFeeTerms(PRODUCT_STREAM, rev, network, 0);
        WorkTerms memory zero = econ.newWorkTerms(PRODUCT_STREAM, payees);
        assertEq(zero.royaltyReceiver, seller, "zero fee: the seller itself");
        assertEq(zero.seller, seller);
    }

    function test_ZeroFeeShareOmitsTheFeePayee() public {
        econ.setFeeTerms(PRODUCT_STREAM, 1, network, 0);
        WorkTerms memory t = econ.newWorkTerms(PRODUCT_STREAM, _artistPayees());
        assertEq(t.feeShare, 0);
        assertEq(t.royaltyReceiver, t.seller);
    }

    function test_NewWorkTermsRejectWhatTheFactoryRejects() public {
        ISplitWallet.Payee[] memory payees = _artistPayees();
        (payees[0], payees[1]) = (payees[1], payees[0]);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayeesNotCanonical.selector, 1));
        econ.newWorkTerms(PRODUCT_STREAM, payees);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.SharesDoNotSum.selector, 50_000));
        econ.newWorkTerms(PRODUCT_STREAM, _list(_fixed(bob, 50_000)));
    }

    /// @dev Works lock their terms at mint: a later change gives new works new wallets and
    ///      leaves a deployed royalty wallet's split untouched.
    function test_ChangesApplyToNewWorksOnly() public {
        WorkTerms memory before = econ.newWorkTerms(PRODUCT_STREAM, _artistPayees());
        factory.createWallet(
            Splits.royaltyPayees(before.seller, network, before.feeShare), bytes32(0)
        );
        econ.setFeeTerms(PRODUCT_STREAM, 1, network, 30_000);
        econ.setRoyaltyRate(PRODUCT_STREAM, 1, 5_000);
        WorkTerms memory later = econ.newWorkTerms(PRODUCT_STREAM, _artistPayees());
        assertEq(later.seller, before.seller);
        assertTrue(later.royaltyReceiver != before.royaltyReceiver);
        assertEq(later.royaltyRate, 5_000);
        assertEq(before.royaltyRate, 6_529);

        vm.deal(before.royaltyReceiver, 1 ether);
        SplitWallet r = SplitWallet(payable(before.royaltyReceiver));
        assertEq(r.release(ETH, _indexOf(r, network)), 0.25 ether);
    }

    // ------------------------------------------------------------------ share maths

    function testFuzz_RoyaltySplitSharesAddUp(uint32 feeShare, uint96 amount, address recipient)
        public
    {
        feeShare = uint32(bound(feeShare, 1, D - 1));
        vm.assume(recipient != address(0) && recipient.code.length == 0);
        vm.assume(uint160(recipient) > 0xffff);
        econ.setFeeTerms(PRODUCT_EDITIONS, 1, recipient, feeShare);
        WorkTerms memory t = econ.newWorkTerms(PRODUCT_EDITIONS, _artistPayees());
        vm.assume(recipient != t.seller);
        ISplitWallet.Payee[] memory royalty = Splits.royaltyPayees(t.seller, recipient, feeShare);
        assertEq(royalty[0].share + royalty[1].share, D);
        assertLt(uint160(royalty[0].account), uint160(royalty[1].account));
        assertEq(factory.createWallet(royalty, bytes32(0)), t.royaltyReceiver);

        vm.deal(t.royaltyReceiver, amount);
        SplitWallet r = SplitWallet(payable(t.royaltyReceiver));
        uint256 toFee = uint256(amount) * feeShare / D;
        uint256 toSeller = uint256(amount) * (D - feeShare) / D;
        uint256 balanceBefore = recipient.balance;
        if (toFee > 0) r.release(ETH, _indexOf(r, recipient));
        if (toSeller > 0) r.release(ETH, _indexOf(r, t.seller));
        assertEq(recipient.balance - balanceBefore, toFee);
        assertEq(t.seller.balance, toSeller);
        assertLe(amount - toFee - toSeller, 1, "dust below the payee count");
    }

    function _assertEconomics(
        ProductEconomics memory e,
        address feeRecipient,
        uint32 feeShare,
        uint32 royaltyRate
    ) internal pure {
        assertEq(e.feeRecipient, feeRecipient);
        assertEq(e.feeShare, feeShare);
        assertEq(e.royaltyRate, royaltyRate);
    }
}

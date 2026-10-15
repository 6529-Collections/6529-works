// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import {
    CURRENCY_DEFAULT,
    PRODUCT_FEDERATED,
    PRODUCT_STREAM
} from "src/interfaces/types/EconomicsTypes.sol";
import { LockedTerms, PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import {
    MockFederationRegistryV2,
    MockMintTarget,
    PlainMintTarget
} from "../../mocks/sales/AuctionMocks.sol";
import { MockFederationRegistry } from "../../mocks/sales/SaleMocks.sol";
import { AuctionBase } from "./AuctionBase.sol";
import { Dependency } from "src/libraries/Dependency.sol";

/// @notice Federated targets (D21): a contract listed ACTIVE in the federation registry sells
///         through the auction at the registry's fee share, paid to the network's federated
///         recipient; its registry entry pins its code hash, and the registry's own code is
///         pinned when it is installed.
contract EnglishAuctionFederationTest is AuctionBase {
    function test_Federation_ActiveContractsSellWithTheRegistryFee() public {
        MockFederationRegistry registry = new MockFederationRegistry();
        MockMintTarget federated = new MockMintTarget();
        federated.setAdmittedMinter(address(auction), true);
        federated.setTerms(_terms(ETH));
        assertFalse(auction.isTarget(address(federated)));

        vm.prank(successor);
        vm.expectRevert(ISaleAdapter.ExpectedValueMismatch.selector);
        auction.setFederationRegistry(alice, address(registry));
        vm.expectEmit(address(auction));
        emit ISaleAdapter.FederationRegistrySet(address(0), address(registry));
        vm.prank(successor);
        auction.setFederationRegistry(address(0), address(registry));
        assertEq(auction.federationRegistry(), address(registry));

        IFederationRegistry.Entry memory e = IFederationRegistry.Entry(
            IFederationRegistry.Form.ERC721,
            address(0),
            uint160(artist),
            1,
            address(federated).codehash,
            10_000,
            IFederationRegistry.Status.ACTIVE
        );
        registry.register(address(federated), e);
        assertTrue(auction.isTarget(address(federated)));
        uint256 saleId = auction.start(address(federated), "");
        LockedTerms memory lt = auction.lockedTerms(saleId);
        assertEq(lt.feeShare, 10_000, "the registry's fee, not the token's");
        _bidEth(saleId, alice, 1 ether);
        vm.warp(block.timestamp + DURATION);
        auction.settle(saleId);
        // MARKET-3: the registry's fee goes to the network's federated recipient, never to the
        // recipient the token reports.
        assertEq(federatedNetwork.balance, 0.1 ether);
        assertEq(network.balance, 0);
        assertEq(seller.balance, 0.9 ether);

        registry.setStatus(address(federated), IFederationRegistry.Status.DELISTED, bytes32(0));
        assertFalse(auction.isTarget(address(federated)));
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(federated))
        );
        auction.start(address(federated), "");
    }

    function test_Federation_SetterIsRestrictedAndChecksCode() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice)
        );
        auction.setFederationRegistry(address(0), alice);
        vm.prank(successor);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, alice));
        auction.setFederationRegistry(address(0), alice);
        vm.prank(successor);
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(escrow))
        );
        auction.setFederationRegistry(address(0), address(escrow));
    }

    /// @dev A federated token naming `CURRENCY_DEFAULT` locks the Federated product's default.
    function test_Federation_DefaultCurrencyIsTheFederatedProducts() public {
        MockFederationRegistry registry = new MockFederationRegistry();
        MockMintTarget federated = new MockMintTarget();
        federated.setAdmittedMinter(address(auction), true);
        federated.setTerms(_terms(CURRENCY_DEFAULT));
        vm.prank(successor);
        auction.setFederationRegistry(address(0), address(registry));
        IFederationRegistry.Entry memory e;
        e.codeHash = address(federated).codehash;
        e.status = IFederationRegistry.Status.ACTIVE;
        e.feeShare = 10_000;
        registry.register(address(federated), e);
        _setDefault(PRODUCT_STREAM, ETH);
        _setDefault(PRODUCT_FEDERATED, address(usd));
        uint256 saleId = auction.start(address(federated), "");
        assertEq(auction.auction(saleId).currency, address(usd));
    }

    /// Regression: M-1 (PoC F1, inverted) in the review of #21
    /// @dev The settlement hook is part of `IMintTarget`, so every served token has it; a
    ///      template that makes it a no-op still settles and pays.
    function test_Federation_ANoOpSettlementHookStillSettles() public {
        PlainMintTarget fed = new PlainMintTarget();
        fed.setAdmittedMinter(address(auction), true);
        fed.setTerms(
            PrimaryTerms(SaleKind.ENGLISH_AUCTION, ETH, 0, "", seller, network, FEE, artist)
        );
        MockFederationRegistry registry = new MockFederationRegistry();
        registry.register(
            address(fed),
            IFederationRegistry.Entry(
                IFederationRegistry.Form.ERC721,
                address(0),
                1,
                1,
                address(fed).codehash,
                25_000,
                IFederationRegistry.Status.ACTIVE
            )
        );
        vm.prank(successor);
        auction.setFederationRegistry(address(0), address(registry));

        uint256 saleId = auction.start(address(fed), "");
        _bidEth(saleId, alice, 1 ether);
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(saleId);
        assertEq(fed.ownerOf(1), alice);
        assertEq(seller.balance, 0.75 ether);
        // MARKET-3: the federated network fee recipient, not the token's.
        assertEq(federatedNetwork.balance, 0.25 ether);
    }

    /// Regression: L-6 in the review of #21
    /// @dev A federated token whose code does not match its registry entry, or a registry whose
    ///      code changed after it was pinned, serves no sale.
    function test_Federation_CodeHashesArePinned() public {
        PlainMintTarget fed = new PlainMintTarget();
        fed.setAdmittedMinter(address(auction), true);
        fed.setTerms(
            PrimaryTerms(SaleKind.ENGLISH_AUCTION, ETH, 0, "", seller, network, FEE, artist)
        );
        MockFederationRegistry registry = new MockFederationRegistry();
        IFederationRegistry.Entry memory e = IFederationRegistry.Entry(
            IFederationRegistry.Form.ERC721,
            address(0),
            1,
            1,
            keccak256("another template"),
            25_000,
            IFederationRegistry.Status.ACTIVE
        );
        registry.register(address(fed), e);
        vm.prank(successor);
        auction.setFederationRegistry(address(0), address(registry));
        assertEq(auction.federationRegistryCodeHash(), address(registry).codehash);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(fed), 1)
        );
        auction.start(address(fed), "");

        e.codeHash = address(fed).codehash;
        registry.register(address(fed), e);
        assertTrue(auction.isTarget(address(fed)));
        vm.etch(address(registry), address(new MockFederationRegistryV2()).code);
        assertFalse(auction.isTarget(address(fed)), "registry code changed");
    }

    function _federated(PrimaryTerms memory terms) internal returns (MockMintTarget federated) {
        MockFederationRegistry registry = new MockFederationRegistry();
        federated = new MockMintTarget();
        federated.setAdmittedMinter(address(auction), true);
        federated.setTerms(terms);
        vm.prank(successor);
        auction.setFederationRegistry(address(0), address(registry));
        registry.register(
            address(federated),
            IFederationRegistry.Entry(
                IFederationRegistry.Form.ERC721,
                address(0),
                uint160(artist),
                1,
                address(federated).codehash,
                10_000,
                IFederationRegistry.Status.ACTIVE
            )
        );
    }

    /// Regression: MARKET-3 (docs/security/internal-review-2026-10.md); L6 in the review of #57
    /// @dev A federated sale's fee goes to the network's federated recipient, so that recipient,
    ///      not the token's own, is checked at start: a zero one is refused while nothing is in
    ///      custody, in ETH and in ERC-20.
    function test_Federation_StartNeedsANetworkRecipient() public {
        resolver.set(PRODUCT_FEDERATED, address(0), 0);
        address[2] memory currencies = [ETH, address(usd)];
        for (uint256 i; i < 2; ++i) {
            MockMintTarget federated = _federated(_terms(currencies[i]));
            vm.expectRevert(
                abi.encodeWithSelector(
                    ISaleAdapter.InvalidSaleTerms.selector, address(federated), 1
                )
            );
            auction.start(address(federated), "");
            address installed = auction.federationRegistry();
            vm.prank(successor);
            auction.setFederationRegistry(installed, address(0));
        }
    }

    /// Regression: MARKET-3 (docs/security/internal-review-2026-10.md); L6 in the review of #57
    /// @dev The token's own fee recipient is never paid for a federated sale, so it is not
    ///      checked: zero, or even the escrow, starts and settles to the network's recipient.
    function test_Federation_TheTokensOwnRecipientIsIgnored() public {
        PrimaryTerms memory terms = _terms(ETH);
        terms.feeRecipient = address(escrow);
        MockMintTarget federated = _federated(terms);
        uint256 saleId = auction.start(address(federated), "");
        _bidEth(saleId, alice, 1 ether);
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(saleId);
        assertEq(federatedNetwork.balance, 0.1 ether);
        assertEq(escrow.owed(address(escrow), ETH), 0);
    }
}

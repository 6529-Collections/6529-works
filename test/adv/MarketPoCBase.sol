// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { IDutchSale } from "src/interfaces/IDutchSale.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import {
    CURRENCY_ETH,
    PRODUCT_EDITIONS,
    PRODUCT_FEDERATED,
    PRODUCT_STREAM,
    WorkTerms
} from "src/interfaces/types/EconomicsTypes.sol";
import { EditionFormat, EditionTerms, ItemKind } from "src/interfaces/types/PackageTypes.sol";
import {
    DutchParams,
    Payment,
    PaymentMethod,
    PrimaryTerms,
    SaleKind
} from "src/interfaces/types/SaleTypes.sol";
import { MockMintTarget } from "../mocks/sales/AuctionMocks.sol";
import { MockFederationRegistry } from "../mocks/sales/SaleMocks.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";

/// @notice Shared setup for the MARKET lens PoCs, on the real stack deployed through `DeployV1` and the committed
///         genesis policy (guardians hold PAUSER and GUARDIAN with no delay; the hot admin holds
///         UNPAUSER and SUCCESSOR_SETTER with 48-hour and 30-day delays).
abstract contract MarketPoCBase is IntegrationBase {
    uint256 internal constant DUTCH_START = 1 ether;
    uint256 internal constant DUTCH_REST = 0.1 ether;
    uint64 internal constant DUTCH_DECAY = 24 hours;
    uint64 internal constant DUTCH_SIZE = 20;
    uint256 internal constant FIXED_PRICE = 0.1 ether;
    uint64 internal constant FIXED_SIZE = 50;

    address internal artist;
    address internal collector = makeAddr("masterCollector");
    address internal bot = makeAddr("mevBot");
    address internal fan = makeAddr("allowlistedFan");
    bytes32 internal root;

    function setUp() public override {
        super.setUp();
        artist = _actor("marketArtist");
        Work[] memory works = new Work[](4);
        works[0] = _master(_work(artist, collectionId), _dutchTerms());
        works[1] = _master(_work(artist, collectionId), _fixedTerms());
        works[2] = _work(artist, collectionId); // a plain 1/1 for the auction PoCs
        works[3] = _master(_work(artist, collectionId), _openTerms());
        root = _publish(works);
        _keep(root, works);
    }

    // ------------------------------------------------------------------ helpers

    function _dutchTerms() internal pure returns (EditionTerms memory) {
        return EditionTerms(
            EditionFormat.FIXED,
            DUTCH_SIZE,
            0,
            DUTCH_START,
            CURRENCY_ETH,
            SaleKind.DUTCH,
            abi.encode(DutchParams(DUTCH_REST, DUTCH_DECAY, 0))
        );
    }

    function _fixedTerms() internal pure returns (EditionTerms memory) {
        return EditionTerms(
            EditionFormat.FIXED, FIXED_SIZE, 0, FIXED_PRICE, CURRENCY_ETH, SaleKind.FIXED_PRICE, ""
        );
    }

    /// @dev An OPEN edition: unlimited copies for 48 hours from the first mint.
    function _openTerms() internal pure returns (EditionTerms memory) {
        return EditionTerms(
            EditionFormat.OPEN, 0, 48 hours, FIXED_PRICE, CURRENCY_ETH, SaleKind.FIXED_PRICE, ""
        );
    }

    function _master(Work memory w, EditionTerms memory terms) internal pure returns (Work memory) {
        w.item.kind = ItemKind.EDITION_MASTER;
        w.item.edition = terms;
        return w;
    }

    function _masterAndEdition(uint256 index) internal returns (uint256 workId) {
        Work[] memory works = _package(root);
        uint256 saleId;
        (saleId, workId) = _start(root, works, index);
        _ethBid(saleId, collector, 1 ether);
        _settleAtEnd(saleId);
        editions.createEdition(workId, works[index].item, root, _proofOf(works, index));
    }

    function _dutchBuy(uint256 saleId, address buyer, uint256 quantity) internal returns (uint256) {
        uint256 unit = dutchSale.currentPrice(saleId);
        uint256 total = unit * quantity;
        vm.deal(buyer, buyer.balance + total);
        vm.prank(buyer);
        dutchSale.purchase{ value: total }(
            saleId,
            address(0),
            quantity,
            unit,
            Payment(PaymentMethod.DIRECT, buyer, total, 0, 0, "")
        );
        return total;
    }

    /// @dev A federated ERC-721 (mock template) whose terms name `seller` and `feeRecipient`,
    ///      registered ACTIVE with a 10% network fee in a registry that governance installs on
    ///      the real auction through the 30-day SUCCESSOR_SETTER class.
    function _federated(address seller, address feeRecipient)
        internal
        returns (MockFederationRegistry reg, MockMintTarget fed)
    {
        reg = new MockFederationRegistry();
        fed = new MockMintTarget();
        fed.setAdmittedMinter(address(auction), true);
        fed.setTerms(
            PrimaryTerms(
                SaleKind.ENGLISH_AUCTION, CURRENCY_ETH, 0, "", seller, feeRecipient, 0, artist
            )
        );
        _govern(
            hotAdmin,
            address(auction),
            abi.encodeCall(auction.setFederationRegistry, (address(0), address(reg)))
        );
        reg.register(
            address(fed),
            IFederationRegistry.Entry(
                IFederationRegistry.Form.ERC721,
                address(0),
                uint160(artist),
                1,
                address(fed).codehash,
                10_000,
                IFederationRegistry.Status.ACTIVE
            )
        );
    }
}

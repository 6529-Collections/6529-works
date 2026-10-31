// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
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
import { EditionTerms, ItemKind } from "src/interfaces/types/PackageTypes.sol";
import { PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { MockMintTarget } from "../mocks/sales/AuctionMocks.sol";
import { MockFederationRegistry } from "../mocks/sales/SaleMocks.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";

/// @notice Shared setup for the sale adapters' tests on the real stack, deployed through
///         `DeployV1` with the committed genesis policy (guardians hold PAUSER and GUARDIAN with
///         no delay; the hot admin holds UNPAUSER and SUCCESSOR_SETTER with 48-hour and 30-day
///         delays). One package holds three edition masters (capped at 20 and 50, and
///         uncapped) and a plain 1/1 for the auction; helpers sell a master and create its
///         edition, and register a federated token.
abstract contract SalesStackBase is IntegrationBase {
    uint32 internal constant SMALL_CAP = 20;
    uint32 internal constant LARGE_CAP = 50;

    address internal artist;
    address internal collector = makeAddr("masterCollector");
    address internal bot = makeAddr("mevBot");
    address internal fan = makeAddr("allowlistedFan");
    bytes32 internal root;

    function setUp() public override {
        super.setUp();
        artist = _actor("marketArtist");
        Work[] memory works = new Work[](4);
        works[0] = _master(_work(artist, collectionId), _editionTerms(SMALL_CAP));
        works[1] = _master(_work(artist, collectionId), _editionTerms(LARGE_CAP));
        works[2] = _work(artist, collectionId); // a plain 1/1 for the auction PoCs
        works[3] = _master(_work(artist, collectionId), _editionTerms(0));
        root = _publish(works);
        _keep(root, works);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev The uniform-price edition auction in ETH, capped at `maxCount` (zero: no cap).
    function _editionTerms(uint32 maxCount) internal pure returns (EditionTerms memory) {
        return EditionTerms(maxCount, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
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

    function _deprecateEth() internal {
        _govern(
            guardian1, address(allowlist), abi.encodeCall(allowlist.deprecateAsset, (CURRENCY_ETH))
        );
    }

    function _readmitEth() internal {
        (,, uint64 revision) = allowlist.assetConfig(CURRENCY_ETH);
        _govern(
            hotAdmin,
            address(allowlist),
            abi.encodeCall(allowlist.admitAsset, (CURRENCY_ETH, revision, 0.001 ether))
        );
    }
}

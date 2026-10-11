// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { EditionFormat, EditionTerms, ItemKind } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";

/// @notice 6529 Editions gas on the real, wired stack (the integration lane's `IntegrationBase`):
///         `createEdition` for a settled master, and a first and a later copy minted by the
///         admitted fixed-price adapter. Run with `forge test --match-contract EditionsGasReport
///         -vv` to print the table.
/// @dev Every figure is cold (every contract cooled first) and a whole transaction: 21,000
///      intrinsic, the calldata and the called frame's execution (`IntegrationBase._measure`).
///      The mints call `Editions.mint` as the adapter does, so they are the token's share of a
///      purchase. Each copy goes to a new holder, the expensive case.
contract EditionsGasReport is IntegrationBase {
    /// @dev Regression ceilings, with headroom over the measured values.
    uint256 internal constant CREATE_CEILING = 330_000;
    uint256 internal constant MINT_CEILING = 110_000;

    address internal artist;
    bytes32 internal root;
    uint256 internal workId;

    function setUp() public override {
        super.setUp();
        artist = _actor("gasEditionArtist");
        Work[] memory works = new Work[](2);
        for (uint256 i; i < works.length; ++i) {
            works[i] = _work(artist, collectionId);
            works[i].item.kind = ItemKind.EDITION_MASTER;
            works[i].item.edition = EditionTerms(
                EditionFormat.FIXED, 50, 0, 0.01 ether, CURRENCY_ETH, SaleKind.FIXED_PRICE, ""
            );
        }
        root = _publish(works);
        _keep(root, works);
        // Two masters sold and settled; the first gets its edition here (steady state), the
        // second is the one measured.
        for (uint256 i; i < works.length; ++i) {
            (uint256 saleId, uint256 tokenId) = _start(root, works, i);
            _ethBid(saleId, makeAddr(string.concat("gasCollector", vm.toString(i))), 1 ether);
            _settleAtEnd(saleId);
            if (i == 0) editions.createEdition(tokenId, works[i].item, root, _proofOf(works, i));
            else workId = tokenId;
        }
    }

    function _createData() internal view returns (bytes memory) {
        Work[] memory works = _package(root);
        return
            abi.encodeCall(
                editions.createEdition, (workId, works[1].item, root, _proofOf(works, 1))
            );
    }

    function _mintData(address to) internal view returns (bytes memory) {
        return abi.encodeCall(editions.mint, (to, workId, 1, ""));
    }

    function test_Gas_CreateEdition() public {
        (uint256 total, uint256 execution) =
            _measure(makeAddr("anyone"), address(editions), _createData(), 0);
        _row("createEdition (settled master, 2-item package)", total, execution);
        assertLe(total, CREATE_CEILING, "createEdition");
        assertTrue(editions.exists(workId));
    }

    function test_Gas_MintFirstAndLaterCopy() public {
        Work[] memory works = _package(root);
        editions.createEdition(workId, works[1].item, root, _proofOf(works, 1));
        (uint256 total, uint256 execution) =
            _measure(address(fixedSale), address(editions), _mintData(makeAddr("buyer1")), 0);
        _row("mint, first copy of the edition (new holder)", total, execution);
        assertLe(total, MINT_CEILING, "first mint");
        (total, execution) =
            _measure(address(fixedSale), address(editions), _mintData(makeAddr("buyer2")), 0);
        _row("mint, later copy (new holder)", total, execution);
        assertLe(total, MINT_CEILING, "later mint");
        assertEq(editions.edition(workId).minted, 2);
    }

    function _row(string memory label, uint256 total, uint256 execution) internal pure {
        console2.log(label);
        console2.log("  execution (cold)", execution);
        console2.log("  whole transaction", total);
    }
}

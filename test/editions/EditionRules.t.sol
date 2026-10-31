// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { EditionRules } from "src/editions/EditionRules.sol";
import { CURRENCY_DEFAULT, CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { EditionTerms } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";

/// @dev Exposes the calldata-only rule.
contract EditionRulesHarness {
    function isValid(EditionTerms calldata t) external pure returns (bool) {
        return EditionRules.isValid(t);
    }
}

/// @notice The one edition-terms rule shared by the package registry and 6529 Stream Editions:
///         the uniform-price edition auction in ETH with no params, or any other sale kind a
///         later adapter claims (owner decision 14), with bounded params; any creator cap.
contract EditionRulesTest is Test {
    bytes32 internal constant FIXED_PRICE = keccak256("FIXED_PRICE");
    EditionRulesHarness internal rules = new EditionRulesHarness();

    function _terms(uint32 maxCount) internal pure returns (EditionTerms memory) {
        return EditionTerms(maxCount, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
    }

    /// @dev Any cap is valid, zero (no cap) included.
    function testFuzz_AnyCap(uint32 maxCount) public view {
        assertTrue(rules.isValid(_terms(maxCount)));
    }

    /// @dev The uniform-price edition auction is ETH-only with no params (ADR 0005).
    function test_UniformAuctionIsEthOnlyWithoutParams() public view {
        EditionTerms memory t = _terms(10);
        t.currency = CURRENCY_DEFAULT;
        assertFalse(rules.isValid(t));
        t.currency = address(0xE20);
        assertFalse(rules.isValid(t));
        t.currency = address(1);
        assertFalse(rules.isValid(t));
        t = _terms(0);
        t.params = hex"00";
        assertFalse(rules.isValid(t));
        t.params = abi.encode(uint256(1));
        assertFalse(rules.isValid(t));
    }

    /// @dev Another sale method's terms are valid without a redeployment: any label other than
    ///      none and the 1/1's, in any currency, with params up to the bound. Its adapter checks
    ///      the currency and params when it opens a sale.
    function test_OtherSaleKindsStayOpen() public view {
        EditionTerms memory t = EditionTerms(50, address(0xE20), FIXED_PRICE, abi.encode(1 ether));
        assertTrue(rules.isValid(t));
        t.currency = CURRENCY_DEFAULT;
        assertTrue(rules.isValid(t));
        t.saleKind = keccak256("RAFFLE");
        t.params = new bytes(EditionRules.MAX_PARAMS_BYTES);
        assertTrue(rules.isValid(t));
        t.params = new bytes(EditionRules.MAX_PARAMS_BYTES + 1);
        assertFalse(rules.isValid(t), "params past the bound");
        t.params = "";
        t.saleKind = 0;
        assertFalse(rules.isValid(t), "no sale kind");
        t.saleKind = SaleKind.ENGLISH_AUCTION;
        assertFalse(rules.isValid(t), "the 1/1's sale");
    }

    /// @dev Arbitrary terms never make the rule revert, and the verdict is exactly the rule.
    function testFuzz_MatchesTheRule(
        uint32 maxCount,
        address currency,
        bytes32 saleKind,
        bytes calldata params
    ) public view {
        EditionTerms memory t = EditionTerms(maxCount, currency, saleKind, params);
        bool expected = saleKind == SaleKind.UNIFORM_AUCTION
            ? currency == CURRENCY_ETH && params.length == 0
            : saleKind != 0 && saleKind != SaleKind.ENGLISH_AUCTION
                && params.length <= EditionRules.MAX_PARAMS_BYTES;
        assertEq(rules.isValid(t), expected);
    }

    /// @dev The kinds next to the auction's label are other kinds, not malformed auctions.
    function test_NeighbouringLabels() public view {
        EditionTerms memory t = _terms(10);
        t.currency = address(0xE20);
        t.saleKind = bytes32(uint256(SaleKind.UNIFORM_AUCTION) - 1);
        assertTrue(rules.isValid(t));
        t.saleKind = bytes32(uint256(SaleKind.UNIFORM_AUCTION) + 1);
        assertTrue(rules.isValid(t));
        t.saleKind = SaleKind.UNIFORM_AUCTION;
        assertFalse(rules.isValid(t));
    }
}

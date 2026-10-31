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

/// @notice The one edition-terms rule shared by the package registry and 6529 Stream Editions
///         (ADR 0005, owner decision 14): a nonzero sale kind and bounded params, nothing else.
///         The kind's adapter checks its own currency and params when it opens a sale.
contract EditionRulesTest is Test {
    EditionRulesHarness internal rules = new EditionRulesHarness();

    function _terms(uint32 maxCount) internal pure returns (EditionTerms memory) {
        return EditionTerms(maxCount, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
    }

    /// @dev Any cap is valid, zero (no cap) included.
    function testFuzz_AnyCap(uint32 maxCount) public view {
        assertTrue(rules.isValid(_terms(maxCount)));
    }

    /// @dev No sale kind is refused; every label an adapter may claim is accepted, the
    ///      edition auction's, rc.1's and one no adapter serves yet (LIM-EA-8).
    function test_AnyNonzeroKind() public view {
        EditionTerms memory t = _terms(10);
        t.saleKind = 0;
        assertFalse(rules.isValid(t), "no sale kind");
        bytes32[5] memory kinds = [
            SaleKind.UNIFORM_AUCTION,
            SaleKind.FIXED_PRICE,
            SaleKind.DUTCH,
            keccak256("RAFFLE"),
            bytes32(uint256(1))
        ];
        for (uint256 i; i < kinds.length; ++i) {
            t.saleKind = kinds[i];
            assertTrue(rules.isValid(t));
        }
    }

    /// @dev The currency is the sale method's: the rule never reads it (the edition auction
    ///      refuses anything but ETH when it opens).
    function test_AnyCurrency() public view {
        EditionTerms memory t = _terms(10);
        address[3] memory currencies = [CURRENCY_DEFAULT, address(0xE20), address(1)];
        for (uint256 i; i < currencies.length; ++i) {
            t.currency = currencies[i];
            assertTrue(rules.isValid(t));
        }
    }

    /// @dev Params are opaque but bounded, so `createEdition` always fits the transaction cap.
    function test_ParamsAreBounded() public view {
        EditionTerms memory t = _terms(0);
        t.params = abi.encode(uint256(1 ether));
        assertTrue(rules.isValid(t));
        t.params = new bytes(EditionRules.MAX_PARAMS_BYTES);
        assertTrue(rules.isValid(t), "at the bound");
        t.params = new bytes(EditionRules.MAX_PARAMS_BYTES + 1);
        assertFalse(rules.isValid(t), "past the bound");
    }

    /// @dev Arbitrary terms never make the rule revert, and the verdict is exactly the rule.
    function testFuzz_MatchesTheRule(
        uint32 maxCount,
        address currency,
        bytes32 saleKind,
        bytes calldata params
    ) public view {
        EditionTerms memory t = EditionTerms(maxCount, currency, saleKind, params);
        assertEq(rules.isValid(t), saleKind != 0 && params.length <= EditionRules.MAX_PARAMS_BYTES);
    }
}

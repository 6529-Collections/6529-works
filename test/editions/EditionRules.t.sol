// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { EditionRules } from "src/editions/EditionRules.sol";
import { CURRENCY_DEFAULT, CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { EditionFormat, EditionTerms } from "src/interfaces/types/PackageTypes.sol";
import { DutchParams, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { DutchPricing } from "src/sales/DutchPricing.sol";

/// @dev Exposes the calldata-only rule.
contract EditionRulesHarness {
    function isValid(EditionTerms calldata t) external pure returns (bool) {
        return EditionRules.isValid(t);
    }
}

/// @notice The one edition-terms rule shared by the package registry and 6529 Editions.
contract EditionRulesTest is Test {
    uint256 internal constant PRICE = 0.1 ether;
    EditionRulesHarness internal rules = new EditionRulesHarness();

    function _fixed() internal pure returns (EditionTerms memory) {
        return
            EditionTerms(EditionFormat.FIXED, 10, 0, PRICE, CURRENCY_ETH, SaleKind.FIXED_PRICE, "");
    }

    function _dutch(uint256 resting, uint64 duration, uint64 step)
        internal
        pure
        returns (EditionTerms memory)
    {
        return EditionTerms(
            EditionFormat.OPEN,
            0,
            1 days,
            PRICE,
            CURRENCY_ETH,
            SaleKind.DUTCH,
            abi.encode(DutchParams(resting, duration, step))
        );
    }

    function test_FixedPriceShapes() public view {
        EditionTerms memory t = _fixed();
        assertTrue(rules.isValid(t));
        t.size = 0; // a fixed edition of nothing
        assertFalse(rules.isValid(t));
        t = _fixed();
        t.window = 1; // a fixed edition has no window
        assertFalse(rules.isValid(t));
        t = _fixed();
        t.format = EditionFormat.OPEN; // an open edition needs a window
        assertFalse(rules.isValid(t));
        t.window = 1 days;
        assertTrue(rules.isValid(t));
        t.size = 0; // an uncapped open edition
        assertTrue(rules.isValid(t));
        t = _fixed();
        t.params = hex"01"; // fixed price takes no params
        assertFalse(rules.isValid(t));
    }

    function test_SaleKinds() public view {
        EditionTerms memory t = _fixed();
        t.saleKind = SaleKind.ENGLISH_AUCTION;
        assertFalse(rules.isValid(t));
        t.saleKind = 0;
        assertFalse(rules.isValid(t));
        t.saleKind = keccak256("RAFFLE");
        assertFalse(rules.isValid(t));
    }

    function test_DefaultCurrencyOnlyWhenFree() public view {
        EditionTerms memory t = _fixed();
        t.currency = CURRENCY_DEFAULT;
        assertFalse(rules.isValid(t));
        t.price = 0;
        assertTrue(rules.isValid(t));
        EditionTerms memory d = _dutch(0, 0, 0);
        d.currency = CURRENCY_DEFAULT;
        assertFalse(rules.isValid(d));
    }

    /// @dev The Dutch schedule must be one `DutchSale.openSale` accepts (`DutchPricing.isValid`).
    function test_DutchSchedules() public view {
        assertTrue(rules.isValid(_dutch(PRICE / 10, 1 hours, 0)));
        assertTrue(rules.isValid(_dutch(PRICE / 10, 100, 10)));
        assertTrue(rules.isValid(_dutch(PRICE, 0, 0)), "a flat price needs no duration");
        assertFalse(rules.isValid(_dutch(PRICE + 1, 1 hours, 0)), "rests above the start");
        assertFalse(rules.isValid(_dutch(PRICE / 10, 0, 0)), "falls with no duration");
        assertFalse(rules.isValid(_dutch(PRICE / 10, 100, 7)), "steps do not divide");
    }

    /// @dev Malformed params never revert the rule: wrong length or words that are not uint64.
    function test_DutchMalformedParams() public view {
        EditionTerms memory t = _dutch(0, 1, 0);
        t.params = abi.encode(DutchParams(0, 1, 0), uint256(1)); // too long
        assertFalse(rules.isValid(t));
        t.params = hex"00"; // too short
        assertFalse(rules.isValid(t));
        t.params = "";
        assertFalse(rules.isValid(t));
        t.params = abi.encode(uint256(0), uint256(1) << 64, uint256(0)); // duration > uint64
        assertFalse(rules.isValid(t));
        t.params = abi.encode(uint256(0), uint256(64), uint256(1) << 64); // step > uint64
        assertFalse(rules.isValid(t));
    }

    /// @dev For well-formed params the Dutch verdict is exactly `DutchPricing.isValid`.
    function testFuzz_DutchMatchesPricing(
        uint256 price,
        uint256 resting,
        uint64 duration,
        uint64 step
    ) public view {
        EditionTerms memory t = _dutch(resting, duration, step);
        t.price = price;
        assertEq(rules.isValid(t), DutchPricing.isValid(price, resting, duration, step));
    }

    /// @dev Arbitrary params bytes never make the rule revert.
    function testFuzz_NeverReverts(bytes calldata params, bool dutch, uint8 format) public view {
        EditionTerms memory t = _dutch(0, 1, 0);
        t.params = params;
        t.saleKind = dutch ? SaleKind.DUTCH : SaleKind.FIXED_PRICE;
        t.format = EditionFormat(format % 2);
        rules.isValid(t);
    }
}

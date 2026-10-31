// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { UniformClearing } from "src/sales/UniformClearing.sol";
import { StepLadder } from "src/interfaces/types/StepLadder.sol";
import { UniformClearingBase } from "./UniformClearingBase.sol";

/// @notice A settlement's read of the book: the live words in storage, keyed as PLAN Appendix A
///         keys them (`saleKey << 8 | word`), loaded into memory and cleared. Each call reports
///         the gas of the library call alone, and of the load and the call together.
contract BookReader {
    mapping(uint256 => uint256) internal live;

    function store(uint256 key, uint256[] calldata words) external {
        for (uint256 w; w < words.length; ++w) {
            live[key << 8 | w] = words[w];
        }
    }

    /// @dev Loads words `lo / 8` to `hi / 8` (the used range), clears, and meters both.
    function settleRead(
        uint256 key,
        uint256 lo,
        uint256 hi,
        uint256 words,
        UniformClearing.Rules memory rules
    )
        external
        view
        returns (UniformClearing.Result memory r, uint256 clearCost, uint256 totalCost)
    {
        uint256 start = gasleft();
        uint256[] memory book = new uint256[](words);
        for (uint256 w = lo >> 3; w <= hi >> 3; ++w) {
            book[w] = live[key << 8 | w];
        }
        uint256 beforeClear = gasleft();
        r = UniformClearing.clear(book, rules);
        uint256 end = gasleft();
        (clearCost, totalCost) = (beforeClear - end, start - end);
    }

    /// @dev The gas of {UniformClearing.clear} on a book in memory.
    function clearGas(uint256[] memory book, UniformClearing.Rules memory rules)
        external
        view
        returns (uint256 used)
    {
        uint256 start = gasleft();
        UniformClearing.clear(book, rules);
        used = start - gasleft();
    }

    /// @dev The gas of {UniformClearing.quote} on a book in memory.
    function quoteGas(
        uint256[] memory book,
        UniformClearing.Rules memory rules,
        uint256 step,
        uint256 qty
    ) external view returns (uint256 used) {
        uint256 start = gasleft();
        UniformClearing.quote(book, rules, step, qty);
        used = start - gasleft();
    }

    /// @dev The gas of one `StepLadder.price`, which a bid pays once and a raise twice.
    function priceGas(uint256 base, uint256 perDecade, uint256 step)
        external
        view
        returns (uint256 used)
    {
        uint256 start = gasleft();
        StepLadder.price(base, perDecade, step);
        used = start - gasleft();
    }
}

/// @notice Prague gas of the clearing library on dense books: every one of the default 336
///         steps used, the settlement worst case the plan budgets (PLAN section 1.11), and the
///         512-step maximum. The figures are exact for the pinned compiler and optimizer
///         settings; a change to the library that moves them updates them here.
contract UniformClearingGasTest is UniformClearingBase {
    BookReader internal reader;

    function setUp() public override {
        super.setUp();
        reader = new BookReader();
    }

    /// @dev Every step below `steps` holds `1 + step % 7` units, as lane L0's dense vector does.
    function _dense(uint256 steps) internal pure returns (uint256[] memory live) {
        live = new uint256[]((steps + 7) / 8);
        for (uint256 s; s < steps; ++s) {
            live[s >> 3] |= (1 + s % 7) << ((s & 7) * 32);
        }
    }

    function test_Gas_ClearADenseBookOf336Steps() public {
        reader.store(1, _dense(336));
        vm.cool(address(reader));
        (UniformClearing.Result memory r, uint256 clearGas, uint256 totalGas) =
            reader.settleRead(1, 0, 335, 42, _rules(0, TEN_PERCENT));
        console.log("dense 336, uncapped: clear %d; with its 42 cold slots %d", clearGas, totalGas);
        assertEq(r.count, 125);
        assertEq(r.step, 306);
        assertEq(clearGas, 188_349);
        assertEq(totalGas, 288_266);
    }

    /// @dev A cap reached only at the bottom of the book keeps every step a candidate.
    function test_Gas_ClearADenseBookOf336StepsWithACap() public {
        reader.store(1, _dense(336));
        vm.cool(address(reader));
        (UniformClearing.Result memory r, uint256 clearGas, uint256 totalGas) =
            reader.settleRead(1, 0, 335, 42, _rules(1340, TEN_PERCENT));
        console.log("dense 336, capped: clear %d; with its 42 cold slots %d", clearGas, totalGas);
        assertEq(r.count, 125);
        assertEq(clearGas, 187_439);
        assertEq(totalGas, 287_356);
    }

    /// @dev The library's maximum: 512 steps on the 24-per-decade ladder, every lane full.
    function test_Gas_ClearTheLargestBook() public {
        uint256[] memory live = new uint256[](64);
        for (uint256 w; w < 64; ++w) {
            live[w] = type(uint256).max;
        }
        reader.store(1, live);
        vm.cool(address(reader));
        UniformClearing.Rules memory rules = UniformClearing.Rules({
            basePrice: type(uint96).max, stepsPerDecade: 24, maxCount: 0, marginShare: 0
        });
        (, uint256 clearGas, uint256 totalGas) = reader.settleRead(1, 0, 511, 64, rules);
        console.log("512 full steps: clear %d; with its 64 cold slots %d", clearGas, totalGas);
        assertEq(clearGas, 285_507);
        assertEq(totalGas, 437_658);
    }

    /// @dev A typical book: 40 used steps, 5 apart from 0.0018 ETH up (steps 60 to 255), in 25
    ///      words of the default 42.
    function test_Gas_ClearATypicalBook() public {
        uint256[] memory live = new uint256[](42);
        for (uint256 i; i < 40; ++i) {
            uint256 s = 60 + i * 5;
            live[s >> 3] |= (1 + i % 9) << ((s & 7) * 32);
        }
        reader.store(1, live);
        vm.cool(address(reader));
        (, uint256 clearGas, uint256 totalGas) =
            reader.settleRead(1, 60, 255, 42, _rules(0, TEN_PERCENT));
        console.log("40 used steps: clear %d; with its 25 cold slots %d", clearGas, totalGas);
        assertEq(clearGas, 40_406);
        assertEq(totalGas, 100_067);
    }

    function test_Gas_QuoteADenseBook() public view {
        uint256 used = reader.quoteGas(_dense(336), _rules(0, TEN_PERCENT), 200, 5);
        console.log("quote on the dense book: %d", used);
        assertEq(used, 189_117);
    }

    function test_Gas_PriceOfOneStep() public view {
        uint256 low = reader.priceGas(BASE, N, 0);
        uint256 high = reader.priceGas(BASE, N, 335);
        console.log("price: step 0 %d, step 335 %d", low, high);
        assertEq(low, 909);
        assertEq(high, 1116);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title StepLadder
/// @notice The fixed price steps of the 6529 Stream Editions auction (ADR 0005; 6529chain
///         D138: "the fixed steps are right too, people should see if they would get cards or
///         not at any point in time"). Every bid sits on a step; step `i` costs
///         `basePrice * mantissa((i % N) * (192 / N)) * 10^(i / N) / 100`, dividing last, where
///         `N` is the governed number of steps per decade (24, 48, 96 or 192: about 10%, 4.9%,
///         2.4% or 1.2% apart). The mantissa table rounds `100 * 10^(j / 192)` half up for
///         `j < 192`, so every coarser ladder is a subset of every finer one and prices read
///         cleanly (0.0464, 0.0487, 0.0511 ETH). Defaults: 48 steps per decade from 0.0001 ETH,
///         336 steps, the top one 953 ETH.
/// @dev Internal functions and constants only: nothing here is linked. Lookups are O(1) and
///      read no storage, so the bid, settlement and every view price a step identically, and
///      `tools/edition_auction_ref.py` reproduces every price (golden vectors in
///      `test/fixtures/edition-auction/ladder.json`, pinned by `test/interfaces/StepLadder.t.sol`).
///      The 192 mantissas are three-digit values packed as 16-bit words, 16 to a constant.
library StepLadder {
    /// @notice Entries in the mantissa table.
    uint256 internal constant MANTISSAS = 192;
    /// @notice The mantissas' scale: mantissa 100 is a price of exactly `basePrice`.
    uint256 internal constant MANTISSA_SCALE = 100;
    /// @notice The default price of step 0: 0.0001 ETH.
    uint256 internal constant DEFAULT_BASE_PRICE = 1e14;
    /// @notice The default steps per decade: 48, steps 4.3% to 5.3% apart.
    uint256 internal constant DEFAULT_STEPS_PER_DECADE = 48;
    /// @notice The default number of steps: 336, from 0.0001 ETH to 953 ETH.
    uint256 internal constant DEFAULT_STEP_COUNT = 336;
    /// @notice The lowest base price governance may set, in wei.
    uint256 internal constant MIN_BASE_PRICE = 1e12;
    /// @notice The highest base price governance may set, in wei.
    uint256 internal constant MAX_BASE_PRICE = 1e17;
    /// @notice The fewest steps a ladder may have.
    uint256 internal constant MIN_STEP_COUNT = 64;
    /// @notice The most steps a ladder may have; it bounds the settlement scan.
    uint256 internal constant MAX_STEP_COUNT = 512;
    /// @notice The lowest top-step price a ladder may have, so no configuration caps every
    ///         edition's price below plausible demand: 10 ETH.
    uint256 internal constant MIN_TOP_PRICE = 10 ether;

    /// @dev Mantissas 0 to 15.
    uint256 private constant _M0 =
        0x00640065006600680069006a006b006d006e006f007100720073007500760078;
    /// @dev Mantissas 16 to 31.
    uint256 private constant _M1 =
        0x0079007b007c007e007f008100820084008500870089008a008c008e008f0091;
    /// @dev Mantissas 32 to 47.
    uint256 private constant _M2 =
        0x0093009500960098009a009c009e00a000a200a400a500a700a900ac00ae00b0;
    /// @dev Mantissas 48 to 63.
    uint256 private constant _M3 =
        0x00b200b400b600b800bb00bd00bf00c100c400c600c800cb00cd00d000d200d5;
    /// @dev Mantissas 64 to 79.
    uint256 private constant _M4 =
        0x00d700da00dd00df00e200e500e800ea00ed00f000f300f600f900fc00ff0102;
    /// @dev Mantissas 80 to 95.
    uint256 private constant _M5 =
        0x01050108010b010f011201150118011c011f01230126012a012d013101350138;
    /// @dev Mantissas 96 to 111.
    uint256 private constant _M6 =
        0x013c014001440148014c015001540158015c016001650169016d01720176017b;
    /// @dev Mantissas 112 to 127.
    uint256 private constant _M7 =
        0x017f01840188018d01920197019c01a101a601ab01b001b501ba01c001c501cb;
    /// @dev Mantissas 128 to 143.
    uint256 private constant _M8 =
        0x01d001d601db01e101e701ed01f301f901ff0205020b02120218021e0225022c;
    /// @dev Mantissas 144 to 159.
    uint256 private constant _M9 =
        0x0232023902400247024e0255025c0264026b0272027a028202890291029902a1;
    /// @dev Mantissas 160 to 175.
    uint256 private constant _M10 =
        0x02a902b202ba02c202cb02d302dc02e502ee02f7030003090313031c03260330;
    /// @dev Mantissas 176 to 191.
    uint256 private constant _M11 =
        0x03390343034d03580362036c03770382038d039703a303ae03b903c503d003dc;

    /// @notice A mantissa index at or past `MANTISSAS`.
    error MantissaIndexOutOfRange(uint256 index);

    /// @notice Whether `stepsPerDecade` is one of the four ladders: 24, 48, 96 or 192.
    function isStepsPerDecade(uint256 stepsPerDecade) internal pure returns (bool) {
        return stepsPerDecade == 24 || stepsPerDecade == 48 || stepsPerDecade == 96
            || stepsPerDecade == 192;
    }

    /// @notice Whether a ladder is within the bounds governance may set: a valid steps per
    ///         decade, a base price in `[MIN_BASE_PRICE, MAX_BASE_PRICE]`, a step count in
    ///         `[MIN_STEP_COUNT, MAX_STEP_COUNT]` and a top step of at least `MIN_TOP_PRICE`.
    function isValid(uint256 basePrice, uint256 stepsPerDecade, uint256 stepCount)
        internal
        pure
        returns (bool)
    {
        return isStepsPerDecade(stepsPerDecade) && basePrice >= MIN_BASE_PRICE
            && basePrice <= MAX_BASE_PRICE && stepCount >= MIN_STEP_COUNT
            && stepCount <= MAX_STEP_COUNT
            && price(basePrice, stepsPerDecade, stepCount - 1) >= MIN_TOP_PRICE;
    }

    /// @notice Mantissa `j`: `100 * 10^(j / 192)` rounded half up, from 100 to 988.
    function mantissa(uint256 j) internal pure returns (uint256) {
        if (j >= MANTISSAS) revert MantissaIndexOutOfRange(j);
        uint256 q = j >> 4;
        uint256 w;
        if (q < 6) {
            if (q < 3) w = q == 0 ? _M0 : q == 1 ? _M1 : _M2;
            else w = q == 3 ? _M3 : q == 4 ? _M4 : _M5;
        } else {
            if (q < 9) w = q == 6 ? _M6 : q == 7 ? _M7 : _M8;
            else w = q == 9 ? _M9 : q == 10 ? _M10 : _M11;
        }
        return (w >> ((15 - (j & 15)) * 16)) & 0xffff;
    }

    /// @notice The price of `step`, in wei: `basePrice * mantissa * 10^decade / 100`.
    /// @dev `stepsPerDecade` must satisfy `isStepsPerDecade`; callers validate it with the rest
    ///      of the configuration. A step whose price overflows reverts (far past any bound).
    function price(uint256 basePrice, uint256 stepsPerDecade, uint256 step)
        internal
        pure
        returns (uint256)
    {
        uint256 m = mantissa((step % stepsPerDecade) * (MANTISSAS / stepsPerDecade));
        return basePrice * m * 10 ** (step / stepsPerDecade) / MANTISSA_SCALE;
    }
}

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
///      The 192 mantissas are packed as 10-bit fields, 24 to a constant (mantissa `j` in bits
///      `10 * (j % 24)` of constant `j / 24`): 8 words, the cheapest exact packing measured in
///      bytecode and gas (lane L1).
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
    /// @notice The lowest base price governance may set, in wei: 0.000001 ETH. Every base
    ///         price is a power of ten (`isBasePrice`).
    uint256 internal constant MIN_BASE_PRICE = 1e12;
    /// @notice The highest base price governance may set, in wei: 0.1 ETH.
    uint256 internal constant MAX_BASE_PRICE = 1e17;
    /// @notice The fewest steps a ladder may have.
    uint256 internal constant MIN_STEP_COUNT = 64;
    /// @notice The most steps a ladder may have; it bounds the settlement scan.
    uint256 internal constant MAX_STEP_COUNT = 512;
    /// @notice The lowest top-step price a ladder may have, so no configuration caps every
    ///         edition's price below plausible demand: 10 ETH.
    uint256 internal constant MIN_TOP_PRICE = 10 ether;

    /// @dev Mantissas 0 to 23: 100 101 102 104 105 106 107 109 110 111 113 114
    ///      115 117 118 120 121 123 124 126 127 129 130 132.
    uint256 private constant _M0 = 0x210822047f1f87c1ec791e0761d4731c8711bc6e1b46b1a8691a06619464;
    /// @dev Mantissas 24 to 47: 133 135 137 138 140 142 143 145 147 149 150 152
    ///      154 156 158 160 162 164 165 167 169 172 174 176.
    uint256 private constant _M1 = 0x2c0ae2b0a929ca5290a22809e2709a26096254932448f2388c2288921c85;
    /// @dev Mantissas 48 to 71: 178 180 182 184 187 189 191 193 196 198 200 203
    ///      205 208 210 213 215 218 221 223 226 229 232 234.
    uint256 private constant _M2 = 0x3a8e8394e237cdd368d7354d2340cd32cc8318c4304bf2f4bb2e0b62d0b2;
    /// @dev Mantissas 72 to 95: 237 240 243 246 249 252 255 258 261 264 267 271
    ///      274 277 280 284 287 291 294 298 301 305 309 312.
    uint256 private constant _M3 = 0x4e1354c52d4a92648d1f471184551243d0b42105408ff3f0f93d8f33c0ed;
    /// @dev Mantissas 96 to 119: 316 320 324 328 332 336 340 344 348 352 357 361
    ///      365 370 374 379 383 388 392 397 402 407 412 417.
    uint256 private constant _M4 = 0x6859c65d92635886117f5ed765c96d5a5655815c561545414c521445013c;
    /// @dev Mantissas 120 to 143: 422 427 432 437 442 448 453 459 464 470 475 481
    ///      487 493 499 505 511 517 523 530 536 542 549 556.
    uint256 private constant _M5 = 0x8b22587a1884a0b815ff7e5f37b5e7785db759d072dc5701ba6d5b06ada6;
    /// @dev Mantissas 144 to 167: 562 569 576 583 590 597 604 612 619 626 634 642
    ///      649 657 665 673 681 690 698 706 715 723 732 741.
    uint256 private constant _M6 = 0xb96dcb4ecbb0abaacaa9a8699a4689a0a7a9ca6b9925c9564e91e408e632;
    /// @dev Mantissas 168 to 191: 750 759 768 777 787 796 806 816 825 835 845 856
    ///      866 876 887 898 909 919 931 942 953 965 976 988.
    uint256 private constant _M7 = 0xf73d0f17b9ebba3e5f8de0b77db362d634dd0f39cc326c7313c2700bdeee;

    /// @notice A mantissa index at or past `MANTISSAS`.
    error MantissaIndexOutOfRange(uint256 index);

    /// @notice Whether `stepsPerDecade` is one of the four ladders: 24, 48, 96 or 192.
    function isStepsPerDecade(uint256 stepsPerDecade) internal pure returns (bool) {
        return stepsPerDecade == 24 || stepsPerDecade == 48 || stepsPerDecade == 96
            || stepsPerDecade == 192;
    }

    /// @notice Whether `basePrice` is a power of ten from `MIN_BASE_PRICE` to `MAX_BASE_PRICE`
    ///         (10^12 to 10^17 wei). With a power-of-ten base every price is a table mantissa
    ///         times a power of ten, so it reads as the table does (ADR 0005 decision 3, readable
    ///         prices from a fixed table). A base of 0.00015 ETH would price the next steps
    ///         at 0.0001575 and 0.000165 ETH instead of 0.000105 and 0.00011.
    function isBasePrice(uint256 basePrice) internal pure returns (bool) {
        for (uint256 p = MIN_BASE_PRICE; p <= MAX_BASE_PRICE; p *= 10) {
            if (basePrice == p) return true;
        }
        return false;
    }

    /// @notice Whether a ladder is within the bounds governance may set: a valid steps per
    ///         decade, a base price `isBasePrice` accepts (a power of ten from `MIN_BASE_PRICE`
    ///         to `MAX_BASE_PRICE`), a step count in `[MIN_STEP_COUNT, MAX_STEP_COUNT]` and a
    ///         top step of at least `MIN_TOP_PRICE`.
    function isValid(uint256 basePrice, uint256 stepsPerDecade, uint256 stepCount)
        internal
        pure
        returns (bool)
    {
        return isStepsPerDecade(stepsPerDecade) && isBasePrice(basePrice)
            && stepCount >= MIN_STEP_COUNT && stepCount <= MAX_STEP_COUNT
            && price(basePrice, stepsPerDecade, stepCount - 1) >= MIN_TOP_PRICE;
    }

    /// @notice Mantissa `j`: `100 * 10^(j / 192)` rounded half up, from 100 to 988.
    function mantissa(uint256 j) internal pure returns (uint256) {
        if (j >= MANTISSAS) revert MantissaIndexOutOfRange(j);
        unchecked {
            uint256 q = j / 24;
            uint256 w;
            if (q < 4) {
                if (q < 2) w = q == 0 ? _M0 : _M1;
                else w = q == 2 ? _M2 : _M3;
            } else {
                if (q < 6) w = q == 4 ? _M4 : _M5;
                else w = q == 6 ? _M6 : _M7;
            }
            return (w >> ((j - q * 24) * 10)) & 0x3ff;
        }
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

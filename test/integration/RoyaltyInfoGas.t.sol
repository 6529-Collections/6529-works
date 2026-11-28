// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { GasBase } from "./GasBase.sol";

/// @notice `Stream6529.royaltyInfo` under a caller's gas limit (ADR 0004's table: 50,000 gas of
///         execution), on the deployed stack. Marketplaces call it with their own limits, so the
///         call must fit the budget, and with less gas it must revert, never answer a zero or
///         partial royalty.
/// @dev The work is minted in `setUp`, a separate transaction, so Stream is a cold account at
///      the start of each test, as for a marketplace's call; its storage is cooled too
///      (`_coolAll`). The work's royalty receiver is its royalty-payees vault (the seller and the
///      network at the genesis fee share), so the answer is a real receiver and a nonzero
///      amount. Stream answers from its own storage (no module is asked).
contract RoyaltyInfoGasTest is GasBase {
    /// @dev ADR 0004's budget for `royaltyInfo`, in execution gas.
    uint256 internal constant ROYALTY_INFO_BUDGET = 50_000;
    uint256 internal constant PRICE = 1 ether;

    uint256 internal tokenId;

    function setUp() public override {
        super.setUp();
        Work[] memory works = _one(_work(_actor("royaltyArtist"), collectionId));
        bytes32 root = _publish(works);
        (, tokenId) = _start(root, works, 0);
    }

    /// @dev `royaltyInfo` with exactly `gas` for its frame; the decoded answer when it succeeds.
    function _capped(uint256 gas) internal returns (bool ok, address receiver, uint256 amount) {
        _coolAll();
        bytes memory ret;
        (ok, ret) = address(stream).staticcall{ gas: gas }(
            abi.encodeCall(stream.royaltyInfo, (tokenId, PRICE))
        );
        if (ok) (receiver, amount) = abi.decode(ret, (address, uint256));
    }

    /// @dev The first call of the test, with every account and slot it reads cold: the budget is
    ///      enough, and the answer is the uncapped one.
    function test_RoyaltyInfo_FitsItsGasBudgetCold() public {
        (bool ok, address receiver, uint256 amount) = _capped(ROYALTY_INFO_BUDGET);
        assertTrue(ok, "royaltyInfo within its 50,000-gas budget");
        (address expectedReceiver, uint256 expectedAmount) = stream.royaltyInfo(tokenId, PRICE);
        assertEq(receiver, expectedReceiver, "receiver");
        assertEq(amount, expectedAmount, "amount");
        assertTrue(receiver != address(0) && amount != 0, "a real royalty");
        assertEq(receiver, stream.workOf(tokenId).royaltyReceiver, "the stored receiver");
    }

    /// @dev Below the least gas that succeeds, every limit reverts; none answers a zero or
    ///      partial royalty. Every limit from 3,000 gas below the threshold (or from nothing) to
    ///      just above it is tried, then every 50 gas down to nothing. Measured threshold: 2,937.
    function test_RoyaltyInfo_RevertsWithTooLittleGasAndNeverAnswersZero() public {
        (address expectedReceiver, uint256 expectedAmount) = stream.royaltyInfo(tokenId, PRICE);
        assertGt(expectedAmount, 0);
        // The least gas that succeeds, by bisection (the call is monotone in its gas).
        uint256 low;
        uint256 high = ROYALTY_INFO_BUDGET;
        (bool ok,,) = _capped(high);
        assertTrue(ok, "the budget succeeds");
        while (high - low > 1) {
            uint256 mid = (low + high) / 2;
            (ok,,) = _capped(mid);
            if (ok) high = mid;
            else low = mid;
        }
        uint256 threshold = high;
        // At least one cold storage read (2,100): the answer is read, not assumed.
        assertGt(threshold, 2100, "a real threshold");
        for (uint256 gas = threshold > 3000 ? threshold - 3000 : 0; gas < threshold + 100; ++gas) {
            _expectRevertOrExact(gas, threshold, expectedReceiver, expectedAmount);
        }
        for (uint256 gas; gas < threshold; gas += 50) {
            _expectRevertOrExact(gas, threshold, expectedReceiver, expectedAmount);
        }
    }

    function _expectRevertOrExact(
        uint256 gas,
        uint256 threshold,
        address expectedReceiver,
        uint256 expectedAmount
    ) internal {
        (bool ok, address receiver, uint256 amount) = _capped(gas);
        if (gas < threshold) {
            assertFalse(ok, string.concat("succeeded below the threshold at ", vm.toString(gas)));
        } else {
            assertTrue(ok, string.concat("failed above the threshold at ", vm.toString(gas)));
            assertEq(receiver, expectedReceiver, "receiver");
            assertEq(amount, expectedAmount, "amount");
        }
    }
}

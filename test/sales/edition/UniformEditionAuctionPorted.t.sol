// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { UniformEditionAuction } from "src/sales/UniformEditionAuction.sol";
import { EditionAuctionBase } from "./EditionAuctionBase.sol";

/// @notice Re-ported from the retired edition auction's suite (found by mutation testing): the
///         payout gas's two absolute bounds, each where no other rule refuses the value.
contract UniformEditionAuctionPortedTest is EditionAuctionBase {
    function _constructWith(uint32 payoutGas) internal returns (UniformEditionAuction) {
        return new UniformEditionAuction(
            address(manager),
            address(escrow),
            address(directory),
            address(editions),
            address(english),
            lensAddress,
            lensAddress.codehash,
            defaultConfig(),
            IUniformEditionAuction.Limits(payoutGas)
        );
    }

    /// @dev The bounds are exact. At construction (no current figure, so the rise rule does not
    ///      apply) 29,999 and 3,000,001 are refused, 30,000 and 3,000,000 taken. From 1,600,000
    ///      doubling would allow 3,200,000, so only the ceiling refuses 3,000,001; 3,000,000 is
    ///      taken though it is below double.
    function test_SetLimits_TheBoundsAreExact() public {
        vm.expectRevert(IUniformEditionAuction.InvalidConfig.selector);
        _constructWith(29_999);
        assertEq(IUniformEditionAuction(address(_constructWith(30_000))).limits().payoutGas, 30_000);
        vm.expectRevert(IUniformEditionAuction.InvalidConfig.selector);
        _constructWith(3_000_001);
        assertEq(
            IUniformEditionAuction(address(_constructWith(3_000_000))).limits().payoutGas, 3_000_000
        );

        _setLimits(IUniformEditionAuction.Limits(200_000));
        _setLimits(IUniformEditionAuction.Limits(400_000));
        _setLimits(IUniformEditionAuction.Limits(800_000));
        _setLimits(IUniformEditionAuction.Limits(1_600_000));
        vm.expectRevert(IUniformEditionAuction.InvalidConfig.selector);
        auction.setLimits(1_600_000, 3_000_001);
        _setLimits(IUniformEditionAuction.Limits(3_000_000));
        assertEq(ua.limits().payoutGas, 3_000_000);
    }
}

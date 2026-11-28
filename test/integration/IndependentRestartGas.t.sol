// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IndependentStream6529 } from "src/independent/IndependentStream6529.sol";
import { GasBase } from "./GasBase.sol";
import { IndependentIntegrationBase } from "./IndependentIntegrationBase.sol";
import { IntegrationBase } from "./IntegrationBase.sol";
import { StateGrowth } from "test/helpers/StateGrowth.sol";

/// @notice The Prague gas and state growth of offering an unsold Independent Stream work again
///         (`EnglishAuction.restart`), measured as `IntegrationGasReport` measures its rows: the
///         whole transaction on the real deployed stack, every contract's storage cold. Two rows
///         of ADR 0004's table: a work's first restart, which writes the one new word that
///         records when the work was offered again, and a later restart, which rewrites it.
/// @dev The ceilings are regression ceilings: the figure when set (23 November 2026) plus about
///      2%, rounded up to the thousand. A change that crosses one says why and moves it.
contract IndependentRestartGasTest is GasBase, IndependentIntegrationBase {
    uint256 internal constant RESTART_FIRST_CEILING = 114_000;
    uint256 internal constant RESTART_LATER_CEILING = 96_000;

    address internal artist;
    address internal anyone = makeAddr("gasAnyone");
    IndependentStream6529 internal fStream;
    uint256 internal saleId;

    function setUp() public override(IntegrationBase, IndependentIntegrationBase) {
        super.setUp();
        artist = _actor("restartGasArtist");
        (fStream,) = _listPair(artist);
        (, saleId,) = _fedApproveAndStart(address(fStream), artist);
    }

    /// @dev The artist's token is read by the restart, so it is cooled and probed too.
    function _cooled() internal view override returns (address[] memory all) {
        address[] memory base = super._cooled();
        all = new address[](base.length + 1);
        for (uint256 i; i < base.length; ++i) {
            all[i] = base[i];
        }
        all[base.length] = address(fStream);
    }

    function test_Gas_IndependentRestart_AWorksFirst() public {
        _settleAtEnd(saleId);
        vm.warp(block.timestamp + auction.RESTART_DELAY());
        (uint256 total, StateGrowth.Growth memory growth) = _restart();
        emit log_named_uint("Independent Stream restart, a work's first: Prague gas", total);
        assertLe(total, RESTART_FIRST_CEILING, "first restart over its regression ceiling");
        assertEq(growth.slots, 1, "one new slot: when the work was offered again");
        assertEq(growth.accounts, 0, "no new account");
    }

    function test_Gas_IndependentRestart_ALaterOne() public {
        _settleAtEnd(saleId);
        vm.warp(block.timestamp + auction.RESTART_DELAY());
        vm.prank(anyone);
        auction.restart(saleId);
        _settleAtEnd(saleId);
        vm.warp(block.timestamp + auction.RESTART_DELAY());
        (uint256 total, StateGrowth.Growth memory growth) = _restart();
        emit log_named_uint("Independent Stream restart, a later one: Prague gas", total);
        assertLe(total, RESTART_LATER_CEILING, "later restart over its regression ceiling");
        assertEq(growth.slots, 0, "no new slot");
        assertEq(growth.accounts, 0, "no new account");
    }

    function _restart() internal returns (uint256 total, StateGrowth.Growth memory growth) {
        (total,, growth) = _measureGrowth(
            anyone, address(auction), abi.encodeCall(auction.restart, (saleId)), 0
        );
    }
}

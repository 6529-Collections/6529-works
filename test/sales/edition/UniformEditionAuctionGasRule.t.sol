// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { UniformEditionAuction } from "src/sales/UniformEditionAuction.sol";
import { UniformEditionAuctionLens } from "src/sales/UniformEditionAuctionLens.sol";
import { Burner, GasRuleAssertions } from "../../helpers/GasRule.sol";
import { GasBurnerWallet } from "../../mocks/sales/SaleMocks.sol";
import { EditionAuctionBase } from "./EditionAuctionBase.sol";

/// @notice The gas rule on the edition auction's reads whose refusal has a meaning (EA-20): the
///         1/1's clock at `open` and in the abandonment check, and 6529 Stream's settlement
///         record in it. Each dependency is wrapped in a `Burner` costing 1x to 100x its base:
///         the outcome never changes with the multiple, and running short reverts with
///         `BoundedCallShortfall(burner)`, never reads as a missing 1/1 or an unsettled master.
///         The payout gas is the governed figure.
contract UniformEditionAuctionGasRuleTest is EditionAuctionBase, GasRuleAssertions {
    uint256 internal constant BASE = 20_000;
    Burner internal clockBurner;
    Burner internal streamBurner;
    UniformEditionAuction internal wrapped;
    address internal alice = makeAddr("alice");

    function setUp() public override {
        super.setUp();
        clockBurner = new Burner(address(english), BASE);
        streamBurner = new Burner(address(stream), BASE);
        editions.setStream(address(streamBurner));
        address l = address(
            new UniformEditionAuctionLens(
                address(editions), address(streamBurner), address(clockBurner), address(escrow)
            )
        );
        wrapped = new UniformEditionAuction(
            address(manager),
            address(escrow),
            address(editions),
            address(clockBurner),
            l,
            l.codehash,
            defaultConfig(),
            defaultLimits()
        );
        wrapped.setTarget(address(editions), true);
        editions.admit(address(wrapped), true);
        english.set(
            address(streamBurner),
            ID,
            IEnglishAuction.AuctionState.ACTIVE,
            uint64(block.timestamp + 1 days)
        );
    }

    function _openData() internal returns (bytes memory) {
        PackageItem memory item = _item(ID, 0);
        return abi.encodeCall(wrapped.open, (address(editions), ID, abi.encode(item)));
    }

    /// @dev At 1x the clock read is too cheap to be the call that runs short (a later plain call
    ///      does, with an empty revert); from 10x it is.
    function test_GasRule_OpenReadsTheClock() public {
        streamBurner.burnerSetBase(0);
        bytes memory data = _openData();
        Outcome memory o = _assertSameAtEveryMultiple(clockBurner, opener, address(wrapped), data);
        assertTrue(o.ok, "opens at every multiple");
        clockBurner.burnerSetMultiple(10);
        _assertShortfallNeverAnswers(clockBurner, opener, address(wrapped), data);
        clockBurner.burnerSetMultiple(100);
        _assertShortfallNeverAnswers(clockBurner, opener, address(wrapped), data);
    }

    /// @dev A stuck master past the delay: the abandonment check reads the clock and 6529
    ///      Stream's record forwarding all gas.
    function _stuckSale() internal returns (uint256 saleId) {
        vm.prank(opener);
        (bool ok, bytes memory ret) = address(wrapped).call(_openData());
        assertTrue(ok);
        saleId = abi.decode(ret, (uint256));
        english.set(
            address(streamBurner),
            ID,
            IEnglishAuction.AuctionState.SETTLED,
            uint64(block.timestamp + 1 days)
        );
        vm.warp(block.timestamp + 400 days);
    }

    function test_GasRule_AbandonReadsTheClock() public {
        uint256 saleId = _stuckSale();
        streamBurner.burnerSetBase(0);
        bytes memory data = abi.encodeCall(wrapped.abandon, (saleId));
        Outcome memory o = _assertSameAtEveryMultiple(clockBurner, alice, address(wrapped), data);
        assertTrue(o.ok, "abandoned at every multiple");
        _assertShortfallNeverAnswers(clockBurner, alice, address(wrapped), data);
        clockBurner.burnerSetMultiple(10);
        _assertShortfallNeverAnswers(clockBurner, alice, address(wrapped), data);
    }

    /// @dev The 1/1 settled but 6529 Stream's record unsettled: a starved record read must never
    ///      read as "unsettled" (which would allow the abandonment).
    function test_GasRule_AbandonReadsStreamsRecord() public {
        uint256 saleId = _stuckSale();
        clockBurner.burnerSetBase(0);
        bytes memory data = abi.encodeCall(wrapped.abandon, (saleId));
        Outcome memory o = _assertSameAtEveryMultiple(streamBurner, alice, address(wrapped), data);
        assertTrue(o.ok);
        _assertShortfallNeverAnswers(streamBurner, alice, address(wrapped), data);
        // Settled in Stream (and the edition created): refused at every multiple.
        stream.setSettled(ID, true);
        editions.setExists(ID, true);
        o = _assertSameAtEveryMultiple(streamBurner, alice, address(wrapped), data);
        assertFalse(o.ok);
        assertEq(
            o.data, abi.encodeWithSelector(IUniformEditionAuction.NotAbandonable.selector, saleId)
        );
    }

    /// @dev The payout gas is the governed figure: a seller wallet that needs more than it is
    ///      paid through the escrow; raising the figure pays it directly.
    function test_PayoutGas_IsTheGovernedFigure() public {
        Burner payee = new Burner(makeAddr("payeeInner"), 150_000);
        payee.burnerSetMutating(true);
        economics.set(address(payee), networkFee, FEE_SHARE);
        uint256 first = _open(0);
        _bid(first, alice, 100, 1);
        uint256 revenue = _price(first, 100);
        uint256 sellerPart = revenue - revenue * FEE_SHARE / 100_000;
        _settle(first);
        assertEq(escrow.owed(address(payee), address(0)), sellerPart, "100,000: escrowed");
        _setLimits(IUniformEditionAuction.Limits(30 days, 150, 400_000));
        english.set(
            address(stream),
            8,
            IEnglishAuction.AuctionState.ACTIVE,
            uint64(block.timestamp + 1 days)
        );
        uint256 second = _openId(8, 0);
        _bid(second, alice, 100, 1);
        english.set(
            address(stream),
            8,
            IEnglishAuction.AuctionState.SETTLED,
            uint64(block.timestamp + 1 days)
        );
        vm.warp(ua.endTimes(second).endTime);
        editions.setExists(8, true);
        auction.settle(second, new uint256[](0));
        assertEq(makeAddr("payeeInner").balance, sellerPart, "400,000: paid directly");
        assertEq(escrow.owed(address(payee), address(0)), sellerPart, "nothing more escrowed");
    }

    /// @dev Kept from the hostile suite's double: a payee burning everything is escrowed within
    ///      the governed figure, whatever it is set to.
    function test_PayoutGas_ABurnerIsEscrowedAtAnyFigure() public {
        GasBurnerWallet burner = new GasBurnerWallet();
        economics.set(address(burner), networkFee, FEE_SHARE);
        _setLimits(IUniformEditionAuction.Limits(30 days, 150, 3_000_000));
        uint256 saleId = _open(0);
        _bid(saleId, alice, 100, 1);
        _settle(saleId);
        uint256 revenue = _price(saleId, 100);
        assertEq(escrow.owed(address(burner), address(0)), revenue - revenue * FEE_SHARE / 100_000);
    }
}

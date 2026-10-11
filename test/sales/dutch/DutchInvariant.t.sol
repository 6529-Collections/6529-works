// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import {
    DutchParams,
    LockedTerms,
    Payment,
    PaymentMethod,
    PrimaryTerms,
    SaleKind
} from "src/interfaces/types/SaleTypes.sol";
import { DutchSale } from "src/sales/DutchSale.sol";
import { BlocklistToken, ToggleRecipient } from "../../mocks/EconomicsMocks.sol";
import { MockEditionTarget } from "../../mocks/sales/SaleMocks.sol";
import { DutchBase } from "./DutchBase.sol";

/// @notice Drives the Dutch adapter with valid purchases only: ETH buyers overpay at random
///         (credited), ERC-20 buyers authorize a maximum, time moves forward, credits are
///         claimed, and the seller wallet refuses payments at random (escrow fallback).
contract DutchHandler is Test {
    uint256 public constant ETH_ID = 51;
    uint256 public constant TOKEN_ID = 52;
    uint256 public constant SIZE = 40;
    uint32 public constant FEE_SHARE = 25_000;

    DutchSale public immutable dutch;
    MockEditionTarget public immutable editions;
    BlocklistToken public immutable token;
    ToggleRecipient public immutable wallet;
    address[4] public actors;
    uint256 public ethSale;
    uint256 public tokenSale;

    uint256 public ethIn;
    uint256 public ethCharged;
    uint256 public ethFees;
    uint256 public ethClaimed;
    uint256 public tokenPaid;
    uint256 public tokenFees;
    mapping(uint256 id => uint256) public minted;
    mapping(uint256 saleId => uint256) public lastPrice;
    bool public priceRose;

    constructor(
        DutchSale dutch_,
        MockEditionTarget editions_,
        BlocklistToken token_,
        ToggleRecipient wallet_
    ) {
        dutch = dutch_;
        editions = editions_;
        token = token_;
        wallet = wallet_;
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("dutchActor", vm.toString(i)));
        }
    }

    function setSales(uint256 ethSale_, uint256 tokenSale_) external {
        ethSale = ethSale_;
        tokenSale = tokenSale_;
        lastPrice[ethSale_] = type(uint256).max;
        lastPrice[tokenSale_] = type(uint256).max;
    }

    function buyEth(uint256 payerSeed, uint256 recipientSeed, uint256 quantitySeed, uint256 overpay)
        external
    {
        uint256 quantity = _quantity(ETH_ID, quantitySeed);
        if (quantity == 0) return;
        address payer = actors[payerSeed % 4];
        uint256 unit = _observe(ethSale);
        uint256 charge = unit * quantity;
        uint256 value = charge + bound(overpay, 0, 2 ether);
        vm.deal(payer, payer.balance + value);
        vm.prank(payer);
        dutch.purchase{ value: value }(
            ethSale,
            actors[recipientSeed % 4],
            quantity,
            unit,
            Payment(PaymentMethod.DIRECT, payer, value, 0, 0, "")
        );
        ethIn += value;
        ethCharged += charge;
        ethFees += charge * FEE_SHARE / 100_000;
        minted[ETH_ID] += quantity;
    }

    function buyToken(uint256 payerSeed, uint256 recipientSeed, uint256 quantitySeed) external {
        uint256 quantity = _quantity(TOKEN_ID, quantitySeed);
        if (quantity == 0) return;
        address payer = actors[payerSeed % 4];
        uint256 unit = _observe(tokenSale);
        (LockedTerms memory terms,,) = dutch.sale(tokenSale);
        uint256 maximum = terms.price * quantity;
        token.mint(payer, maximum);
        vm.prank(payer);
        token.approve(address(dutch), maximum);
        vm.prank(payer);
        dutch.purchase(
            tokenSale,
            actors[recipientSeed % 4],
            quantity,
            type(uint256).max,
            Payment(PaymentMethod.DIRECT, payer, maximum, 0, 0, "")
        );
        tokenPaid += unit * quantity;
        tokenFees += unit * quantity * FEE_SHARE / 100_000;
        minted[TOKEN_ID] += quantity;
    }

    function claim(uint256 actorSeed) external {
        address actor = actors[actorSeed % 4];
        uint256 amount = dutch.claimable(actor, CURRENCY_ETH);
        if (amount == 0) return;
        vm.prank(actor);
        dutch.claim(CURRENCY_ETH, actor);
        ethClaimed += amount;
    }

    function setWallet(bool acceptsEth, bool blockedByToken) external {
        wallet.setOpen(acceptsEth);
        token.setBlocked(address(wallet), blockedByToken);
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 300));
    }

    function _quantity(uint256 id, uint256 seed) internal view returns (uint256) {
        uint256 left = SIZE - editions.minted(id);
        return left == 0 ? 0 : bound(seed, 1, left < 5 ? left : 5);
    }

    /// @dev The current price, recording whether it ever rose since the last purchase.
    function _observe(uint256 saleId) internal returns (uint256 unit) {
        unit = dutch.currentPrice(saleId);
        if (unit > lastPrice[saleId]) priceRose = true;
        lastPrice[saleId] = unit;
    }
}

/// @notice Handler-based invariants of the Dutch adapter: ETH conservation (paid out, escrowed,
///         credited or claimed), credits fully backed, exact fees, ERC-20 conservation with exact
///         charges, minted within supply, and a price that never rises.
contract DutchInvariantTest is StdInvariant, DutchBase {
    DutchHandler internal handler;
    BlocklistToken internal token;
    ToggleRecipient internal wallet;

    function setUp() public override {
        super.setUp();
        token = new BlocklistToken();
        wallet = new ToggleRecipient();
        wallet.setOpen(true);
        allowlist.set(address(token), true);
        handler = new DutchHandler(dutch, editions, token, wallet);
        _setWalletDutch(handler.ETH_ID(), CURRENCY_ETH, 1 ether, 0.05 ether, 3000, 0);
        _setWalletDutch(handler.TOKEN_ID(), address(token), 500e18, 20e18, 3000, 300);
        handler.setSales(_openNow(handler.ETH_ID()), _openNow(handler.TOKEN_ID()));

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = DutchHandler.buyEth.selector;
        selectors[1] = DutchHandler.buyToken.selector;
        selectors[2] = DutchHandler.claim.selector;
        selectors[3] = DutchHandler.setWallet.selector;
        selectors[4] = DutchHandler.warp.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function _setWalletDutch(
        uint256 id,
        address currency,
        uint256 start,
        uint256 rest,
        uint64 duration,
        uint64 step
    ) internal {
        PrimaryTerms memory t = _terms(
            SaleKind.DUTCH, currency, start, abi.encode(DutchParams(rest, duration, step))
        );
        t.seller = address(wallet);
        editions.setTerms(id, t, handler.SIZE());
    }

    function _credits() internal view returns (uint256 total) {
        for (uint256 i; i < 4; ++i) {
            total += dutch.claimable(handler.actors(i), CURRENCY_ETH);
        }
    }

    /// @dev The handler is not vacuous: one fixed sequence credits and claims excess, reaches
    ///      escrow in both currencies, walks down the curve and ends the supply.
    function test_HandlerReachesEveryPath() public {
        handler.setWallet(false, true);
        for (uint256 i; i < 14; ++i) {
            handler.buyEth(i, i + 1, 3, 0.5 ether);
            handler.buyToken(i, i + 2, 3);
            handler.warp(250);
            if (i % 3 == 0) handler.claim(i);
        }
        assertGt(handler.ethClaimed(), 0);
        assertGt(escrow.owed(address(wallet), CURRENCY_ETH), 0);
        assertGt(escrow.owed(address(wallet), address(token)), 0);
        assertEq(editions.minted(handler.ETH_ID()), handler.SIZE());
        assertLt(dutch.currentPrice(handler.ethSale()), 1 ether);
        invariant_CreditsAreFullyBacked();
        invariant_EthIsConserved();
        invariant_TokenChargesAreExactAndNeverKept();
        invariant_MintedWithinSupply();
        invariant_PriceNeverRises();
    }

    function invariant_CreditsAreFullyBacked() public view {
        assertEq(address(dutch).balance, _credits());
    }

    function invariant_EthIsConserved() public view {
        uint256 out = address(wallet).balance + network.balance
            + escrow.owed(address(wallet), CURRENCY_ETH) + escrow.owed(network, CURRENCY_ETH);
        assertEq(out, handler.ethCharged());
        assertEq(handler.ethIn(), out + address(dutch).balance + handler.ethClaimed());
        assertEq(network.balance + escrow.owed(network, CURRENCY_ETH), handler.ethFees());
    }

    function invariant_TokenChargesAreExactAndNeverKept() public view {
        assertEq(token.balanceOf(address(dutch)), 0);
        assertEq(dutch.claimable(handler.actors(0), address(token)), 0);
        assertEq(
            handler.tokenPaid(),
            token.balanceOf(address(wallet)) + token.balanceOf(network)
                + escrow.owed(address(wallet), address(token))
                + escrow.owed(network, address(token))
        );
        assertEq(
            token.balanceOf(network) + escrow.owed(network, address(token)), handler.tokenFees()
        );
    }

    function invariant_MintedWithinSupply() public view {
        uint256[2] memory ids = [handler.ETH_ID(), handler.TOKEN_ID()];
        for (uint256 k; k < 2; ++k) {
            assertLe(editions.minted(ids[k]), handler.SIZE());
            assertEq(editions.minted(ids[k]), handler.minted(ids[k]));
        }
    }

    function invariant_PriceNeverRises() public view {
        assertFalse(handler.priceRose());
    }
}

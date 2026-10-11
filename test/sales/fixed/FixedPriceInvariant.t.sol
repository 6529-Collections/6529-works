// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { Payment, PaymentMethod, PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { FixedPriceSale } from "src/sales/FixedPriceSale.sol";
import { ISignatureTransfer } from "src/sales/ISignatureTransfer.sol";
import { BlocklistToken, ToggleRecipient } from "../../mocks/EconomicsMocks.sol";
import { MockEditionTarget, MockPermit2 } from "../../mocks/sales/SaleMocks.sol";
import { SaleMerkle } from "../../helpers/SaleFixture.sol";
import { FixedPriceBase } from "./FixedPriceBase.sol";

/// @notice Drives the fixed-price adapter with valid purchases only (the campaign fails on any
///         revert): a recipient-keyed priced allowlist phase, a payer-keyed phase, a public
///         phase, and an ERC-20 sale paid directly or by relayed Permit2 intents, while the seller
///         wallet refuses ETH and is blocked by the token at random (escrow fallback).
contract FixedPriceHandler is Test {
    uint256 public constant ETH_ID = 7;
    uint256 public constant TOKEN_ID = 40;
    uint256 public constant SIZE = 16;
    uint256 public constant PRICE = 0.1 ether;
    uint256 public constant TOKEN_PRICE = 25e18;
    uint32 public constant PUBLIC_CAP = 3;
    uint32 public constant TOKEN_CAP = 5;
    uint32 public constant FEE_SHARE = 25_000;

    FixedPriceSale public immutable sale;
    MockEditionTarget public immutable editions;
    BlocklistToken public immutable token;
    MockPermit2 public immutable permit2;
    ToggleRecipient public immutable wallet;

    address[4] public actors;
    uint256[4] internal keys;
    uint256[4] public caps0 = [uint256(2), 3, 1, 4];
    uint256[4] public prices0 = [uint256(0.04 ether), 0.1 ether, 0, 0.07 ether];
    uint256[4] public caps1 = [uint256(1), 2, 3, 1];
    bytes32[] internal leaves0;
    bytes32[] internal leaves1;
    uint256 public ethSale;
    uint256 public tokenSale;

    uint256 public ethPaid;
    uint256 public ethFees;
    uint256 public tokenPaid;
    uint256 public tokenFees;
    mapping(uint256 id => uint256) public minted;
    uint256 internal nonce;
    /// @dev Set if an over-cap or foreign-leaf purchase ever succeeds.
    bool public breached;
    uint256 public attacks;

    constructor(
        FixedPriceSale sale_,
        MockEditionTarget editions_,
        BlocklistToken token_,
        MockPermit2 permit2_,
        ToggleRecipient wallet_
    ) {
        sale = sale_;
        editions = editions_;
        token = token_;
        permit2 = permit2_;
        wallet = wallet_;
        for (uint256 i; i < 4; ++i) {
            (actors[i], keys[i]) = makeAddrAndKey(string.concat("actor", vm.toString(i)));
            leaves0.push(
                sale.allowlistLeaf(address(editions), ETH_ID, 0, actors[i], caps0[i], prices0[i])
            );
            leaves1.push(sale.allowlistLeaf(address(editions), ETH_ID, 1, actors[i], caps1[i], 0));
        }
    }

    function roots() external view returns (bytes32, bytes32) {
        return (SaleMerkle.root(leaves0), SaleMerkle.root(leaves1));
    }

    function setSales(uint256 ethSale_, uint256 tokenSale_) external {
        ethSale = ethSale_;
        tokenSale = tokenSale_;
    }

    // ------------------------------------------------------------------ actions

    function buyAllowlisted(uint256 leafSeed, uint256 payerSeed, uint256 quantitySeed) external {
        uint256 i = leafSeed % 4;
        uint256 left = caps0[i] - sale.purchased(ethSale, 0, actors[i]);
        uint256 quantity = _quantity(ETH_ID, quantitySeed, left);
        if (quantity == 0) return;
        _payEth(
            actors[payerSeed % 4],
            IFixedPriceSale.Purchase(ethSale, 0, actors[i], quantity, caps0[i], prices0[i]),
            SaleMerkle.proof(leaves0, i),
            prices0[i] * quantity
        );
    }

    function buyPayerKeyed(uint256 payerSeed, uint256 recipientSeed, uint256 quantitySeed)
        external
    {
        uint256 i = payerSeed % 4;
        uint256 left = caps1[i] - sale.purchased(ethSale, 1, actors[i]);
        uint256 quantity = _quantity(ETH_ID, quantitySeed, left);
        if (quantity == 0) return;
        _payEth(
            actors[i],
            IFixedPriceSale.Purchase(ethSale, 1, actors[recipientSeed % 4], quantity, caps1[i], 0),
            SaleMerkle.proof(leaves1, i),
            PRICE * quantity
        );
    }

    function buyPublic(uint256 payerSeed, uint256 recipientSeed, uint256 quantitySeed) external {
        address recipient = actors[recipientSeed % 4];
        uint256 left = PUBLIC_CAP - sale.purchased(ethSale, 2, recipient);
        uint256 quantity = _quantity(ETH_ID, quantitySeed, left);
        if (quantity == 0) return;
        _payEth(
            actors[payerSeed % 4],
            IFixedPriceSale.Purchase(ethSale, 2, recipient, quantity, 0, 0),
            new bytes32[](0),
            PRICE * quantity
        );
    }

    function buyToken(
        uint256 payerSeed,
        uint256 recipientSeed,
        uint256 quantitySeed,
        bool viaPermit2
    ) external {
        address recipient = actors[recipientSeed % 4];
        uint256 left = TOKEN_CAP - sale.purchased(tokenSale, 0, recipient);
        uint256 quantity = _quantity(TOKEN_ID, quantitySeed, left);
        if (quantity == 0) return;
        uint256 p = payerSeed % 4;
        uint256 total = TOKEN_PRICE * quantity;
        token.mint(actors[p], total);
        IFixedPriceSale.Purchase memory purchase =
            IFixedPriceSale.Purchase(tokenSale, 0, recipient, quantity, 0, 0);
        Payment memory payment;
        if (viaPermit2) {
            vm.prank(actors[p]);
            token.approve(address(permit2), type(uint256).max);
            payment = _intent(p, purchase, total);
            vm.prank(address(0xBEEF));
        } else {
            vm.prank(actors[p]);
            token.approve(address(sale), total);
            payment = Payment(PaymentMethod.DIRECT, actors[p], total, 0, 0, "");
            vm.prank(actors[p]);
        }
        sale.purchase(purchase, new bytes32[](0), payment);
        tokenPaid += total;
        tokenFees += total * FEE_SHARE / 100_000;
        minted[TOKEN_ID] += quantity;
    }

    /// @dev Tries to buy one copy more than a leaf's remaining allowance.
    function attackOverCap(uint256 leafSeed, uint256 payerSeed) external {
        uint256 i = leafSeed % 4;
        uint256 quantity = caps0[i] - sale.purchased(ethSale, 0, actors[i]) + 1;
        _attack(
            actors[payerSeed % 4],
            IFixedPriceSale.Purchase(ethSale, 0, actors[i], quantity, caps0[i], prices0[i]),
            SaleMerkle.proof(leaves0, i),
            prices0[i] * quantity
        );
    }

    /// @dev Tries to use another wallet's leaf for the attacker: minting to itself in the
    ///      recipient-keyed phase, or paying as itself in the payer-keyed phase.
    function attackForeignLeaf(uint256 leafSeed, uint256 attackerSeed, bool payerKeyed) external {
        uint256 i = leafSeed % 4;
        uint256 j = attackerSeed % 4;
        if (j == i) j = (j + 1) % 4;
        address attacker = actors[j];
        if (payerKeyed) {
            _attack(
                attacker,
                IFixedPriceSale.Purchase(ethSale, 1, actors[i], 1, caps1[i], 0),
                SaleMerkle.proof(leaves1, i),
                PRICE
            );
        } else {
            _attack(
                attacker,
                IFixedPriceSale.Purchase(ethSale, 0, attacker, 1, caps0[i], prices0[i]),
                SaleMerkle.proof(leaves0, i),
                prices0[i]
            );
        }
    }

    function setWallet(bool acceptsEth, bool blockedByToken) external {
        wallet.setOpen(acceptsEth);
        token.setBlocked(address(wallet), blockedByToken);
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 1 days));
    }

    // ------------------------------------------------------------------ helpers

    /// @dev A quantity within the wallet's remaining cap and the edition's remaining supply.
    function _quantity(uint256 id, uint256 seed, uint256 left) internal view returns (uint256) {
        uint256 supply = SIZE - editions.minted(id);
        if (supply < left) left = supply;
        return left == 0 ? 0 : bound(seed, 1, left);
    }

    function _payEth(
        address payer,
        IFixedPriceSale.Purchase memory purchase,
        bytes32[] memory proof,
        uint256 total
    ) internal {
        vm.deal(payer, total);
        vm.prank(payer);
        sale.purchase{ value: total }(
            purchase, proof, Payment(PaymentMethod.DIRECT, payer, total, 0, 0, "")
        );
        ethPaid += total;
        ethFees += total * FEE_SHARE / 100_000;
        minted[ETH_ID] += purchase.quantity;
    }

    function _attack(
        address payer,
        IFixedPriceSale.Purchase memory purchase,
        bytes32[] memory proof,
        uint256 total
    ) internal {
        ++attacks;
        vm.deal(payer, total);
        vm.prank(payer);
        try sale.purchase{ value: total }(
            purchase, proof, Payment(PaymentMethod.DIRECT, payer, total, 0, 0, "")
        ) {
            breached = true;
        } catch { }
    }

    function _intent(uint256 p, IFixedPriceSale.Purchase memory purchase, uint256 total)
        internal
        returns (Payment memory)
    {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 n = nonce++;
        bytes32 digest = permit2.witnessDigest(
            address(sale),
            ISignatureTransfer.PermitTransferFrom(
                ISignatureTransfer.TokenPermissions(address(token), total), n, deadline
            ),
            keccak256(
                abi.encode(
                    Typehashes.PURCHASE_WITNESS,
                    purchase.saleId,
                    purchase.phase,
                    purchase.recipient,
                    purchase.quantity,
                    total,
                    deadline
                )
            ),
            Typehashes.PURCHASE_WITNESS_TYPE
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[p], digest);
        return
            Payment(PaymentMethod.PERMIT2, actors[p], total, deadline, n, abi.encodePacked(r, s, v));
    }
}

/// @notice Handler-based invariants of the fixed-price adapter: payment conservation in ETH and
///         in an ERC-20 (paid in or escrowed, never kept), exact fees, minted within supply and
///         fully accounted, and every per-wallet cap respected.
contract FixedPriceInvariantTest is StdInvariant, FixedPriceBase {
    FixedPriceHandler internal handler;
    BlocklistToken internal token;
    ToggleRecipient internal wallet;

    function setUp() public override {
        super.setUp();
        token = new BlocklistToken();
        wallet = new ToggleRecipient();
        wallet.setOpen(true);
        allowlist.set(address(token), true);
        handler = new FixedPriceHandler(fixedSale, editions, token, permit2, wallet);
        uint256 size = handler.SIZE();
        editions.setTerms(
            handler.ETH_ID(),
            _withWallet(_terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, handler.PRICE(), "")),
            size
        );
        editions.setTerms(
            handler.TOKEN_ID(),
            _withWallet(_terms(SaleKind.FIXED_PRICE, address(token), handler.TOKEN_PRICE(), "")),
            size
        );
        (bytes32 root0, bytes32 root1) = handler.roots();
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](3);
        uint64 t = uint64(block.timestamp);
        phases[0] = IFixedPriceSale.Phase(t, t + 365 days, root0, 0, false, true);
        phases[1] = IFixedPriceSale.Phase(t, t + 365 days, root1, 0, true, false);
        phases[2] = IFixedPriceSale.Phase(t, t + 365 days, 0, handler.PUBLIC_CAP(), false, false);
        uint256 ethSale = _open(creator, handler.ETH_ID(), phases);
        IFixedPriceSale.Phase[] memory tokenPhases = new IFixedPriceSale.Phase[](1);
        tokenPhases[0] =
            IFixedPriceSale.Phase(t, t + 365 days, 0, handler.TOKEN_CAP(), false, false);
        uint256 tokenSale = _open(platform, handler.TOKEN_ID(), tokenPhases);
        handler.setSales(ethSale, tokenSale);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = FixedPriceHandler.buyAllowlisted.selector;
        selectors[1] = FixedPriceHandler.buyPayerKeyed.selector;
        selectors[2] = FixedPriceHandler.buyPublic.selector;
        selectors[3] = FixedPriceHandler.buyToken.selector;
        selectors[4] = FixedPriceHandler.setWallet.selector;
        selectors[5] = FixedPriceHandler.warp.selector;
        selectors[6] = FixedPriceHandler.attackOverCap.selector;
        selectors[7] = FixedPriceHandler.attackForeignLeaf.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function _withWallet(PrimaryTerms memory t) internal view returns (PrimaryTerms memory) {
        t.seller = address(wallet);
        return t;
    }

    /// @dev The handler is not vacuous: one fixed sequence reaches escrow in both currencies,
    ///      Permit2, every phase and the end of the supply, and the invariants hold after it.
    function test_HandlerReachesEveryPath() public {
        handler.setWallet(false, true);
        for (uint256 i; i < 8; ++i) {
            handler.buyAllowlisted(i, i + 1, 1);
            handler.buyPayerKeyed(i, i + 2, 1);
            handler.buyPublic(i, i + 3, 1);
            handler.buyToken(i, i + 1, 1, i % 2 == 0);
            handler.attackOverCap(i, i + 1);
            handler.attackForeignLeaf(i, i + 2, i % 2 == 0);
        }
        assertEq(handler.attacks(), 16);
        assertFalse(handler.breached());
        assertGt(escrow.owed(address(wallet), CURRENCY_ETH), 0);
        assertGt(escrow.owed(address(wallet), address(token)), 0);
        assertEq(editions.minted(handler.ETH_ID()), handler.SIZE());
        assertGt(fixedSale.purchased(handler.ethSale(), 0, handler.actors(0)), 0);
        assertGt(fixedSale.purchased(handler.ethSale(), 1, handler.actors(0)), 0);
        assertGt(handler.tokenPaid(), 0);
        invariant_EthIsPaidOrEscrowedNeverKept();
        invariant_TokenIsPaidOrEscrowedNeverKept();
        invariant_FeesAreExact();
        invariant_MintedWithinSupplyAndAccounted();
        invariant_PerWalletCapsHold();
    }

    function invariant_NoOverCapOrForeignLeafPurchaseSucceeds() public view {
        assertFalse(handler.breached());
    }

    function invariant_EthIsPaidOrEscrowedNeverKept() public view {
        assertEq(address(fixedSale).balance, 0);
        assertEq(
            handler.ethPaid(),
            address(wallet).balance + network.balance + escrow.owed(address(wallet), CURRENCY_ETH)
                + escrow.owed(network, CURRENCY_ETH)
        );
        assertEq(address(escrow).balance, escrow.totalOwed(CURRENCY_ETH));
    }

    function invariant_TokenIsPaidOrEscrowedNeverKept() public view {
        assertEq(token.balanceOf(address(fixedSale)), 0);
        assertEq(
            handler.tokenPaid(),
            token.balanceOf(address(wallet)) + token.balanceOf(network)
                + escrow.owed(address(wallet), address(token))
                + escrow.owed(network, address(token))
        );
        assertEq(token.balanceOf(address(escrow)), escrow.totalOwed(address(token)));
    }

    function invariant_FeesAreExact() public view {
        assertEq(network.balance + escrow.owed(network, CURRENCY_ETH), handler.ethFees());
        assertEq(
            token.balanceOf(network) + escrow.owed(network, address(token)), handler.tokenFees()
        );
    }

    function invariant_MintedWithinSupplyAndAccounted() public view {
        uint256[2] memory ids = [handler.ETH_ID(), handler.TOKEN_ID()];
        for (uint256 k; k < 2; ++k) {
            uint256 minted = editions.minted(ids[k]);
            assertLe(minted, handler.SIZE());
            assertEq(minted, handler.minted(ids[k]));
            uint256 held;
            for (uint256 i; i < 4; ++i) {
                held += editions.balanceOf(handler.actors(i), ids[k]);
            }
            assertEq(held, minted);
        }
    }

    function invariant_PerWalletCapsHold() public view {
        uint256 ethSale = handler.ethSale();
        uint256 tokenSale = handler.tokenSale();
        for (uint256 i; i < 4; ++i) {
            address a = handler.actors(i);
            assertLe(fixedSale.purchased(ethSale, 0, a), handler.caps0(i));
            assertLe(fixedSale.purchased(ethSale, 1, a), handler.caps1(i));
            assertLe(fixedSale.purchased(ethSale, 2, a), handler.PUBLIC_CAP());
            assertLe(fixedSale.purchased(tokenSale, 0, a), handler.TOKEN_CAP());
        }
    }
}

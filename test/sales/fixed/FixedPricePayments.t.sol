// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { TokenTransfer } from "src/economics/TokenTransfer.sol";
import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { Payment, PaymentMethod, PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { ISignatureTransfer } from "src/interfaces/external/ISignatureTransfer.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { MintSaleBase } from "src/sales/MintSaleBase.sol";
import {
    BlocklistToken,
    CallbackToken,
    FeeOnTransferToken,
    Mock1271Account,
    MockERC20,
    NoReturnToken,
    RebasingToken,
    RejectingRecipient,
    ReentrantRecipient,
    ReturnsFalseToken
} from "../../mocks/EconomicsMocks.sol";
import { GasBurnerWallet, HostileReceiver, MockPermit2 } from "../../mocks/sales/SaleMocks.sol";
import { FixedPriceBase } from "./FixedPriceBase.sol";

/// @dev Reports a zero balance for one hidden account while moving its tokens normally.
contract UnderReportingToken is MockERC20 {
    address public hidden;

    constructor() MockERC20("Under-reporting", "UND") { }

    function hide(address account) external {
        hidden = account;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return account == hidden ? 0 : super.balanceOf(account);
    }
}

/// @notice Fixed-price payments: ERC-20 direct pulls, EIP-2612 permits and Permit2 signed
///         payment intents (with replay, deadline and witness binding), the hostile-token
///         matrix, hostile payout wallets (escrow fallback) and hostile token receivers.
contract FixedPricePaymentsTest is FixedPriceBase {
    uint256 internal saleId;

    function setUp() public override {
        super.setUp();
        saleId = _openPublic(USD_ED, 0);
        usd.mint(alice, 1000e18);
    }

    function _usdPurchase(address recipient, uint256 quantity)
        internal
        view
        returns (IFixedPriceSale.Purchase memory)
    {
        return _p(saleId, 0, recipient, quantity, 0, 0);
    }

    function _direct(address payer, uint256 amount) internal pure returns (Payment memory p) {
        p = _eth(payer, amount);
    }

    function _intent(
        uint256 key,
        address owner,
        IFixedPriceSale.Purchase memory p,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (Payment memory) {
        return _permit2Payment(
            key,
            owner,
            address(fixedSale),
            address(usd),
            amount,
            nonce,
            deadline,
            _witness(p, amount, deadline),
            Typehashes.PURCHASE_WITNESS_TYPE
        );
    }

    function _assertPaid(uint256 total) internal view {
        assertEq(usd.balanceOf(seller), total - _fee(total));
        assertEq(usd.balanceOf(network), _fee(total));
        assertEq(usd.balanceOf(address(fixedSale)), 0);
    }

    // ------------------------------------------------------------------ direct

    function test_Direct_PullsExactlyAndPays() public {
        vm.prank(alice);
        usd.approve(address(fixedSale), 2 * USD_PRICE);
        _purchase(alice, _usdPurchase(bob, 2), new bytes32[](0), _direct(alice, 2 * USD_PRICE));
        assertEq(usd.balanceOf(alice), 1000e18 - 2 * USD_PRICE);
        assertEq(editions.balanceOf(bob, USD_ED), 2);
        _assertPaid(2 * USD_PRICE);
        assertEq(usd.allowance(alice, address(fixedSale)), 0);
    }

    function test_Direct_RevertsWithEthOrForeignPayer() public {
        vm.prank(alice);
        usd.approve(address(fixedSale), type(uint256).max);
        vm.deal(alice, 1 ether);
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        vm.prank(alice);
        fixedSale.purchase{ value: 1 }(
            _usdPurchase(alice, 1), new bytes32[](0), _direct(alice, USD_PRICE)
        );
        // Bob cannot spend Alice's allowance.
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        _purchase(bob, _usdPurchase(bob, 1), new bytes32[](0), _direct(alice, USD_PRICE));
    }

    // ------------------------------------------------------------------ EIP-2612

    function test_Permit_ApprovesAndBuysInOneStep() public {
        Payment memory pay = _permitPayment(
            aliceKey, alice, address(fixedSale), USD_PRICE, block.timestamp + 1 hours
        );
        _purchase(alice, _usdPurchase(alice, 1), new bytes32[](0), pay);
        assertEq(usd.nonces(alice), 1);
        assertEq(editions.balanceOf(alice, USD_ED), 1);
        _assertPaid(USD_PRICE);
    }

    function test_Permit_ReplayFailsOnceTheAllowanceIsSpent() public {
        Payment memory pay = _permitPayment(
            aliceKey, alice, address(fixedSale), USD_PRICE, block.timestamp + 1 hours
        );
        _purchase(alice, _usdPurchase(alice, 1), new bytes32[](0), pay);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenTransfer.TokenCallFailed.selector, address(usd), bytes4(0x23b872dd)
            )
        );
        _purchase(alice, _usdPurchase(alice, 1), new bytes32[](0), pay);
    }

    function test_Permit_FrontRunPermitStillBuys() public {
        Payment memory pay = _permitPayment(
            aliceKey, alice, address(fixedSale), USD_PRICE, block.timestamp + 1 hours
        );
        (uint8 v, bytes32 r, bytes32 s) = _split(pay.signature);
        // Someone submits Alice's permit to the token first.
        usd.permit(alice, address(fixedSale), USD_PRICE, pay.deadline, v, r, s);
        _purchase(alice, _usdPurchase(alice, 1), new bytes32[](0), pay);
        assertEq(editions.balanceOf(alice, USD_ED), 1);
    }

    function test_Permit_RevertsWhenExpiredOrNotTheSender() public {
        Payment memory pay =
            _permitPayment(aliceKey, alice, address(fixedSale), USD_PRICE, block.timestamp - 1);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.PaymentExpired.selector, block.timestamp - 1)
        );
        _purchase(alice, _usdPurchase(alice, 1), new bytes32[](0), pay);
        pay = _permitPayment(
            aliceKey, alice, address(fixedSale), USD_PRICE, block.timestamp + 1 hours
        );
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        _purchase(relayer, _usdPurchase(alice, 1), new bytes32[](0), pay);
    }

    /// @dev QUALITY-7: EIP-2612 takes the documented 65-byte `r || s || v` in every adapter, so
    ///      the 64-byte compact (ERC-2098) form of a valid permit is refused, as in the auction.
    function test_Permit_RefusesTheCompactSignatureForm() public {
        Payment memory pay = _permitPayment(
            aliceKey, alice, address(fixedSale), USD_PRICE, block.timestamp + 1 hours
        );
        (uint8 v, bytes32 r, bytes32 s) = _split(pay.signature);
        pay.signature = abi.encodePacked(r, bytes32(uint256(s) | (uint256(v - 27) << 255)));
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        _purchase(alice, _usdPurchase(alice, 1), new bytes32[](0), pay);
        assertEq(usd.nonces(alice), 0, "the permit was never submitted");
    }

    // ------------------------------------------------------------------ Permit2

    function test_Permit2_RelayerSubmitsTheSignedIntent() public {
        vm.prank(alice);
        usd.approve(address(permit2), type(uint256).max);
        IFixedPriceSale.Purchase memory p = _usdPurchase(bob, 2);
        Payment memory pay =
            _intent(aliceKey, alice, p, 2 * USD_PRICE, 0, block.timestamp + 1 hours);
        vm.expectEmit(address(fixedSale));
        emit ISaleAdapter.SaleSettled(
            saleId,
            address(editions),
            USD_ED,
            alice,
            bob,
            2,
            address(usd),
            2 * USD_PRICE,
            seller,
            2 * USD_PRICE - _fee(2 * USD_PRICE),
            network,
            _fee(2 * USD_PRICE)
        );
        _purchase(relayer, p, new bytes32[](0), pay);
        assertEq(editions.balanceOf(bob, USD_ED), 2);
        assertEq(usd.balanceOf(relayer), 0);
        assertEq(usd.balanceOf(alice), 1000e18 - 2 * USD_PRICE);
        _assertPaid(2 * USD_PRICE);
    }

    function test_Permit2_ReplayIsRejectedByTheNonce() public {
        vm.prank(alice);
        usd.approve(address(permit2), type(uint256).max);
        IFixedPriceSale.Purchase memory p = _usdPurchase(alice, 1);
        Payment memory pay = _intent(aliceKey, alice, p, USD_PRICE, 42, block.timestamp + 1 hours);
        _purchase(relayer, p, new bytes32[](0), pay);
        vm.expectRevert(MockPermit2.InvalidNonce.selector);
        _purchase(relayer, p, new bytes32[](0), pay);
        // The 64-byte compact form of the same signature is the same intent: still replayed.
        (uint8 v, bytes32 r, bytes32 s) = _split(pay.signature);
        pay.signature = abi.encodePacked(r, bytes32(uint256(s) | (uint256(v - 27) << 255)));
        vm.expectRevert(MockPermit2.InvalidNonce.selector);
        _purchase(relayer, p, new bytes32[](0), pay);
        assertEq(editions.balanceOf(alice, USD_ED), 1);
    }

    function test_Permit2_DeadlineIsEnforced() public {
        vm.prank(alice);
        usd.approve(address(permit2), type(uint256).max);
        IFixedPriceSale.Purchase memory p = _usdPurchase(alice, 1);
        uint256 deadline = block.timestamp + 10;
        Payment memory pay = _intent(aliceKey, alice, p, USD_PRICE, 1, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.PaymentExpired.selector, deadline));
        _purchase(relayer, p, new bytes32[](0), pay);
    }

    function test_Permit2_WitnessBindsThePurchase() public {
        vm.prank(alice);
        usd.approve(address(permit2), type(uint256).max);
        IFixedPriceSale.Purchase memory p = _usdPurchase(alice, 1);
        Payment memory pay = _intent(aliceKey, alice, p, USD_PRICE, 1, block.timestamp + 1 hours);
        // A relayer may not redirect the tokens, change the quantity or the deadline.
        IFixedPriceSale.Purchase memory redirected = _usdPurchase(relayer, 1);
        vm.expectRevert(MockPermit2.InvalidSigner.selector);
        _purchase(relayer, redirected, new bytes32[](0), pay);
        Payment memory later = _intent(aliceKey, alice, p, USD_PRICE, 1, block.timestamp + 1 hours);
        later.deadline += 1;
        vm.expectRevert(MockPermit2.InvalidSigner.selector);
        _purchase(relayer, p, new bytes32[](0), later);
        // Nor can another payer's balance be named.
        Payment memory foreign =
            _intent(aliceKey, alice, p, USD_PRICE, 1, block.timestamp + 1 hours);
        foreign.payer = bob;
        vm.expectRevert(MockPermit2.InvalidSigner.selector);
        _purchase(relayer, p, new bytes32[](0), foreign);
        // The intent is bound to this adapter as the spender.
        Payment memory elsewhere = _permit2Payment(
            aliceKey,
            alice,
            address(0xBEEF),
            address(usd),
            USD_PRICE,
            2,
            block.timestamp + 1 hours,
            _witness(p, USD_PRICE, block.timestamp + 1 hours),
            Typehashes.PURCHASE_WITNESS_TYPE
        );
        vm.expectRevert(MockPermit2.InvalidSigner.selector);
        _purchase(relayer, p, new bytes32[](0), elsewhere);
        _purchase(relayer, p, new bytes32[](0), pay);
    }

    function test_Permit2_ContractPayerByErc1271() public {
        Mock1271Account safe = new Mock1271Account();
        usd.mint(address(safe), 100e18);
        vm.prank(address(safe));
        usd.approve(address(permit2), type(uint256).max);
        IFixedPriceSale.Purchase memory p = _usdPurchase(bob, 1);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 witness = _witness(p, USD_PRICE, deadline);
        safe.accept(
            permit2.witnessDigest(
                address(fixedSale),
                _permit(address(usd), USD_PRICE, 9, deadline),
                witness,
                Typehashes.PURCHASE_WITNESS_TYPE
            )
        );
        Payment memory pay =
            Payment(PaymentMethod.PERMIT2, address(safe), USD_PRICE, deadline, 9, hex"00");
        _purchase(relayer, p, new bytes32[](0), pay);
        assertEq(editions.balanceOf(bob, USD_ED), 1);
        assertEq(usd.balanceOf(address(safe)), 100e18 - USD_PRICE);
    }

    function test_Permit2_PayerKeyedLeafNeedsThePayersSignature() public {
        bytes32[] memory leaves =
            _leaves(USD_ED, 0, _list3(alice, bob, creator), _nums3(1, 1, 1), _nums3(0, 0, 0));
        vm.prank(creator);
        fixedSale.closeSale(saleId);
        uint256 keyed = _open(creator, USD_ED, _one(_phase(_root(leaves), 0, true, false)));
        vm.prank(alice);
        usd.approve(address(permit2), type(uint256).max);
        IFixedPriceSale.Purchase memory p = _p(keyed, 0, bob, 1, 1, 0);
        Payment memory pay = _intent(aliceKey, alice, p, USD_PRICE, 3, block.timestamp + 1 hours);
        // The relayer gifts to Bob on Alice's allowance, with Alice's signature.
        _purchase(relayer, p, _proof(leaves, 0), pay);
        assertEq(editions.balanceOf(bob, USD_ED), 1);
        assertEq(_bought(keyed, 0, alice), 1);
        // Another signer does not borrow Alice's leaf.
        (address mallory, uint256 malloryKey) = makeAddrAndKey("mallory");
        usd.mint(mallory, 100e18);
        vm.prank(mallory);
        usd.approve(address(permit2), type(uint256).max);
        Payment memory forged =
            _intent(malloryKey, mallory, p, USD_PRICE, 4, block.timestamp + 1 hours);
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.NotAllowlisted.selector, keyed, 0, mallory)
        );
        _purchase(relayer, p, _proof(leaves, 0), forged);
    }

    // ------------------------------------------------------------------ hostile tokens

    /// @dev Opens a sale of an edition priced in `token`; the edition ID is the token address.
    function _hostileSale(MockERC20 token) internal returns (uint256 sale) {
        uint256 id = uint256(uint160(address(token)));
        allowlist.set(address(token), true);
        editions.setTerms(id, _terms(SaleKind.FIXED_PRICE, address(token), 10e18, ""), SIZE);
        sale = _openPublic(id, 0);
        token.mint(alice, 1000e18);
        vm.prank(alice);
        token.approve(address(fixedSale), type(uint256).max);
    }

    function _buyHostile(uint256 sale) internal {
        _purchase(alice, _p(sale, 0, alice, 1, 0, 0), new bytes32[](0), _direct(alice, 10e18));
    }

    function test_HostileToken_FeeOnTransferRevertsOnTheDelta() public {
        FeeOnTransferToken token = new FeeOnTransferToken();
        uint256 id = _hostileSale(token);
        vm.expectRevert(
            abi.encodeWithSelector(TokenTransfer.TokenBalanceMismatch.selector, address(token))
        );
        _buyHostile(id);
    }

    function test_HostileToken_RebasingRoundingRevertsOnTheDelta() public {
        RebasingToken token = new RebasingToken();
        uint256 id = _hostileSale(token);
        token.setIndex(3e18);
        vm.expectRevert(
            abi.encodeWithSelector(TokenTransfer.TokenBalanceMismatch.selector, address(token))
        );
        _buyHostile(id);
    }

    function test_HostileToken_NoReturnAndFalseReturnRevert() public {
        NoReturnToken silent = new NoReturnToken();
        uint256 id = _hostileSale(silent);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenTransfer.TokenCallFailed.selector, address(silent), bytes4(0x23b872dd)
            )
        );
        _buyHostile(id);
        ReturnsFalseToken liar = new ReturnsFalseToken();
        id = _hostileSale(liar);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenTransfer.TokenCallFailed.selector, address(liar), bytes4(0x23b872dd)
            )
        );
        _buyHostile(id);
    }

    function test_HostileToken_Permit2CannotSkipTheDeltaCheck() public {
        FeeOnTransferToken token = new FeeOnTransferToken();
        uint256 id = _hostileSale(token);
        vm.prank(alice);
        token.approve(address(permit2), type(uint256).max);
        IFixedPriceSale.Purchase memory p = _p(id, 0, alice, 1, 0, 0);
        uint256 deadline = block.timestamp + 1 hours;
        Payment memory pay = _permit2Payment(
            aliceKey,
            alice,
            address(fixedSale),
            address(token),
            10e18,
            0,
            deadline,
            _witness(p, 10e18, deadline),
            Typehashes.PURCHASE_WITNESS_TYPE
        );
        vm.expectRevert(
            abi.encodeWithSelector(TokenTransfer.TokenBalanceMismatch.selector, address(token))
        );
        _purchase(relayer, p, new bytes32[](0), pay);
    }

    /// @dev QUALITY-7: a token that reports less than the payer holds fails the payer-side
    ///      delta check with `TokenBalanceMismatch`, as in the auction, not with an arithmetic
    ///      panic.
    function test_HostileToken_Permit2UnderReportedPayerBalanceReverts() public {
        UnderReportingToken token = new UnderReportingToken();
        uint256 id = _hostileSale(token);
        token.hide(alice);
        vm.prank(alice);
        token.approve(address(permit2), type(uint256).max);
        IFixedPriceSale.Purchase memory p = _p(id, 0, alice, 1, 0, 0);
        uint256 deadline = block.timestamp + 1 hours;
        Payment memory pay = _permit2Payment(
            aliceKey,
            alice,
            address(fixedSale),
            address(token),
            10e18,
            0,
            deadline,
            _witness(p, 10e18, deadline),
            Typehashes.PURCHASE_WITNESS_TYPE
        );
        vm.expectRevert(
            abi.encodeWithSelector(TokenTransfer.TokenBalanceMismatch.selector, address(token))
        );
        _purchase(relayer, p, new bytes32[](0), pay);
    }

    function test_HostileToken_BlockedSellerIsPaidThroughEscrow() public {
        BlocklistToken token = new BlocklistToken();
        uint256 id = _hostileSale(token);
        token.setBlocked(seller, true);
        _buyHostile(id);
        assertEq(escrow.owed(seller, address(token)), 10e18 - _fee(10e18));
        assertEq(token.balanceOf(network), _fee(10e18));
        assertEq(token.balanceOf(address(fixedSale)), 0);
        assertEq(editions.balanceOf(alice, uint256(uint160(address(token)))), 1);
    }

    function test_HostileToken_CallbackReentryIsBlocked() public {
        CallbackToken token = new CallbackToken();
        uint256 id = _hostileSale(token);
        token.setHook(address(fixedSale), abi.encodeCall(ISaleAdapter.claim, (address(0), alice)));
        _buyHostile(id);
        assertFalse(token.lastHookOk());
        assertEq(
            bytes4(token.lastHookResult()),
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
        );
        assertEq(editions.balanceOf(alice, uint256(uint160(address(token)))), 1);
    }

    // ------------------------------------------------------------------ hostile payout wallets

    function _ethSaleWith(address sellerWallet, address feeWallet) internal returns (uint256) {
        editions.setTerms(
            30,
            _withWallets(
                _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, 1 ether, ""), sellerWallet, feeWallet
            ),
            SIZE
        );
        return _openPublic(30, 0);
    }

    function _withWallets(PrimaryTerms memory t, address sellerWallet, address feeWallet)
        internal
        pure
        returns (PrimaryTerms memory)
    {
        t.seller = sellerWallet;
        t.feeRecipient = feeWallet;
        return t;
    }

    function test_HostileWallet_RefusingSellerIsEscrowed() public {
        RejectingRecipient refusing = new RejectingRecipient();
        uint256 id = _ethSaleWith(address(refusing), network);
        _buyEth(alice, id, 0, alice, 1, 1 ether);
        assertEq(escrow.owed(address(refusing), CURRENCY_ETH), 0.75 ether);
        assertEq(network.balance, 0.25 ether);
        assertEq(address(fixedSale).balance, 0);
    }

    function test_HostileWallet_GasBurnersCannotBlockTheSale() public {
        GasBurnerWallet burner = new GasBurnerWallet();
        uint256 id = _ethSaleWith(address(burner), address(burner));
        _buyEth(alice, id, 0, alice, 1, 1 ether);
        assertEq(escrow.owed(address(burner), CURRENCY_ETH), 1 ether);
        assertEq(editions.balanceOf(alice, 30), 1);
    }

    function test_HostileWallet_ReentrantSellerCannotReenter() public {
        ReentrantRecipient reentrant = new ReentrantRecipient();
        uint256 id = _ethSaleWith(address(reentrant), network);
        reentrant.configure(
            address(fixedSale), abi.encodeCall(ISaleAdapter.claim, (CURRENCY_ETH, alice))
        );
        _buyEth(alice, id, 0, alice, 1, 1 ether);
        // The wallet's nested call hit the lock; the wallet swallowed it and was paid.
        assertFalse(reentrant.lastOk());
        assertEq(
            bytes4(reentrant.lastResult()),
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
        );
        assertEq(address(reentrant).balance, 0.75 ether);
        assertEq(address(fixedSale).balance, 0);
    }

    // ------------------------------------------------------------------ hostile receivers

    function test_HostileReceiver_RejectionRevertsTheWholePurchase() public {
        HostileReceiver receiver = new HostileReceiver();
        receiver.configure(HostileReceiver.Mode.Reject, false, address(0), "");
        uint256 id = _openPublic(ETH_ED, 0);
        vm.deal(alice, PRICE);
        vm.expectRevert("rejected");
        vm.prank(alice);
        fixedSale.purchase{ value: PRICE }(
            _p(id, 0, address(receiver), 1, 0, 0), new bytes32[](0), _eth(alice, PRICE)
        );
        assertEq(alice.balance, PRICE);
        assertEq(_bought(id, 0, address(receiver)), 0);
    }

    function test_HostileReceiver_ReentryIsBlocked() public {
        HostileReceiver receiver = new HostileReceiver();
        uint256 id = _openPublic(ETH_ED, 0);
        bytes memory again = abi.encodeCall(
            IFixedPriceSale.purchase,
            (_p(id, 0, address(receiver), 1, 0, 0), new bytes32[](0), _eth(address(receiver), 0))
        );
        // Swallowed: the purchase completes once, the nested one failed.
        receiver.configure(HostileReceiver.Mode.Reenter, false, address(fixedSale), again);
        _buyEth(alice, id, 0, address(receiver), 1, PRICE);
        assertFalse(receiver.lastOk());
        assertEq(
            bytes4(receiver.lastResult()),
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
        );
        assertEq(editions.balanceOf(address(receiver), ETH_ED), 1);
        // Bubbled: the whole purchase reverts.
        receiver.configure(HostileReceiver.Mode.Reenter, true, address(fixedSale), again);
        vm.deal(alice, PRICE);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        fixedSale.purchase{ value: PRICE }(
            _p(id, 0, address(receiver), 1, 0, 0), new bytes32[](0), _eth(alice, PRICE)
        );
    }

    // ------------------------------------------------------------------ helpers

    function _split(bytes memory sig) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        assembly ("memory-safe") {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
    }

    function _permit(address token, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (ISignatureTransfer.PermitTransferFrom memory)
    {
        return ISignatureTransfer.PermitTransferFrom(
            ISignatureTransfer.TokenPermissions(token, amount), nonce, deadline
        );
    }
}

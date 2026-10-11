// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IDutchSale } from "src/interfaces/IDutchSale.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { DutchParams, Payment, PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { BlocklistToken } from "../../mocks/EconomicsMocks.sol";
import { GasBurnerWallet } from "../../mocks/sales/SaleMocks.sol";
import { DutchBase } from "./DutchBase.sol";

/// @notice The largest Dutch purchases fit Fusaka's per-transaction gas cap (EIP-7825) with a
///         wide margin, measured cold: ETH with a credited excess and two gas-burning payout
///         wallets, and a relayed Permit2 intent with two escrowed token payouts.
contract DutchGasCapTest is DutchBase {
    uint256 internal constant QUANTITY = 1000;

    function _cool() internal {
        vm.cool(address(dutch));
        vm.cool(address(editions));
        vm.cool(address(escrow));
        vm.cool(address(permit2));
    }

    function test_WorstCaseEthPurchaseFitsTheCap() public {
        GasBurnerWallet burner = new GasBurnerWallet();
        PrimaryTerms memory t = _terms(
            SaleKind.DUTCH, CURRENCY_ETH, 1 ether, abi.encode(DutchParams(0.1 ether, 1000, 10))
        );
        (t.seller, t.feeRecipient) = (address(burner), address(burner));
        editions.setTerms(70, t, SIZE);
        uint256 saleId = _openNow(70);
        vm.warp(block.timestamp + 555);
        Payment memory pay = _eth(alice, 1 ether * QUANTITY);
        vm.deal(alice, pay.amount);
        _cool();
        vm.cool(address(burner));
        vm.prank(alice);
        uint256 start = gasleft();
        dutch.purchase{ value: pay.amount }(saleId, bob, QUANTITY, 1 ether, pay);
        uint256 used = start - gasleft();
        assertGt(dutch.claimable(alice, CURRENCY_ETH), 0);
        assertGt(escrow.owed(address(burner), CURRENCY_ETH), 0);
        _assertFits(
            "Dutch purchase: ETH credit, two gas-burning wallets",
            abi.encodeCall(IDutchSale.purchase, (saleId, bob, QUANTITY, 1 ether, pay)),
            used
        );
    }

    function test_WorstCaseTokenPurchaseFitsTheCap() public {
        BlocklistToken token = new BlocklistToken();
        allowlist.set(address(token), true);
        editions.setTerms(
            71,
            _terms(SaleKind.DUTCH, address(token), 100e18, abi.encode(DutchParams(1e18, 1000, 0))),
            SIZE
        );
        uint256 saleId = _openNow(71);
        vm.warp(block.timestamp + 333);
        token.setBlocked(seller, true);
        token.setBlocked(network, true);
        uint256 maximum = 100e18 * QUANTITY;
        token.mint(alice, maximum);
        vm.prank(alice);
        token.approve(address(permit2), type(uint256).max);
        uint256 deadline = block.timestamp + 1 hours;
        Payment memory pay = _permit2Payment(
            aliceKey,
            alice,
            address(dutch),
            address(token),
            maximum,
            0,
            deadline,
            _witness(saleId, bob, QUANTITY, 100e18, deadline),
            Typehashes.DUTCH_PURCHASE_WITNESS_TYPE
        );
        _cool();
        vm.cool(address(token));
        vm.prank(relayer);
        uint256 start = gasleft();
        dutch.purchase(saleId, bob, QUANTITY, 100e18, pay);
        uint256 used = start - gasleft();
        assertGt(escrow.owed(seller, address(token)), 0);
        assertGt(escrow.owed(network, address(token)), 0);
        _assertFits(
            "Dutch purchase: Permit2, two escrowed token payouts",
            abi.encodeCall(IDutchSale.purchase, (saleId, bob, QUANTITY, 100e18, pay)),
            used
        );
    }
}

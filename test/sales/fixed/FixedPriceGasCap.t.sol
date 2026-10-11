// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { Payment, PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { BlocklistToken, Mock1271Account } from "../../mocks/EconomicsMocks.sol";
import { GasBurnerWallet } from "../../mocks/sales/SaleMocks.sol";
import { FixedPriceBase } from "./FixedPriceBase.sol";

/// @notice The largest fixed-price transactions fit Fusaka's per-transaction gas cap (EIP-7825)
///         with a wide margin, measured cold: opening 16 phases with a 4 KiB ERC-1271 consent,
///         and purchases through a 32-node proof with both payouts falling back to escrow.
contract FixedPriceGasCapTest is FixedPriceBase {
    uint256 internal constant TOKEN_ID = 60;
    uint256 internal constant ETH_ID = 61;
    uint256 internal constant UNIT = 10e18;
    uint256 internal constant QUANTITY = 1000;

    BlocklistToken internal token;

    function setUp() public override {
        super.setUp();
        token = new BlocklistToken();
        allowlist.set(address(token), true);
        editions.setTerms(TOKEN_ID, _terms(SaleKind.FIXED_PRICE, address(token), UNIT, ""), SIZE);
    }

    function _cool() internal {
        vm.cool(address(fixedSale));
        vm.cool(address(editions));
        vm.cool(address(token));
        vm.cool(address(escrow));
        vm.cool(address(permit2));
        vm.cool(address(allowlist));
        vm.cool(address(manager));
    }

    function test_WorstCaseOpenSaleFitsTheCap() public {
        Mock1271Account safe = new Mock1271Account();
        editions.setCreator(TOKEN_ID, address(safe));
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](16);
        uint64 t = uint64(block.timestamp);
        for (uint256 i; i < 16; ++i) {
            phases[i] = IFixedPriceSale.Phase(
                t, t + 365 days, keccak256(abi.encode(i)), uint32(i + 1), i % 2 == 0, true
            );
        }
        uint64 deadline = t + 1 hours;
        safe.accept(
            fixedSale.phaseConfigurationDigest(address(editions), TOKEN_ID, phases, 1, deadline)
        );
        IFixedPriceSale.ArtistConsent memory consent =
            IFixedPriceSale.ArtistConsent(1, deadline, new bytes(4096));
        _cool();
        vm.cool(address(safe));
        vm.prank(platform);
        uint256 start = gasleft();
        fixedSale.openSale(address(editions), TOKEN_ID, phases, consent);
        uint256 used = start - gasleft();
        _assertFits(
            "openSale: 16 phases, 4 KiB ERC-1271 consent",
            abi.encodeCall(
                IFixedPriceSale.openSale, (address(editions), TOKEN_ID, phases, consent)
            ),
            used
        );
    }

    function test_WorstCaseTokenPurchaseFitsTheCap() public {
        // A relayed Permit2 intent in a payer-keyed priced phase, a 32-node proof, and a token
        // that refuses both payouts (two escrow deposits).
        bytes32 leaf =
            fixedSale.allowlistLeaf(address(editions), TOKEN_ID, 0, alice, QUANTITY, UNIT);
        (bytes32 root, bytes32[] memory proof) = _deepProof(leaf, 32);
        uint256 saleId = _open(creator, TOKEN_ID, _one(_phase(root, 0, true, true)));
        token.setBlocked(seller, true);
        token.setBlocked(network, true);
        token.mint(alice, UNIT * QUANTITY);
        vm.prank(alice);
        token.approve(address(permit2), type(uint256).max);
        IFixedPriceSale.Purchase memory p = _p(saleId, 0, bob, QUANTITY, QUANTITY, UNIT);
        uint256 deadline = block.timestamp + 1 hours;
        Payment memory pay = _permit2Payment(
            aliceKey,
            alice,
            address(fixedSale),
            address(token),
            UNIT * QUANTITY,
            0,
            deadline,
            _witness(p, UNIT * QUANTITY, deadline),
            Typehashes.PURCHASE_WITNESS_TYPE
        );
        _cool();
        vm.prank(relayer);
        uint256 start = gasleft();
        fixedSale.purchase(p, proof, pay);
        uint256 used = start - gasleft();
        assertGt(escrow.owed(seller, address(token)), 0);
        assertGt(escrow.owed(network, address(token)), 0);
        assertEq(editions.balanceOf(bob, TOKEN_ID), QUANTITY);
        _assertFits(
            "purchase: Permit2, 32-node proof, two escrowed payouts",
            abi.encodeCall(IFixedPriceSale.purchase, (p, proof, pay)),
            used
        );
    }

    function test_WorstCaseEthPurchaseFitsTheCap() public {
        // Both payout wallets burn their whole gas allowance and are escrowed.
        GasBurnerWallet burner = new GasBurnerWallet();
        PrimaryTerms memory t = _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, 1 ether, "");
        (t.seller, t.feeRecipient) = (address(burner), address(burner));
        editions.setTerms(ETH_ID, t, SIZE);
        bytes32 leaf = fixedSale.allowlistLeaf(address(editions), ETH_ID, 0, bob, QUANTITY, 1 ether);
        (bytes32 root, bytes32[] memory proof) = _deepProof(leaf, 32);
        uint256 saleId = _open(creator, ETH_ID, _one(_phase(root, 0, false, true)));
        IFixedPriceSale.Purchase memory p = _p(saleId, 0, bob, QUANTITY, QUANTITY, 1 ether);
        Payment memory pay = _eth(alice, 1 ether * QUANTITY);
        vm.deal(alice, pay.amount);
        _cool();
        vm.cool(address(burner));
        vm.prank(alice);
        uint256 start = gasleft();
        fixedSale.purchase{ value: pay.amount }(p, proof, pay);
        uint256 used = start - gasleft();
        assertEq(escrow.owed(address(burner), CURRENCY_ETH), pay.amount);
        _assertFits(
            "purchase: ETH, 32-node proof, two gas-burning wallets",
            abi.encodeCall(IFixedPriceSale.purchase, (p, proof, pay)),
            used
        );
    }
}

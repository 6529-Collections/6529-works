// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { LockedTerms, Payment, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { FixedPriceSale } from "src/sales/FixedPriceSale.sol";
import { ISignatureTransfer } from "src/sales/ISignatureTransfer.sol";
import { SaleFixture } from "../../helpers/SaleFixture.sol";

/// @notice Fixed-price setup: the adapter wired to an ETH edition and a USD edition, with phase,
///         allowlist and purchase helpers.
abstract contract FixedPriceBase is SaleFixture {
    uint256 internal constant ETH_ED = 7;
    uint256 internal constant USD_ED = 8;
    uint256 internal constant PRICE = 0.1 ether;
    uint256 internal constant USD_PRICE = 50e18;
    uint64 internal constant DAY = 1 days;

    FixedPriceSale internal fixedSale;

    function setUp() public virtual {
        _setUpBase();
        (IRevenueEscrow e, IAssetAllowlist a, ISignatureTransfer p, IEconomicsResolver r) = _deps();
        fixedSale = new FixedPriceSale(address(manager), e, a, p, r);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = IFixedPriceSale.openSale.selector;
        selectors[1] = IFixedPriceSale.closeSale.selector;
        _wire(address(fixedSale), selectors);
        editions.setTerms(ETH_ED, _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, PRICE, ""), SIZE);
        editions.setTerms(USD_ED, _terms(SaleKind.FIXED_PRICE, address(usd), USD_PRICE, ""), SIZE);
    }

    function _phase(bytes32 root, uint32 walletCap, bool payerKeyed, bool leafPriced)
        internal
        view
        returns (IFixedPriceSale.Phase memory)
    {
        return IFixedPriceSale.Phase(
            uint64(block.timestamp),
            uint64(block.timestamp) + DAY,
            root,
            walletCap,
            payerKeyed,
            leafPriced
        );
    }

    function _one(IFixedPriceSale.Phase memory phase)
        internal
        pure
        returns (IFixedPriceSale.Phase[] memory phases)
    {
        phases = new IFixedPriceSale.Phase[](1);
        phases[0] = phase;
    }

    function _noConsent() internal pure returns (IFixedPriceSale.ArtistConsent memory c) { }

    function _open(address caller, uint256 id, IFixedPriceSale.Phase[] memory phases)
        internal
        returns (uint256 saleId)
    {
        vm.prank(caller);
        saleId = fixedSale.openSale(address(editions), id, phases, _noConsent());
    }

    function _openPublic(uint256 id, uint32 walletCap) internal returns (uint256) {
        return _open(creator, id, _one(_phase(0, walletCap, false, false)));
    }

    /// @dev The creator's signed approval of `phases` for edition `id`.
    function _consent(
        uint256 key,
        uint256 id,
        IFixedPriceSale.Phase[] memory phases,
        uint256 nonce,
        uint64 deadline
    ) internal view returns (IFixedPriceSale.ArtistConsent memory) {
        bytes32 digest = fixedSale.phaseConfigurationDigest(
                address(editions), id, phases, nonce, deadline
            );
        return IFixedPriceSale.ArtistConsent(nonce, deadline, _sig(key, digest));
    }

    /// @dev Leaves for `accounts` with their caps and prices, in `phase` of a sale of `id`.
    function _leaves(
        uint256 id,
        uint256 phase,
        address[] memory accounts,
        uint256[] memory caps,
        uint256[] memory prices
    ) internal view returns (bytes32[] memory leaves) {
        leaves = new bytes32[](accounts.length);
        for (uint256 i; i < accounts.length; ++i) {
            leaves[i] = fixedSale.allowlistLeaf(
                address(editions), id, phase, accounts[i], caps[i], prices[i]
            );
        }
    }

    function _p(
        uint256 saleId,
        uint256 phase,
        address recipient,
        uint256 quantity,
        uint256 leafCap,
        uint256 leafPrice
    ) internal pure returns (IFixedPriceSale.Purchase memory) {
        return IFixedPriceSale.Purchase(saleId, phase, recipient, quantity, leafCap, leafPrice);
    }

    /// @dev `buyer` pays `quantity * unit` in ETH for `recipient` in a phase without a root.
    function _buyEth(
        address buyer,
        uint256 saleId,
        uint256 phase,
        address recipient,
        uint256 quantity,
        uint256 unit
    ) internal {
        uint256 total = quantity * unit;
        vm.deal(buyer, buyer.balance + total);
        vm.prank(buyer);
        fixedSale.purchase{ value: total }(
            _p(saleId, phase, recipient, quantity, 0, 0), new bytes32[](0), _eth(buyer, total)
        );
    }

    function _purchase(
        address caller,
        IFixedPriceSale.Purchase memory p,
        bytes32[] memory proof,
        Payment memory payment
    ) internal {
        vm.prank(caller);
        fixedSale.purchase(p, proof, payment);
    }

    function _locked(uint256 saleId) internal view returns (LockedTerms memory terms) {
        (terms,,) = fixedSale.sale(saleId);
    }

    function _approved(uint256 saleId) internal view returns (bool approved) {
        (, approved,) = fixedSale.sale(saleId);
    }

    function _closed(uint256 saleId) internal view returns (bool closed) {
        (,, closed) = fixedSale.sale(saleId);
    }

    /// @dev The Permit2 witness of a fixed-price purchase (`Typehashes.PURCHASE_WITNESS`).
    function _witness(IFixedPriceSale.Purchase memory p, uint256 amount, uint256 deadline)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                Typehashes.PURCHASE_WITNESS,
                p.saleId,
                p.phase,
                p.recipient,
                p.quantity,
                amount,
                deadline
            )
        );
    }

    function _list3(address a, address b, address c) internal pure returns (address[] memory l) {
        l = new address[](3);
        (l[0], l[1], l[2]) = (a, b, c);
    }

    function _nums3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory l) {
        l = new uint256[](3);
        (l[0], l[1], l[2]) = (a, b, c);
    }
}

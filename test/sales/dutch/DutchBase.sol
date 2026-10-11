// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IDutchSale } from "src/interfaces/IDutchSale.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { DutchParams, Payment, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { DutchSale } from "src/sales/DutchSale.sol";
import { ISignatureTransfer } from "src/interfaces/external/ISignatureTransfer.sol";
import { SaleFixture } from "../../helpers/SaleFixture.sol";

/// @notice Dutch setup: the adapter wired to a linear ETH edition, a stepped ETH edition and a
///         linear USD edition.
abstract contract DutchBase is SaleFixture {
    uint256 internal constant LINEAR = 11;
    uint256 internal constant STEPPED = 12;
    uint256 internal constant USD_LINEAR = 13;
    uint256 internal constant START = 1 ether;
    uint256 internal constant REST = 0.1 ether;
    uint64 internal constant DURATION = 1000;
    uint64 internal constant STEP = 100;
    uint256 internal constant USD_START = 100e18;
    uint256 internal constant USD_REST = 10e18;

    DutchSale internal dutch;

    function setUp() public virtual {
        _setUpBase();
        (IRevenueEscrow e, ISignatureTransfer p, IEconomicsResolver r) = _deps();
        dutch = new DutchSale(address(manager), e, p, r);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = IDutchSale.openSale.selector;
        selectors[1] = IDutchSale.closeSale.selector;
        _wire(address(dutch), selectors);
        _setDutch(LINEAR, CURRENCY_ETH, START, REST, DURATION, 0);
        _setDutch(STEPPED, CURRENCY_ETH, START, 0.2 ether, DURATION, STEP);
        _setDutch(USD_LINEAR, address(usd), USD_START, USD_REST, DURATION, 0);
    }

    function _setDutch(
        uint256 id,
        address currency,
        uint256 start,
        uint256 rest,
        uint64 duration,
        uint64 step
    ) internal {
        editions.setTerms(
            id,
            _terms(SaleKind.DUTCH, currency, start, abi.encode(DutchParams(rest, duration, step))),
            SIZE
        );
    }

    function _openNow(uint256 id) internal returns (uint256 saleId) {
        vm.prank(creator);
        saleId = dutch.openSale(address(editions), id, uint64(block.timestamp));
    }

    /// @dev `buyer` pays `value` wei for `quantity` copies at most `maxUnit` each.
    function _buy(
        address buyer,
        uint256 saleId,
        address recipient,
        uint256 quantity,
        uint256 maxUnit,
        uint256 value
    ) internal {
        vm.deal(buyer, buyer.balance + value);
        vm.prank(buyer);
        dutch.purchase{ value: value }(saleId, recipient, quantity, maxUnit, _eth(buyer, value));
    }

    function _closed(uint256 saleId) internal view returns (bool closed) {
        (,, closed) = dutch.sale(saleId);
    }

    function _witness(
        uint256 saleId,
        address recipient,
        uint256 quantity,
        uint256 maxUnit,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                Typehashes.DUTCH_PURCHASE_WITNESS, saleId, recipient, quantity, maxUnit, deadline
            )
        );
    }

    /// @dev Alice-style Permit2 intent for up to `amount` USD over `witness`.
    function _intent(
        uint256 key,
        address owner,
        bytes32 witness,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (Payment memory) {
        return _permit2Payment(
            key,
            owner,
            address(dutch),
            address(usd),
            amount,
            nonce,
            deadline,
            witness,
            Typehashes.DUTCH_PURCHASE_WITNESS_TYPE
        );
    }
}

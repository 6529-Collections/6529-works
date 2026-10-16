// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { Payment } from "src/interfaces/types/SaleTypes.sol";
import { FixedPriceSale } from "src/sales/FixedPriceSale.sol";

/// @notice Adversarial mocks for the fixed-price adapter: ERC-20s whose `transferFrom` moves less
///         or more to the receiver, or more or less from the sender, than asked (the
///         balance-delta checks on each side of a Permit2 payment), and a creator wallet that
///         closes and reopens its sale from its own ERC-1155 receiver hook. First written for the
///         PR #18 review's proofs of concept and mutation killers.

/// @dev `transferFrom` delivers one unit less than asked (receiver short); `transfer` is exact.
contract InboundShortToken is ERC20 {
    constructor() ERC20("Short", "SHT") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount - 1);
        _burn(from, 1);
        return true;
    }
}

/// @dev `transferFrom` debits the sender one unit more than it delivers; `transfer` is exact.
contract OverDebitToken is ERC20 {
    constructor() ERC20("Over", "OVR") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        _burn(from, 1);
        return true;
    }
}

/// @dev `transferFrom` delivers one unit more than asked (a reward to the receiver) and debits
///      the sender exactly; `transfer` is exact.
contract InboundExcessToken is ERC20 {
    constructor() ERC20("Excess", "EXC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        _mint(to, 1);
        return true;
    }
}

/// @dev `transferFrom` debits the sender one unit less than it delivers (a rebate to the
///      sender); `transfer` is exact.
contract UnderDebitToken is ERC20 {
    constructor() ERC20("UnderDebit", "UDB") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        _mint(from, 1);
        return true;
    }
}

/// @dev A creator wallet that, on receiving its own edition, closes the running sale and opens a
///      new one, then tries to reenter `purchase`.
contract CreatorReentrant is IERC1155Receiver {
    FixedPriceSale public sale;
    address public token;
    uint256 public id;
    uint256 public saleId;
    uint256 public reopened;
    bool public purchaseReentryBlocked;
    bool public armed;

    function arm(FixedPriceSale sale_, address token_, uint256 id_, uint256 saleId_) external {
        (sale, token, id, saleId, armed) = (sale_, token_, id_, saleId_, true);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        returns (bytes4)
    {
        if (armed) {
            armed = false;
            sale.closeSale(saleId);
            IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](1);
            phases[0] = IFixedPriceSale.Phase(
                uint64(block.timestamp), uint64(block.timestamp + 1 days), 0, 0, false, false
            );
            IFixedPriceSale.ArtistConsent memory none;
            reopened = sale.openSale(token, id, phases, none);
            Payment memory pay;
            pay.payer = address(this);
            (bool ok, bytes memory ret) = address(sale)
                .call(
                    abi.encodeCall(
                        IFixedPriceSale.purchase,
                        (
                            IFixedPriceSale.Purchase(reopened, 0, address(this), 1, 0, 0),
                            new bytes32[](0),
                            pay
                        )
                    )
                );
            purchaseReentryBlocked = !ok
                && bytes4(ret) == ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector;
        }
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == 0x01ffc9a7;
    }

    receive() external payable { }
}

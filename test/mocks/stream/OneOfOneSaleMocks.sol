// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Splits } from "src/economics/Splits.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { PrimaryOutcome, PrimaryTerms } from "src/interfaces/types/SaleTypes.sol";

/// @notice A minimal 1/1 sale method added after launch (owner decision 15): a fixed price in
///         ETH, carried in the item's sale params as `abi.encode(uint256 price)`. One call mints
///         the work into the adapter's custody, takes the price, settles the primary sale with
///         Stream (SOLD, owner decision 17), pays the network fee and the seller, and hands the
///         work to the buyer. A listing can also wait for a buyer until a deadline; one that ends
///         unsold is reported UNBID, and Stream itself moves it to the 6529 Network Museum: the
///         adapter never moves it. A test stand-in, not a reviewed adapter: it pushes payments
///         and has no pause or credits.
contract FixedPriceOneOfOneMock is ISaleAdapter {
    bytes32 public constant KIND = keccak256("FIXED_PRICE_1OF1");

    error WrongPrice(uint256 expected, uint256 paid);
    error WrongCurrency(address currency);
    error PaymentFailed(address to);
    error NotListed(uint256 id);
    error ListingOpen(uint256 id);

    /// @notice A listed work's deadline, by token ID (one token contract per test).
    mapping(uint256 id => uint256 deadline) public listedUntil;

    /// @notice Mints the work `mintData` names into custody and lists it until `deadline`.
    function list(address token, bytes calldata mintData, uint256 deadline)
        external
        returns (uint256 id)
    {
        PrimaryTerms memory t;
        (id, t) = IMintTarget(token).mint(address(this), 0, 1, mintData);
        if (t.saleKind != KIND) revert IMintTarget.SaleKindMismatch(KIND, t.saleKind);
        if (t.currency != CURRENCY_ETH) revert WrongCurrency(t.currency);
        listedUntil[id] = deadline;
    }

    /// @notice Settles a listing that ended with no buyer: it reports UNBID, and Stream moves
    ///         the work to the museum its economics resolver names now.
    function closeUnsold(address token, uint256 id) external {
        uint256 deadline = listedUntil[id];
        if (deadline == 0) revert NotListed(id);
        if (block.timestamp < deadline) revert ListingOpen(id);
        delete listedUntil[id];
        IMintTarget(token).settlePrimary(id, PrimaryOutcome.UNBID, address(0), CURRENCY_ETH, 0);
    }

    /// @notice Buys the work `mintData` names, at the price its item fixed, for `msg.sender`.
    function buy(address token, bytes calldata mintData) external payable returns (uint256 id) {
        PrimaryTerms memory t;
        (id, t) = IMintTarget(token).mint(address(this), 0, 1, mintData);
        if (t.saleKind != KIND) revert IMintTarget.SaleKindMismatch(KIND, t.saleKind);
        // Stream leaves the currency to the adapter: this method takes ETH only.
        if (t.currency != CURRENCY_ETH) revert WrongCurrency(t.currency);
        uint256 price = abi.decode(t.params, (uint256));
        if (msg.value != price) revert WrongPrice(price, msg.value);
        IMintTarget(token).settlePrimary(id, PrimaryOutcome.SOLD, msg.sender, CURRENCY_ETH, price);
        uint256 fee = price * t.feeShare / Splits.DENOMINATOR;
        _pay(t.feeRecipient, fee);
        _pay(t.seller, price - fee);
        IERC721(token).transferFrom(address(this), msg.sender, id);
    }

    function _pay(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert PaymentFailed(to);
    }

    function saleKind() external pure returns (bytes32) {
        return KIND;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(ISaleAdapter).interfaceId
                || interfaceId == type(IERC165).interfaceId;
    }

    // ------------------------------------------------------------------ unused surface

    function pause() external pure {
        revert("unused");
    }

    function unpause() external pure {
        revert("unused");
    }

    function paused() external pure returns (bool) {
        return false;
    }

    function isTarget(address) external pure returns (bool) {
        return true;
    }

    function setTarget(address, bool) external pure {
        revert("unused");
    }

    function federationRegistry() external pure returns (address) {
        return address(0);
    }

    function setFederationRegistry(address, address) external pure {
        revert("unused");
    }

    function claimable(address, address) external pure returns (uint256) {
        return 0;
    }

    function claim(address, address) external pure returns (uint256) {
        revert("unused");
    }
}

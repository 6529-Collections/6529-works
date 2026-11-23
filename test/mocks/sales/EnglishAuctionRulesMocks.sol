// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { MintFacts } from "src/interfaces/core/CoreTypes.sol";
import { MockMintPolicy } from "test/sales/auction/AuctionMocks.sol";

/// @notice A mint policy whose every answer the test sets: the fee recipient and the creator of
///         its terms, and the artist, royalty receiver and royalty rate of its facts.
contract OpenTermsPolicy is MockMintPolicy {
    constructor(address seller, address feeRecipient, uint32 feeShare)
        MockMintPolicy(seller, feeRecipient, feeShare)
    { }

    /// @dev Sets the two parties of the terms that `MockMintPolicy.setTerms` leaves alone.
    function setParties(address feeRecipient, address creator) external {
        (_terms.feeRecipient, _terms.creator) = (feeRecipient, creator);
    }

    /// @dev Sets the royalty receiver and rate the facts state from now on.
    function setRoyalty(address receiver, uint24 rate) external {
        (royaltyReceiver, royaltyRate) = (receiver, rate);
    }
}

/// @notice A token that mints with a receiver callback, as a safe mint does: `mint` calls the
///         receiver's `onERC721Received`, stating the caller as the operator and no previous
///         owner, or whatever operator and previous owner the test set. `offer` makes the same
///         callback outside a mint.
contract CallbackMintToken {
    mapping(uint256 tokenId => address) public ownerOf;
    uint256 public minted;
    bytes4 public answer;
    address public statedOperator;
    address public statedFrom;
    bool public stated;

    /// @dev From now on a mint's callback states `operator` and `from`.
    function state(address operator, address from) external {
        (statedOperator, statedFrom, stated) = (operator, from, true);
    }

    function isMinter(address) external pure returns (bool) {
        return true;
    }

    function mint(address to, MintFacts calldata) external returns (uint256 tokenId) {
        tokenId = ++minted;
        ownerOf[tokenId] = to;
        answer = IERC721Receiver(to)
            .onERC721Received(
                stated ? statedOperator : msg.sender, stated ? statedFrom : address(0), tokenId, ""
            );
    }

    function offer(address to, address operator, address from, uint256 tokenId)
        external
        returns (bytes4)
    {
        return IERC721Receiver(to).onERC721Received(operator, from, tokenId, "");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { CoreFixture } from "../mocks/core/CoreFixture.sol";
import { MockSale } from "../mocks/core/CoreMocks.sol";

/// @notice The real core (`CoreFixture`) with helpers for 6529 Stream Editions: a sold master
///         per edition, a second sale contract, and edition creation through the fixture's sale
///         contract (a genesis minter of both tokens).
abstract contract EditionsFixture is CoreFixture {
    address internal buyer = makeAddr("buyer");
    address internal stranger = makeAddr("stranger");
    address internal constant ROYALTY = address(0xFEE);
    uint24 internal constant RATE = 6529;

    /// @dev Another sale contract, not yet a minter of anything.
    MockSale internal other;

    function setUp() public virtual override {
        super.setUp();
        other = new MockSale();
    }

    /// @dev A master sold to the collector and its edition created by `sale` with cap `cap`.
    function _edition(uint256 n, uint40 cap) internal returns (uint256 id) {
        id = _sell(n, collector);
        sale.createEdition(address(editions), id, cap, ROYALTY, RATE);
    }

    /// @dev Adds `minter` to Editions and waits until it is active.
    function _addActive(address minter) internal {
        editions.addMinter(minter);
        skip(editions.moduleDelay());
    }
}

/// @notice An ERC-1155 receiver that accepts, refuses, or re-enters `Editions.mint` through the
///         sale contract that is minting to it.
contract EditionsReceiver is IERC1155Receiver {
    enum Mode {
        ACCEPT,
        REFUSE,
        REENTER
    }

    Mode public mode;
    MockSale public via;
    IEditions public editions;
    /// @dev The edition's minted count seen inside the acceptance call.
    uint256 public seenMinted;
    bool public reenterSucceeded;

    function set(Mode mode_, MockSale via_, IEditions editions_) external {
        (mode, via, editions) = (mode_, via_, editions_);
    }

    function onERC1155Received(address, address, uint256 id, uint256, bytes calldata)
        external
        returns (bytes4)
    {
        if (mode == Mode.REFUSE) revert("refused");
        if (mode == Mode.REENTER && seenMinted == 0) {
            // First call only: the re-entered mint calls back here once more.
            seenMinted = editions.editionOf(id).minted;
            (reenterSucceeded,) = address(via)
                .call(
                    abi.encodeCall(
                        MockSale.mintEdition, (address(editions), address(this), id, 1, 0)
                    )
                );
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
}

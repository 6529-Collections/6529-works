// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Dependency } from "../libraries/Dependency.sol";
import { IGovernedVault } from "./interfaces/IGovernedVault.sol";
import { IRevenueEscrow } from "./interfaces/IRevenueEscrow.sol";
import { ISplitLedger } from "./interfaces/ISplitLedger.sol";
import { ISplitWallet } from "./interfaces/ISplitWallet.sol";
import { TokenTransfer } from "./TokenTransfer.sol";

/// @title GovernedVault
/// @notice The network fee recipient and the 6529 Network Museum as contracts that outlive any key
///         (study D, finding 6): a fixed payee of every royalty wallet, and the holder of every
///         unbid work, each moving what it holds only to a destination governance sets on the
///         slow funds path.
/// @dev Deliberately small and without upgrade: a bug here would be permanent for every work's fee
///      share. Its empty `receive` costs a few hundred gas, so it accepts a sale adapter's
///      100,000-gas payout and a 2,300-gas stipend alike. ERC-20 forwards count a `transfer` that
///      returns `true` or nothing, with exact balance deltas, because the vault has no other way
///      out of a token a marketplace chose. Every external call forwards all available gas and
///      reverts on failure.
contract GovernedVault is IGovernedVault, IERC721Receiver, IERC1155Receiver, AccessManaged {
    /// @inheritdoc IGovernedVault
    ISplitLedger public immutable ledger;

    /// @dev The destination and its revision share one slot.
    address private _destination;
    uint64 private _revision;

    /// @param authority The AccessManager governing {setDestination}.
    /// @param ledger_ The split ledger whose wallets name this vault as a payee.
    /// @param destination_ The first destination; not zero or the vault.
    constructor(address authority, ISplitLedger ledger_, address destination_)
        AccessManaged(authority)
    {
        Dependency.check(address(ledger_));
        ledger = ledger_;
        _setDestination(destination_);
    }

    /// @notice Accepts ETH from anyone.
    receive() external payable { }

    /// @inheritdoc IGovernedVault
    function destination() external view returns (address) {
        return _destination;
    }

    /// @inheritdoc IGovernedVault
    function destinationRevision() external view returns (uint64) {
        return _revision;
    }

    /// @inheritdoc IGovernedVault
    function setDestination(uint64 expectedRevision, address next) external restricted {
        if (expectedRevision != _revision) revert RevisionMismatch(expectedRevision, _revision);
        _setDestination(next);
    }

    /// @inheritdoc IGovernedVault
    function forward(address asset, uint256 amount) external returns (uint256 sent) {
        address to = _destination;
        sent = amount;
        if (sent == type(uint256).max) {
            sent = asset == address(0)
                ? address(this).balance
                : TokenTransfer.balanceOf(asset, address(this));
        }
        if (sent == 0) revert NothingToForward(asset);
        emit Forwarded(asset, to, sent);
        if (asset == address(0)) {
            if (!TokenTransfer.sendETH(to, sent, gasleft())) revert ETHTransferFailed(to, sent);
        } else {
            TokenTransfer.transferExactAllowingNoReturn(asset, to, sent);
        }
    }

    /// @inheritdoc IGovernedVault
    function forwardERC721(address token, uint256 tokenId) external {
        address to = _destination;
        emit TokenForwarded(token, tokenId, to, 1);
        IERC721(token).safeTransferFrom(address(this), to, tokenId);
    }

    /// @inheritdoc IGovernedVault
    function forwardERC1155(address token, uint256 id, uint256 amount) external {
        address to = _destination;
        emit TokenForwarded(token, id, to, amount);
        IERC1155(token).safeTransferFrom(address(this), to, id, amount, "");
    }

    /// @inheritdoc IGovernedVault
    function releaseToDestination(
        ISplitWallet.Payee[] calldata payees,
        bytes32 salt,
        address asset,
        uint256 index
    ) external returns (uint256) {
        return ledger.releaseTo(payees, salt, asset, index, _destination);
    }

    /// @inheritdoc IGovernedVault
    function consentToRecovery(IRevenueEscrow escrow) external {
        escrow.consentToRecovery(_destination);
    }

    /// @inheritdoc IERC721Receiver
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @inheritdoc IERC1155Receiver
    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    /// @inheritdoc IERC1155Receiver
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IGovernedVault).interfaceId
            || interfaceId == type(IERC721Receiver).interfaceId
            || interfaceId == type(IERC1155Receiver).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    function _setDestination(address next) private {
        if (next == address(0) || next == address(this)) revert InvalidDestination(next);
        uint64 revision = _revision + 1;
        emit DestinationSet(_destination, next, revision);
        (_destination, _revision) = (next, revision);
    }
}

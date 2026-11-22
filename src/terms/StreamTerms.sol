// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { ISplitFactory } from "../economics/interfaces/ISplitFactory.sol";
import { Splits } from "../economics/Splits.sol";
import { Edition, Slots, Work } from "../interfaces/core/CoreTypes.sol";
import { IEditions } from "../interfaces/core/IEditions.sol";
import { IFederationGate } from "../interfaces/core/IFederationGate.sol";
import { IModuleSlots } from "../interfaces/core/IModules.sol";
import { IStream } from "../interfaces/core/IStream.sol";
import { ITerms } from "../interfaces/core/ITerms.sol";

/// @title StreamTerms
/// @notice The TERMS module (replaceable): the royalty policy of existing works, for 6529 Stream
///         and its editions and, through the directory's `FEDERATED_TERMS` slot, for federated
///         tokens. It is the only caller of the tokens' royalty setters.
///         - The royalty rate changes only through the token's RECORDS module, which checked
///           every party's consent and the network's call; a master's edition follows it.
///         - The rate is locked for good only through the RECORDS module.
///         - The network alone lowers its share of a work's royalties, never raises it. The
///           caller states the seller, fee recipient and current share; they must derive the
///           receiver the token stores, so this module stores nothing per work. The new split
///           vault is deployed before it is set, so royalties never point at an address without
///           code.
/// @dev For a federated token (any token but `stream` and its editions) the new share may not
///      exceed the federation module's current share for that token
///      (`IFederationGate.feeShareOf`), which only ever goes down.
contract StreamTerms is AccessManaged, ITerms {
    /// @notice The network paired an editions contract with a token contract.
    /// @param token The ERC-721 token contract.
    /// @param editions The editions contract (zero: unpaired).
    event EditionsSet(address indexed token, address editions);

    /// @notice The editions contract's `stream()` is not the token, or it is already paired.
    /// @param token The token contract.
    /// @param editions The editions contract.
    error InvalidEditions(address token, address editions);
    /// @notice The work or edition does not exist.
    error UnknownWork(address token, uint256 tokenId);

    /// @notice The split factory that deploys royalty vaults.
    address public immutable splitFactory;
    /// @notice 6529 Stream, the one token that is not federated.
    address public immutable stream;
    /// @notice The directory, through which the federation module is found.
    address public immutable directory;

    /// @inheritdoc ITerms
    mapping(address token => address editions) public editionsOf;
    /// @notice The ERC-721 token contract an editions contract is paired with, or zero.
    mapping(address editions => address token) public tokenOfEditions;

    /// @param authority_ The AccessManager (the network).
    /// @param splitFactory_ The split factory.
    /// @param stream_ 6529 Stream.
    /// @param editions_ 6529 Stream Editions, paired with `stream_` (or zero).
    /// @param directory_ The directory.
    constructor(
        address authority_,
        address splitFactory_,
        address stream_,
        address editions_,
        address directory_
    ) AccessManaged(authority_) {
        splitFactory = splitFactory_;
        stream = stream_;
        directory = directory_;
        if (editions_ != address(0)) _pair(stream_, editions_);
    }

    // ------------------------------------------------------------------ the RECORDS module

    /// @inheritdoc ITerms
    /// @dev The receiver stays as it is. The edition, if one exists, takes the same rate.
    function setRoyaltyRate(address token, uint256 tokenId, uint24 rate) external {
        _onlyRecords(token);
        Work memory w = IStream(token).workOf(tokenId);
        IStream(token).setRoyalty(tokenId, w.royaltyReceiver, rate);
        address editions = editionsOf[token];
        if (editions == address(0)) return;
        Edition memory e = IEditions(editions).editionOf(tokenId);
        if (e.minter != address(0)) {
            IEditions(editions).setRoyalty(tokenId, e.royaltyReceiver, rate);
        }
    }

    /// @inheritdoc ITerms
    function lockRoyaltyRate(address token, uint256 tokenId) external {
        _onlyRecords(token);
        IStream(token).lockRoyaltyRate(tokenId);
    }

    // ------------------------------------------------------------------------- the network

    /// @inheritdoc ITerms
    /// @dev `token` is an ERC-721 token contract or a paired editions contract. For a work, the
    ///      edition moves with it when the edition's receiver is the work's old receiver; an
    ///      edition with its own receiver is lowered by naming the editions contract as
    ///      `token`. The rate never changes here.
    function lowerFeeShare(
        address token,
        uint256 tokenId,
        address seller,
        address feeRecipient,
        uint32 currentShare,
        uint32 newShare
    ) external restricted {
        address master = tokenOfEditions[token];
        bool isEdition = master != address(0);
        if (!isEdition) master = token;
        if (newShare >= currentShare) revert InvalidFeeShare();
        if (master != stream) {
            address gate = IModuleSlots(directory).moduleOf(Slots.FEDERATION);
            if (newShare > IFederationGate(gate).feeShareOf(master)) revert InvalidFeeShare();
        }
        address previous;
        uint24 rate;
        if (isEdition) {
            Edition memory e = IEditions(token).editionOf(tokenId);
            if (e.minter == address(0)) revert UnknownWork(token, tokenId);
            (previous, rate) = (e.royaltyReceiver, e.royaltyRate);
        } else {
            IStream(token).ownerOf(tokenId);
            Work memory w = IStream(token).workOf(tokenId);
            (previous, rate) = (w.royaltyReceiver, w.royaltyRate);
        }
        if (_receiver(seller, feeRecipient, currentShare, false) != previous) {
            revert InvalidFeeShare();
        }
        address receiver = _receiver(seller, feeRecipient, newShare, true);
        if (isEdition) {
            IEditions(token).setRoyalty(tokenId, receiver, rate);
        } else {
            IStream(token).setRoyalty(tokenId, receiver, rate);
            address editions = editionsOf[token];
            if (editions != address(0)) {
                Edition memory e = IEditions(editions).editionOf(tokenId);
                if (e.minter != address(0) && e.royaltyReceiver == previous) {
                    IEditions(editions).setRoyalty(tokenId, receiver, e.royaltyRate);
                }
            }
        }
        emit FeeShareLowered(token, tokenId, currentShare, newShare, receiver);
    }

    /// @notice Pairs an editions contract with its token contract, so the editions follow
    ///         their masters, replacing any earlier pairing of the token. The network only.
    ///         The editions contract must name the token as its `stream()` and must not be
    ///         paired already.
    /// @param token The ERC-721 token contract.
    /// @param editions The editions contract.
    function setEditions(address token, address editions) external restricted {
        _pair(token, editions);
    }

    // ---------------------------------------------------------------------------- internal

    function _pair(address token, address editions) private {
        if (tokenOfEditions[editions] != address(0) || IEditions(editions).stream() != token) {
            revert InvalidEditions(token, editions);
        }
        delete tokenOfEditions[editionsOf[token]];
        editionsOf[token] = editions;
        tokenOfEditions[editions] = token;
        emit EditionsSet(token, editions);
    }

    /// @dev Only the token's RECORDS module.
    function _onlyRecords(address token) private view {
        if (msg.sender != IModuleSlots(token).moduleOf(Slots.RECORDS)) {
            revert NotRecordsModule(token, msg.sender);
        }
    }

    /// @dev The royalty receiver of (seller, fee recipient) at `share`: the seller at a zero
    ///      share, else the split vault of the two, deployed first when `deploy`.
    function _receiver(address seller, address feeRecipient, uint32 share, bool deploy)
        private
        returns (address)
    {
        if (share == 0) return seller;
        ISplitFactory factory = ISplitFactory(splitFactory);
        if (deploy) {
            return factory.createWallet(Splits.royaltyPayees(seller, feeRecipient, share), 0);
        }
        return factory.walletFor(Splits.royaltyPayees(seller, feeRecipient, share), 0);
    }
}

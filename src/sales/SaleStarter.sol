// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { ISplitFactory } from "../economics/interfaces/ISplitFactory.sol";
import { Splits } from "../economics/Splits.sol";
import { MintTerms, Work } from "../interfaces/core/CoreTypes.sol";
import { IMintPolicy } from "../interfaces/core/IMintPolicy.sol";
import { IStream } from "../interfaces/core/IStream.sol";
import { IWorkFacts } from "../interfaces/core/IWorkFacts.sol";
import { IEnglishAuction } from "../interfaces/IEnglishAuction.sol";
import { MediaFile } from "../interfaces/types/ContentTypes.sol";
import { PackageItem, StreamMintRequest } from "../interfaces/types/PackageTypes.sol";

/// @title SaleStarter
/// @notice Starts a 6529 Stream sale whole: in one transaction it starts the English auction (the
///         work is minted into the auction's custody), deploys the work's seller vault and, when
///         the network takes a share, its royalty vault, and opens the work's record in
///         `StreamWorkFacts6529`. If any step fails, nothing happens.
/// @dev Stateless, with no roles and no owner. Every call out is a high-level call, which
///      forwards all the gas EIP-150 allows and reverts the whole transaction on any failure. It
///      binds no one: `IEnglishAuction.start` and `startWithBid` stay permissionless, and a start
///      made directly can leave the vaults and the record to later calls (each is open to
///      anyone). A first bid is not offered here: the auction records its caller as the bidder.
contract SaleStarter {
    /// @notice A vault the factory deployed is not the one the work's terms name.
    /// @param wallet The address the factory returned.
    error VaultMismatch(address wallet);

    /// @notice Starts the auction of the work `request` mints, deploys its vaults and opens its
    ///         record; all or nothing.
    /// @param auction The English auction.
    /// @param stream 6529 Stream.
    /// @param request `abi.encode(StreamMintRequest)`, passed to `IEnglishAuction.start`.
    /// @param media The work's media files, primary first, in the order its item's `mediaHash`
    ///        commits to (`IWorkFacts.open`).
    /// @return saleId The auction's sale ID.
    function start(
        IEnglishAuction auction,
        address stream,
        bytes calldata request,
        MediaFile[] calldata media
    ) external returns (uint256 saleId) {
        // The same block's answer of the policy names the fee terms the start locks.
        (, MintTerms memory t) = IMintPolicy(auction.policyOf(stream)).preview(stream, request);
        saleId = auction.start(stream, request);
        uint256 tokenId = auction.auction(saleId).tokenId;
        PackageItem memory item = abi.decode(request, (StreamMintRequest)).item;
        Work memory w = IStream(stream).workOf(tokenId);
        ISplitFactory factory = ISplitFactory(auction.economics().splitFactory());
        address seller = factory.createWallet(item.payees, bytes32(0));
        if (seller != t.seller) revert VaultMismatch(seller);
        if (w.royaltyReceiver != seller) {
            address royalty = factory.createWallet(
                Splits.royaltyPayees(seller, t.feeRecipient, t.feeShare), bytes32(0)
            );
            if (royalty != w.royaltyReceiver) revert VaultMismatch(royalty);
        }
        IWorkFacts(IStream(stream).facts()).open(stream, tokenId, item, media);
    }
}

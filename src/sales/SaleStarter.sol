// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitFactory } from "../economics/interfaces/ISplitFactory.sol";
import { Splits } from "../economics/Splits.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "../interfaces/IEnglishAuction.sol";
import { IMintTarget } from "../interfaces/IMintTarget.sol";
import { IStream } from "../interfaces/IStream.sol";
import { IWorkRecords } from "../interfaces/IWorkRecords.sol";
import { MediaFile } from "../interfaces/types/ContentTypes.sol";
import { PackageItem, StreamMintRequest } from "../interfaces/types/PackageTypes.sol";
import { Payment, PrimaryTerms } from "../interfaces/types/SaleTypes.sol";

/// @title SaleStarter
/// @notice Starts a 6529 Stream sale whole: in one transaction it starts the English auction (the
///         work is minted into the auction's custody), deploys the work's seller vault and, when
///         the network takes a share, its royalty vault, and opens the work's record in
///         WorkRecords. If any step fails, nothing happens. The network's keeper starts every
///         sale through it, so no sale it starts lacks its vaults or its record.
/// @dev Stateless, with no roles and no owner: it holds nothing between calls, and a call's ETH
///      (`startWithBid` only) is forwarded to the auction in full. Every call out is a high-level
///      call, which forwards all the gas EIP-150 allows and reverts the whole transaction on any
///      failure, a shortfall included. It does not bind anyone else: `IEnglishAuction.start`
///      stays permissionless, and a start made directly can leave the vaults and the record to
///      later calls (each is open to anyone).
contract SaleStarter {
    /// @notice A vault the factory deployed is not the one the work's terms name.
    /// @param wallet The address the factory returned.
    error VaultMismatch(address wallet);
    /// @notice A first bid names this helper as its payer: it could never claim a refund.
    error HelperAsPayer();

    /// @notice Starts the auction of the work `mintData` mints, deploys its vaults and opens its
    ///         record; all or nothing.
    /// @param auction The English auction.
    /// @param stream 6529 Stream.
    /// @param mintData `abi.encode(StreamMintRequest)`, passed to `IEnglishAuction.start`.
    /// @param media The work's media files, in the order its item's `mediaHash` commits to
    ///        (`IWorkRecords.openRecord`).
    /// @return saleId The auction's sale ID.
    function start(
        IEnglishAuction auction,
        address stream,
        bytes calldata mintData,
        MediaFile[] calldata media
    ) external returns (uint256 saleId) {
        saleId = auction.start(stream, mintData);
        _finish(auction, stream, saleId, mintData, media);
    }

    /// @notice As `start`, with a first bid (`IEnglishAuction.startWithBid`). The auction records
    ///         `payment.payer` as the bidder and requires it to be the caller of the auction for a
    ///         DIRECT payment, which here is this helper; a payment naming this helper as payer
    ///         reverts (`HelperAsPayer`), since it could never claim a refund. So only a PERMIT2
    ///         payment, signed by its payer, can succeed. `msg.value` is forwarded in full.
    /// @param auction The English auction.
    /// @param stream 6529 Stream.
    /// @param mintData `abi.encode(StreamMintRequest)`.
    /// @param media The work's media files (`IWorkRecords.openRecord`).
    /// @param recipient Who receives the work if the bid wins, or zero for the payer.
    /// @param payment The first bid's payment.
    /// @return saleId The auction's sale ID.
    function startWithBid(
        IEnglishAuction auction,
        address stream,
        bytes calldata mintData,
        MediaFile[] calldata media,
        address recipient,
        Payment calldata payment
    ) external payable returns (uint256 saleId) {
        if (payment.payer == address(this)) revert HelperAsPayer();
        saleId = auction.startWithBid{ value: msg.value }(stream, mintData, recipient, payment);
        _finish(auction, stream, saleId, mintData, media);
    }

    /// @dev Deploys (or confirms) the seller vault, the split wallet of the item's payees with
    ///      salt zero, which must be the seller the work's terms name, and, with a nonzero network
    ///      share, the royalty vault (`Splits.royaltyPayees` of the seller and the work's fee
    ///      terms, salt zero, as `IEconomicsResolver.newWorkTerms` derives it), both through
    ///      6529 Stream's split factory; then opens the record.
    function _finish(
        IEnglishAuction auction,
        address stream,
        uint256 saleId,
        bytes calldata mintData,
        MediaFile[] calldata media
    ) private {
        uint256 tokenId = auction.auction(saleId).tokenId;
        PackageItem memory item = abi.decode(mintData, (StreamMintRequest)).item;
        PrimaryTerms memory t = IMintTarget(stream).primaryTerms(tokenId, "");
        ISplitFactory factory =
            ISplitFactory(IEconomicsResolver(IStream(stream).economics()).splitFactory());
        address seller = factory.createWallet(item.payees, bytes32(0));
        if (seller != t.seller) revert VaultMismatch(seller);
        if (t.feeShare != 0) {
            factory.createWallet(
                Splits.royaltyPayees(seller, t.feeRecipient, t.feeShare), bytes32(0)
            );
        }
        IWorkRecords(IStream(stream).workRecords()).openRecord(tokenId, item, media);
    }
}

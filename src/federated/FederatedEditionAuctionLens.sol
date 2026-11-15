// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitWallet } from "../economics/interfaces/ISplitWallet.sol";
import { Splits } from "../economics/Splits.sol";
import { IArtistRegistry } from "../interfaces/IArtistRegistry.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "../interfaces/IEnglishAuction.sol";
import { IEnglishAuctionClock } from "../interfaces/IEnglishAuctionClock.sol";
import { IFederatedEditions } from "../interfaces/IFederatedEditions.sol";
import { IFederatedToken } from "../interfaces/IFederatedToken.sol";
import { IFederationRegistry } from "../interfaces/IFederationRegistry.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { IUniformEditionAuctionLens } from "../interfaces/IUniformEditionAuctionLens.sol";
import {
    IUniformEditionAuctionStorage as IStorage
} from "../interfaces/IUniformEditionAuctionStorage.sol";
import { PRODUCT_FEDERATED, WorkTerms } from "../interfaces/types/EconomicsTypes.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";
import { UniformEditionAuctionLensBase } from "../sales/UniformEditionAuctionLens.sol";

/// @title FederatedEditionAuctionLens
/// @notice The lens of {FederatedEditionAuction} (ADR 0008): {UniformEditionAuctionLensBase}'s
///         views and checks, plus the federation rules the adapter asks it for: which contracts
///         are served, the fee a sale locks, and the 1/1 clock a delisting cancels.
/// @dev Stateless; reads the calling adapter's storage (slot 14: each sale's edition contract)
///      and, for the federation registry, the artist registry's current pointer. Every call out
///      forwards all gas; a high-level call reverts on any failure, and the existence check
///      uses `BoundedCall`'s forward-all read, so no shortfall is read as an answer. `editions`
///      and `stream` answer zero (there is no single one).
contract FederatedEditionAuctionLens is UniformEditionAuctionLensBase {
    uint256 private constant _SLOT_TOKENS = 14;

    address private immutable _englishAuctionAddress;
    IArtistRegistry private immutable _artistRegistry;
    IEconomicsResolver private immutable _economics;

    /// @param englishAuction_ The adapter's English auction.
    /// @param escrow_ The adapter's revenue escrow.
    /// @param artistRegistry_ The artist registry, whose pointer names the federation registry.
    /// @param economics_ The economics resolver: the federated network fee recipient.
    constructor(
        address englishAuction_,
        address escrow_,
        address artistRegistry_,
        address economics_
    ) UniformEditionAuctionLensBase(englishAuction_, escrow_) {
        _englishAuctionAddress = englishAuction_;
        _artistRegistry = IArtistRegistry(artistRegistry_);
        _economics = IEconomicsResolver(economics_);
    }

    /// @notice The fee a sale of `token` locks at open: the federation registry entry's share,
    ///         paid to the economics resolver's federated recipient. Reverts with
    ///         `InvalidSaleTerms` unless the registry serves `token` with an entry whose code hash
    ///         is the token's, the share is at most 100,000, and a nonzero share has a payable
    ///         recipient (not zero, not `escrow`).
    /// @param token The edition contract.
    /// @param escrow The adapter's revenue escrow.
    /// @return recipient The network fee recipient.
    /// @return share The network share, out of 100,000.
    function feeTerms(address token, address escrow)
        external
        view
        returns (address recipient, uint256 share)
    {
        IFederationRegistry registry = IFederationRegistry(federationRegistry());
        IFederationRegistry.Entry memory e = registry.entry(token);
        recipient = _economics.networkFeeRecipient(PRODUCT_FEDERATED);
        share = e.feeShare;
        if (
            !registry.isActive(token) || e.codeHash != token.codehash || share > Splits.DENOMINATOR
                || (share != 0 && (recipient == address(0) || recipient == escrow))
        ) revert ISaleAdapter.InvalidSaleTerms(token, 0);
    }

    /// @notice Edition `id`'s 1/1 clock (`IEnglishAuctionClock.auctionClock` of its master's
    ///         sale), or CANCELLED once the federation registry no longer serves `token`.
    /// @param token The edition contract.
    /// @param id The edition ID (the master's token ID).
    /// @return The 1/1's state, end and pause start.
    function clock(address token, uint256 id)
        external
        view
        returns (IEnglishAuction.AuctionState, uint64, uint64)
    {
        if (!_served(token)) return (IEnglishAuction.AuctionState.CANCELLED, 0, 0);
        return IEnglishAuctionClock(_englishAuctionAddress)
            .auctionClock(uint256(keccak256(abi.encode(_masterFor(token), id))));
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function editions() external pure returns (address) {
        return address(0);
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function stream() external pure returns (address) {
        return address(0);
    }

    /// @inheritdoc IUniformEditionAuctionLens
    /// @dev A contract the federation registry serves (`IFederationRegistry.isActive`).
    function isTarget(address token) external view returns (bool) {
        return _served(token);
    }

    /// @inheritdoc IUniformEditionAuctionLens
    /// @dev The artist registry's current federation registry.
    function federationRegistry() public view returns (address) {
        return _artistRegistry.federationRegistry();
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function setFederationRegistry(address, address next) external pure {
        revert ISaleAdapter.TargetNotAllowed(next);
    }

    function _tokenOfSale(uint256 saleId) internal view override returns (address) {
        return address(
            uint160(
                IStorage(msg.sender).storageAt(uint256(keccak256(abi.encode(saleId, _SLOT_TOKENS))))
            )
        );
    }

    function _masterFor(address token) internal view override returns (address) {
        return IFederatedEditions(token).stream();
    }

    function _sells(address token) internal view override returns (bool) {
        return _served(token);
    }

    function _newTerms(address token, ISplitWallet.Payee[] memory payees)
        internal
        view
        override
        returns (WorkTerms memory)
    {
        return IFederatedEditions(token).previewTerms(payees);
    }

    function _factory(address token) internal view override returns (address ledger) {
        (, ledger,,,,) = IFederatedToken(token).federationTerms();
    }

    /// @dev A refusal reads as absent (so an abandonment is never blocked by the token); a
    ///      shortfall reverts.
    function _editionExists(address token, uint256 id) internal view override returns (bool) {
        (bool ok, bytes32 word) =
            BoundedCall.tryReadWordAll(token, abi.encodeCall(IFederatedEditions.exists, (id)));
        return ok && word != 0;
    }

    /// @dev Whether the current federation registry serves `token`.
    function _served(address token) private view returns (bool) {
        address registry = federationRegistry();
        return registry != address(0) && IFederationRegistry(registry).isActive(token);
    }
}

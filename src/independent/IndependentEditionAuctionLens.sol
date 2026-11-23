// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { ISplitFactory } from "../economics/interfaces/ISplitFactory.sol";
import { ISplitWallet } from "../economics/interfaces/ISplitWallet.sol";
import { Splits } from "../economics/Splits.sol";
import { Slots } from "../interfaces/core/CoreTypes.sol";
import { IEditions } from "../interfaces/core/IEditions.sol";
import { IIndependentStreamGate } from "../interfaces/core/IIndependentStreamGate.sol";
import { IModuleSlots } from "../interfaces/core/IModules.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "../interfaces/IEnglishAuction.sol";
import { IEnglishAuctionClock } from "../interfaces/IEnglishAuctionClock.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { IUniformEditionAuctionLens } from "../interfaces/IUniformEditionAuctionLens.sol";
import {
    IUniformEditionAuctionStorage as IStorage
} from "../interfaces/IUniformEditionAuctionStorage.sol";
import { PRODUCT_INDEPENDENT, WorkTerms } from "../interfaces/types/EconomicsTypes.sol";
import { PackageItem } from "../interfaces/types/PackageTypes.sol";
import { UniformEditionAuctionLensBase } from "../sales/UniformEditionAuctionLens.sol";

/// @notice The one view of the Independent Stream module this lens reads besides
///         `IIndependentStreamGate`: whether an Independent Stream contract is listed and served
///         (`IIndependentStreamRegistry.isActive`).
interface IIndependentStreamListing {
    /// @notice Whether `token` is a listed Independent Stream contract the Independent Stream
    ///         module serves.
    /// @param token The Independent Stream contract.
    /// @return True while it is served.
    function isActive(address token) external view returns (bool);
}

/// @title IndependentEditionAuctionLens
/// @notice The lens of {IndependentEditionAuction} (ADR 0008): {UniformEditionAuctionLensBase}'s
///         views and checks, plus the Independent Stream rules the adapter asks it for: which
///         contracts are served, the fee a sale locks, and the 1/1 clock a delisting cancels.
/// @dev Stateless; reads the calling adapter's storage (slot 13: each sale's edition contract)
///      and, for the Independent Stream module, the directory's INDEPENDENT_STREAM slot, read live.
///      The fee share a sale locks is the Independent Stream module's answer for the token
///      (`IIndependentStreamGate.feeShareOf`), never the token's own; the recipient is the
///      economics resolver's Independent Stream one. Every call out forwards all gas and reverts on
///      any failure. `editions` and `stream` answer zero (there is no single one).
contract IndependentEditionAuctionLens is UniformEditionAuctionLensBase {
    uint256 private constant _SLOT_TOKENS = 13;

    /// @param englishAuction_ The adapter's English auction.
    /// @param escrow_ The adapter's revenue escrow.
    /// @param directory_ The directory: its INDEPENDENT_STREAM module and its unclaimed period.
    /// @param economics_ The economics resolver: the Independent Stream network fee recipient and
    ///        the split factory.
    constructor(address englishAuction_, address escrow_, address directory_, address economics_)
        UniformEditionAuctionLensBase(englishAuction_, escrow_, directory_, economics_)
    { }

    /// @notice Edition `id`'s 1/1 clock (`IEnglishAuctionClock.auctionClock` of its master's
    ///         sale), or CANCELLED once the Independent Stream module no longer serves `token`.
    /// @param token The edition contract.
    /// @param id The edition ID (the master's token ID).
    /// @return The 1/1's state.
    /// @return Its end.
    /// @return When its dispute pause began, zero if none.
    /// @return When the 1/1 was last offered again (`IEnglishAuction.restart`), zero if never.
    function clock(address token, uint256 id)
        external
        view
        returns (IEnglishAuction.AuctionState, uint64, uint64, uint64)
    {
        if (!_served(token)) return (IEnglishAuction.AuctionState.CANCELLED, 0, 0, 0);
        return IEnglishAuctionClock(_englishAuction)
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
    /// @dev A contract the Independent Stream module serves (`isActive`).
    function isTarget(address token) external view returns (bool) {
        return _served(token);
    }

    /// @inheritdoc IUniformEditionAuctionLens
    /// @dev The directory's INDEPENDENT_STREAM module now.
    function independentStreamRegistry() public view returns (address) {
        return IModuleSlots(_directory).moduleOf(Slots.INDEPENDENT_STREAM);
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function setIndependentStreamRegistry(address, address next) external pure {
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
        return IEditions(token).stream();
    }

    /// @dev The 1/1 clock, CANCELLED once `token` is no longer served.
    function _clock(address token, uint256 id)
        internal
        view
        override
        returns (IEnglishAuction.AuctionState state, uint64 endTime, uint64 restartedAt)
    {
        if (!_served(token)) return (IEnglishAuction.AuctionState.CANCELLED, 0, 0);
        return super._clock(token, id);
    }

    /// @dev The Independent Stream module lets the calling adapter mint `token` now
    ///      (`IIndependentStreamGate.canMint`), so a suspended or delisted contract opens no sale.
    function _sells(address token) internal view override returns (bool) {
        address gate = independentStreamRegistry();
        return gate != address(0) && IIndependentStreamGate(gate).canMint(token, msg.sender);
    }

    /// @dev The seller's wallet for `payees`, the Independent Stream module's fee share for
    ///      `token`, the resolver's Independent Stream fee recipient, and the royalty receiver they
    ///      derive (the seller at a zero share). The royalty rate is not used here: the edition
    ///      takes the master's.
    function _newTerms(address token, ISplitWallet.Payee[] memory payees)
        internal
        view
        override
        returns (WorkTerms memory w)
    {
        ISplitFactory factory = ISplitFactory(_economics.splitFactory());
        w.seller = factory.walletFor(payees, bytes32(0));
        w.feeRecipient = _economics.networkFeeRecipient(PRODUCT_INDEPENDENT);
        w.feeShare = IIndependentStreamGate(independentStreamRegistry()).feeShareOf(token);
        w.royaltyReceiver = w.feeShare == 0
            ? w.seller
            : factory.walletFor(
                Splits.royaltyPayees(w.seller, w.feeRecipient, w.feeShare), bytes32(0)
            );
    }

    /// @dev `data` is `abi.encode(PackageItem)`: an Independent Stream item has no package to check
    ///      (the Independent Stream module's own item approval plays that part).
    function _item(address, uint256, bytes32, bytes calldata data)
        internal
        pure
        override
        returns (PackageItem memory)
    {
        return abi.decode(data, (PackageItem));
    }

    /// @dev The economics resolver and the Independent Stream product.
    function _feeSource() internal view override returns (IEconomicsResolver, bytes32) {
        return (_economics, PRODUCT_INDEPENDENT);
    }

    /// @dev Whether the current Independent Stream module serves `token` and its master contract: a
    ///      delisted master voids its edition's sale as it refunds its 1/1.
    function _served(address token) private view returns (bool) {
        address gate = independentStreamRegistry();
        return gate != address(0) && IIndependentStreamListing(gate).isActive(token)
            && IIndependentStreamListing(gate).isActive(IEditions(token).stream());
    }
}

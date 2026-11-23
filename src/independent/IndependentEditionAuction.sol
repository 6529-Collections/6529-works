// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IEditions } from "../interfaces/core/IEditions.sol";
import { IEnglishAuction } from "../interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { IUniformEditionAuction } from "../interfaces/IUniformEditionAuction.sol";
import { UniformEditionAuctionBase } from "../sales/UniformEditionAuction.sol";
import { IndependentEditionAuctionLens } from "./IndependentEditionAuctionLens.sol";

/// @title IndependentEditionAuction
/// @notice The uniform-price edition auction for Independent Stream pairs (ADR 0008; IND-53 to
///         IND-58 in `docs/spec/independent-stream.md`): {UniformEditionAuctionBase}'s rules and
///         code, deployed a second time, selling the editions of every pair the Independent Stream
///         module (the directory's INDEPENDENT_STREAM slot) serves. A replaceable network adapter.
/// @dev What differs from 6529 Stream Editions' deployment, with the Independent Stream logic in
///      its lens ({IndependentEditionAuctionLens}) so this contract keeps the shared code within
///      EIP-170: the edition contract is chosen per sale (recorded at open; it opens only while the
///      Independent Stream module lets this adapter mint it, and the Independent Stream Editions
///      contract asks the same module whether this adapter may create the edition); its master is
///      that contract's `stream()`; the network fee is the Independent Stream module's share for
///      the token, locked at open, paid to the economics resolver's Independent Stream recipient
///      read at settlement; a sale of a contract the module stops serving (delisted) reads its 1/1
///      as cancelled, so the sale voids with full refunds, and every bid and raise checks it is
///      still served (6529 Stream Editions' read only near the close would leave a delisted sale
///      taking bids until then), as does every settle call while the scan has paid nothing.
contract IndependentEditionAuction is UniformEditionAuctionBase {
    /// @dev Storage slot 13 (the lens reads it): each sale's edition contract.
    mapping(uint256 saleId => address) private _tokens;

    /// @param authority_ The AccessManager governing the setters and the pause.
    /// @param escrow_ The revenue escrow for refused payouts.
    /// @param directory_ The directory: its INDEPENDENT_STREAM module and its unclaimed period.
    /// @param englishAuction_ The English auction that sells the masters' 1/1s.
    /// @param lens_ The Independent Stream lens, deployed beforehand (code hash `lensCodeHash`).
    /// @param lensCodeHash The lens's reviewed code hash.
    /// @param config_ The initial governed parameters.
    /// @param limits_ The initial governed limit (the payout gas).
    constructor(
        address authority_,
        address escrow_,
        address directory_,
        address englishAuction_,
        address lens_,
        bytes32 lensCodeHash,
        IUniformEditionAuction.AuctionConfig memory config_,
        IUniformEditionAuction.Limits memory limits_
    )
        UniformEditionAuctionBase(
            authority_, escrow_, directory_, englishAuction_, lens_, lensCodeHash, config_, limits_
        )
    { }

    /// @inheritdoc UniformEditionAuctionBase
    /// @dev Refuses a sale whose contract the registry no longer serves (`BiddingClosed` with
    ///      end zero, the end the lens's clock gives it), whatever the time.
    function bid(uint256 saleId, uint256 step, uint256 quantity)
        public
        payable
        override
        returns (uint256)
    {
        _requireServed(saleId);
        return super.bid(saleId, step, quantity);
    }

    /// @inheritdoc UniformEditionAuctionBase
    /// @dev Refuses a sale whose contract the registry no longer serves, as `bid`.
    function raise(uint256 saleId, uint256 bidId, uint256 newStep) public payable override {
        _requireServed(saleId);
        super.raise(saleId, bidId, newStep);
    }

    /// @inheritdoc UniformEditionAuctionBase
    /// @dev A sale whose scan is still in progress has paid nothing (the clearing call pays), so
    ///      a later call re-checks the registry first: a contract delisted since the first call
    ///      voids the sale with full refunds, as the first call would have. Once the clearing
    ///      call has paid, the clearing stands.
    function settle(uint256 saleId, uint256[] calldata order) public override returns (bool) {
        SaleWord storage stored = _sales[saleId];
        if (
            stored.status == IUniformEditionAuction.AuctionStatus.SETTLING && _scans[saleId] != 0
                && !IndependentEditionAuctionLens(lens).isTarget(_tokens[saleId])
        ) {
            if (_reentrancyGuardEntered()) revert ReentrancyGuardReentrantCall();
            _void(saleId, stored);
            return true;
        }
        return super.settle(saleId, order);
    }

    /// @notice Lists nothing: the Independent Stream module decides (`TargetNotAllowed`).
    /// @param token Any token.
    function setTarget(address token, bool) external pure {
        revert ISaleAdapter.TargetNotAllowed(token);
    }

    /// @dev Records the sale's edition contract; the lens refuses one the Independent Stream module
    ///      does not let this adapter mint.
    function _checkTarget(address token, uint256 saleId, bool) internal override {
        _tokens[saleId] = token;
    }

    function _editionsOf(uint256 saleId) internal view override returns (address) {
        return _tokens[saleId];
    }

    function _masterOf(uint256 saleId) internal view override returns (address) {
        return IEditions(_tokens[saleId]).stream();
    }

    /// @dev Reverts with `BiddingClosed` for a recorded sale whose contract the Independent Stream
    ///      module no longer serves; an unknown sale is left to the shared state check.
    function _requireServed(uint256 saleId) private view {
        address token = _tokens[saleId];
        if (token != address(0) && !IndependentEditionAuctionLens(lens).isTarget(token)) {
            revert IUniformEditionAuction.BiddingClosed(saleId, 0);
        }
    }

    /// @dev The lens's `clock`: the 1/1's, or cancelled once the Independent Stream module stops
    ///      serving the sale's contract.
    function _liveClock(uint256 saleId)
        internal
        view
        override
        returns (IEnglishAuction.AuctionState, uint64, uint64)
    {
        return IndependentEditionAuctionLens(lens).clock(_tokens[saleId], _payouts[saleId].id);
    }
}

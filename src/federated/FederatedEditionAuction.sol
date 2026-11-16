// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEnglishAuction } from "../interfaces/IEnglishAuction.sol";
import { IFederatedEditions } from "../interfaces/IFederatedEditions.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { IUniformEditionAuction } from "../interfaces/IUniformEditionAuction.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";
import { UniformEditionAuctionBase } from "../sales/UniformEditionAuction.sol";
import { FederatedEditionAuctionLens } from "./FederatedEditionAuctionLens.sol";

/// @title FederatedEditionAuction
/// @notice The uniform-price edition auction for federated pairs (ADR 0008; FED-53 to FED-58 in
///         `docs/spec/federation.md`): {UniformEditionAuctionBase}'s rules and code, deployed a
///         second time, selling the editions of every pair the current federation registry (the
///         artist registry's pointer) serves. A replaceable network adapter.
/// @dev What differs from 6529 Stream Editions' deployment, with the federation logic in its lens
///      ({FederatedEditionAuctionLens}) so this contract keeps the shared code within EIP-170:
///      the edition contract is chosen per sale (recorded at open; it binds only adapters the
///      registry admits); its master is that contract's partner; the network fee is the registry
///      entry's share, paid to the economics resolver's federated recipient, both locked at
///      open, never what the token reports; a sale of a contract the registry stops serving
///      (delisted, its template revoked) reads its 1/1 as cancelled, so bidding closes and the
///      sale voids with full refunds; and an abandoned sale's seal at zero is best effort (a
///      refusal leaves the edition unsealed: this adapter never mints a void sale's copies).
contract FederatedEditionAuction is UniformEditionAuctionBase {
    /// @dev Storage slot 14 (the lens reads it): each sale's edition contract.
    mapping(uint256 saleId => address) private _tokens;

    /// @param authority_ The AccessManager governing the setters and the pause.
    /// @param escrow_ The revenue escrow for refused payouts.
    /// @param englishAuction_ The English auction that sells the masters' 1/1s.
    /// @param lens_ The federated lens, deployed beforehand (code hash `lensCodeHash`).
    /// @param lensCodeHash The lens's reviewed code hash.
    /// @param config_ The initial governed parameters.
    /// @param limits_ The initial governed limits.
    constructor(
        address authority_,
        address escrow_,
        address englishAuction_,
        address lens_,
        bytes32 lensCodeHash,
        IUniformEditionAuction.AuctionConfig memory config_,
        IUniformEditionAuction.Limits memory limits_
    )
        UniformEditionAuctionBase(
            authority_, escrow_, englishAuction_, lens_, lensCodeHash, config_, limits_
        )
    { }

    /// @notice Lists nothing: the federation registry decides (`TargetNotAllowed`).
    /// @param token Any token.
    function setTarget(address token, bool) external pure {
        revert ISaleAdapter.TargetNotAllowed(token);
    }

    /// @dev Records the sale's edition contract; the lens refuses one the registry does not
    ///      serve (`feeTerms`), and the contract binds only an admitted adapter.
    function _checkTarget(address token, uint256 saleId, bool) internal override {
        _tokens[saleId] = token;
    }

    function _editionsOf(uint256 saleId) internal view override returns (address) {
        return _tokens[saleId];
    }

    function _masterOf(uint256 saleId) internal view override returns (address) {
        return IFederatedEditions(_tokens[saleId]).stream();
    }

    /// @dev The lens's `feeTerms`: the registry entry's share and the resolver's federated
    ///      recipient, never the token's own answer.
    function _feeTerms(address token, address, uint256)
        internal
        view
        override
        returns (address, uint256)
    {
        return FederatedEditionAuctionLens(lens).feeTerms(token, _escrow);
    }

    /// @dev Best effort: all gas forwarded and no return data copied; a failure that left at most
    ///      1/8 of the gas held before is a shortfall and reverts (`BoundedCallShortfall`, the
    ///      shared rule written out to fit EIP-170); any other refusal leaves the edition
    ///      unsealed.
    function _sealVoid(uint256 saleId, uint256 id) internal override {
        address token = _tokens[saleId];
        bytes4 selector = IFederatedEditions.sealSupply.selector;
        uint256 before = gasleft();
        bool ok;
        // `sealSupply(id, 0)`, built past the free memory pointer without moving it.
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, selector)
            mstore(add(p, 4), id)
            mstore(add(p, 0x24), 0)
            ok := call(gas(), token, 0, p, 0x44, 0, 0)
        }
        if (!ok && gasleft() <= before / BoundedCall.SHORTFALL_DIVISOR) {
            revert BoundedCall.BoundedCallShortfall(token);
        }
    }

    /// @dev A federated 1/1 has no rescue (no museum path): nothing added, so `abandon` waits
    ///      the locked delay alone; no 6529 Stream slot is read for a federated sale.
    function _rescueLengthening(uint256) internal pure override returns (uint256) {
        return 0;
    }

    /// @dev The lens's `clock`: the 1/1's, or cancelled once the registry stops serving the
    ///      sale's contract.
    function _oneOfOneClock(uint256 saleId)
        internal
        view
        override
        returns (IEnglishAuction.AuctionState, uint64, uint64)
    {
        return FederatedEditionAuctionLens(lens).clock(_tokens[saleId], _payouts[saleId].id);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { StreamBase } from "../core/StreamBase.sol";
import { IFederatedMembership } from "../interfaces/IFederatedMembership.sol";
import { IFederatedStream } from "../interfaces/IFederatedStream.sol";
import { PendingModule, Slots } from "../interfaces/core/CoreTypes.sol";
import { IModuleSlots } from "../interfaces/core/IModules.sol";
import { IStream } from "../interfaces/core/IStream.sol";
import { FederatedMembership } from "./FederatedMembership.sol";

/// @title FederatedStream
/// @notice A federated artist's own ERC-721 of 1/1s: the same plain permanent token as 6529
///         Stream (`StreamBase`) with a different gate (ADR 0010). Permanent once deployed: a
///         full contract, never behind a proxy or a clone.
/// @dev What differs from 6529 Stream, all through the hooks of `StreamBase`:
///      - Minters: whoever the federation module the directory names says may mint for this
///        token (`IFederationGate.canMint`). A delisted artist's token stops minting at once; an
///        empty FEDERATION slot stops minting and nothing else.
///      - Finishing a sale: an account that minted here (`hasMinted`) records the outcome of, or
///        burns, a token it still holds with no outcome, whatever the federation module says
///        later. A hostile federation module can therefore mint junk into this token, but it can
///        never move, burn or re-record a token another account holds or one that is sold.
///      - Rescue: the network moves a token that an account which minted here still holds with no
///        outcome, once `rescueDelay` (the network's setting) has passed since the federation
///        module removed that account.
///      - Modules: TERMS and RECORDS are the directory's shared `FEDERATED_TERMS` and
///        `FEDERATED_RECORDS`; RENDERER is this token's own slot, administered by the artist, with
///        the waiting period `moduleDelay` (the network's setting, 7 days at deployment).
///      - Admin: any wallet of the artist's account (the collection page and the renderer).
///      - Network: whoever the directory's AccessManager lets call the same function on the
///        directory at once (`rescue`, `setRescueDelay`, `setModuleDelay`).
///      One collection, created at deployment and named by the token. No records, items,
///      locators, vaults or custody live here: records are in the shared `WorkFacts`, the rules in
///      the shared modules, and an unsold work stays in the network's sale contract.
contract FederatedStream is StreamBase, FederatedMembership, IFederatedStream {
    /// @inheritdoc IModuleSlots
    uint48 public moduleDelay = 7 days;
    /// @inheritdoc IFederatedStream
    mapping(address account => bool) public hasMinted;

    address private _renderer;
    PendingModule private _pendingRenderer;

    /// @param name_ The ERC-721 name, also the one collection's name.
    /// @param symbol_ The ERC-721 symbol.
    /// @param facts_ The permanent record contract (`IWorkFacts`), nonzero.
    /// @param directory_ The permanent directory, nonzero.
    /// @param artistId_ The artist, nonzero and at most 160 bits.
    /// @param owner_ The first marketplace owner.
    /// @param renderer_ The first RENDERER module (zero for none), installed at once.
    constructor(
        string memory name_,
        string memory symbol_,
        address facts_,
        address directory_,
        uint256 artistId_,
        address owner_,
        address renderer_
    ) StreamBase(name_, symbol_, facts_, owner_) FederatedMembership(directory_, artistId_) {
        if (facts_ == address(0)) revert InvalidConfig();
        _createCollection(name_, bytes32(0));
        if (renderer_ != address(0)) _setRenderer(renderer_);
    }

    // ------------------------------------------------------------------------- module slots

    /// @inheritdoc IModuleSlots
    function moduleOf(bytes32 slot) public view returns (address) {
        return slot == Slots.RENDERER ? _renderer : _sharedModule(slot);
    }

    /// @inheritdoc IModuleSlots
    function pendingModule(bytes32 slot) external view returns (PendingModule memory p) {
        if (slot == Slots.RENDERER) p = _pendingRenderer;
    }

    /// @inheritdoc IModuleSlots
    /// @dev The network, not the artist: the wait protects the token's collectors.
    function setModuleDelay(uint48 next) external {
        _requireNetwork();
        emit ModuleDelaySet(moduleDelay, next);
        moduleDelay = next;
    }

    /// @inheritdoc IModuleSlots
    /// @dev Any wallet of the artist's account; RENDERER only (`NotLocalSlot`).
    function proposeModule(bytes32 slot, address module) external {
        _requireArtist();
        _requireLocal(slot);
        if (module.code.length == 0) revert InvalidModule(module);
        uint48 readyAt = uint48(block.timestamp) + moduleDelay;
        _pendingRenderer = PendingModule(module, readyAt);
        emit ModuleProposed(slot, module, readyAt);
    }

    /// @inheritdoc IModuleSlots
    function activateModule(bytes32 slot) external {
        _requireLocal(slot);
        PendingModule memory p = _pendingRenderer;
        if (p.readyAt == 0 || block.timestamp < p.readyAt) revert ModuleNotReady(slot);
        delete _pendingRenderer;
        _setRenderer(p.module);
    }

    /// @inheritdoc IModuleSlots
    /// @dev Any wallet of the artist's account; RENDERER only (`NotLocalSlot`).
    function removeModule(bytes32 slot) external {
        _requireArtist();
        _requireLocal(slot);
        delete _pendingRenderer;
        _setRenderer(address(0));
    }

    /// @inheritdoc IFederatedMembership
    function isMinter(address account) external view returns (bool) {
        return _gateCanMint(account);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IModuleSlots).interfaceId
            || interfaceId == type(IFederatedStream).interfaceId
            || interfaceId == type(IFederatedMembership).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // ------------------------------------------------------------------------------ internal

    /// @dev Records the minter of every new token (`hasMinted`); transfers and burns are
    ///      OpenZeppelin's, unchanged.
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address from)
    {
        from = super._update(to, tokenId, auth);
        if (from == address(0) && !hasMinted[msg.sender]) hasMinted[msg.sender] = true;
    }

    function _requireLocal(bytes32 slot) private pure {
        if (slot != Slots.RENDERER) revert NotLocalSlot(slot);
    }

    function _setRenderer(address module) private {
        emit ModuleSet(Slots.RENDERER, _renderer, module);
        _renderer = module;
    }

    // ------------------------------------------------------------------------------- hooks

    function _moduleOf(bytes32 slot) internal view override returns (address) {
        return moduleOf(slot);
    }

    function _isMinter(address account) internal view override returns (bool) {
        return _gateCanMint(account);
    }

    function _wasMinter(address account) internal view override returns (bool) {
        return hasMinted[account];
    }

    function _minterRemovedAt(address account) internal view override returns (uint256) {
        return hasMinted[account] ? _gateRemovedAt(account) : 0;
    }

    /// @dev The artist; `createCollection` is refused for everyone (one collection).
    function _checkAdmin() internal view override {
        if (msg.sig == IStream.createCollection.selector) revert OneCollection();
        _requireArtist();
    }

    function _checkNetwork() internal view override {
        _requireNetwork();
    }
}

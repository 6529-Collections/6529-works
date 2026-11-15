// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitFactory } from "../economics/interfaces/ISplitFactory.sol";
import { ISplitWallet } from "../economics/interfaces/ISplitWallet.sol";
import { Splits } from "../economics/Splits.sol";
import { IArtistRegistry } from "../interfaces/IArtistRegistry.sol";
import { IFederatedToken } from "../interfaces/IFederatedToken.sol";
import { IFederationRegistry } from "../interfaces/IFederationRegistry.sol";
import { Dependency } from "../libraries/Dependency.sol";

/// @title FederatedMembership
/// @notice What both federated templates share: the locked terms, the artist's authority,
///         joining and leaving the federation, minter admission and marketplace metadata
///         (FED-1 to FED-9 in `docs/spec/federation.md`).
/// @dev Source shared by inheritance, never deployed logic. No immutables: every value is in
///      storage, so each template version has one runtime code hash. Every call out is a plain
///      call, which forwards all the gas EIP-150 allows and reverts the whole transaction on any
///      failure, so no shortfall is ever read as an answer.
abstract contract FederatedMembership is IFederatedToken {
    uint8 private constant JOINED = 1;
    uint8 private constant LEFT = 2;

    /// @dev The canonical artist registry; its active authority acts for the artist.
    address internal _artistRegistry;
    /// @dev The canonical split ledger: every payout vault's factory.
    address internal _splitLedger;
    /// @dev Slot: the artist, the network share and the federation state (JOINED, LEFT bits).
    uint160 internal _artistId;
    uint32 internal _feeShare;
    uint8 private _state;
    address internal _feeRecipient;
    address internal _partner;
    address private _owner;
    string private _contractURI;
    /// @dev After the exit only: the minters the artist admitted.
    mapping(address adapter => bool) private _minters;

    /// @param artistRegistry_ The artist registry (code, not EIP-7702 delegated).
    /// @param splitLedger_ The split ledger (likewise).
    /// @param artistId_ The artist, nonzero and below 2^160.
    /// @param feeShare_ The network share, below 100,000.
    /// @param feeRecipient_ The network fee recipient, nonzero with a nonzero share.
    /// @param partner_ The other half of a pair, or zero.
    /// @param owner_ The marketplace owner.
    constructor(
        address artistRegistry_,
        address splitLedger_,
        uint256 artistId_,
        uint32 feeShare_,
        address feeRecipient_,
        address partner_,
        address owner_
    ) {
        if (
            artistId_ == 0 || artistId_ > type(uint160).max || feeShare_ >= Splits.DENOMINATOR
                || (feeShare_ != 0 && feeRecipient_ == address(0))
        ) revert InvalidConfig();
        Dependency.check(artistRegistry_);
        Dependency.check(splitLedger_);
        _artistRegistry = artistRegistry_;
        _splitLedger = splitLedger_;
        // Checked above: below 2^160.
        // forge-lint: disable-next-line(unsafe-typecast)
        _artistId = uint160(artistId_);
        _feeShare = feeShare_;
        _feeRecipient = feeRecipient_;
        _partner = partner_;
        _owner = owner_;
        emit FederationTermsLocked(
            artistId_, artistRegistry_, splitLedger_, feeShare_, feeRecipient_, partner_
        );
        emit OwnershipTransferred(address(0), owner_);
    }

    // ------------------------------------------------------------------ the federation

    /// @inheritdoc IFederatedToken
    function joinFederation(
        bytes32 profileId,
        bytes32 profileDocHash,
        uint64 deadline,
        bytes calldata signature
    ) external {
        _onlyArtist();
        IArtistRegistry ar = IArtistRegistry(_artistRegistry);
        (, IArtistRegistry.FederationStatus before) = ar.federatedListing(address(this));
        if (_state != 0 || before != IArtistRegistry.FederationStatus.NONE) {
            revert FederationStateInvalid();
        }
        address registry = ar.federationRegistry();
        IFederationRegistry(registry).register(profileId, profileDocHash, deadline, signature);
        (uint256 listedAs, IArtistRegistry.FederationStatus status) =
            ar.federatedListing(address(this));
        if (listedAs != _artistId || status != IArtistRegistry.FederationStatus.ACTIVE) {
            revert FederationStateInvalid();
        }
        _state = JOINED;
        emit FederationJoined(_artistId, registry, _feeShare, _feeRecipient, _partner);
    }

    /// @inheritdoc IFederatedToken
    function leaveFederation() external {
        _onlyArtist();
        uint8 state = _state;
        if (state & LEFT != 0) revert FederationStateInvalid();
        _state = state | LEFT;
        emit FederationLeft();
        if (state & JOINED != 0) IArtistRegistry(_artistRegistry).recordFederationExit();
    }

    /// @notice After the exit, the artist admits or removes a minter (`MinterSet`); before it
    ///         the federation registry decides (`FederationStateInvalid`).
    /// @param adapter The minter.
    /// @param admitted Whether it may mint.
    function setAdmittedMinter(address adapter, bool admitted) external {
        _onlyArtist();
        if (_state & LEFT == 0) revert FederationStateInvalid();
        _minters[adapter] = admitted;
        emit MinterSet(adapter, admitted);
    }

    /// @notice Whether `adapter` may mint now (see `IFederatedToken`).
    /// @param adapter The sale adapter.
    /// @return True while it may mint.
    function isAdmittedMinter(address adapter) public view returns (bool) {
        uint8 state = _state;
        if (state & LEFT != 0) return _minters[adapter];
        if (state == 0) return false;
        return IFederationRegistry(IArtistRegistry(_artistRegistry).federationRegistry())
            .canMint(address(this), adapter);
    }

    /// @inheritdoc IFederatedToken
    function federationTerms()
        external
        view
        returns (address, address, uint256, uint32, address, address)
    {
        return (_artistRegistry, _splitLedger, _artistId, _feeShare, _feeRecipient, _partner);
    }

    /// @inheritdoc IFederatedToken
    function federationState() external view returns (bool joined, bool left) {
        return (_state & JOINED != 0, _state & LEFT != 0);
    }

    // ------------------------------------------------------------------ metadata

    /// @inheritdoc IFederatedToken
    function setContractURI(string calldata uri) external {
        _onlyArtist();
        _contractURI = uri;
        emit ContractURIUpdated();
    }

    /// @inheritdoc IFederatedToken
    function setOwner(address next) external {
        _onlyArtist();
        emit OwnershipTransferred(_owner, next);
        _owner = next;
    }

    /// @inheritdoc IFederatedToken
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @inheritdoc IFederatedToken
    function owner() external view returns (address) {
        return _owner;
    }

    // ------------------------------------------------------------------ internal

    /// @dev Reverts unless the caller acts for the artist: the artist registry's active
    ///      authority of `_artistId` (zero, so nobody, while a recovery override is pending), or,
    ///      before the artist has an identity, the account whose address is the artist ID.
    function _onlyArtist() internal view {
        IArtistRegistry ar = IArtistRegistry(_artistRegistry);
        uint256 id = _artistId;
        address account = address(uint160(id));
        address authority = ar.artistIdOf(account) == id ? ar.activeAuthorityOf(id) : account;
        if (msg.sender != authority || authority == address(0)) revert NotArtist(msg.sender);
    }

    /// @dev Reverts unless the caller may mint now.
    function _onlyMinter() internal view {
        if (!isAdmittedMinter(msg.sender)) revert NotAdmittedMinter(msg.sender);
    }

    /// @dev Whether the contract has left the federation.
    function _left() internal view returns (bool) {
        return _state & LEFT != 0;
    }

    /// @dev Whether the contract ever joined or left (its terms and partner are then final).
    function _settled() internal view returns (bool) {
        return _state != 0;
    }

    /// @dev The network's fee terms for a sale or work started now: the locked ones, or none
    ///      after the exit.
    function _feeTerms() internal view returns (address, uint32) {
        return _left() ? (address(0), 0) : (_feeRecipient, _feeShare);
    }

    /// @dev Deploys (or finds) the split ledger's salt-zero vault of `payees`.
    function _vault(ISplitWallet.Payee[] memory payees) internal returns (address) {
        return ISplitFactory(_splitLedger).createWallet(payees, bytes32(0));
    }

    /// @dev The vault that receives the royalties of a work sold by `seller` while listed:
    ///      `seller` takes the artist share and the locked fee recipient the network share.
    function _royaltyVault(address seller) internal view returns (address) {
        return ISplitFactory(_splitLedger)
            .walletFor(Splits.royaltyPayees(seller, _feeRecipient, _feeShare), bytes32(0));
    }
}

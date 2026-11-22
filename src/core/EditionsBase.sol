// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IRenderer } from "../interfaces/IRenderer.sol";
import { Core, Edition, Slots } from "../interfaces/core/CoreTypes.sol";
import { IEditions } from "../interfaces/core/IEditions.sol";
import { IModules, IModuleSlots } from "../interfaces/core/IModules.sol";
import { IStream } from "../interfaces/core/IStream.sol";

/// @title EditionsBase
/// @notice The plain permanent ERC-1155 of editions (ADR 0010): who owns each copy, and each
///         edition's supply. Shared by 6529 Stream Editions (`Editions`) and each federated
///         artist's editions (`FederatedEditions`), which differ only in the hooks at the end.
/// @dev What this contract guarantees, whatever its modules and minters do:
///      - an edition is created once, by an active minter, for a master that exists and is not
///        burned, and that minter becomes its only minter;
///      - only the edition's own minter mints it, and copies minted never pass the maximum;
///      - the supply is sealed once, between the copies minted and the maximum, and a sealed
///        maximum never grows; burned copies still count toward it;
///      - a removed minter can still seal its editions and then mint up to the seal, so the
///        winners of its sales are never stranded; it mints nothing it has not sealed;
///      - the minter of an edition changes only by `rebind`: the network moves an edition with no
///        copies and no seal to another active minter, once `rebindDelay` (the network's setting,
///        read when the rebind is attempted) has passed since its minter's removal;
///      - transfers, approvals and balances are OpenZeppelin's, untouched: no module or minter
///        can move or burn a copy, and no call leaves this contract during a transfer except
///        the standard ERC-1155 acceptance check of the receiver;
///      - `royaltyInfo` reads this contract's storage only.
///      Every state change emits an event from which the state can be rebuilt.
abstract contract EditionsBase is ERC1155, IEditions {
    /// @inheritdoc IEditions
    uint48 public rebindDelay = 14 days;

    /// @inheritdoc IEditions
    address public immutable stream;
    /// @inheritdoc IEditions
    address public owner;
    /// @inheritdoc IEditions
    string public contractURI;
    mapping(uint256 editionId => Edition) private _editions;

    /// @param stream_ The ERC-721 of masters.
    /// @param owner_ The first marketplace owner.
    constructor(address stream_, address owner_) ERC1155("") {
        stream = stream_;
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
        emit RebindDelaySet(0, rebindDelay);
    }

    /// @inheritdoc IEditions
    /// @dev A cap of zero stores the largest maximum (`type(uint40).max`): no cap until the
    ///      seal. The rate is at most 100,000, and a nonzero rate needs a nonzero receiver.
    function create(
        uint256 editionId,
        uint40 maxSupply,
        address royaltyReceiver,
        uint24 royaltyRate
    ) external {
        if (!_isMinter(msg.sender)) revert IModules.NotMinter(msg.sender);
        // Reverts unless the master exists and is not burned.
        IERC721(stream).ownerOf(editionId);
        Edition storage e = _editions[editionId];
        if (e.minter != address(0)) revert EditionExists(editionId);
        if (royaltyRate > Core.DENOMINATOR || (royaltyReceiver == address(0) && royaltyRate != 0)) {
            revert InvalidRoyalty();
        }
        uint40 max = maxSupply == 0 ? type(uint40).max : maxSupply;
        e.minter = msg.sender;
        e.maxSupply = max;
        e.royaltyReceiver = royaltyReceiver;
        e.royaltyRate = royaltyRate;
        emit EditionCreated(editionId, msg.sender, max, royaltyReceiver, royaltyRate);
    }

    /// @inheritdoc IEditions
    /// @dev The supply is written and logged before the ERC-1155 acceptance check, so a
    ///      receiver that re-enters sees the new count; a receiver that refuses fails only its
    ///      own mint.
    function mint(address to, uint256 editionId, uint256 amount, uint256 unitPrice) external {
        Edition storage e = _editions[editionId];
        if (e.minter != msg.sender || !(e.supplySealed || _isMinter(msg.sender))) {
            revert NotEditionMinter(editionId, msg.sender);
        }
        if (amount > e.maxSupply - e.minted) revert SupplyExceeded(editionId);
        // Checked above: at most `maxSupply - minted`, which fits 40 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        e.minted += uint40(amount);
        emit EditionMinted(editionId, to, amount, unitPrice);
        _mint(to, editionId, amount, "");
    }

    /// @inheritdoc IEditions
    function seal(uint256 editionId, uint40 supply) external {
        Edition storage e = _editions[editionId];
        if (e.minter != msg.sender || msg.sender == address(0)) {
            revert NotEditionMinter(editionId, msg.sender);
        }
        if (e.supplySealed || supply < e.minted || supply > e.maxSupply) {
            revert InvalidSeal(editionId);
        }
        e.maxSupply = supply;
        e.supplySealed = true;
        emit EditionSupplySealed(editionId, supply);
    }

    /// @inheritdoc IEditions
    /// @dev The wait in force when the rebind is attempted decides, counted from the removal.
    ///      A minter added again after its removal is no longer removed, so its editions cannot
    ///      be rebound.
    function rebind(uint256 editionId, address minter) external {
        _checkNetwork();
        Edition storage e = _editions[editionId];
        address previous = e.minter;
        uint256 removedAt = _minterRemovedAt(previous);
        if (
            previous == address(0) || e.supplySealed || e.minted != 0 || removedAt == 0
                || block.timestamp < removedAt + rebindDelay || !_isMinter(minter)
        ) revert NotRebindable(editionId);
        e.minter = minter;
        emit EditionRebound(editionId, previous, minter);
    }

    /// @inheritdoc IEditions
    function setRebindDelay(uint48 next) external {
        _checkNetwork();
        emit RebindDelaySet(rebindDelay, next);
        rebindDelay = next;
    }

    /// @inheritdoc IEditions
    function burn(uint256 editionId, uint256 amount) external {
        _burn(msg.sender, editionId, amount);
    }

    /// @inheritdoc IEditions
    function setRoyalty(uint256 editionId, address receiver, uint24 rate) external {
        if (msg.sender != _moduleOf(Slots.TERMS) || msg.sender == address(0)) {
            revert IModuleSlots.NotModule(Slots.TERMS, msg.sender);
        }
        Edition storage e = _editions[editionId];
        if (e.minter == address(0)) revert UnknownEdition(editionId);
        if (rate > Core.DENOMINATOR || (receiver == address(0) && rate != 0)) {
            revert InvalidRoyalty();
        }
        e.royaltyReceiver = receiver;
        e.royaltyRate = rate;
        emit RoyaltySet(editionId, receiver, rate);
    }

    /// @inheritdoc IEditions
    function emitMetadataUpdate(uint256 fromEditionId, uint256 toEditionId) external {
        if (
            msg.sender != _moduleOf(Slots.TERMS)
                && msg.sender != IModuleSlots(stream).moduleOf(Slots.RECORDS)
        ) revert NotMetadataSource(msg.sender);
        if (fromEditionId == toEditionId) emit MetadataUpdate(fromEditionId);
        else emit BatchMetadataUpdate(fromEditionId, toEditionId);
    }

    /// @inheritdoc IEditions
    function setOwner(address next) external {
        _checkAdmin();
        emit OwnershipTransferred(owner, next);
        owner = next;
    }

    /// @inheritdoc IEditions
    function setContractURI(string calldata uri_) external {
        _checkAdmin();
        contractURI = uri_;
        emit ContractURISet(uri_);
        emit ContractURIUpdated();
    }

    /// @inheritdoc IEditions
    function editionOf(uint256 editionId) external view returns (Edition memory) {
        return _editions[editionId];
    }

    /// @inheritdoc IERC2981
    /// @dev This contract's storage only: no module is asked. Exact for any price: the product
    ///      is taken in full precision before the division. An edition that does not exist
    ///      answers zero and the zero address.
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount)
    {
        Edition storage e = _editions[tokenId];
        return (e.royaltyReceiver, Math.mulDiv(salePrice, e.royaltyRate, Core.DENOMINATOR));
    }

    /// @notice The edition's metadata, drawn by its master's renderer (`IStream.rendererOf`).
    /// @dev Reverts if the edition does not exist, or if the master's renderer is missing or
    ///      fails; it never falls back to another renderer.
    /// @param editionId An existing edition.
    /// @return The metadata URI.
    function uri(uint256 editionId) public view override returns (string memory) {
        if (_editions[editionId].minter == address(0)) revert UnknownEdition(editionId);
        return IRenderer(IStream(stream).rendererOf(editionId)).tokenURI(address(this), editionId);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC1155, IERC165)
        returns (bool)
    {
        return interfaceId == type(IERC2981).interfaceId || interfaceId == bytes4(0x49064906)
            || interfaceId == type(IEditions).interfaceId || super.supportsInterface(interfaceId);
    }

    // --------------------------------------------------------------------- hooks (frozen)

    /// @dev The module installed in `slot` for this contract, or zero.
    function _moduleOf(bytes32 slot) internal view virtual returns (address);

    /// @dev Whether `account` may mint now.
    function _isMinter(address account) internal view virtual returns (bool);

    /// @dev When `account` was removed as a minter, or zero.
    function _minterRemovedAt(address account) internal view virtual returns (uint256);

    /// @dev Reverts unless the caller is the contract's admin (owner, contract URI).
    function _checkAdmin() internal virtual;

    /// @dev Reverts unless the caller is the network (`rebind`, `setRebindDelay`).
    function _checkNetwork() internal virtual;
}

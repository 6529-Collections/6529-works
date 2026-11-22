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
/// @dev lane 2 completes this (tests, NatSpec, review). The hooks' signatures are frozen: lane
///      5 builds `FederatedEditions` on them and must not edit this file.
///      Guarantees: an edition is created once, for a live master; only its own minter mints
///      it; copies minted never pass the maximum; the seal happens once; a sealed maximum never
///      grows; burned copies still count. Transfers are OpenZeppelin's, untouched.
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
    }

    /// @inheritdoc IEditions
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
        if (royaltyRate > Core.DENOMINATOR) revert InvalidRoyalty();
        uint40 max = maxSupply == 0 ? type(uint40).max : maxSupply;
        e.minter = msg.sender;
        e.maxSupply = max;
        e.royaltyReceiver = royaltyReceiver;
        e.royaltyRate = royaltyRate;
        emit EditionCreated(editionId, msg.sender, max, royaltyReceiver, royaltyRate);
    }

    /// @inheritdoc IEditions
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
            revert InvalidRoyalty();
        }
        Edition storage e = _editions[editionId];
        if (e.minter == address(0)) revert UnknownEdition(editionId);
        if (rate > Core.DENOMINATOR) revert InvalidRoyalty();
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
        emit ContractURIUpdated();
    }

    /// @inheritdoc IEditions
    function editionOf(uint256 editionId) external view returns (Edition memory) {
        return _editions[editionId];
    }

    /// @inheritdoc IERC2981
    /// @dev This contract's storage only: no module is asked.
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount)
    {
        Edition storage e = _editions[tokenId];
        return (e.royaltyReceiver, Math.mulDiv(salePrice, e.royaltyRate, Core.DENOMINATOR));
    }

    /// @notice The edition's metadata, drawn by its master's renderer (`IStream.rendererOf`).
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

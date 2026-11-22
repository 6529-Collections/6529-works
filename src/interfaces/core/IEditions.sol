// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { Edition } from "./CoreTypes.sol";

/// @title IEditions
/// @notice A permanent ERC-1155 of editions: 6529 Stream Editions, and each federated artist's
///         own. It holds who owns each copy and each edition's supply. An edition's ID is its
///         master's token ID in `stream()`.
/// @dev The seam (ADR 0010). A minter creates the edition of an existing master and becomes
///      its only minter; it mints within the maximum and seals the supply once. A sealed maximum
///      never grows. The TERMS module sets royalties. No module can move a copy.
interface IEditions is IERC1155, IERC2981 {
    /// @notice An edition was created.
    /// @param editionId The edition (its master's token ID).
    /// @param minter Its one minter.
    /// @param maxSupply The maximum until the seal (`type(uint40).max`: no cap).
    /// @param royaltyReceiver The royalty receiver; nonzero unless the rate is zero.
    /// @param royaltyRate The royalty rate, out of 100,000.
    event EditionCreated(
        uint256 indexed editionId,
        address indexed minter,
        uint40 maxSupply,
        address royaltyReceiver,
        uint24 royaltyRate
    );
    /// @notice Copies were minted in a primary sale.
    /// @param editionId The edition.
    /// @param to The buyer.
    /// @param amount The copies.
    /// @param unitPrice The price per copy in wei, as the minter reports it.
    event EditionMinted(
        uint256 indexed editionId, address indexed to, uint256 amount, uint256 unitPrice
    );
    /// @notice The edition's supply was fixed for good.
    /// @param editionId The edition.
    /// @param supply The final maximum.
    event EditionSupplySealed(uint256 indexed editionId, uint256 supply);
    /// @notice The network moved an edition with no copies and no seal to another minter.
    /// @param editionId The edition.
    /// @param previous The removed minter.
    /// @param minter The new minter.
    event EditionRebound(
        uint256 indexed editionId, address indexed previous, address indexed minter
    );
    /// @notice An edition's royalty receiver or rate was set by the TERMS module.
    /// @param editionId The edition.
    /// @param receiver The receiver now.
    /// @param rate The rate now.
    event RoyaltySet(uint256 indexed editionId, address receiver, uint24 rate);
    /// @notice ERC-4906: an edition's metadata changed.
    /// @param _tokenId The edition.
    event MetadataUpdate(uint256 _tokenId);
    /// @notice ERC-4906: a range of editions' metadata changed.
    /// @param _fromTokenId The first.
    /// @param _toTokenId The last.
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    /// @notice The marketplace owner changed.
    /// @param previousOwner The owner before.
    /// @param newOwner The owner now.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @notice ERC-7572: the contract-level metadata changed.
    event ContractURIUpdated();
    /// @notice The contract-level metadata URI was set; carries the value, which ERC-7572's
    ///         `ContractURIUpdated` does not, so the URI can be rebuilt from logs alone.
    /// @param uri The URI now.
    event ContractURISet(string uri);
    /// @notice The wait before a rebind was set: by the network, or at deployment with its
    ///         launch value (`previous` zero).
    /// @param previous The wait before.
    /// @param next The wait now.
    event RebindDelaySet(uint48 previous, uint48 next);

    /// @notice The edition already exists.
    error EditionExists(uint256 editionId);
    /// @notice The edition does not exist.
    error UnknownEdition(uint256 editionId);
    /// @notice The caller is not the edition's minter, or was removed before sealing it.
    error NotEditionMinter(uint256 editionId, address caller);
    /// @notice The mint would pass the maximum.
    error SupplyExceeded(uint256 editionId);
    /// @notice The edition is sealed, or the seal is below the count minted or above the maximum.
    error InvalidSeal(uint256 editionId);
    /// @notice The edition has copies or a seal, its minter is not removed for `rebindDelay`,
    ///         or the new minter is not active.
    error NotRebindable(uint256 editionId);
    /// @notice The rate is over 100,000, or nonzero with a zero receiver.
    error InvalidRoyalty();
    /// @notice The caller may not emit metadata updates.
    error NotMetadataSource(address caller);

    /// @notice How long after a minter's removal the network may rebind its unminted, unsealed
    ///         editions. A setting of the network, 14 days at deployment; not a fixed promise.
    ///         Read when a rebind is attempted.
    /// @return The wait, in seconds.
    function rebindDelay() external view returns (uint48);

    /// @notice Sets `rebindDelay`, at once. The network only. Zero is allowed.
    /// @param next The new wait, in seconds.
    function setRebindDelay(uint48 next) external;

    /// @notice The ERC-721 of masters (`IStream`).
    /// @return The master token contract.
    function stream() external view returns (address);

    /// @notice Creates the edition of an existing, live master. An active minter only; it
    ///         becomes the edition's only minter.
    /// @param editionId The master's token ID.
    /// @param maxSupply The creator's cap, or zero for none until the seal.
    /// @param royaltyReceiver The royalty receiver.
    /// @param royaltyRate The royalty rate, out of 100,000.
    function create(
        uint256 editionId,
        uint40 maxSupply,
        address royaltyReceiver,
        uint24 royaltyRate
    ) external;

    /// @notice Mints copies within the maximum. The edition's minter only; a removed minter
    ///         mints only an edition it has sealed.
    /// @param to The buyer.
    /// @param editionId The edition.
    /// @param amount The copies.
    /// @param unitPrice The price per copy in wei (logged).
    function mint(address to, uint256 editionId, uint256 amount, uint256 unitPrice) external;

    /// @notice Fixes the supply, once, between the count minted and the maximum. The edition's
    ///         minter only, removed or not.
    /// @param editionId The edition.
    /// @param supply The final maximum.
    function seal(uint256 editionId, uint40 supply) external;

    /// @notice Moves an edition with no copies and no seal to another active minter,
    ///         `rebindDelay` after its own minter was removed. The network only.
    /// @param editionId The edition.
    /// @param minter The new minter.
    function rebind(uint256 editionId, address minter) external;

    /// @notice Burns the caller's own copies. They still count toward the maximum.
    /// @param editionId The edition.
    /// @param amount The copies.
    function burn(uint256 editionId, uint256 amount) external;

    /// @notice Sets an edition's royalty receiver and rate. The TERMS module only. A nonzero
    ///         rate needs a nonzero receiver.
    /// @param editionId An existing edition.
    /// @param receiver The receiver.
    /// @param rate The rate, out of 100,000.
    function setRoyalty(uint256 editionId, address receiver, uint24 rate) external;

    /// @notice Emits ERC-4906 for an edition or a range. Only the TERMS module and the master
    ///         token's RECORDS module.
    /// @param fromEditionId The first edition.
    /// @param toEditionId The last (equal to the first for one).
    function emitMetadataUpdate(uint256 fromEditionId, uint256 toEditionId) external;

    /// @notice Sets the marketplace owner. The contract's admin only.
    /// @param next The new owner.
    function setOwner(address next) external;

    /// @notice Sets the contract-level metadata URI. The contract's admin only.
    /// @param uri The URI.
    function setContractURI(string calldata uri) external;

    /// @notice An edition (empty, with a zero minter, if it does not exist).
    /// @param editionId The edition.
    /// @return The edition.
    function editionOf(uint256 editionId) external view returns (Edition memory);

    /// @notice The marketplace owner.
    /// @return The owner.
    function owner() external view returns (address);

    /// @notice ERC-7572 contract-level metadata URI.
    /// @return The URI.
    function contractURI() external view returns (string memory);
}

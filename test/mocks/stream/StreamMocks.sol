// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEntropyModule } from "src/interfaces/IEntropyModule.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IRenderer } from "src/interfaces/IRenderer.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { CURRENCY_DEFAULT, Payee, WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import { MoveAuthorization, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { PrimaryTerms } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";

/// @notice Answers ERC-165 for one interface (plus IERC165 itself), as installs require.
abstract contract Supports165 is IERC165 {
    function _interface() internal pure virtual returns (bytes4);

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == _interface() || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Package registry mock: consumes each item once and returns the lead party's address
///         as the artist ID, unless an override is set.
contract MockPackageRegistry is Supports165 {
    error ItemConsumedAlready(bytes32 itemHash);

    mapping(bytes32 => bool) public isConsumed;
    uint256 public artistOverride;
    bool public overrideArtist;
    bytes32 public lastRoot;
    uint256 public lastProofLength;
    uint256 public lastMoveNonce;

    function _interface() internal pure override returns (bytes4) {
        return type(IPackageRegistry).interfaceId;
    }

    function setArtistOverride(uint256 artistId) external {
        artistOverride = artistId;
        overrideArtist = true;
    }

    function consume(
        bytes32 packageRoot,
        PackageItem calldata item,
        bytes32[] calldata proof,
        MoveAuthorization calldata move
    ) external returns (bytes32 itemHash, uint256 artistId) {
        itemHash = WorksHashing.itemHashCalldata(item);
        if (isConsumed[itemHash]) revert ItemConsumedAlready(itemHash);
        isConsumed[itemHash] = true;
        lastRoot = packageRoot;
        lastProofLength = proof.length;
        lastMoveNonce = move.nonce;
        artistId = overrideArtist ? artistOverride : uint256(uint160(item.parties[0].account));
    }
}

/// @notice A registry that returns constants, so a gas measurement sees only Stream's share.
contract ConstantPackageRegistry is Supports165 {
    uint256 internal immutable artist;

    constructor(uint256 artistId) {
        artist = artistId;
    }

    function _interface() internal pure override returns (bytes4) {
        return type(IPackageRegistry).interfaceId;
    }

    function consume(bytes32, PackageItem calldata, bytes32[] calldata, MoveAuthorization calldata)
        external
        view
        returns (bytes32, uint256)
    {
        return (keccak256(abi.encode(gasleft())), artist);
    }
}

/// @notice Artist registry mock: identities are registered explicitly; an unknown ID reverts.
contract MockArtistRegistry is Supports165 {
    error UnknownArtist(uint256 artistId);

    mapping(uint256 => address) internal _authority;
    mapping(address => uint256) public artistIdOf;

    function _interface() internal pure override returns (bytes4) {
        return type(IArtistRegistry).interfaceId;
    }

    function register(address account) external returns (uint256 artistId) {
        artistId = uint256(uint160(account));
        _authority[artistId] = account;
        artistIdOf[account] = artistId;
    }

    function setAuthority(uint256 artistId, address authority) external {
        _authority[artistId] = authority;
        artistIdOf[authority] = artistId;
    }

    function authorityOf(uint256 artistId) external view returns (address authority) {
        authority = _authority[artistId];
        if (authority == address(0)) revert UnknownArtist(artistId);
    }
}

/// @notice Artist registry answering every ID with its own address, for gas measurement.
contract ConstantArtists is Supports165 {
    function _interface() internal pure override returns (bytes4) {
        return type(IArtistRegistry).interfaceId;
    }

    function authorityOf(uint256 artistId) external pure returns (address) {
        return address(uint160(artistId));
    }

    function artistIdOf(address account) external pure returns (uint256) {
        return uint256(uint160(account));
    }
}

/// @notice Economics mock returning configured terms; `CURRENCY_DEFAULT` resolves to ETH.
contract MockEconomics is Supports165 {
    error CurrencyNotAllowed(address currency);

    WorkTerms internal _terms;
    mapping(address => bool) public blocked;

    constructor(WorkTerms memory terms) {
        _terms = terms;
    }

    function _interface() internal pure override returns (bytes4) {
        return type(IEconomicsResolver).interfaceId;
    }

    function setTerms(WorkTerms memory terms) external {
        _terms = terms;
    }

    function setBlocked(address currency, bool value) external {
        blocked[currency] = value;
    }

    function newWorkTerms(bytes32, Payee[] calldata) external view returns (WorkTerms memory) {
        return _terms;
    }

    function resolveCurrency(bytes32, address requested) external view returns (address) {
        address resolved = requested == CURRENCY_DEFAULT ? address(0) : requested;
        if (blocked[resolved]) revert CurrencyNotAllowed(resolved);
        return resolved;
    }
}

/// @notice Economics that returns constants, for measuring Stream's own gas.
contract ConstantEconomics is Supports165 {
    function _interface() internal pure override returns (bytes4) {
        return type(IEconomicsResolver).interfaceId;
    }

    function newWorkTerms(bytes32, Payee[] calldata) external pure returns (WorkTerms memory) {
        return WorkTerms(address(0x5e11e7), address(0xfee), 25_000, address(0x7071), 6_529);
    }

    function resolveCurrency(bytes32, address) external pure returns (address) {
        return address(0);
    }
}

/// @notice Entropy module mock: seeds keyed by item hash, delivered by the test.
contract MockEntropy is Supports165 {
    mapping(bytes32 => bytes32) internal _seeds;

    function _interface() internal pure override returns (bytes4) {
        return type(IEntropyModule).interfaceId;
    }

    function deliver(bytes32 itemHash, bytes32 seed) external {
        _seeds[itemHash] = seed;
    }

    function isDelivered(bytes32 itemHash) external view returns (bool) {
        return _seeds[itemHash] != 0;
    }

    function seedOf(bytes32 itemHash) external view returns (bytes32) {
        return _seeds[itemHash];
    }
}

/// @notice A renderer mock: `tokenURI` echoes its tag, the token and the ID.
contract MockRenderer is IRenderer {
    string public tag;

    constructor(string memory tag_) {
        tag = tag_;
    }

    function tokenURI(address token, uint256 tokenId) external view returns (string memory) {
        return string(abi.encodePacked(tag, ":", abi.encode(token, tokenId)));
    }

    function fullTokenURI(address, uint256) external pure returns (string memory) {
        return "full";
    }

    function inlineThreshold() external pure returns (uint256) {
        return 256 * 1024;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IRenderer).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice A sale adapter mock holding the MINTER role: mints into its own custody, burns and
///         hands tokens out.
contract MockSaleAdapter is IERC721Receiver {
    bytes32 public saleKind;

    constructor(bytes32 kind) {
        saleKind = kind;
    }

    function setSaleKind(bytes32 kind) external {
        saleKind = kind;
    }

    function start(IMintTarget token, bytes calldata data)
        external
        returns (uint256 tokenId, PrimaryTerms memory terms)
    {
        return token.mint(address(this), 0, 1, data);
    }

    function startRaw(
        IMintTarget token,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external returns (uint256 tokenId, PrimaryTerms memory terms) {
        return token.mint(to, id, amount, data);
    }

    function burn(IMintTarget token, uint256 id, uint256 amount) external {
        token.burn(id, amount);
    }

    function deliver(address token, uint256 id, address to) external {
        (bool ok, bytes memory reason) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", address(this), to, id)
        );
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice An auction stand-in whose `saleKind` is a constant, as a real adapter's is, so a gas
///         measurement does not include a mock's storage read.
contract ConstantAuction is IERC721Receiver {
    bytes32 public constant saleKind = keccak256("ENGLISH_AUCTION");

    function startMeasured(IMintTarget token, bytes calldata data) external returns (uint256 used) {
        used = gasleft();
        token.mint(address(this), 0, 1, data);
        used -= gasleft();
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice A records-satellite mock: holds renderer pins and drives the core's hooks.
contract MockWorkRecords {
    mapping(uint256 => address) public pinnedRenderer;

    function setPin(uint256 tokenId, address renderer) external {
        pinnedRenderer[tokenId] = renderer;
    }

    function setRoyaltyRate(IStream stream, uint256 tokenId, uint32 rate) external {
        stream.setRoyaltyRate(tokenId, rate);
    }

    function refresh(IStream stream, uint256 fromTokenId, uint256 toTokenId) external {
        stream.emitMetadataUpdate(fromTokenId, toTokenId);
    }
}

/// @notice An Editions mock: links masters and counts master-update notifications.
contract MockEditions {
    mapping(uint256 => uint256) public notified;

    function link(IStream stream, uint256 tokenId, uint256 editionId) external {
        stream.linkEdition(tokenId, editionId);
    }

    function notifyMasterUpdated(uint256 workId) external {
        ++notified[workId];
    }
}

/// @notice Calls `royaltyInfo` under a caller-chosen gas limit.
contract RoyaltyProbe {
    function probe(address token, uint256 tokenId, uint256 price, uint256 gasLimit)
        external
        view
        returns (bool ok, address receiver, uint256 amount)
    {
        bytes memory result;
        (ok, result) = token.staticcall{ gas: gasLimit }(
            abi.encodeWithSignature("royaltyInfo(uint256,uint256)", tokenId, price)
        );
        if (ok) (receiver, amount) = abi.decode(result, (address, uint256));
    }
}

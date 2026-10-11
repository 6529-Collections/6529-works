// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IRenderer } from "src/interfaces/IRenderer.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { Payee, WorkTerms, CURRENCY_DEFAULT } from "src/interfaces/types/EconomicsTypes.sol";
import { MoveAuthorization, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { PrimaryTerms } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { IStreamCore } from "src/stream/IStreamCore.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";

/// @notice Package registry mock: consumes each item once and returns the lead party's address
///         as the artist ID, unless an override is set.
contract MockPackageRegistry {
    error ItemConsumedAlready(bytes32 itemHash);

    mapping(bytes32 => bool) public isConsumed;
    uint256 public artistOverride;
    bool public overrideArtist;
    bytes32 public lastRoot;
    bytes32[] internal _lastProof;
    uint256 public lastMoveNonce;

    function setArtistOverride(uint256 artistId) external {
        artistOverride = artistId;
        overrideArtist = true;
    }

    function consume(
        bytes32 packageRoot,
        PackageItem calldata item,
        bytes32[] calldata proof,
        MoveAuthorization calldata move
    ) external returns (bytes32 itemHash, uint256 artistId, bytes32 contentHash) {
        itemHash = WorksHashing.itemHash(item);
        if (isConsumed[itemHash]) revert ItemConsumedAlready(itemHash);
        isConsumed[itemHash] = true;
        lastRoot = packageRoot;
        _lastProof = proof;
        lastMoveNonce = move.nonce;
        artistId = overrideArtist ? artistOverride : uint256(uint160(item.parties[0].account));
        contentHash = keccak256(abi.encode("sha256", item.contentId));
    }

    function lastProof() external view returns (bytes32[] memory) {
        return _lastProof;
    }
}

/// @notice A registry that does nothing but return constants, so a gas measurement sees only
///         6529 Stream's own share of `mint`.
contract ConstantPackageRegistry {
    uint256 internal immutable artist;

    constructor(uint256 artistId) {
        artist = artistId;
    }

    function consume(bytes32, PackageItem calldata, bytes32[] calldata, MoveAuthorization calldata)
        external
        view
        returns (bytes32, uint256, bytes32)
    {
        return (keccak256(abi.encode(gasleft())), artist, keccak256("sha"));
    }
}

/// @notice Artist registry mock: identities are registered explicitly; an unknown ID reverts.
contract MockArtistRegistry {
    error UnknownArtist(uint256 artistId);

    mapping(uint256 => address) internal _authority;
    mapping(address => uint256) public artistIdOf;

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

/// @notice Economics mock returning configured terms; `CURRENCY_DEFAULT` resolves to ETH.
contract MockEconomics {
    error CurrencyNotAllowed(address currency);

    WorkTerms internal _terms;
    mapping(address => bool) public blocked;
    bytes32 public lastPayeesHash;

    constructor(WorkTerms memory terms) {
        _terms = terms;
    }

    function setTerms(WorkTerms memory terms) external {
        _terms = terms;
    }

    function setBlocked(address currency, bool value) external {
        blocked[currency] = value;
    }

    function newWorkTerms(bytes32, Payee[] calldata payees)
        external
        view
        returns (WorkTerms memory)
    {
        payees;
        return _terms;
    }

    function resolveCurrency(bytes32, address requested) external view returns (address) {
        address resolved = requested == CURRENCY_DEFAULT ? address(0) : requested;
        if (blocked[resolved]) revert CurrencyNotAllowed(resolved);
        return resolved;
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

    /// @dev Returns the gas `mint` consumed, measured around the call.
    function startMeasured(IMintTarget token, bytes calldata data) external returns (uint256 used) {
        used = gasleft();
        token.mint(address(this), 0, 1, data);
        used -= gasleft();
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

/// @notice A renderer mock: `tokenURI` echoes the token and ID.
contract MockRenderer is IRenderer, IERC165 {
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

/// @notice A records-satellite mock: holds renderer pins and drives the core's hooks.
contract MockWorkRecords {
    mapping(uint256 => address) public pinnedRenderer;

    function setPin(uint256 tokenId, address renderer) external {
        pinnedRenderer[tokenId] = renderer;
    }

    function setLicense(IStreamCore stream, uint256 tokenId, License calldata next) external {
        stream.setLicense(tokenId, next);
    }

    function setRoyaltyRate(IStreamCore stream, uint256 tokenId, uint32 rate) external {
        stream.setRoyaltyRate(tokenId, rate);
    }

    function refresh(IStreamCore stream, uint256 fromTokenId, uint256 toTokenId) external {
        stream.refreshMetadata(fromTokenId, toTokenId);
    }
}

/// @notice An Editions mock that links masters.
contract MockEditions {
    function link(IStreamCore stream, uint256 tokenId, uint256 editionId) external {
        stream.linkEdition(tokenId, editionId);
    }
}

/// @notice Measures `royaltyInfo` under a caller-chosen gas limit.
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

/// @notice Economics that returns constants, for measuring 6529 Stream's own gas.
contract ConstantEconomics {
    function newWorkTerms(bytes32, Payee[] calldata) external pure returns (WorkTerms memory) {
        return WorkTerms(address(0x5e11e7), address(0xfee), 25_000, address(0x7071), 6_529);
    }

    function resolveCurrency(bytes32, address) external pure returns (address) {
        return address(0);
    }
}

/// @notice Artist registry that answers every ID with its own address, for gas measurement.
contract ConstantArtists {
    function authorityOf(uint256 artistId) external pure returns (address) {
        return address(uint160(artistId));
    }

    function artistIdOf(address account) external pure returns (uint256) {
        return uint256(uint160(account));
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

/// @notice Entropy module mock: seeds are delivered by the test.
contract MockEntropy {
    mapping(address => mapping(uint256 => bytes32)) internal _seeds;

    function deliver(address token, uint256 tokenId, bytes32 seed) external {
        _seeds[token][tokenId] = seed;
    }

    function isDelivered(address token, uint256 tokenId) external view returns (bool) {
        return _seeds[token][tokenId] != 0;
    }

    function seedOf(address token, uint256 tokenId) external view returns (bytes32) {
        return _seeds[token][tokenId];
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IEntropyModule } from "src/interfaces/IEntropyModule.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IRenderer } from "src/interfaces/IRenderer.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import {
    CURRENCY_DEFAULT,
    ProductEconomics,
    WorkTerms
} from "src/interfaces/types/EconomicsTypes.sol";
import {
    MoveAuthorization,
    PackageItem,
    SeedPolicy,
    StreamMintRequest
} from "src/interfaces/types/PackageTypes.sol";
import { IMintPolicy } from "src/interfaces/IMintPolicy.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { PRODUCT_STREAM } from "src/interfaces/types/EconomicsTypes.sol";
import { SpdxId } from "src/stream/SpdxId.sol";
import {
    PrimaryOutcome,
    PrimarySettlement,
    PrimaryTerms
} from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";

/// @notice Answers ERC-165 for one interface (plus IERC165 itself), as installs require.
abstract contract Supports165 is IERC165 {
    function _interface() internal pure virtual returns (bytes4);

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == _interface() || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Package registry mock, as Stream's mint policy: applies the v1 item rules, consumes
///         each item once and returns the lead party's address as the artist ID, unless an
///         override is set; quotes the terms from the context's economics and split factory.
contract MockPackageRegistry is Supports165 {
    error NotBoundCaller(address caller);

    uint256 public consumes;

    address public stream;
    uint256 public artistOverride;
    bool public overrideArtist;
    bytes32 public lastRoot;
    uint256 public lastProofLength;
    uint256 public lastMoveNonce;
    address internal _reentryAdapter;
    bytes internal _reentryCall;

    address public artistRegistry;

    function _interface() internal pure override returns (bytes4) {
        return type(IMintPolicy).interfaceId;
    }

    function setArtistRegistry(address registry) external {
        artistRegistry = registry;
    }

    function authorize(IMintPolicy.MintContext calldata c, bytes calldata request)
        external
        returns (IMintPolicy.MintRecord memory r)
    {
        if (request.length < 160 || uint256(bytes32(request[:32])) != 32) {
            revert IMintTarget.InvalidMintRequest();
        }
        StreamMintRequest memory req = abi.decode(request, (StreamMintRequest));
        PackageItem memory item = req.item;
        _check(item, c.entropyModule);
        address creator;
        (r.itemHash, r.artistId, creator) = this.consume(req.packageRoot, item, req.proof, req.move);
        if (
            item.seedPolicy == uint8(SeedPolicy.VRF)
                && !IEntropyModule(c.entropyModule).isDeliveredContent(item.contentHash)
        ) revert IMintPolicy.SeedNotDelivered(r.itemHash);
        PrimaryTerms memory t;
        (t, r.royaltyRate) = _quote(item, c);
        (r.saleKind, r.currency, r.params) = (t.saleKind, t.currency, t.params);
        (r.seller, r.feeRecipient, r.feeShare, r.creator) =
        (t.seller, t.feeRecipient, t.feeShare, creator);
        r.collectionId = item.collectionId;
        r.kind = uint8(item.kind);
        r.seedPolicy = uint8(item.seedPolicy);
        r.packageRoot = req.packageRoot;
        r.contentHash = item.contentHash;
        r.mediaHash = item.mediaHash;
        r.recordFileId = item.recordFileId;
    }

    function preview(IMintPolicy.MintContext calldata c, bytes calldata request)
        external
        view
        returns (PrimaryTerms memory terms)
    {
        if (request.length < 160 || uint256(bytes32(request[:32])) != 32) {
            revert IMintTarget.InvalidMintRequest();
        }
        StreamMintRequest memory req = abi.decode(request, (StreamMintRequest));
        _check(req.item, c.entropyModule);
        uint256 artistId = IArtistRegistry(artistRegistry).artistIdOf(req.item.parties[0].account);
        if (artistId == 0) revert IMintPolicy.InvalidLeadArtist();
        (terms,) = _quote(req.item, c);
        terms.creator = IArtistRegistry(artistRegistry).activeAuthorityOf(artistId);
    }

    function _check(PackageItem memory item, address entropy) internal pure {
        if (item.sale.saleKind == 0) revert IMintPolicy.InvalidItemSale();
        if (item.parties.length == 0) revert IMintPolicy.InvalidLeadArtist();
        uint8 policy = item.seedPolicy;
        if (
            (policy == uint8(SeedPolicy.ARTIST)) != (item.seed != 0)
                || (policy == uint8(SeedPolicy.VRF) && entropy == address(0))
        ) revert IMintPolicy.InvalidSeedPolicy();
        if (!SpdxId.isValid(item.license.spdxId)) revert IMintPolicy.InvalidLicenseId();
    }

    function _quote(PackageItem memory item, IMintPolicy.MintContext calldata c)
        internal
        view
        returns (PrimaryTerms memory terms, uint32 royaltyRate)
    {
        ProductEconomics memory e = IEconomicsResolver(c.economics).economics(PRODUCT_STREAM);
        address seller = ISplitFactory(c.splitFactory).walletFor(item.payees, bytes32(0));
        if (
            e.royaltyRate > Splits.DENOMINATOR || e.feeShare >= Splits.DENOMINATOR
                || (e.feeShare != 0 && (e.feeRecipient == address(0) || e.feeRecipient == seller))
        ) revert IMintPolicy.InvalidWorkTerms();
        terms.saleKind = item.sale.saleKind;
        terms.currency = item.sale.currency;
        terms.params = item.sale.params;
        terms.seller = seller;
        terms.feeRecipient = e.feeRecipient;
        terms.feeShare = e.feeShare;
        royaltyRate = e.royaltyRate;
    }

    function bindStream(address stream_) external {
        stream = stream_;
    }

    /// @dev Makes the next `consume` call `adapter` with `call` (once) before returning, the
    ///      re-entry Slither's `reentrancy-no-eth` finding on `Stream.mint` describes.
    function setReentry(address adapter, bytes calldata call) external {
        _reentryAdapter = adapter;
        _reentryCall = call;
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
    ) external returns (bytes32 itemHash, uint256 artistId, address authority) {
        itemHash = WorksHashing.itemHashCalldata(item);
        // Content uniqueness is Stream's (AUC-44): the mock keeps no record of its own.
        ++consumes;
        lastRoot = packageRoot;
        lastProofLength = proof.length;
        lastMoveNonce = move.nonce;
        artistId = overrideArtist ? artistOverride : uint256(uint160(item.parties[0].account));
        // The active authority, as the real registry returns it once it checked the move: read
        // from the caller's (Stream's) artist registry.
        authority = overrideArtist
            ? address(uint160(artistOverride))
            : IArtistRegistry(artistRegistry).activeAuthorityOf(artistId);
        address adapter = _reentryAdapter;
        if (adapter != address(0)) {
            delete _reentryAdapter;
            (bool ok, bytes memory reason) = adapter.call(_reentryCall);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        }
    }
}

/// @notice A mint policy without consent or uniqueness checks, so a gas measurement sees only
///         Stream's share plus the terms quote every policy makes (the context's economics and
///         the split factory's seller wallet): a fresh item hash per call, a constant lead artist.
contract ConstantMintPolicy is Supports165 {
    uint256 internal immutable artist;
    address public immutable artistRegistry;

    constructor(uint256 artistId, address artists) {
        artist = artistId;
        artistRegistry = artists;
    }

    function _interface() internal pure override returns (bytes4) {
        return type(IMintPolicy).interfaceId;
    }

    function authorize(IMintPolicy.MintContext calldata c, bytes calldata request)
        external
        view
        returns (IMintPolicy.MintRecord memory r)
    {
        PackageItem memory item = abi.decode(request, (StreamMintRequest)).item;
        ProductEconomics memory e = IEconomicsResolver(c.economics).economics(PRODUCT_STREAM);
        r.itemHash = keccak256(abi.encode(gasleft()));
        r.artistId = artist;
        r.collectionId = item.collectionId;
        r.kind = uint8(item.kind);
        r.seedPolicy = uint8(item.seedPolicy);
        r.royaltyRate = e.royaltyRate;
        r.contentHash = item.contentHash;
        r.mediaHash = item.mediaHash;
        r.recordFileId = item.recordFileId;
        r.saleKind = item.sale.saleKind;
        r.currency = item.sale.currency;
        r.seller = ISplitFactory(c.splitFactory).walletFor(item.payees, bytes32(0));
        r.feeRecipient = e.feeRecipient;
        r.feeShare = e.feeShare;
        r.creator = address(uint160(artist));
        r.params = item.sale.params;
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

    function authorityOf(uint256 artistId) public view returns (address authority) {
        authority = _authority[artistId];
        if (authority == address(0)) revert UnknownArtist(artistId);
    }

    /// @dev No recovery override is modelled: the active authority is the authority.
    function activeAuthorityOf(uint256 artistId) external view returns (address) {
        return authorityOf(artistId);
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

    function activeAuthorityOf(uint256 artistId) external pure returns (address) {
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
    address public immutable splitFactory;
    /// @notice The museum an unsold work goes to (owner decision 17); settable, even to zero.
    address public museum = address(0x6529);

    constructor(WorkTerms memory terms, address factory) {
        _terms = terms;
        splitFactory = factory;
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

    function setMuseum(address next) external {
        museum = next;
    }

    /// @dev The fee terms of `_terms`; Stream derives the seller from the item's payees, so
    ///      `_terms.seller` and `_terms.royaltyReceiver` are not used. There is no
    ///      `newWorkTerms`: a call to it would revert.
    function economics(bytes32) external view returns (ProductEconomics memory) {
        return ProductEconomics(_terms.feeRecipient, _terms.feeShare, _terms.royaltyRate);
    }

    function resolveCurrency(bytes32, address requested) external view returns (address) {
        address resolved = requested == CURRENCY_DEFAULT ? address(0) : requested;
        if (blocked[resolved]) revert CurrencyNotAllowed(resolved);
        return resolved;
    }
}

/// @notice Economics that returns constants, for measuring Stream's own gas.
contract ConstantEconomics is Supports165 {
    address public immutable splitFactory;

    constructor(address factory) {
        splitFactory = factory;
    }

    function _interface() internal pure override returns (bytes4) {
        return type(IEconomicsResolver).interfaceId;
    }

    function economics(bytes32) external pure returns (ProductEconomics memory) {
        return ProductEconomics(address(0xfee), 25_000, 6_529);
    }

    function resolveCurrency(bytes32, address) external pure returns (address) {
        return address(0);
    }
}

/// @notice Entropy module mock: seeds keyed by item hash, delivered by the test.
contract MockEntropy is Supports165 {
    mapping(bytes32 => bytes32) internal _seeds;
    mapping(bytes32 => bytes32) internal _contentSeeds;

    function _interface() internal pure override returns (bytes4) {
        return type(IEntropyModule).interfaceId;
    }

    /// @dev Delivers `item`'s seed, by item hash and by content hash, as the real module links
    ///      them.
    function deliver(PackageItem memory item, bytes32 seed) external {
        _seeds[WorksHashing.itemHash(item)] = seed;
        _contentSeeds[item.contentHash] = seed;
    }

    function isDelivered(bytes32 itemHash) external view returns (bool) {
        return _seeds[itemHash] != 0;
    }

    function seedOf(bytes32 itemHash) external view returns (bytes32) {
        return _seeds[itemHash];
    }

    function isDeliveredContent(bytes32 contentHash) external view returns (bool) {
        return _contentSeeds[contentHash] != 0;
    }

    function seedOfContent(bytes32 contentHash) external view returns (bytes32) {
        return _contentSeeds[contentHash];
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
contract MockSaleAdapter is IERC721Receiver, Supports165 {
    bytes32 public saleKind;

    constructor(bytes32 kind) {
        saleKind = kind;
    }

    function _interface() internal pure override returns (bytes4) {
        return type(ISaleAdapter).interfaceId;
    }

    function setSaleKind(bytes32 kind) external {
        saleKind = kind;
    }

    /// @dev Settles as SOLD to `buyer` (the adapter keeps the work to deliver).
    function settle(IStream stream, uint256 tokenId) external {
        stream.settlePrimary(tokenId, PrimaryOutcome.SOLD, address(this), address(0), 0);
    }

    function settleWith(
        IStream stream,
        uint256 tokenId,
        PrimaryOutcome outcome,
        address buyer,
        address currency,
        uint256 price
    ) external returns (PrimarySettlement memory) {
        return stream.settlePrimary(tokenId, outcome, buyer, currency, price);
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
contract ConstantAuction is IERC721Receiver, Supports165 {
    bytes32 public constant saleKind = keccak256("ENGLISH_AUCTION");

    function _interface() internal pure override returns (bytes4) {
        return type(ISaleAdapter).interfaceId;
    }

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

/// @notice A records-satellite mock: holds renderer pins and drives the core's hooks. Its
///         `pinnedRenderer` can be made to fail in each way `Stream.rendererOf` must handle.
contract MockWorkRecords is Supports165 {
    /// @notice The Stream this satellite serves, which `bindWorkRecords` checks.
    address public immutable stream;
    mapping(uint256 => address) internal _pins;
    mapping(uint256 => bool) public isOpen;
    /// @notice 0 none; 1 revert; 2 run out of gas; 3 answer nothing; 4 answer two words;
    ///         5 a word that is not an address; 6 an address without code; 7 revert with
    ///         `DependencyCodeChanged` for the pin; 8 revert with `RecordNotOpen`.
    uint8 public fault;

    function setFault(uint8 fault_) external {
        fault = fault_;
    }

    function pinnedRenderer(uint256 tokenId) external view returns (address) {
        uint8 f = fault;
        if (f == 8) revert IWorkRecords.RecordNotOpen(tokenId);
        if (f == 1) revert("records fault");
        if (f == 2) {
            uint256 i;
            while (gasleft() > 0) {
                ++i;
            }
        }
        if (f == 3) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (f == 4) {
            address pin = _pins[tokenId];
            assembly ("memory-safe") {
                mstore(0, pin)
                mstore(0x20, pin)
                return(0, 0x40)
            }
        }
        if (f == 5) {
            assembly ("memory-safe") {
                mstore(0, not(0))
                return(0, 0x20)
            }
        }
        if (f == 6) return address(0xdead);
        if (f == 7) revert Dependency.DependencyCodeChanged(_pins[tokenId]);
        return _pins[tokenId];
    }

    constructor(address stream_) {
        stream = stream_;
    }

    function _interface() internal pure override returns (bytes4) {
        return type(IWorkRecords).interfaceId;
    }

    function setPin(uint256 tokenId, address renderer) external {
        _pins[tokenId] = renderer;
        isOpen[tokenId] = true;
    }

    function setRoyaltyRate(IStream target, uint256 tokenId, uint32 rate) external {
        target.setRoyaltyRate(tokenId, rate);
    }

    function refresh(IStream target, uint256 fromTokenId, uint256 toTokenId) external {
        target.emitMetadataUpdate(fromTokenId, toTokenId);
    }
}

/// @notice An Editions mock: links masters and records the hooks Stream and WorkRecords call.
contract MockEditions is Supports165 {
    /// @notice The Stream this contract serves, which `bindEditions` checks.
    address public immutable stream;
    mapping(uint256 => uint256) public notified;
    mapping(uint256 => uint32) public rateOf;
    uint256 public notifiedAll;

    constructor(address stream_) {
        stream = stream_;
    }

    function _interface() internal pure override returns (bytes4) {
        return type(IEditions).interfaceId;
    }

    function notifyAllUpdated() external {
        ++notifiedAll;
    }

    function setRoyaltyRate(uint256 editionId, uint32 rate) external {
        rateOf[editionId] = rate;
    }

    function link(IStream target, uint256 tokenId, uint256 editionId) external {
        target.linkEdition(tokenId, editionId);
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

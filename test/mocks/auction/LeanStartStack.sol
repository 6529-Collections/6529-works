// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import {
    MoveAuthorization,
    PackageItem,
    SeedPolicy,
    StreamMintRequest
} from "src/interfaces/types/PackageTypes.sol";
import { PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";

/// @notice A lean model of the 6529 Stream start path as the PR #10 reviews decided it (D3, D6,
///         E3, E4, E8 and E11), used to measure the end-to-end `start` gas before the stream,
///         curation, identity and economics lanes land. Every storage write and external read the
///         decided design needs is here, and nothing more:
///         - Stream: the admitted-adapter check on `mint` (E4), the adapter's sale kind, the
///           request (read in place from calldata), the ERC-721 owner and balance, three work
///           slots (seller, serial and fee share; the item hash; the lead artist ID, royalty
///           rate, fee-recipient index and collection; the royalty receiver is derived, E3), the
///           token counter and the collection serial, the `WorkMinted` event, and the lead
///           artist's authority for the returned terms;
///         - registry (`consume`, a bound caller with no AccessManager hop): the item hash, the
///           Merkle proof, the package status, `acceptedAs` per party, the payee coverage check,
///           the lead artist's authority and move signature, the move nonce bit, and one slot for
///           single use and content uniqueness keyed on the item's declared content hash;
///         - economics: the product economics and the seller split-wallet prediction (the real
///           `SplitFactory`). The currency is passed through: the auction resolves
///           `CURRENCY_DEFAULT` and checks it in the allowlist.
///         No split wallet is deployed, no content store is read, a VRF seed is checked only for
///         VRF items, and no heartbeat is written, as decided.

/// @dev The artist registry read on the start path: the lead artist's current authority.
contract LeanArtistRegistry {
    mapping(uint256 artistId => address) public authorityOf;

    function set(uint256 artistId, address authority) external {
        authorityOf[artistId] = authority;
    }
}

/// @dev `IPackageRegistry.consume` as decided: bound to one Stream, one slot per consumed item.
contract LeanPackageRegistry is EIP712 {
    LeanArtistRegistry public immutable artists;
    address public stream;
    mapping(bytes32 root => bool) public approved;
    mapping(bytes32 root => mapping(address account => uint256 artistId)) public acceptedAs;
    mapping(uint256 artistId => mapping(uint256 word => uint256)) public moveNonces;
    mapping(bytes32 contentHash => bytes32 itemHash) public consumedItemOf;

    event ItemConsumed(
        bytes32 indexed packageRoot,
        bytes32 indexed itemHash,
        uint256 indexed artistId,
        bytes32 contentHash
    );

    constructor(LeanArtistRegistry artists_)
        EIP712(Typehashes.PACKAGE_REGISTRY_NAME, Typehashes.DOMAIN_VERSION)
    {
        artists = artists_;
    }

    function bind(address stream_) external {
        require(stream == address(0), "bound");
        stream = stream_;
    }

    function approve(bytes32 root) external {
        approved[root] = true;
    }

    function accept(bytes32 root, address account) external {
        acceptedAs[root][account] = uint160(account);
    }

    function moveDigest(bytes32 root, bytes32 itemHash, uint256 nonce, uint64 deadline)
        external
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(abi.encode(Typehashes.MOVE_TO_STREAM, root, itemHash, nonce, deadline))
        );
    }

    function consume(
        bytes32 root,
        PackageItem calldata item,
        bytes32[] calldata proof,
        MoveAuthorization calldata move
    ) external returns (bytes32 itemHash, uint256 artistId) {
        require(msg.sender == stream, "caller");
        itemHash = WorksHashing.itemHashCalldata(item);
        require(MerkleProof.verifyCalldata(proof, root, WorksHashing.leaf(itemHash)), "proof");
        require(approved[root], "package");
        uint256 parties = item.parties.length;
        for (uint256 i; i < parties; ++i) {
            uint256 id = acceptedAs[root][item.parties[i].account];
            require(id != 0, "consent");
            if (i == 0) artistId = id;
        }
        for (uint256 i; i < item.payees.length; ++i) {
            ISplitWallet.Payee calldata p = item.payees[i];
            bool covered;
            for (uint256 j; j < parties && !covered; ++j) {
                address account = item.parties[j].account;
                covered = p.account == account || p.artistId == uint160(account);
            }
            require(covered, "payee");
        }
        require(block.timestamp <= move.deadline, "deadline");
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(Typehashes.MOVE_TO_STREAM, root, itemHash, move.nonce, move.deadline)
            )
        );
        require(SignatureVerifier.isValid(artists.authorityOf(artistId), digest, move.signature));
        uint256 bit = 1 << (move.nonce & 0xff);
        uint256 word = moveNonces[artistId][move.nonce >> 8];
        require(word & bit == 0, "nonce");
        moveNonces[artistId][move.nonce >> 8] = word | bit;
        bytes32 contentHash = item.contentHash;
        require(consumedItemOf[contentHash] == 0, "used");
        consumedItemOf[contentHash] = itemHash;
        emit ItemConsumed(root, itemHash, artistId, contentHash);
    }
}

/// @dev `IEconomicsResolver.newWorkTerms` over the real split factory: one packed economics slot
///      and the seller wallet prediction (the royalty receiver is derived later, E3).
contract LeanEconomicsResolver {
    ISplitFactory public immutable factory;
    address public feeRecipient;
    uint32 public feeShare;
    uint32 public royaltyRate;

    constructor(ISplitFactory factory_, address feeRecipient_) {
        factory = factory_;
        feeRecipient = feeRecipient_;
        feeShare = 25_000;
        royaltyRate = 6_529;
    }

    function newWorkTerms(ISplitWallet.Payee[] calldata payees)
        external
        view
        returns (WorkTerms memory t)
    {
        (t.feeRecipient, t.feeShare, t.royaltyRate) = (feeRecipient, feeShare, royaltyRate);
        t.seller = factory.walletFor(payees, bytes32(0));
    }
}

/// @dev 6529 Stream's mint as decided: three work slots per token.
contract LeanStream is ERC721, IMintTarget {
    LeanPackageRegistry public immutable registry;
    LeanEconomicsResolver public immutable resolver;
    LeanArtistRegistry public immutable artists;
    mapping(address adapter => bool) public isAdmittedMinter;
    uint256 public lastId;
    mapping(uint256 collectionId => uint64) public collectionSize;
    /// @dev seller (160) | serial (64) | fee share (32).
    mapping(uint256 tokenId => uint256) public workSlot;
    mapping(uint256 tokenId => bytes32) public itemHashOf;
    /// @dev artist ID (160) | royalty rate (32) | fee-recipient index (16) | collection ID (40) |
    ///      flags (8, bit 0: primary sale settled).
    mapping(uint256 tokenId => uint256) public artistSlot;

    event WorkMinted(
        uint256 indexed tokenId,
        bytes32 indexed itemHash,
        uint256 indexed artistId,
        uint256 collectionId,
        uint64 serial
    );

    constructor(
        LeanPackageRegistry registry_,
        LeanEconomicsResolver resolver_,
        LeanArtistRegistry artists_
    ) ERC721("6529 Stream", "STREAM") {
        registry = registry_;
        resolver = resolver_;
        artists = artists_;
    }

    /// @dev In Stream, a `restricted` setter mapped to the 30-day class (E4).
    function setAdmittedMinter(address adapter, bool admitted) external {
        isAdmittedMinter[adapter] = admitted;
        emit AdmittedMinterSet(adapter, admitted);
    }

    function mint(address to, uint256 id, uint256 amount, bytes calldata data)
        external
        returns (uint256 tokenId, PrimaryTerms memory terms)
    {
        require(isAdmittedMinter[msg.sender], "minter");
        require(id == 0 && amount == 1, "mint");
        require(ISaleAdapter(msg.sender).saleKind() == SaleKind.ENGLISH_AUCTION, "kind");
        StreamMintRequest calldata request = _request(data);
        PackageItem calldata item = request.item;
        require(item.seedPolicy != SeedPolicy.VRF, "seed not delivered");
        (bytes32 itemHash, uint256 artistId) =
            registry.consume(request.packageRoot, item, request.proof, request.move);
        WorkTerms memory w = resolver.newWorkTerms(item.payees);
        tokenId = _record(to, item.collectionId, itemHash, artistId, w);
        terms = PrimaryTerms(
            SaleKind.ENGLISH_AUCTION,
            item.sale.currency,
            0,
            "",
            w.seller,
            w.feeRecipient,
            w.feeShare,
            artists.authorityOf(artistId)
        );
    }

    function _record(
        address to,
        uint256 collectionId,
        bytes32 itemHash,
        uint256 artistId,
        WorkTerms memory w
    ) private returns (uint256 tokenId) {
        tokenId = ++lastId;
        uint64 serial = ++collectionSize[collectionId];
        workSlot[tokenId] =
            uint256(uint160(w.seller)) | uint256(serial) << 160 | uint256(w.feeShare) << 224;
        itemHashOf[tokenId] = itemHash;
        artistSlot[tokenId] = artistId | uint256(w.royaltyRate) << 160 | 1 << 192
            | uint256(uint40(collectionId)) << 208;
        _mint(to, tokenId);
        emit WorkMinted(tokenId, itemHash, artistId, collectionId, serial);
    }

    /// @dev E8: the sale kind, the locked seller and fee share, the fee recipient (by index),
    ///      and the artist's current authority. The adapter owns the currency.
    function primaryTerms(uint256 id, bytes calldata) external view returns (PrimaryTerms memory) {
        uint256 work = workSlot[id];
        require(work != 0, "unknown");
        return PrimaryTerms(
            SaleKind.ENGLISH_AUCTION,
            address(0),
            0,
            "",
            address(uint160(work)),
            resolver.feeRecipient(),
            uint32(work >> 224),
            artists.authorityOf(uint160(artistSlot[id]))
        );
    }

    /// @dev E11: only the minting adapter, while the token is still in its custody.
    function markPrimarySettled(uint256 id) external {
        require(isAdmittedMinter[msg.sender] && _ownerOf(id) == msg.sender, "adapter");
        artistSlot[id] |= 1 << 248;
    }

    function burn(uint256 id, uint256) external {
        require(isAdmittedMinter[msg.sender] && ownerOf(id) == msg.sender, "custody");
        _burn(id);
    }

    function _request(bytes calldata data) private pure returns (StreamMintRequest calldata r) {
        assembly ("memory-safe") {
            r := add(data.offset, calldataload(data.offset))
        }
    }
}

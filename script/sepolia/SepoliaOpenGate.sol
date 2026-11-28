// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { StreamHashing } from "src/interfaces/types/StreamHashing.sol";

/// @dev The two reads of the curation verifier (`Eip712CurationVerifier`) the gate needs.
interface IOpenGateVerifier {
    /// @notice The digest a curation signer signs to approve a package root at its epoch.
    /// @param packageRoot The package root.
    /// @param evidenceHash The evidence hash the approval binds.
    /// @param signerEpoch_ The signer's epoch.
    /// @return The approval digest in the verifier's EIP-712 domain.
    function approvalDigest(bytes32 packageRoot, bytes32 evidenceHash, uint256 signerEpoch_)
        external
        view
        returns (bytes32);

    /// @notice The current epoch of `signer`.
    /// @param signer The curation signer.
    /// @return The epoch an approval must name to count.
    function signerEpoch(address signer) external view returns (uint256);
}

/// @dev The one call the gate makes on 6529 Stream (`IStream.createCollection`).
interface IOpenGateStream {
    /// @notice Creates a collection.
    /// @param name The collection's name.
    /// @param metadataHash The hash of the collection's metadata document.
    /// @return collectionId The new collection's ID.
    function createCollection(string calldata name, bytes32 metadataHash)
        external
        returns (uint256 collectionId);
}

/// @title SepoliaOpenGate
/// @notice A SEPOLIA TEST CONVENIENCE. NEVER DEPLOY IT ON MAINNET. On a Sepolia test instance it
///         lets any wallet try the curated path of 6529 Stream with no curation step: it approves
///         every package root, and it lets anyone create a collection. It is not part of 6529
///         Stream, lives under `script/sepolia/` and is not used by any contract under `src/`.
/// @dev The constructor reverts on every chain except Sepolia (11155111) and a local development
///      chain (31337), and both entry points refuse to answer anywhere else.
///
///      It has no owner, no setter, no `receive` and no `fallback`, holds no funds and makes one
///      kind of state-changing call: `createCollection` on the Stream named at deployment. Its
///      other functions are views ({oneItemPackage} and {mediaHashOf} are pure helpers). What
///      it can do comes from two roles the network of the test instance grants it after
///      deployment, each with no delay, and each revocable at once:
///      - `CURATION_SIGNER` (role 4). The curation verifier accepts a contract as a signer
///        through ERC-1271. {isValidSignature} answers yes for exactly one kind of digest: the
///        verifier's approval digest of a package root with the evidence hash {evidenceOf}
///        gives for it, at the gate's current signer epoch. So anyone can register any root with
///        `PackageRegistry.registerPackage(root, evidenceOf(root), attestationOf(root))`. Every
///        later step keeps its own rule: each party of an item still signs its acceptance, and
///        the lead artist still signs each move, with its own wallet.
///      - `PLATFORM` (role 8). {createCollection} forwards to `Stream6529.createCollection`.
///        The role also maps to other platform functions; the gate has no code that calls them.
///      To close the gate the network revokes the two roles, or calls the verifier's
///      `disableSigner` with the gate's address; `PackageRegistry.killSignerApprovals` also
///      stops the packages the gate approved before.
contract SepoliaOpenGate is IERC1271 {
    /// @notice Sepolia's chain ID.
    uint256 public constant SEPOLIA_CHAIN_ID = 11_155_111;
    /// @notice The chain ID of a local development chain (anvil, a forge test).
    uint256 public constant LOCAL_CHAIN_ID = 31_337;
    /// @dev What ERC-1271 answers for a signature that is not valid.
    bytes4 private constant NOT_VALID = 0xffffffff;

    /// @notice The curation verifier whose approval digests the gate answers for.
    IOpenGateVerifier public immutable verifier;
    /// @notice The 6529 Stream contract {createCollection} forwards to.
    IOpenGateStream public immutable stream;

    /// @notice `creator` created collection `collectionId` through the gate.
    /// @param collectionId The new collection of {stream}.
    /// @param creator The wallet that called {createCollection}.
    /// @param name The collection's name.
    /// @param metadataHash The hash of the collection's metadata document.
    event CollectionOpened(
        uint256 indexed collectionId, address indexed creator, string name, bytes32 metadataHash
    );

    /// @notice The chain is neither Sepolia nor a local development chain.
    /// @param chainId The chain's ID.
    error NotATestChain(uint256 chainId);
    /// @notice An address given to the constructor has no code.
    /// @param account The address.
    error NotAContract(address account);

    /// @param verifier_ The test instance's curation verifier (`CurationVerifier` in its
    ///        deployment record).
    /// @param stream_ The test instance's `Stream6529`.
    constructor(address verifier_, address stream_) {
        _requireTestChain();
        if (verifier_.code.length == 0) revert NotAContract(verifier_);
        if (stream_.code.length == 0) revert NotAContract(stream_);
        verifier = IOpenGateVerifier(verifier_);
        stream = IOpenGateStream(stream_);
    }

    /// @notice Creates a collection of {stream} for the caller. Anyone may call it. It needs the
    ///         gate to hold the `PLATFORM` role; without it the Stream refuses the call.
    /// @dev A collection has no owner in 6529 Stream: an item of any package may name any
    ///      collection. The event only records who asked for it.
    /// @param name The collection's name.
    /// @param metadataHash The hash of the collection's metadata document.
    /// @return collectionId The new collection's ID.
    function createCollection(string calldata name, bytes32 metadataHash)
        external
        returns (uint256 collectionId)
    {
        _requireTestChain();
        collectionId = stream.createCollection(name, metadataHash);
        emit CollectionOpened(collectionId, msg.sender, name, metadataHash);
    }

    /// @notice What to pass to `PackageRegistry.registerPackage` to register `packageRoot`
    ///         through the gate.
    /// @param packageRoot The package root.
    /// @return evidenceHash The evidence hash to pass ({evidenceOf}).
    /// @return attestation The attestation to pass: `abi.encode(address(this), packageRoot as
    ///         32 bytes)`.
    function attestationOf(bytes32 packageRoot)
        external
        view
        returns (bytes32 evidenceHash, bytes memory attestation)
    {
        return (evidenceOf(packageRoot), abi.encode(address(this), abi.encodePacked(packageRoot)));
    }

    /// @notice The hashes of a package of one item, for a tool that would rather read them than
    ///         compute them (`StreamHashing`). Pure: it reads and checks nothing.
    /// @param item The package's only item.
    /// @return itemHash The item's hash (`StreamHashing.itemHash`).
    /// @return packageRoot The root of the one-item package: the item's leaf. Its proof is empty.
    function oneItemPackage(PackageItem calldata item)
        external
        pure
        returns (bytes32 itemHash, bytes32 packageRoot)
    {
        itemHash = StreamHashing.itemHashCalldata(item);
        packageRoot = StreamHashing.leaf(itemHash);
    }

    /// @notice The hash of an ordered media list, which `PackageItem.mediaHash` commits to
    ///         (`StreamHashing.mediaHash`). Pure.
    /// @param media The media files, primary first.
    /// @return The media hash.
    function mediaHashOf(MediaFile[] calldata media) external pure returns (bytes32) {
        return StreamHashing.mediaHash(media);
    }

    /// @inheritdoc IERC1271
    /// @dev Valid only when `signature` is exactly a 32-byte package root and `hash` is the
    ///      verifier's approval digest of that root, with the evidence hash {evidenceOf} gives
    ///      and the gate's current signer epoch. Every other digest (an acceptance, a move, a
    ///      consent, a Safe transaction, anything of another contract) is not valid, so the gate
    ///      cannot stand in for a wallet anywhere else.
    function isValidSignature(bytes32 hash, bytes calldata signature)
        external
        view
        returns (bytes4)
    {
        if (!_isTestChain() || signature.length != 32) return NOT_VALID;
        bytes32 packageRoot = bytes32(signature);
        bytes32 expected = verifier.approvalDigest(
            packageRoot, evidenceOf(packageRoot), verifier.signerEpoch(address(this))
        );
        return hash == expected ? IERC1271.isValidSignature.selector : NOT_VALID;
    }

    /// @notice The evidence hash the gate approves `packageRoot` with. It is fixed per root, so
    ///         whoever registers a root first leaves the same record.
    /// @param packageRoot The package root.
    /// @return The evidence hash; never zero in practice (a hash).
    function evidenceOf(bytes32 packageRoot) public view returns (bytes32) {
        return keccak256(abi.encode("6529-stream/sepolia/open-gate/evidence", this, packageRoot));
    }

    function _isTestChain() private view returns (bool) {
        return block.chainid == SEPOLIA_CHAIN_ID || block.chainid == LOCAL_CHAIN_ID;
    }

    function _requireTestChain() private view {
        if (!_isTestChain()) revert NotATestChain(block.chainid);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ISplitWallet } from "../economics/interfaces/ISplitWallet.sol";
import { Splits } from "../economics/Splits.sol";
import { EditionRules } from "../editions/EditionRules.sol";
import { IArtistRegistry } from "../interfaces/IArtistRegistry.sol";
import { ICurationVerifier } from "../interfaces/ICurationVerifier.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IEntropyModule } from "../interfaces/IEntropyModule.sol";
import { IItemApprovals } from "../interfaces/IItemApprovals.sol";
import { IPackageRegistry } from "../interfaces/IPackageRegistry.sol";
import { IRevokedRoots } from "../interfaces/IRevokedRoots.sol";
import { MintFacts, MintTerms, Slots } from "../interfaces/core/CoreTypes.sol";
import { IDirectory } from "../interfaces/core/IDirectory.sol";
import { IMintPolicy } from "../interfaces/core/IMintPolicy.sol";
import { IModuleSlots, IModules } from "../interfaces/core/IModules.sol";
import { IStream } from "../interfaces/core/IStream.sol";
import { IWorkFacts } from "../interfaces/core/IWorkFacts.sol";
import {
    CURRENCY_DEFAULT,
    CURRENCY_ETH,
    PRODUCT_STREAM,
    WorkTerms
} from "../interfaces/types/EconomicsTypes.sol";
import { ArtistIdentity } from "../interfaces/types/IdentityTypes.sol";
import { Limits } from "../interfaces/types/Limits.sol";
import {
    EditionTerms,
    ItemKind,
    MoveAuthorization,
    PackageItem,
    Party,
    PartyAcceptance,
    PartyRole,
    SeedPolicy,
    StreamMintRequest
} from "../interfaces/types/PackageTypes.sol";
import { Typehashes } from "../interfaces/types/Typehashes.sol";
import { StreamHashing } from "../interfaces/types/StreamHashing.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";
import { Dependency } from "../libraries/Dependency.sol";
import { SignatureVerifier } from "../libraries/SignatureVerifier.sol";
import { SpdxId } from "../stream/SpdxId.sol";

/// @title PackageRegistry
/// @notice The mint policy of 6529 Stream (`IMintPolicy`): approved package roots, party consent,
///         the lead artist's revocable "move to Stream", the item rules, VRF delivery, the terms
///         of each new work, and the content rules after an upheld dispute.
/// @dev Replaceable. Stream never calls it: a sale contract that is an active minter of the
///      bound Stream calls `authorize`, then passes the facts it answers to `IStream.mint`.
///
///      Single use. An item mints once because Stream refuses a second live token with the same
///      content hash. A burned work's content (`IStream.tokenOfContent` names a burned token)
///      mints again only after the network released it (`releaseContent`), only for an item
///      whose lead artist the release names, and never by the burned item itself, which the
///      release bars for good (`isBarred`). A release names the burned token it applies to, so a
///      content released, minted again and burned again needs a new release.
///
///      Replay protection never looks at signature bytes (a 65-byte signature and its 64-byte
///      ERC-2098 form both verify): a move spends a per-artist nonce, and an acceptance is
///      recorded once per (root, account). Move nonces live in a per-artist bitmap of 255 nonces
///      per word whose top bit is set on every write, so an artist's first 255 starts update a
///      slot that the identity-creating acceptance already wrote. Tools should use each artist's
///      nonces in order from 0.
///
///      Accounts. Every read of an artist (acceptance, move signatures, `register`, releases)
///      asks the accounts module the directory's ACCOUNTS slot names at that moment, so the
///      network's swap of that module reaches this registry at once.
///
///      Replacement. A mint policy that replaces another is deployed naming it as `previous`
///      (zero for the first). A root the replaced policy reports as revoked (`isRevoked`:
///      revoked there, revoked in advance, its signer's approvals killed, or revoked in a
///      policy that one replaced) is never registered here and is not live here, whenever
///      the revocation was made. The read forwards all gas, a shortfall reverts, and a
///      replaced policy that does not answer leaves every root refused. Nothing else is
///      inherited: approvals, acceptances and move nonces are this policy's own, and it
///      starts with no releases and no barred items. Content uniqueness still holds through
///      `IStream.tokenOfContent`, so a burned work's content stays unmintable until the
///      network releases it again in the replacement (`releaseContent`), which bars the
///      burned item there too; a release made here and not yet used must be made again.
///
///      Approvals are per root: revoking a root stops only that root. Disabling a curation
///      signer in the verifier stops future registrations; `killSignerApprovals` also stops
///      every package that signer approved before the kill.
///
///      Terms. Every work locks the 6529 Stream economics in force at its start
///      (`IEconomicsResolver.newWorkTerms`): the seller (the split wallet of the item's payees,
///      salt zero), the network's fee recipient and share, the royalty receiver (the seller
///      when the share is zero, else the split wallet of `Splits.royaltyPayees(seller,
///      feeRecipient, feeShare)`, salt zero) and the royalty rate. The rate is the network's
///      default at the start; no party signs it.
contract PackageRegistry is
    IPackageRegistry,
    IMintPolicy,
    IItemApprovals,
    IRevokedRoots,
    AccessManaged,
    EIP712
{
    /// @dev Move nonces per bitmap word; bit 255 of every written word is set.
    uint256 private constant NONCES_PER_WORD = 255;
    uint256 private constant SENTINEL = 1 << 255;
    /// @dev The binding name (`Bound`, `AlreadyBound`).
    bytes32 private constant STREAM = "STREAM";

    /// @dev `epoch` is the kill epoch at registration: the package stops authorizing once its
    ///      signer is killed at a later epoch.
    struct Package {
        PackageStatus status;
        address signer;
        uint64 epoch;
        bytes32 evidenceHash;
    }

    /// @dev A release of a burned token's content: the burned token and the artist it is for.
    struct Release {
        uint256 tokenId;
        uint256 beneficiary;
    }

    /// @notice The permanent directory: its ACCOUNTS slot names the accounts module this
    ///         registry asks at every use, so a swap of that module takes effect here at once.
    address public immutable directory;

    /// @inheritdoc IPackageRegistry
    IEconomicsResolver public immutable economics;
    /// @notice The deployment's CC0 text (`IWorkFacts.cc0TextFileId` of the bound Stream's
    ///         facts, which never changes): the text a CC0 item must name. Kept here so a start
    ///         does not read it from `StreamWorkFacts6529` each time; `bindStream` checks it is the
    ///         same.
    bytes32 public immutable cc0TextFileId;
    /// @notice The mint policy this one replaces (zero for the first): a root it reports as
    ///         revoked is refused here.
    address public immutable previous;
    /// @inheritdoc IPackageRegistry
    ICurationVerifier public verifier;
    /// @inheritdoc IPackageRegistry
    address public stream;
    /// @dev The number of kills so far (`killSignerApprovals`).
    uint64 private _killEpoch;
    /// @inheritdoc IPackageRegistry
    address public entropyModule;
    /// @dev The verifier's pinned code hash, checked again at every registration.
    bytes32 private _verifierCodeHash;

    mapping(bytes32 root => Package) private _packages;
    mapping(bytes32 root => mapping(address account => uint256 artistId)) private _acceptedAs;
    mapping(uint256 artistId => mapping(uint256 word => uint256 bits)) private _moveNonces;
    /// @dev Verifiers replaced by `setVerifier`: never installable again.
    mapping(address verifier => bool) private _retired;
    /// @dev The kill epoch of each curation signer's latest kill, zero if never killed.
    mapping(address signer => uint64) private _killedAt;
    mapping(address token => mapping(bytes32 contentHash => Release)) private _releases;
    /// @inheritdoc IMintPolicy
    mapping(bytes32 itemHash => bool) public isBarred;

    /// @param authority_ The AccessManager that governs this registry.
    /// @param verifier_ The initial curation verifier.
    /// @param verifierCodeHash The reviewed code hash `verifier_` must have.
    /// @param directory_ The permanent directory (`IDirectory`, immutable). The accounts module
    ///        its ACCOUNTS slot names must bind this registry as its only `register` caller.
    /// @param economics_ The economics resolver (immutable): the terms of new works.
    /// @param entropyModule_ The VRF entropy module, or zero (VRF items are then refused).
    /// @param cc0TextFileId_ The deployment's CC0 text file (`IWorkFacts.cc0TextFileId`).
    /// @param previous_ The mint policy this one replaces, or zero for the first. It must
    ///        declare `IRevokedRoots` (ERC-165).
    constructor(
        address authority_,
        ICurationVerifier verifier_,
        bytes32 verifierCodeHash,
        address directory_,
        IEconomicsResolver economics_,
        address entropyModule_,
        bytes32 cc0TextFileId_,
        address previous_
    )
        AccessManaged(authority_)
        EIP712(Typehashes.PACKAGE_REGISTRY_NAME, Typehashes.DOMAIN_VERSION)
    {
        Dependency.check(directory_, type(IDirectory).interfaceId);
        Dependency.check(address(economics_), type(IEconomicsResolver).interfaceId);
        directory = directory_;
        economics = economics_;
        cc0TextFileId = cc0TextFileId_;
        previous = previous_;
        if (previous_ != address(0)) {
            Dependency.check(previous_, type(IRevokedRoots).interfaceId);
        }
        _setVerifier(verifier_, verifierCodeHash);
        _setEntropyModule(entropyModule_);
    }

    // ------------------------------------------------------------------------------ wiring

    /// @inheritdoc IPackageRegistry
    function bindStream(address target) external restricted {
        if (stream != address(0)) revert AlreadyBound(STREAM);
        Dependency.check(target, type(IStream).interfaceId);
        if (IWorkFacts(IStream(target).facts()).cc0TextFileId() != cc0TextFileId) {
            revert Dependency.InvalidDependency(target);
        }
        stream = target;
        emit Bound(STREAM, target);
    }

    /// @inheritdoc IPackageRegistry
    function setEntropyModule(address expected, address next) external restricted {
        if (entropyModule != expected) revert ExpectedValueMismatch();
        _setEntropyModule(next);
    }

    // ----------------------------------------------------------------------------- packages

    /// @inheritdoc IPackageRegistry
    /// @dev A root a replaced policy reports as revoked reverts with `PackageNotApproved`.
    function registerPackage(bytes32 packageRoot, bytes32 evidenceHash, bytes calldata attestation)
        external
    {
        Package storage p = _packages[packageRoot];
        if (p.status != PackageStatus.NONE) revert PackageExists(packageRoot);
        if (_revokedBefore(packageRoot)) revert PackageNotApproved(packageRoot);
        ICurationVerifier v = verifier;
        Dependency.checkUnchanged(address(v), _verifierCodeHash);
        (bool approved, address signer) = v.isApproved(packageRoot, evidenceHash, attestation);
        if (!approved || evidenceHash == 0) revert NotApproved(packageRoot);
        (p.status, p.signer, p.epoch) = (PackageStatus.APPROVED, signer, _killEpoch);
        p.evidenceHash = evidenceHash;
        emit PackageRegistered(packageRoot, evidenceHash, address(v), signer);
    }

    /// @inheritdoc IPackageRegistry
    /// @dev Final. A root not yet registered may be revoked in advance, and then can never be
    ///      registered, so a leaked attestation can be stopped before anyone submits it.
    function revokePackage(bytes32 packageRoot, bytes32 reasonHash) external restricted {
        Package storage p = _packages[packageRoot];
        if (p.status == PackageStatus.REVOKED) revert PackageNotApproved(packageRoot);
        p.status = PackageStatus.REVOKED;
        emit PackageRevoked(packageRoot, reasonHash);
    }

    /// @inheritdoc IPackageRegistry
    /// @dev The root must be approved. The artist registry checks the proof: the account itself
    ///      when it has no artist ID yet (the acceptance then creates the identity, artist ID
    ///      `uint160(account)`), otherwise any wallet of its account; the profile fields must
    ///      match the record. A repeat is a no-op.
    function acceptPackage(
        bytes32 packageRoot,
        PartyAcceptance calldata acceptance,
        bytes calldata proof
    ) external returns (uint256 artistId) {
        _requireApproved(packageRoot);
        SignatureVerifier.checkDeadline(acceptance.deadline);
        address account = acceptance.account;
        IArtistRegistry artists = _artists();
        artistId = artists.artistIdOf(account);
        artists.requireSigned(
            uint256(uint160(account)), acceptanceDigest(packageRoot, acceptance), proof
        );
        mapping(address => uint256) storage accepted = _acceptedAs[packageRoot];
        if (accepted[account] != 0) return accepted[account];
        if (artistId != 0) {
            (ArtistIdentity memory identity,) = artists.artist(artistId);
            if (
                identity.profileId != acceptance.profileId
                    || identity.profileDocHash != acceptance.profileDocHash
            ) revert ProfileMismatch(artistId);
            accepted[account] = artistId;
            emit PackageAccepted(packageRoot, artistId, account);
        } else {
            artistId = uint256(uint160(account));
            accepted[account] = artistId;
            _moveNonces[artistId][0] |= SENTINEL;
            emit PackageAccepted(packageRoot, artistId, account);
            if (
                artists.register(account, acceptance.profileId, acceptance.profileDocHash)
                    != artistId
            ) revert Dependency.InvalidDependency(address(artists));
        }
    }

    /// @inheritdoc IPackageRegistry
    function revokeMove(uint256 artistId, uint256 nonce) external {
        if (!_artists().isWallet(artistId, msg.sender)) revert NotAuthority(artistId, msg.sender);
        _spendMoveNonce(artistId, nonce);
        emit MoveRevoked(artistId, nonce);
    }

    /// @inheritdoc IPackageRegistry
    /// @dev The replaced verifier is retired: it, the current verifier and every verifier
    ///      retired before revert with `Dependency.InvalidDependency`.
    function setVerifier(ICurationVerifier expected, ICurationVerifier next, bytes32 nextCodeHash)
        external
        restricted
    {
        if (address(verifier) != address(expected)) revert ExpectedValueMismatch();
        if (address(next) == address(expected) || _retired[address(next)]) {
            revert Dependency.InvalidDependency(address(next));
        }
        _retired[address(expected)] = true;
        _setVerifier(next, nextCodeHash);
    }

    /// @inheritdoc IPackageRegistry
    function killSignerApprovals(address signer) external restricted {
        uint64 epoch = ++_killEpoch;
        _killedAt[signer] = epoch;
        emit SignerApprovalsKilled(signer, epoch);
    }

    // --------------------------------------------------------------------------- the policy

    /// @inheritdoc IMintPolicy
    /// @dev `request` is `abi.encode(StreamMintRequest)`. Checks, in order: `token` is the bound
    ///      Stream and the caller one of its active minters; the item rules; the root is live;
    ///      the proof places the item; content, seed and edition fields; every party accepted
    ///      the root; a wallet of the lead's account signed the move, unexpired, on an unused
    ///      nonce (spent here); the content rules after a burn; a VRF item's delivered seed.
    function authorize(address token, bytes calldata request)
        external
        returns (MintFacts memory facts, MintTerms memory terms)
    {
        if (token != stream || token == address(0) || !IModules(token).isMinter(msg.sender)) {
            revert NotSaleContract(token, msg.sender);
        }
        StreamMintRequest calldata req = _request(request);
        PackageItem calldata item = req.item;
        _checkItem(item);
        bytes32 root = req.packageRoot;
        _requireApproved(root);
        bytes32 itemHash = StreamHashing.itemHashCalldata(item);
        if (
            req.proof.length > Limits.MAX_PROOF_DEPTH
                || !MerkleProof.verifyCalldata(req.proof, root, StreamHashing.leaf(itemHash))
        ) revert ItemNotInPackage(root, itemHash);
        _checkTerms(item, itemHash);
        uint256 artistId = _checkParties(root, item, itemHash, true);
        terms.creator = _useMove(root, itemHash, artistId, req.move);
        _checkContent(token, item.contentHash, itemHash, artistId);
        _fill(facts, terms, item, itemHash, artistId, root);
        facts.seed = _seed(item);
    }

    /// @inheritdoc IMintPolicy
    /// @dev The check to run on an item before anyone signs: an item that breaks a rule can be
    ///      approved and accepted, and is refused only when its sale starts. It runs every item
    ///      check of `authorize`, with the same errors: the item rules, the content, seed and
    ///      edition fields, and the party and payee rules. It does not run the others: an
    ///      approved root, a proof, the parties' acceptances, the move, a VRF item's delivered
    ///      seed (the seed reads zero until it is delivered), and the content rules
    ///      (`ContentUsed`, `ContentReserved`: content a live token holds, or reserved after a
    ///      burn), which depend on what was minted and are read from the token. A party that has not accepted the root counts as the artist
    ///      it would be accepted as: its artist ID, or its own address as a number while it has
    ///      none, so the item of a new artist can be checked before any acceptance. The creator
    ///      is the lead's active authority now, or the lead's own address while it has no
    ///      identity.
    function preview(address token, bytes calldata request)
        external
        view
        returns (MintFacts memory facts, MintTerms memory terms)
    {
        token;
        StreamMintRequest calldata req = _request(request);
        PackageItem calldata item = req.item;
        _checkItem(item);
        bytes32 itemHash = StreamHashing.itemHashCalldata(item);
        _checkTerms(item, itemHash);
        uint256 artistId = _checkParties(req.packageRoot, item, itemHash, false);
        _fill(facts, terms, item, itemHash, artistId, req.packageRoot);
        // A lead that accepted this root has an identity; for any other the accounts module says.
        IArtistRegistry artists = _artists();
        address lead = item.parties[0].account;
        terms.creator = _acceptedAs[req.packageRoot][lead] == 0 && artists.artistIdOf(lead) == 0
            ? lead
            : artists.activeAuthorityOf(artistId);
        if (item.seedPolicy == uint8(SeedPolicy.ARTIST)) {
            facts.seed = item.seed;
        } else if (item.seedPolicy == uint8(SeedPolicy.VRF)) {
            IEntropyModule entropy = IEntropyModule(entropyModule);
            if (entropy.isDeliveredContent(item.contentHash)) {
                facts.seed = entropy.seedOfContent(item.contentHash);
            }
        }
    }

    /// @inheritdoc IMintPolicy
    /// @dev The network, after an upheld dispute burned the token in its sale. `token` must be
    ///      the bound Stream, the token burned and the content its own (`ContentUsed`
    ///      otherwise); the beneficiary a registered artist (`IArtistRegistry.UnknownArtist`).
    ///      A later release of the same burned token replaces the beneficiary.
    function releaseContent(
        address token,
        uint256 tokenId,
        bytes32 contentHash,
        uint256 beneficiary
    ) external restricted {
        if (
            token != stream || tokenId == 0 || IStream(token).tokenOfContent(contentHash) != tokenId
                || _isLive(token, tokenId)
        ) revert ContentUsed(contentHash, tokenId);
        if (beneficiary > type(uint160).max || _artists().authorityOf(beneficiary) == address(0)) {
            revert IArtistRegistry.UnknownArtist(beneficiary);
        }
        _releases[token][contentHash] = Release(tokenId, beneficiary);
        isBarred[IStream(token).workOf(tokenId).itemHash] = true;
        emit ContentReleased(token, tokenId, contentHash, beneficiary);
    }

    /// @inheritdoc IMintPolicy
    /// @dev Zero once the released token's content minted again (the release is used up).
    function releasedTo(address token, bytes32 contentHash) public view returns (uint256) {
        Release storage r = _releases[token][contentHash];
        if (r.tokenId == 0 || IStream(token).tokenOfContent(contentHash) != r.tokenId) return 0;
        return r.beneficiary;
    }

    // -------------------------------------------------------------------------------- views

    /// @inheritdoc IItemApprovals
    function isApprovedItem(bytes32 packageRoot, bytes32 itemHash, bytes32[] calldata proof)
        external
        view
        returns (bool)
    {
        return _isLiveRoot(packageRoot) && proof.length <= Limits.MAX_PROOF_DEPTH
            && MerkleProof.verifyCalldata(proof, packageRoot, StreamHashing.leaf(itemHash));
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IPackageRegistry).interfaceId
            || interfaceId == type(IItemApprovals).interfaceId
            || interfaceId == type(IRevokedRoots).interfaceId
            || interfaceId == type(IMintPolicy).interfaceId;
    }

    /// @inheritdoc IRevokedRoots
    function isRevoked(bytes32 packageRoot) public view returns (bool) {
        Package storage p = _packages[packageRoot];
        PackageStatus status = p.status;
        return status == PackageStatus.REVOKED || (status == PackageStatus.APPROVED && _killed(p))
            || _revokedBefore(packageRoot);
    }

    /// @inheritdoc IPackageRegistry
    function artistRegistry() external view returns (address) {
        return address(_artists());
    }

    /// @inheritdoc IPackageRegistry
    function packageOf(bytes32 packageRoot)
        external
        view
        returns (PackageStatus status, bytes32 evidenceHash, address signer)
    {
        Package storage p = _packages[packageRoot];
        status = isRevoked(packageRoot) ? PackageStatus.REVOKED : p.status;
        return (status, p.evidenceHash, p.signer);
    }

    /// @inheritdoc IPackageRegistry
    function consumedItemOf(bytes32 contentHash) external view returns (bytes32 itemHash) {
        address token = stream;
        uint256 tokenId = IStream(token).tokenOfContent(contentHash);
        if (tokenId == 0 || _releases[token][contentHash].tokenId == tokenId) return 0;
        return IStream(token).workOf(tokenId).itemHash;
    }

    /// @inheritdoc IPackageRegistry
    function signerKilledAt(address signer) external view returns (uint64) {
        return _killedAt[signer];
    }

    /// @inheritdoc IPackageRegistry
    function acceptedAs(bytes32 packageRoot, address account) external view returns (uint256) {
        return _acceptedAs[packageRoot][account];
    }

    /// @inheritdoc IPackageRegistry
    function isMoveNonceUsed(uint256 artistId, uint256 nonce) external view returns (bool) {
        return _moveNonces[artistId][nonce / NONCES_PER_WORD] & _bit(nonce) != 0;
    }

    /// @notice The EIP-712 digest the lead artist signs to move an item to Stream.
    /// @param packageRoot The package root the item is consumed through.
    /// @param itemHash The item's hash (`StreamHashing.itemHash`).
    /// @param nonce The lead artist's move nonce; any unused `uint256`.
    /// @param deadline The Unix time in seconds after which the signature is expired.
    /// @return The `Typehashes.MOVE_TO_STREAM` digest in this registry's EIP-712 domain.
    function moveDigest(bytes32 packageRoot, bytes32 itemHash, uint256 nonce, uint64 deadline)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(abi.encode(Typehashes.MOVE_TO_STREAM, packageRoot, itemHash, nonce, deadline))
        );
    }

    /// @notice The EIP-712 digest a party signs to accept a package root.
    /// @param packageRoot The package root to accept.
    /// @param acceptance The party's account, profile fields and signature deadline.
    /// @return The `Typehashes.PACKAGE_ACCEPTANCE` digest in this registry's EIP-712 domain.
    function acceptanceDigest(bytes32 packageRoot, PartyAcceptance calldata acceptance)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    Typehashes.PACKAGE_ACCEPTANCE,
                    packageRoot,
                    acceptance.account,
                    acceptance.profileId,
                    acceptance.profileDocHash,
                    acceptance.deadline
                )
            )
        );
    }

    // ----------------------------------------------------------------------------- internal

    /// @dev The accounts module the directory names now (`IArtistRegistry`: the current
    ///      `Accounts`). An empty slot makes every call that needs it revert.
    function _artists() private view returns (IArtistRegistry) {
        return IArtistRegistry(IModuleSlots(directory).moduleOf(Slots.ACCOUNTS));
    }

    /// @dev Decodes `abi.encode(StreamMintRequest)`.
    function _request(bytes calldata data) private pure returns (StreamMintRequest calldata req) {
        if (data.length < 160 || uint256(bytes32(data[:32])) != 32) revert InvalidMintRequest();
        // A view of the calldata in place; the compiler bounds-checks every member access.
        assembly ("memory-safe") {
            req := add(data.offset, 32)
        }
    }

    /// @dev Item rules: a sale kind, sold in ETH (`CURRENCY_ETH` or `CURRENCY_DEFAULT`, which is
    ///      ETH at launch); a lead party; a known seed policy coherent with its seed, and a VRF
    ///      item only with an entropy module; a license ID that follows the `SpdxId` rule; a CC0
    ///      license naming the deployment's CC0 text (`IWorkFacts.cc0TextFileId`), the rule
    ///      `StreamWorkFacts6529.open` enforces. The media rules of `StreamWorkFacts6529.open` (one
    ///      to `MAX_MEDIA_FILES` files, the primary first with the content hash, each registered in
    ///      the content store with its stated SHA-256) cannot be checked here, since the request
    ///      carries only the media commitment: curation checks them before it signs a package, and
    ///      `SaleStarter` opens the record in the same transaction as the start.
    function _checkItem(PackageItem calldata item) private view {
        address currency = item.sale.currency;
        if (item.sale.saleKind == 0 || (currency != CURRENCY_ETH && currency != CURRENCY_DEFAULT)) {
            revert InvalidItemSale();
        }
        if (item.parties.length == 0) revert InvalidLeadArtist();
        uint8 policy = item.seedPolicy;
        if (
            policy > uint8(SeedPolicy.VRF)
                || (policy == uint8(SeedPolicy.ARTIST)) != (item.seed != 0)
                || (policy == uint8(SeedPolicy.VRF) && entropyModule == address(0))
        ) revert InvalidSeedPolicy();
        if (!SpdxId.isValidCalldata(item.license.spdxId)) revert InvalidLicenseId();
        // `StreamWorkFacts6529.open` refuses a CC0 item whose text is not the deployment's CC0
        // text, and takes only the exact item a token was minted from: such a token could never get
        // a record. The text is compared first, so an item naming the CC0 text costs no more.
        if (
            item.license.textFileId != cc0TextFileId
                && StreamHashing.licenseKey(item.license.spdxId) == StreamHashing.CC0_LICENSE_KEY
        ) revert InvalidLicenseId();
    }

    /// @dev Fills the facts and terms both `authorize` and `preview` answer, from the item and
    ///      the 6529 Stream economics now (`newWorkTerms`), which must be usable: a fee share
    ///      below 100,000 with a fee recipient that is neither zero nor the seller, or no fee,
    ///      and a rate of at most 100,000 (`InvalidWorkTerms`).
    function _fill(
        MintFacts memory facts,
        MintTerms memory terms,
        PackageItem calldata item,
        bytes32 itemHash,
        uint256 artistId,
        bytes32 root
    ) private view {
        WorkTerms memory w = economics.newWorkTerms(PRODUCT_STREAM, item.payees);
        if (
            w.royaltyRate > Splits.DENOMINATOR || w.feeShare >= Splits.DENOMINATOR
                || (w.feeShare != 0 && (w.feeRecipient == address(0) || w.feeRecipient == w.seller))
        ) revert InvalidWorkTerms();
        facts.itemHash = itemHash;
        facts.contentHash = item.contentHash;
        facts.artistId = artistId;
        facts.collectionId = item.collectionId;
        facts.kind = item.kind;
        facts.seedPolicy = item.seedPolicy;
        facts.royaltyReceiver = w.royaltyReceiver;
        // Checked above: at most 100,000.
        // forge-lint: disable-next-line(unsafe-typecast)
        facts.royaltyRate = uint24(w.royaltyRate);
        facts.packageRoot = root;
        facts.mediaHash = item.mediaHash;
        facts.recordFileId = item.recordFileId;
        facts.seller = w.seller;
        terms.saleKind = item.sale.saleKind;
        terms.params = item.sale.params;
        terms.seller = w.seller;
        terms.feeRecipient = w.feeRecipient;
        terms.feeShare = w.feeShare;
    }

    /// @dev The work's seed: the artist's for an ARTIST item, the delivered one for a VRF item
    ///      (`SeedNotDelivered` before delivery), zero otherwise.
    function _seed(PackageItem calldata item) private view returns (bytes32) {
        if (item.seedPolicy == uint8(SeedPolicy.ARTIST)) return item.seed;
        if (item.seedPolicy != uint8(SeedPolicy.VRF)) return 0;
        IEntropyModule entropy = IEntropyModule(entropyModule);
        if (!entropy.isDeliveredContent(item.contentHash)) {
            revert SeedNotDelivered(StreamHashing.itemHashCalldata(item));
        }
        return entropy.seedOfContent(item.contentHash);
    }

    /// @dev The content rules after a burn: when `tokenOfContent` names a token (the content was
    ///      minted before), the item may mint only if the release for that very token names the
    ///      lead artist and the item is not barred. A live token is refused here too (Stream
    ///      would refuse it anyway).
    function _checkContent(address token, bytes32 contentHash, bytes32 itemHash, uint256 artistId)
        private
        view
    {
        uint256 prior = IStream(token).tokenOfContent(contentHash);
        if (prior == 0) return;
        Release storage r = _releases[token][contentHash];
        if (r.tokenId != prior || isBarred[itemHash]) revert ContentUsed(contentHash, prior);
        if (r.beneficiary != artistId) revert ContentReserved(contentHash, r.beneficiary);
    }

    /// @dev Whether a token is live (not burned): `ownerOf` answers for a live token and
    ///      reverts for a burned one.
    function _isLive(address token, uint256 tokenId) private view returns (bool) {
        try IERC721(token).ownerOf(tokenId) returns (address) {
            return true;
        } catch {
            return false;
        }
    }

    function _requireApproved(bytes32 packageRoot) private view {
        if (!_isLiveRoot(packageRoot)) revert PackageNotApproved(packageRoot);
    }

    /// @dev Approved here, its signer's approvals not killed since it was registered, and not
    ///      reported as revoked by a replaced policy.
    function _isLiveRoot(bytes32 packageRoot) private view returns (bool) {
        Package storage p = _packages[packageRoot];
        return p.status == PackageStatus.APPROVED && !_killed(p) && !_revokedBefore(packageRoot);
    }

    /// @dev Whether the approvals of the package's signer were killed after it was registered.
    function _killed(Package storage p) private view returns (bool) {
        uint64 epoch = p.epoch;
        return epoch != _killEpoch && _killedAt[p.signer] > epoch;
    }

    /// @dev Whether the policy this one replaces reports the root as revoked (`isRevoked`,
    ///      which asks the policy it replaced in turn). The read forwards all gas
    ///      (`BoundedCall.tryReadWordAll`): a shortfall reverts, and a policy that does not
    ///      answer exactly one word counts as "revoked".
    function _revokedBefore(bytes32 packageRoot) private view returns (bool) {
        address replaced = previous;
        if (replaced == address(0)) return false;
        (bool ok, bytes32 word) = BoundedCall.tryReadWordAll(
            replaced, abi.encodeCall(IRevokedRoots.isRevoked, (packageRoot))
        );
        return !ok || word != 0;
    }

    /// @dev Content, seed and edition fields: a nonzero content hash; an artist seed exactly
    ///      under `SeedPolicy.ARTIST`; an ORIGINAL with empty edition terms; an EDITION_MASTER
    ///      with edition terms `EditionRules.isValid` accepts.
    function _checkTerms(PackageItem calldata item, bytes32 itemHash) private pure {
        EditionTerms calldata e = item.edition;
        bool bad = item.contentHash == 0
            || (item.seedPolicy == uint8(SeedPolicy.ARTIST)) == (item.seed == 0)
            || item.kind > uint8(ItemKind.EDITION_MASTER);
        if (item.kind == uint8(ItemKind.ORIGINAL)) {
            bad = bad || e.maxCount != 0 || e.currency != address(0) || e.saleKind != 0
                || e.params.length != 0;
        } else {
            bad = bad || !EditionRules.isValid(e);
        }
        if (bad) revert InvalidItem(itemHash);
    }

    /// @dev Every party accepted the root and is a distinct artist; the lead is an ARTIST; the
    ///      payee list is canonical (strictly increasing `(artistId, account)`, exactly one of the
    ///      two set, nonzero shares summing to `Splits.DENOMINATOR`, no more payees than parties)
    ///      and every payee is a party by account or by artist ID. The lead is paid only through
    ///      its account (artist-resolved), never as a fixed payee. With `acceptances` false (a
    ///      preview) a party that has not accepted the root is not refused: it counts as the
    ///      artist it would be accepted as (`acceptPackage`): its artist ID, or its own address
    ///      as a number while it has none.
    /// @return leadId The lead artist's ID.
    function _checkParties(
        bytes32 packageRoot,
        PackageItem calldata item,
        bytes32 itemHash,
        bool acceptances
    ) private view returns (uint256 leadId) {
        Party[] calldata parties = item.parties;
        ISplitWallet.Payee[] calldata payees = item.payees;
        uint256 n = parties.length;
        if (
            n == 0 || n > Limits.MAX_PARTIES || parties[0].role != uint8(PartyRole.ARTIST)
                || payees.length == 0 || payees.length > n
        ) revert InvalidItem(itemHash);
        mapping(address => uint256) storage accepted = _acceptedAs[packageRoot];
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            if (parties[i].role > uint8(PartyRole.COLLABORATOR)) revert InvalidItem(itemHash);
            address account = parties[i].account;
            uint256 id = accepted[account];
            if (id == 0) {
                if (acceptances) revert PartyNotAccepted(packageRoot, account);
                id = _artists().artistIdOf(account);
                if (id == 0) id = uint256(uint160(account));
            }
            for (uint256 j; j < i; ++j) {
                if (ids[j] == id) revert InvalidItem(itemHash);
            }
            ids[i] = id;
        }
        uint256 sum = 0;
        address lead = parties[0].account;
        for (uint256 i; i < payees.length; ++i) {
            ISplitWallet.Payee calldata p = payees[i];
            bool ordered = i == 0 || p.artistId > payees[i - 1].artistId
                || (p.artistId == payees[i - 1].artistId && p.account > payees[i - 1].account);
            if (
                !ordered || (p.artistId == 0) == (p.account == address(0)) || p.share == 0
                    || p.account == lead || !_isParty(parties, ids, p)
            ) revert InvalidItem(itemHash);
            sum += p.share;
        }
        if (sum != Splits.DENOMINATOR) revert InvalidItem(itemHash);
        return ids[0];
    }

    function _isParty(Party[] calldata parties, uint256[] memory ids, ISplitWallet.Payee calldata p)
        private
        pure
        returns (bool)
    {
        for (uint256 j; j < ids.length; ++j) {
            if (p.artistId == 0 ? parties[j].account == p.account : ids[j] == p.artistId) {
                return true;
            }
        }
        return false;
    }

    /// @dev Checks the deadline, spends the nonce and checks that a wallet of the lead's account
    ///      signed; returns that wallet. The proof is `abi.encodePacked(wallet, signature)`. When
    ///      it names the account's root and the root may act now (`activeAuthorityOf`), the
    ///      signature is checked here; any other wallet is checked by the artist registry.
    function _useMove(
        bytes32 packageRoot,
        bytes32 itemHash,
        uint256 artistId,
        MoveAuthorization calldata move
    ) private returns (address wallet) {
        SignatureVerifier.checkDeadline(move.deadline);
        _spendMoveNonce(artistId, move.nonce);
        bytes32 digest = moveDigest(packageRoot, itemHash, move.nonce, move.deadline);
        bytes calldata proof = move.signature;
        IArtistRegistry artists = _artists();
        address root = artists.activeAuthorityOf(artistId);
        if (root != address(0) && proof.length >= 20 && address(bytes20(proof[:20])) == root) {
            SignatureVerifier.check(root, digest, proof[20:]);
            return root;
        }
        wallet = artists.requireSigned(artistId, digest, proof);
    }

    function _spendMoveNonce(uint256 artistId, uint256 nonce) private {
        mapping(uint256 => uint256) storage words = _moveNonces[artistId];
        uint256 word = nonce / NONCES_PER_WORD;
        uint256 bits = words[word];
        uint256 bit = _bit(nonce);
        if (bits & bit != 0) revert MoveNonceUsed(artistId, nonce);
        words[word] = bits | bit | SENTINEL;
    }

    function _setVerifier(ICurationVerifier next, bytes32 codeHash) private {
        Dependency.checkPinned(address(next), type(ICurationVerifier).interfaceId, codeHash);
        emit VerifierSet(address(verifier), address(next), codeHash);
        verifier = next;
        _verifierCodeHash = codeHash;
    }

    function _setEntropyModule(address next) private {
        if (next != address(0)) Dependency.check(next, type(IEntropyModule).interfaceId);
        emit EntropyModuleSet(entropyModule, next);
        entropyModule = next;
    }

    function _bit(uint256 nonce) private pure returns (uint256) {
        return uint256(1) << (nonce % NONCES_PER_WORD);
    }
}

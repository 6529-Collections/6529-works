// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistPayoutResolver } from "../economics/interfaces/IArtistPayoutResolver.sol";
import { ISplitFactory } from "../economics/interfaces/ISplitFactory.sol";
import { IAccounts } from "../interfaces/IAccounts.sol";
import { IArtistRegistry, IConsolidationSource } from "../interfaces/IArtistRegistry.sol";
import { IArtistRoleResolver } from "../interfaces/IArtistRoleResolver.sol";
import { IEditions } from "../interfaces/IEditions.sol";
import { IFederationRegistry } from "../interfaces/IFederationRegistry.sol";
import { IStatementLog } from "../interfaces/IStatementLog.sol";
import { IPackageRegistry } from "../interfaces/IPackageRegistry.sol";
import { IStream } from "../interfaces/IStream.sol";
import { ArtistIdentity, ChangeKind, PendingChange } from "../interfaces/types/IdentityTypes.sol";
import { Typehashes } from "../interfaces/types/Typehashes.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";
import { Dependency } from "../libraries/Dependency.sol";
import { ProtocolContracts } from "../libraries/ProtocolContracts.sol";
import { SignatureVerifier } from "../libraries/SignatureVerifier.sol";

/// @title ArtistRegistry
/// @notice The artist registry: artist accounts, their payout and profile, and the federation
///         directory (ADR 0001 sections 11 and 16). An account is a 6529 consolidated account:
///         its root wallet and every wallet consolidated with the root act for it with the same
///         rights. Every consumer asks this registry who may act for an account (`IAccounts`);
///         split wallets resolve artist-resolved payees through {payoutAddress}, and the
///         statement log asks {isArtist}. Its address never changes: split wallets pin it, and
///         the consolidation source is swapped inside it ({setConsolidationSource}).
/// @dev Who may act. The root always may, without any read of the consolidation source, so a
///      broken, reverting or repriced source never locks an account out. Any other wallet may
///      while the source says it is consolidated with the root, read live with `BoundedCall`'s
///      forward-all rule: a shortfall reverts, any other failure is "no". Nobody may while the
///      account is frozen or a network replacement is pending (and has not lapsed).
///
///      The consolidation source is replaceable code that answers, live, who may act for a
///      permanent account. That departs from the permanent rule that nothing permanent takes
///      instruction from replaceable code; it is what the owner's account model needs. Its
///      limits: the root never depends on the source; replacing the source is a network action
///      at the 7-day class; a freeze stops an account at once.
///
///      Every waiting period is a compiled constant: the number is the guarantee.
contract ArtistRegistry is IArtistRegistry, AccessManaged, EIP712 {
    /// @notice How long an account's own change waits before it may execute.
    uint48 public constant OWN_CHANGE_DELAY = 2 days;
    /// @notice The public notice of a network replacement before it may execute.
    uint48 public constant REPLACEMENT_NOTICE = 14 days;
    /// @notice A contested replacement lapses this long after its contest unless the network
    ///         resolves it.
    uint48 public constant CONTEST_LAPSE = 90 days;
    /// @notice How long a freeze lasts.
    uint48 public constant FREEZE_PERIOD = 14 days;

    /// @dev Slot 0 holds everything {isWallet} needs: the root, the end of a freeze, whether a
    ///      replacement is pending and the federation delisting flag.
    struct Artist {
        address root;
        uint48 frozenUntil;
        bool replacing;
        bool delisted;
        address payout;
        uint64 nonce;
        bytes32 profileId;
        bytes32 profileDocHash;
    }

    /// @dev A federation directory entry; artist IDs fit 160 bits. One slot.
    struct Listing {
        uint160 artistId;
        FederationStatus status;
        uint32 feeShare;
    }

    mapping(uint256 artistId => Artist) private _artists;
    mapping(uint256 artistId => PendingChange) private _pending;
    mapping(bytes32 digest => bool) private _acceptanceUsed;
    mapping(address token => Listing) private _listings;

    /// @inheritdoc IArtistRegistry
    mapping(address account => uint256) public override artistIdOf;
    /// @inheritdoc IArtistRegistry
    mapping(address account => uint256) public override reservedFor;
    /// @inheritdoc IArtistRegistry
    IConsolidationSource public override consolidationSource;
    /// @inheritdoc IArtistRegistry
    bytes32 public override consolidationSourceCodeHash;
    /// @inheritdoc IArtistRegistry
    address public override packageRegistry;
    /// @inheritdoc IArtistRegistry
    address public override stream;
    /// @inheritdoc IArtistRegistry
    address public override federationRegistry;
    /// @inheritdoc IArtistRegistry
    address public override splitFactory;
    /// @inheritdoc IArtistRegistry
    address public override statementLog;

    /// @param initialAuthority The AccessManager.
    /// @param source The consolidation source (the v1 `ConsolidationAdapter`).
    /// @param sourceCodeHash The reviewed code hash of `source`.
    constructor(address initialAuthority, IConsolidationSource source, bytes32 sourceCodeHash)
        AccessManaged(initialAuthority)
        EIP712(Typehashes.ARTIST_REGISTRY_NAME, Typehashes.DOMAIN_VERSION)
    {
        _checkSource(source, sourceCodeHash);
        consolidationSource = source;
        consolidationSourceCodeHash = sourceCodeHash;
        emit ConsolidationSourceSet(address(0), address(source), sourceCodeHash);
    }

    // ----- wiring -----

    /// @inheritdoc IArtistRegistry
    function bindPackageRegistry(address target) external restricted {
        Dependency.check(target, type(IPackageRegistry).interfaceId);
        packageRegistry = _bind("PACKAGE_REGISTRY", packageRegistry, target);
    }

    /// @inheritdoc IArtistRegistry
    function setPackageRegistry(address expected, address next) external restricted {
        if (expected != packageRegistry) revert ExpectedValueMismatch();
        Dependency.check(next, type(IPackageRegistry).interfaceId);
        packageRegistry = next;
        emit PackageRegistrySet(expected, next);
    }

    /// @inheritdoc IArtistRegistry
    function bindStream(address target) external restricted {
        Dependency.check(target, type(IStream).interfaceId);
        stream = _bind("STREAM", stream, target);
    }

    /// @inheritdoc IArtistRegistry
    function bindFederationRegistry(address target) external restricted {
        Dependency.check(target, type(IFederationRegistry).interfaceId);
        federationRegistry = _bind("FEDERATION_REGISTRY", federationRegistry, target);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev A zero successor is refused, so the pointer never returns to the unbound state.
    function setFederationRegistry(address expected, address next) external restricted {
        if (expected != federationRegistry) revert ExpectedValueMismatch();
        Dependency.check(next, type(IFederationRegistry).interfaceId);
        federationRegistry = next;
        emit FederationRegistrySet(expected, next);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev The factory does not implement ERC-165, so only code and no EIP-7702 are checked.
    function bindSplitFactory(address target) external restricted {
        Dependency.check(target);
        splitFactory = _bind("SPLIT_FACTORY", splitFactory, target);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev The statement log does not implement ERC-165: code, no EIP-7702, and its
    ///      `artistResolver()` naming this registry are checked instead, read forwarding all gas.
    function bindStatementLog(address target) external restricted {
        Dependency.check(target);
        (bool ok, bytes32 resolver) =
            BoundedCall.tryReadWordAll(target, abi.encodeWithSignature("artistResolver()"));
        if (!ok || resolver != bytes32(uint256(uint160(address(this))))) {
            revert InvalidBinding(target);
        }
        statementLog = _bind("STATEMENT_LOG", statementLog, target);
    }

    /// @inheritdoc IArtistRegistry
    function setConsolidationSource(
        IConsolidationSource expected,
        IConsolidationSource next,
        bytes32 nextCodeHash
    ) external restricted {
        if (address(expected) != address(consolidationSource)) {
            revert ExpectedValueMismatch();
        }
        _checkSource(next, nextCodeHash);
        consolidationSource = next;
        consolidationSourceCodeHash = nextCodeHash;
        emit ConsolidationSourceSet(address(expected), address(next), nextCodeHash);
    }

    // ----- accounts -----

    /// @inheritdoc IArtistRegistry
    function register(address root, bytes32 profileId, bytes32 profileDocHash)
        external
        returns (uint256)
    {
        if (msg.sender != packageRegistry) revert UnboundCaller(msg.sender);
        return _create(root, profileId, profileDocHash);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev The package registry verifies the account's own acceptance before it calls
    ///      `register`; the federation registry is not trusted to, so the signature is checked
    ///      here, in this registry's domain.
    function registerFederated(
        address account,
        bytes32 profileId,
        bytes32 profileDocHash,
        uint64 deadline,
        bytes calldata signature
    ) external returns (uint256) {
        if (msg.sender != federationRegistry) {
            revert UnboundCaller(msg.sender);
        }
        SignatureVerifier.checkDeadline(deadline);
        SignatureVerifier.check(
            account, registrationDigest(account, profileId, profileDocHash, deadline), signature
        );
        return _create(account, profileId, profileDocHash);
    }

    function _create(address root, bytes32 profileId, bytes32 profileDocHash)
        private
        returns (uint256 artistId)
    {
        if (root == address(0) || !_payoutAllowed(root)) revert InvalidIdentity();
        if (artistIdOf[root] != 0 || reservedFor[root] != 0) revert AccountTaken(root);
        artistId = uint256(uint160(root));
        Artist storage a = _artists[artistId];
        (a.root, a.payout, a.profileId, a.profileDocHash) = (root, root, profileId, profileDocHash);
        artistIdOf[root] = artistId;
        emit ArtistRegistered(artistId, ArtistIdentity(root, root, profileId, profileDocHash));
    }

    /// @inheritdoc IArtistRegistry
    /// @dev Consumes the nonce. The signature is checked through {requireSigned}, so any wallet
    ///      of the account may sign and a frozen or replacing account cannot.
    function stageChange(
        uint256 artistId,
        ArtistIdentity calldata next,
        uint64 deadline,
        bytes calldata proof
    ) external {
        Artist storage a = _artist(artistId);
        if (_pending[artistId].kind != ChangeKind.NONE) revert ChangePending(artistId);
        _checkNext(artistId, next);
        if (next.root != a.root && !isWallet(artistId, next.root)) revert InvalidIdentity();
        SignatureVerifier.checkDeadline(deadline);
        requireSigned(artistId, changeDigest(artistId, next, a.nonce, deadline), proof);
        _stage(artistId, a, ChangeKind.OWN, next, bytes32(0), OWN_CHANGE_DELAY);
    }

    /// @inheritdoc IArtistRegistry
    function stageReplacement(
        uint256 artistId,
        ArtistIdentity calldata next,
        bytes32 evidenceHash,
        uint64 deadline,
        bytes calldata rootAcceptance
    ) external restricted {
        Artist storage a = _artist(artistId);
        if (evidenceHash == bytes32(0) || next.root == a.root) revert InvalidIdentity();
        _checkNext(artistId, next);
        ChangeKind pending = _pending[artistId].kind;
        if (pending == ChangeKind.REPLACEMENT) revert ChangePending(artistId);
        bytes32 digest = replacementDigest(artistId, next, evidenceHash, deadline);
        if (_acceptanceUsed[digest]) revert AcceptanceUsed(digest);
        SignatureVerifier.checkDeadline(deadline);
        SignatureVerifier.check(next.root, digest, rootAcceptance);
        _acceptanceUsed[digest] = true;
        emit ReplacementAcceptanceConsumed(artistId, digest);
        if (pending == ChangeKind.OWN) _clear(artistId, msg.sender, true);
        _stage(artistId, a, ChangeKind.REPLACEMENT, next, evidenceHash, REPLACEMENT_NOTICE);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev The caller is checked against the root directly (not through {isWallet}), so a
    ///      pending replacement, which blocks {isWallet}, does not stop its own contest.
    function cancelChange(uint256 artistId) external {
        PendingChange storage p = _pendingOf(artistId);
        Artist storage a = _artists[artistId];
        _requireUnfrozen(artistId, a);
        address root = a.root;
        if (msg.sender != root && !_consolidated(root, msg.sender)) {
            revert NotAuthorized(artistId, msg.sender);
        }
        if (p.kind == ChangeKind.OWN) return _clear(artistId, msg.sender, false);
        if (p.contestedAt != 0) return;
        // A contest happens during the notice; a late one could front-run a due execution.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= p.executableAt) {
            revert ContestWindowClosed(artistId, p.executableAt);
        }
        p.contestedAt = _now();
        bytes32 prior = _latestOutcome(artistId);
        p.priorOutcome = prior;
        emit ChangeContested(artistId, msg.sender, prior);
    }

    /// @inheritdoc IArtistRegistry
    function cancelReplacement(uint256 artistId) external restricted {
        if (_pending[artistId].kind != ChangeKind.REPLACEMENT) revert NoPendingChange(artistId);
        _clear(artistId, msg.sender, true);
    }

    /// @inheritdoc IArtistRegistry
    function cancelOwnChange(uint256 artistId) external restricted {
        if (_pending[artistId].kind != ChangeKind.OWN) revert NoPendingChange(artistId);
        _clear(artistId, msg.sender, true);
    }

    /// @inheritdoc IArtistRegistry
    function resolveContested(uint256 artistId, bool uphold, bytes32 outcomeRef)
        external
        restricted
    {
        PendingChange storage p = _pending[artistId];
        if (p.contestedAt == 0 || _lapsed(p)) revert NotContested(artistId);
        if (outcomeRef == bytes32(0) || outcomeRef != _latestOutcome(artistId)) {
            revert OutcomeNotRecorded(artistId, outcomeRef);
        }
        if (outcomeRef == p.priorOutcome) revert OutcomePredatesContest(artistId, outcomeRef);
        // forge-lint: disable-next-line(block-timestamp)
        if (uphold && block.timestamp < p.executableAt) {
            revert ChangeNotDue(artistId, p.executableAt);
        }
        bool executed = uphold && _apply(artistId, p);
        if (!uphold) _clear(artistId, msg.sender, true);
        emit ContestResolved(artistId, uphold, executed, outcomeRef);
    }

    /// @inheritdoc IArtistRegistry
    function expireContest(uint256 artistId) external {
        PendingChange storage p = _pending[artistId];
        if (p.contestedAt == 0) revert NotContested(artistId);
        if (!_lapsed(p)) revert ContestNotExpired(artistId, p.contestedAt + CONTEST_LAPSE);
        emit ContestExpired(artistId);
        _clear(artistId, address(this), false);
    }

    /// @inheritdoc IArtistRegistry
    function executeChange(uint256 artistId) external {
        PendingChange storage p = _pendingOf(artistId);
        if (p.contestedAt != 0) revert ReplacementContested(artistId);
        // Delays are wall-clock bounds; validator drift is immaterial.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < p.executableAt) revert ChangeNotDue(artistId, p.executableAt);
        _requireUnfrozen(artistId, _artists[artistId]);
        _apply(artistId, p);
    }

    /// @inheritdoc IArtistRegistry
    function revokeNonce(uint256 artistId) external {
        Artist storage a = _artist(artistId);
        if (!isWallet(artistId, msg.sender)) revert NotAuthorized(artistId, msg.sender);
        emit NonceRevoked(artistId, a.nonce++);
    }

    /// @inheritdoc IArtistRegistry
    function freeze(uint256 artistId) external restricted {
        Artist storage a = _artist(artistId);
        _requireUnfrozen(artistId, a);
        uint48 until = _now() + FREEZE_PERIOD;
        a.frozenUntil = until;
        emit AccountFrozen(artistId, until);
    }

    /// @inheritdoc IArtistRegistry
    function unfreeze(uint256 artistId) external restricted {
        _artist(artistId).frozenUntil = 0;
        emit AccountUnfrozen(artistId);
    }

    // ----- federation directory -----

    /// @inheritdoc IArtistRegistry
    /// @dev No list and no cap: each listing is its own slot, paid by its registrant;
    ///      enumeration is by events. A listing happens once per token, so the consent needs no
    ///      nonce.
    function listFederatedContract(FederatedListing calldata listing, bytes calldata consent)
        external
    {
        if (msg.sender != federationRegistry) revert UnboundCaller(msg.sender);
        uint256 artistId = listing.artistId;
        address token = listing.token;
        Artist storage a = _artist(artistId);
        SignatureVerifier.checkDeadline(listing.deadline);
        requireSigned(artistId, _listingDigest(listing), consent);
        address s = stream;
        address e = IStream(s).editions();
        if (
            a.delisted || _listings[token].status != FederationStatus.NONE
                || !Dependency.isInstallable(token) || _canonical(token, s, e)
                || _canonical(listing.partner, s, e) || _canonical(listing.feeRecipient, s, e)
        ) revert FederatedContractRefused(token);
        // A registered artist's ID is the uint160 of its first root.
        // forge-lint: disable-next-line(unsafe-typecast)
        _listings[token] = Listing(uint160(artistId), FederationStatus.ACTIVE, listing.feeShare);
        emit FederatedContractListed(
            artistId,
            token,
            token.codehash,
            listing.form,
            listing.partner,
            listing.feeShare,
            listing.feeRecipient
        );
    }

    /// @inheritdoc IArtistRegistry
    function setFederatedStatus(address token, FederationStatus status, bytes32 ref) external {
        if (msg.sender != federationRegistry) revert UnboundCaller(msg.sender);
        Listing storage l = _listings[token];
        FederationStatus current = l.status;
        if (current == FederationStatus.NONE || status == FederationStatus.NONE) {
            revert FederatedStatusRefused(token, current);
        }
        l.status = status;
        emit FederatedContractStatus(token, l.artistId, current, status, ref);
    }

    /// @inheritdoc IArtistRegistry
    function setFederationDelisted(uint256 artistId, bool delisted, bytes32 ref)
        external
        restricted
    {
        _artist(artistId).delisted = delisted;
        emit FederationDelistedSet(artistId, delisted, ref);
    }

    /// @inheritdoc IArtistRegistry
    function lowerFederatedFeeShare(address token, uint32 share) external restricted {
        Listing storage l = _listings[token];
        uint32 current = l.feeShare;
        if (l.status == FederationStatus.NONE || share >= current) {
            revert FeeShareNotLowered(token, current);
        }
        l.feeShare = share;
        emit FederatedFeeShareLowered(token, current, share);
    }

    // ----- IAccounts -----

    /// @inheritdoc IAccounts
    function isWallet(uint256 accountId, address wallet) public view returns (bool) {
        if (wallet == address(0)) return false;
        (uint256 id, Artist storage a) = _resolve(accountId);
        address root = a.root;
        if (root == address(0)) return id >> 160 == 0 && wallet == address(uint160(id));
        if (_blocked(id, a)) return false;
        return wallet == root || _consolidated(root, wallet);
    }

    /// @inheritdoc IAccounts
    /// @dev Reverts with `SignatureVerifier.InvalidSignature(wallet)` when the wallet may not act
    ///      for the account or did not sign (`InvalidSignature(address(0))` for a proof shorter
    ///      than an address).
    function requireSigned(uint256 accountId, bytes32 digest, bytes calldata proof)
        public
        view
        returns (address wallet)
    {
        if (proof.length < 20) revert SignatureVerifier.InvalidSignature(address(0));
        wallet = address(bytes20(proof[:20]));
        if (!isWallet(accountId, wallet)) revert SignatureVerifier.InvalidSignature(wallet);
        SignatureVerifier.check(wallet, digest, proof[20:]);
    }

    /// @inheritdoc IAccounts
    function requireConsent(uint256 accountId, bytes32 what, bytes calldata proof)
        external
        view
        returns (address wallet)
    {
        return requireSigned(accountId, consentDigest(msg.sender, what), proof);
    }

    /// @inheritdoc IAccounts
    function consentDigest(address subject, bytes32 what) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(Typehashes.ACCOUNT_CONSENT, subject, what)));
    }

    /// @inheritdoc IAccounts
    function frozenUntil(uint256 accountId) external view returns (uint48) {
        (, Artist storage a) = _resolve(accountId);
        return a.frozenUntil;
    }

    /// @inheritdoc IAccounts
    function isFederationDelisted(uint256 accountId) external view returns (bool) {
        (, Artist storage a) = _resolve(accountId);
        return a.delisted;
    }

    /// @inheritdoc IAccounts
    /// @dev The share recorded at listing, as lowered since. An unlisted token reads the largest
    ///      `uint32`, never zero, so a token taking the smaller of its own share and this one
    ///      keeps its own share until it is listed.
    function federatedFeeShare(address token) external view returns (uint32) {
        Listing storage l = _listings[token];
        return l.status == FederationStatus.NONE ? type(uint32).max : l.feeShare;
    }

    // ----- reads -----

    /// @inheritdoc IArtistRoleResolver
    /// @dev Resolves a 6529 Stream work (`IStream.artistOf`), or a 6529 Stream Editions edition
    ///      through its master, to the lead artist's account, and answers {isWallet}. Any other
    ///      subject returns false.
    function isArtist(address token, uint256 id, address account) external view returns (bool) {
        address s = stream;
        if (s == address(0) || token == address(0) || account == address(0)) return false;
        uint256 gasBefore = gasleft();
        if (token != s) {
            if (token != IStream(s).editions()) return false;
            try IEditions(token).masterOf(id) returns (
                address master, uint256 workId, bytes32 contentHash
            ) {
                // A well-formed answer names this Stream and the master's content.
                if (master != s || contentHash == bytes32(0)) return false;
                id = workId;
            } catch {
                _revertOnShortfall(token, gasBefore);
                return false;
            }
            gasBefore = gasleft();
        }
        try IStream(s).artistOf(id) returns (uint256 artistId) {
            return artistId != 0 && isWallet(artistId, account);
        } catch {
            _revertOnShortfall(s, gasBefore);
            return false;
        }
    }

    /// @inheritdoc IArtistPayoutResolver
    /// @dev Zero for an unknown artist, while the account is frozen, and while a pending change
    ///      would move the payout (a lapsed contest no longer counts).
    function payoutAddress(uint256 artistId) external view returns (address) {
        Artist storage a = _artists[artistId];
        // forge-lint: disable-next-line(block-timestamp)
        if (a.frozenUntil > block.timestamp) return address(0);
        address current = a.payout;
        PendingChange storage p = _pending[artistId];
        bool moves = p.kind != ChangeKind.NONE && p.next.payout != current && !_lapsed(p);
        return moves ? address(0) : current;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IArtistRoleResolver).interfaceId
            || interfaceId == type(IArtistPayoutResolver).interfaceId
            || interfaceId == type(IAccounts).interfaceId
            || interfaceId == type(IArtistRegistry).interfaceId;
    }

    /// @inheritdoc IArtistRegistry
    function artist(uint256 artistId)
        external
        view
        returns (ArtistIdentity memory identity, uint48 frozenUntil_)
    {
        Artist storage a = _artist(artistId);
        return (ArtistIdentity(a.root, a.payout, a.profileId, a.profileDocHash), a.frozenUntil);
    }

    /// @inheritdoc IArtistRegistry
    function authorityOf(uint256 artistId) external view returns (address) {
        return _artist(artistId).root;
    }

    /// @inheritdoc IArtistRegistry
    function activeAuthorityOf(uint256 artistId) external view returns (address) {
        Artist storage a = _artist(artistId);
        return _blocked(artistId, a) ? address(0) : a.root;
    }

    /// @inheritdoc IArtistRegistry
    function pendingChange(uint256 artistId) external view returns (PendingChange memory) {
        return _pending[artistId];
    }

    /// @inheritdoc IArtistRegistry
    function changeNonce(uint256 artistId) external view returns (uint256) {
        return _artists[artistId].nonce;
    }

    /// @inheritdoc IArtistRegistry
    function federatedListing(address token)
        external
        view
        returns (uint256 artistId, FederationStatus status)
    {
        Listing storage l = _listings[token];
        artistId = l.artistId;
        status = l.status;
        if (status == FederationStatus.ACTIVE && _artists[artistId].delisted) {
            status = FederationStatus.DELISTED;
        }
    }

    /// @notice The EIP-712 digest a wallet signs to consent to an account created through the
    ///         federation registry (`registerFederated`).
    /// @param account The consenting wallet.
    /// @param profileId The claimed 6529 profile ID.
    /// @param profileDocHash The profile document hash.
    /// @param deadline The Unix time in seconds after which the signature is expired.
    /// @return The `ArtistRegistration` digest in this registry's EIP-712 domain.
    function registrationDigest(
        address account,
        bytes32 profileId,
        bytes32 profileDocHash,
        uint64 deadline
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    Typehashes.ARTIST_REGISTRATION, account, profileId, profileDocHash, deadline
                )
            )
        );
    }

    /// @notice The EIP-712 digest of an account's own change.
    /// @param artistId The account to change.
    /// @param next The identity after the change.
    /// @param nonce The account's change nonce the signature binds (`changeNonce` when staged).
    /// @param deadline The Unix time in seconds after which the signature is expired.
    /// @return The `Typehashes.IDENTITY_CHANGE` digest in this registry's EIP-712 domain.
    function changeDigest(
        uint256 artistId,
        ArtistIdentity calldata next,
        uint256 nonce,
        uint64 deadline
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    Typehashes.IDENTITY_CHANGE,
                    artistId,
                    next.root,
                    next.payout,
                    next.profileId,
                    next.profileDocHash,
                    nonce,
                    deadline
                )
            )
        );
    }

    /// @notice The EIP-712 digest a new root signs to accept a network replacement.
    /// @param artistId The account to replace.
    /// @param next The identity after the replacement.
    /// @param evidenceHash The replacement's evidence hash.
    /// @param deadline The Unix time in seconds after which the acceptance is expired.
    /// @return The `Typehashes.REPLACEMENT_ACCEPTANCE` digest in this registry's EIP-712 domain.
    function replacementDigest(
        uint256 artistId,
        ArtistIdentity calldata next,
        bytes32 evidenceHash,
        uint64 deadline
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    Typehashes.REPLACEMENT_ACCEPTANCE,
                    artistId,
                    next.root,
                    next.payout,
                    next.profileId,
                    next.profileDocHash,
                    evidenceHash,
                    deadline
                )
            )
        );
    }

    // ----- internals -----

    /// @dev The EIP-712 digest of a listing consent: `Typehashes.FEDERATED_LISTING` over the
    ///      struct's seven words, in this registry's domain. The struct is static, so its seven
    ///      calldata words are hashed as they are: words that are not canonically encoded only
    ///      fail the signature check.
    function _listingDigest(FederatedListing calldata listing) private view returns (bytes32) {
        bytes32 typehash = Typehashes.FEDERATED_LISTING;
        bytes32 structHash;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, typehash)
            calldatacopy(add(ptr, 0x20), listing, 0xe0)
            structHash := keccak256(ptr, 0x100)
        }
        return _hashTypedDataV4(structHash);
    }

    /// @dev The account `accountId` names: an artist ID, or an address that is or was a root.
    ///      An unregistered account comes back with an empty record and `id == accountId`.
    function _resolve(uint256 accountId) private view returns (uint256 id, Artist storage a) {
        id = accountId;
        a = _artists[accountId];
        if (a.root == address(0) && accountId >> 160 == 0) {
            uint256 mapped = artistIdOf[address(uint160(accountId))];
            if (mapped != 0) (id, a) = (mapped, _artists[mapped]);
        }
    }

    function _artist(uint256 artistId) private view returns (Artist storage a) {
        a = _artists[artistId];
        if (a.root == address(0)) revert UnknownArtist(artistId);
    }

    function _pendingOf(uint256 artistId) private view returns (PendingChange storage p) {
        p = _pending[artistId];
        if (p.kind == ChangeKind.NONE) revert NoPendingChange(artistId);
    }

    /// @dev Whether nobody may act for the account now: it is frozen, or a replacement is
    ///      pending and has not lapsed. The pending change is read only while `replacing` is set.
    function _blocked(uint256 artistId, Artist storage a) private view returns (bool) {
        // forge-lint: disable-next-line(block-timestamp)
        return a.frozenUntil > block.timestamp || (a.replacing && !_lapsed(_pending[artistId]));
    }

    function _requireUnfrozen(uint256 artistId, Artist storage a) private view {
        uint48 until = a.frozenUntil;
        // forge-lint: disable-next-line(block-timestamp)
        if (until > block.timestamp) revert AccountIsFrozen(artistId, until);
    }

    /// @dev Whether the consolidation source says `wallet` is consolidated with `root`, read
    ///      forwarding all gas (`BoundedCall.tryReadWordAll`): a shortfall reverts with
    ///      `BoundedCallShortfall`; any other failure, any answer but exactly `true`, and a source
    ///      whose code no longer matches its pin are "no".
    function _consolidated(address root, address wallet) private view returns (bool) {
        address source = address(consolidationSource);
        if (source.codehash != consolidationSourceCodeHash) return false;
        (bool ok, bytes32 word) = BoundedCall.tryReadWordAll(
            source, abi.encodeCall(IConsolidationSource.isConsolidated, (root, wallet))
        );
        return ok && word == bytes32(uint256(1));
    }

    /// @dev Reverts unless `next` names a nonzero root that is free for this account and a
    ///      payout this registry allows.
    function _checkNext(uint256 artistId, ArtistIdentity calldata next) private view {
        if (next.root == address(0) || !_payoutAllowed(next.payout)) revert InvalidIdentity();
        if (_taken(artistId, next.root)) revert AccountTaken(next.root);
    }

    /// @dev Whether `account` may not become `artistId`'s root: it is or was another account's
    ///      root, or another account's pending change reserves it.
    function _taken(uint256 artistId, address account) private view returns (bool) {
        uint256 mapped = artistIdOf[account];
        uint256 reserved = reservedFor[account];
        return (mapped != 0 && mapped != artistId) || (reserved != 0 && reserved != artistId);
    }

    /// @dev False for payouts that would strand or stall pull-only artist funds: none of these
    ///      can call `release`, and a release some other caller triggers for them pays them.
    function _payoutAllowed(address account) private view returns (bool) {
        address s = stream;
        address factory = splitFactory;
        return !(account == address(0) || account == address(this) || account == packageRegistry
                || (s != address(0) && (account == s || account == IStream(s).editions()))
                || (factory != address(0)
                    && (account == factory || ISplitFactory(factory).isWallet(account)))
                || ProtocolContracts.isProtocolContract(account));
    }

    /// @dev Whether `account` is a contract this registry knows as canonical or protocol: this
    ///      registry, 6529 Stream `s` and its Editions `e`, and every bound contract. Zero is not.
    function _canonical(address account, address s, address e) private view returns (bool) {
        return account != address(0)
            && (account == address(this)
                || account == s
                || account == e
                || account == packageRegistry
                || account == federationRegistry
                || account == splitFactory
                || account == statementLog
                || account == address(consolidationSource));
    }

    function _checkSource(IConsolidationSource source, bytes32 codeHash) private view {
        Dependency.checkPinned(address(source), type(IConsolidationSource).interfaceId, codeHash);
    }

    function _bind(bytes32 name, address current, address target) private returns (address) {
        if (current != address(0)) revert AlreadyBound(name);
        emit Bound(name, target);
        return target;
    }

    /// @dev Consumes the nonce, records the change and reserves a new root until it ends.
    function _stage(
        uint256 artistId,
        Artist storage a,
        ChangeKind kind,
        ArtistIdentity calldata next,
        bytes32 evidenceHash,
        uint48 delay
    ) private {
        ++a.nonce;
        if (kind == ChangeKind.REPLACEMENT) a.replacing = true;
        PendingChange storage p = _pending[artistId];
        p.kind = kind;
        p.executableAt = _now() + delay;
        p.next = next;
        p.evidenceHash = evidenceHash;
        if (next.root != a.root) reservedFor[next.root] = artistId;
        emit ChangeStaged(artistId, p);
    }

    /// @dev Applies `p` after its re-checks (the payout is still allowed, the root still free,
    ///      and an OWN change's new root still a wallet of the account), or clears it; returns
    ///      whether it was applied.
    function _apply(uint256 artistId, PendingChange storage p) private returns (bool) {
        ArtistIdentity memory next = p.next;
        Artist storage a = _artists[artistId];
        ArtistIdentity memory previous =
            ArtistIdentity(a.root, a.payout, a.profileId, a.profileDocHash);
        bool ok = _payoutAllowed(next.payout) && !_taken(artistId, next.root)
            && (p.kind != ChangeKind.OWN
                || next.root == previous.root
                || _consolidated(previous.root, next.root));
        if (!ok) {
            _clear(artistId, address(this), false);
            return false;
        }
        artistIdOf[next.root] = artistId;
        (a.root, a.replacing, a.payout) = (next.root, false, next.payout);
        (a.profileId, a.profileDocHash) = (next.profileId, next.profileDocHash);
        delete reservedFor[next.root];
        delete _pending[artistId];
        emit ChangeExecuted(artistId, previous, next);
        return true;
    }

    /// @dev The account's latest DISPUTE_OUTCOME entry in the bound statement log, or zero.
    function _latestOutcome(uint256 artistId) private view returns (bytes32) {
        address log = statementLog;
        if (log == address(0)) return bytes32(0);
        return IStatementLog(log).latestDisputeOutcome(address(this), artistId);
    }

    /// @dev Whether `p` is a contest nobody resolved within {CONTEST_LAPSE}.
    function _lapsed(PendingChange storage p) private view returns (bool) {
        uint256 contestedAt = p.contestedAt;
        // forge-lint: disable-next-line(block-timestamp)
        return contestedAt != 0 && block.timestamp >= contestedAt + CONTEST_LAPSE;
    }

    /// @dev Ends the pending change and its reservation.
    function _clear(uint256 artistId, address by, bool byNetwork) private {
        delete reservedFor[_pending[artistId].next.root];
        delete _pending[artistId];
        _artists[artistId].replacing = false;
        emit ChangeCancelled(artistId, by, byNetwork);
    }

    /// @dev The shared gas rule for the registry's own try/catch reads, which forward all gas.
    function _revertOnShortfall(address target, uint256 gasBefore) private view {
        if (gasleft() <= gasBefore / BoundedCall.SHORTFALL_DIVISOR) {
            revert BoundedCall.BoundedCallShortfall(target);
        }
    }

    /// @dev The block time as stored (48 bits last for millions of years).
    function _now() private view returns (uint48) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint48(block.timestamp);
    }
}

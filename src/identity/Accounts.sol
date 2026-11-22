// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistPayoutResolver } from "../economics/interfaces/IArtistPayoutResolver.sol";
import { IRevenueEscrow } from "../economics/interfaces/IRevenueEscrow.sol";
import { ISplitFactory } from "../economics/interfaces/ISplitFactory.sol";
import { IArtistRegistry, IConsolidationSource } from "../interfaces/IArtistRegistry.sol";
import { IArtistRoleResolver } from "../interfaces/IArtistRoleResolver.sol";
import { IFederationRegistry } from "../interfaces/IFederationRegistry.sol";
import { IStatementLog } from "../interfaces/IStatementLog.sol";
import { Slots } from "../interfaces/core/CoreTypes.sol";
import { IAccounts } from "../interfaces/core/IAccounts.sol";
import { IDirectory } from "../interfaces/core/IDirectory.sol";
import { IEditions } from "../interfaces/core/IEditions.sol";
import { IFederationGate } from "../interfaces/core/IFederationGate.sol";
import { IMintPolicy } from "../interfaces/core/IMintPolicy.sol";
import { IModuleSlots } from "../interfaces/core/IModules.sol";
import { IStream } from "../interfaces/core/IStream.sol";
import { IWorkFacts } from "../interfaces/core/IWorkFacts.sol";
import { ArtistIdentity, ChangeKind, PendingChange } from "../interfaces/types/IdentityTypes.sol";
import { Typehashes } from "../interfaces/types/Typehashes.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";
import { Dependency } from "../libraries/Dependency.sol";
import { SignatureVerifier } from "../libraries/SignatureVerifier.sol";

/// @title Accounts
/// @notice The accounts module (replaceable): artist accounts, their payout and profile. An
///         account is a 6529 consolidated account: its root wallet and every wallet consolidated
///         with the root act for it with the same rights. The permanent `Directory` names the
///         current accounts module (slot `ACCOUNTS`): split vaults ask it for an artist's payout
///         address through `Directory.payoutAddress`, federated tokens ask it who may administer
///         them, and the statement log asks it `isArtist`.
/// @dev Who may act. The root always may, without any read of the consolidation source, so a
///      broken, reverting or repriced source never locks an account out. Any other wallet may
///      while the source says it is consolidated with the root, read live with `BoundedCall`'s
///      forward-all rule: a shortfall reverts, any other failure is "no". Nobody may while the
///      account is frozen or a network replacement is pending (and has not lapsed).
///
///      A freeze blocks a contest of a replacement, and a freeze can be placed again. While a
///      freeze runs nobody can contest (`cancelChange` refuses), so a freeze placed together with
///      a replacement leaves no moment to contest it: a contest binds only a network that does
///      not also freeze the account. `freeze` is refused while a freeze runs, but once a freeze
///      ended, or the network lifted it (`unfreeze`), the network may place another at once.
///
///      The waits (an account's own change 2 days, a replacement's notice 14 days, a contest's
///      lapse 90 days, a freeze 14 days) are compiled into this module. The module is
///      replaceable by the network, so they are its current rules, not promises of the
///      permanent contracts.
contract Accounts is IArtistRegistry, AccessManaged, EIP712 {
    /// @notice How long an account's own change waits before it may execute.
    uint48 public constant OWN_CHANGE_DELAY = 2 days;
    /// @notice The public notice of a network replacement before it may execute.
    uint48 public constant REPLACEMENT_NOTICE = 14 days;
    /// @notice A contested replacement lapses this long after its contest unless the network
    ///         resolves it.
    uint48 public constant CONTEST_LAPSE = 90 days;
    /// @notice How long one freeze lasts. The network may lift it early and place it again.
    uint48 public constant FREEZE_PERIOD = 14 days;

    /// @notice The contracts this module is deployed against.
    /// @param directory The permanent directory (its FEDERATION slot names the federation module).
    /// @param stream 6529 Stream.
    /// @param editions 6529 Stream Editions.
    /// @param splitFactory The split ledger (whose vaults are refused as payouts).
    /// @param statementLog The statement log `resolveContested` reads (zero: none).
    /// @param packageRegistry The first package registry, the only `register` caller.
    struct Wiring {
        address directory;
        address stream;
        address editions;
        address splitFactory;
        address statementLog;
        address packageRegistry;
    }

    /// @dev Slot 0 holds everything {isWallet} needs: the root, the end of a freeze and whether a
    ///      replacement is pending.
    struct Artist {
        address root;
        uint48 frozenUntil;
        bool replacing;
        address payout;
        uint64 nonce;
        bytes32 profileId;
        bytes32 profileDocHash;
    }

    /// @dev `Work` as `IStream.workOf` returns it: eleven words.
    uint256 private constant WORK_WORDS = 11;

    mapping(uint256 artistId => Artist) private _artists;
    mapping(uint256 artistId => PendingChange) private _pending;
    mapping(bytes32 digest => bool) private _acceptanceUsed;

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
    address public immutable override directory;
    /// @inheritdoc IArtistRegistry
    address public immutable override stream;
    /// @inheritdoc IArtistRegistry
    address public immutable override editions;
    /// @inheritdoc IArtistRegistry
    address public immutable override splitFactory;
    /// @inheritdoc IArtistRegistry
    address public immutable override statementLog;

    /// @param initialAuthority The AccessManager.
    /// @param source The consolidation source (the v1 `ConsolidationAdapter`).
    /// @param sourceCodeHash The reviewed code hash of `source`.
    /// @param w The contracts this module is deployed against (`Wiring`). They may be predicted
    ///        addresses with no code yet; none is called here.
    constructor(
        address initialAuthority,
        IConsolidationSource source,
        bytes32 sourceCodeHash,
        Wiring memory w
    )
        AccessManaged(initialAuthority)
        EIP712(Typehashes.ARTIST_REGISTRY_NAME, Typehashes.DOMAIN_VERSION)
    {
        _checkSource(source, sourceCodeHash);
        consolidationSource = source;
        consolidationSourceCodeHash = sourceCodeHash;
        directory = w.directory;
        stream = w.stream;
        editions = w.editions;
        splitFactory = w.splitFactory;
        statementLog = w.statementLog;
        packageRegistry = w.packageRegistry;
        emit ConsolidationSourceSet(address(0), address(source), sourceCodeHash);
        emit PackageRegistrySet(address(0), w.packageRegistry);
    }

    // ----- wiring -----

    /// @inheritdoc IArtistRegistry
    function setPackageRegistry(address expected, address next) external restricted {
        if (expected != packageRegistry) revert ExpectedValueMismatch();
        Dependency.check(next);
        packageRegistry = next;
        emit PackageRegistrySet(expected, next);
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
    ///      `register`; the federation module is not trusted to, so the signature is checked
    ///      here, in this module's domain.
    function registerFederated(
        address account,
        bytes32 profileId,
        bytes32 profileDocHash,
        uint64 deadline,
        bytes calldata signature
    ) external returns (uint256) {
        if (msg.sender != federationRegistry() || msg.sender == address(0)) {
            revert UnboundCaller(msg.sender);
        }
        SignatureVerifier.checkDeadline(deadline);
        SignatureVerifier.check(
            account, registrationDigest(account, profileId, profileDocHash, deadline), signature
        );
        return _create(account, profileId, profileDocHash);
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
    ///      pending replacement, which blocks {isWallet}, does not stop its own contest. A freeze
    ///      does: `_requireUnfrozen` runs first, so nobody contests while the account is frozen.
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
    /// @dev Refused while a freeze runs; once it ended or was lifted it may be placed again.
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

    /// @inheritdoc IArtistRegistry
    /// @dev Zero for an unknown artist, while the account is frozen, and while a pending change
    ///      would move the payout (a lapsed contest no longer counts).
    function payoutAddress(uint256 artistId)
        external
        view
        override(IArtistRegistry)
        returns (address)
    {
        Artist storage a = _artists[artistId];
        // forge-lint: disable-next-line(block-timestamp)
        if (a.frozenUntil > block.timestamp) return address(0);
        address current = a.payout;
        PendingChange storage p = _pending[artistId];
        bool moves = p.kind != ChangeKind.NONE && p.next.payout != current && !_lapsed(p);
        return moves ? address(0) : current;
    }

    // ----- reads -----

    /// @inheritdoc IArtistRoleResolver
    /// @dev Resolves the lead artist of any token that answers `IStream.workOf` (6529 Stream and
    ///      every federated token), or of an edition through the master of an `IEditions`
    ///      contract (`stream()`, same ID), and answers {isWallet}. A token that answers neither,
    ///      or answers malformed data, is "false"; so is a call that fails for lack of gas, which
    ///      only withholds an answer. Any token is accepted: the statement log keys every
    ///      statement by its token, so an answer about a contract that is not a network token
    ///      only lets its own artist speak about it.
    function isArtist(address token, uint256 id, address account) external view returns (bool) {
        if (token == address(0) || account == address(0)) return false;
        uint256 artistId = _artistOf(token, id);
        if (artistId == 0) {
            (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(IEditions.stream, ()));
            if (!ok || ret.length != 32) return false;
            uint256 word = abi.decode(ret, (uint256));
            if (word == 0 || word > type(uint160).max || address(uint160(word)) == token) {
                return false;
            }
            artistId = _artistOf(address(uint160(word)), id);
        }
        return artistId != 0 && isWallet(artistId, account);
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
    function federationRegistry() public view returns (address) {
        return IModuleSlots(directory).moduleOf(Slots.FEDERATION);
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

    /// @notice The EIP-712 digest a wallet signs to consent to an account created through the
    ///         federation module (`registerFederated`).
    /// @param account The consenting wallet.
    /// @param profileId The claimed 6529 profile ID.
    /// @param profileDocHash The profile document hash.
    /// @param deadline The Unix time in seconds after which the signature is expired.
    /// @return The `ArtistRegistration` digest in this module's EIP-712 domain.
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
    /// @return The `Typehashes.IDENTITY_CHANGE` digest in this module's EIP-712 domain.
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
    /// @return The `Typehashes.REPLACEMENT_ACCEPTANCE` digest in this module's EIP-712 domain.
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

    /// @dev The lead artist `token` reports for `id` (`IStream.workOf`), or zero when the call
    ///      fails or answers anything but a whole `Work` with an artist ID of at most 160 bits.
    function _artistOf(address token, uint256 id) private view returns (uint256 artistId) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(IStream.workOf, (id)));
        if (!ok || ret.length != WORK_WORDS * 32) return 0;
        (, artistId) = abi.decode(ret, (bytes32, uint256));
        if (artistId > type(uint160).max) return 0;
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
    ///      payout this module allows.
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
    ///      can call `release`, and a release some other caller triggers for them pays them. The
    ///      contracts this module knows, the split factory's vaults, and any contract declaring
    ///      (ERC-165) a network contract's interface are refused.
    function _payoutAllowed(address account) private view returns (bool) {
        if (
            account == address(0) || account == address(this) || account == directory
                || account == stream || account == editions || account == splitFactory
                || account == statementLog || account == packageRegistry
        ) return false;
        address factory = splitFactory;
        if (factory.code.length != 0 && ISplitFactory(factory).isWallet(account)) return false;
        return !_isNetworkContract(account);
    }

    /// @dev Whether `account` declares (ERC-165) the interface of a network contract that cannot
    ///      pull or move funds onward: a token or edition contract, a module host, the directory,
    ///      the record contract, a mint policy, a federation gate, an accounts module or the
    ///      escrow.
    function _isNetworkContract(address account) private view returns (bool) {
        if (account.code.length == 0 || !BoundedCall.supportsERC165(account)) return false;
        bytes4[9] memory ids = [
            type(IStream).interfaceId,
            type(IEditions).interfaceId,
            type(IModuleSlots).interfaceId,
            type(IDirectory).interfaceId,
            type(IWorkFacts).interfaceId,
            type(IMintPolicy).interfaceId,
            type(IFederationGate).interfaceId,
            type(IArtistRegistry).interfaceId,
            type(IRevenueEscrow).interfaceId
        ];
        for (uint256 i; i < ids.length; ++i) {
            if (BoundedCall.supportsInterfaceUnchecked(account, ids[i])) return true;
        }
        return false;
    }

    function _checkSource(IConsolidationSource source, bytes32 codeHash) private view {
        Dependency.checkPinned(address(source), type(IConsolidationSource).interfaceId, codeHash);
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

    /// @dev The account's latest DISPUTE_OUTCOME entry in the statement log, or zero.
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

    /// @dev The block time as stored (48 bits last for millions of years).
    function _now() private view returns (uint48) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint48(block.timestamp);
    }
}

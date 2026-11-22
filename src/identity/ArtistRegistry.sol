// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistPayoutResolver } from "../economics/interfaces/IArtistPayoutResolver.sol";
import { ISplitFactory } from "../economics/interfaces/ISplitFactory.sol";
import { IAccounts } from "../interfaces/IAccounts.sol";
import { IConsolidationSource } from "../interfaces/IArtistRegistry.sol";
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

/// @title IArtistRegistryV1
/// @dev The earlier registry's interface, kept beside its contract until both are deleted.
/// @notice The artist registry: artist accounts, their payout and profile, and the federation
///         directory. An account is a 6529 consolidated account: its root wallet and every
///         wallet consolidated with the root act for it with the same rights (`IAccounts`).
/// @dev Artist IDs: an account's ID is `artistIdOf(wallet)` when nonzero, otherwise
///      `uint256(uint160(wallet))`, the ID its first package acceptance creates. IDs fit 160 bits
///      and never change when the root does; every address that has been an account's root maps
///      to its ID forever. An address that never registered is its own single-wallet account.
///
///      Changes. One change may be pending per account:
///      - OWN: any wallet of the account signs `Typehashes.IDENTITY_CHANGE` (relayed by anyone).
///        It waits 2 days; any wallet of the account, or the network (`cancelOwnChange`), may
///        cancel it. A new root must already
///        be a wallet of the account.
///      - REPLACEMENT: the network replaces the root (and with it payout and profile), with 14
///        days' public notice and the new root's signed acceptance. It replaces a pending OWN
///        change. Any wallet of the account may contest it during the notice; a contested
///        replacement runs only if the network upholds it, citing a DISPUTE_OUTCOME statement
///        recorded after the contest, within 90 days of the contest; otherwise it lapses. The
///        network may withdraw its own replacement at any time (`cancelReplacement`).
///      While a replacement is pending (and has not lapsed) the account has no acting wallet:
///      `isWallet` is false, `activeAuthorityOf` is zero.
///
///      Freeze. The network may freeze an account at once for 14 days (`freeze`), and end a
///      freeze early (`unfreeze`). While frozen the account has no acting wallet, its payout
///      reads zero (split wallets hold its money) and no pending change executes, with one
///      exception: the network's own `resolveContested` may uphold a contested replacement
///      while the account is frozen (the freeze then still runs for the new identity). A freeze
///      cannot be extended while it runs; it can be placed again once it ended.
///
///      The 2-day, 14-day, 90-day and 14-day numbers are compiled constants: each is the
///      guarantee, and no setter exists.
///
///      Federation directory (ADR 0001 section 16): one entry per federated token, written by
///      the current federation registry (`listFederatedContract`, `setFederatedStatus`). A first
///      listing needs the consent of a wallet of the artist's account; later status changes do
///      not, so a replacement federation registry inherits every listing. The network may
///      delist a whole account (`setFederationDelisted`): its new contracts cannot list, and
///      every contract of the account reads DELISTED. The network may lower a listing's fee
///      share (`lowerFederatedFeeShare`); nothing raises it.
interface IArtistRegistryV1 is IArtistRoleResolver, IArtistPayoutResolver, IAccounts {
    /// @notice A federated contract's directory status, before the account flag is applied.
    enum FederationStatus {
        NONE,
        ACTIVE,
        DELISTED
    }

    /// @notice A directory entry's facts, as the artist consents to them (EIP-712
    ///         `FederatedListing`, `listFederatedContract`).
    /// @param artistId The registered artist to list the contract under.
    /// @param token The federated token contract.
    /// @param form The token's form, recorded and not interpreted (see `FederatedContractListed`).
    /// @param partner The other half of a linked pair, or zero.
    /// @param feeShare The network's share, out of 100,000, as locked in the token.
    /// @param feeRecipient The network fee recipient locked in the token.
    /// @param deadline The consent's expiry, inclusive.
    struct FederatedListing {
        uint256 artistId;
        address token;
        uint8 form;
        address partner;
        uint32 feeShare;
        address feeRecipient;
        uint64 deadline;
    }

    /// @notice An artist account was created.
    /// @param artistId The new artist ID, `uint256(uint160(identity.root))`.
    /// @param identity The new identity: the accepting wallet as root and payout, with the
    ///        profile fields of its signed acceptance.
    event ArtistRegistered(uint256 indexed artistId, ArtistIdentity identity);
    /// @notice A change was staged.
    /// @param artistId The account whose identity would change.
    /// @param change The pending change as stored.
    event ChangeStaged(uint256 indexed artistId, PendingChange change);
    /// @notice A pending change ended without taking effect.
    /// @param artistId The account whose pending change ended.
    /// @param by The wallet or network caller that ended it, or this registry when it cleared
    ///        the change itself (a lapsed contest, a failed execution re-check).
    /// @param byNetwork True when the network ended it (a withdrawal, a void, or a replacement
    ///        that superseded an OWN change).
    event ChangeCancelled(uint256 indexed artistId, address indexed by, bool byNetwork);
    /// @notice A change took effect.
    /// @param artistId The account whose identity changed.
    /// @param previous The identity before the change.
    /// @param next The identity after the change.
    event ChangeExecuted(uint256 indexed artistId, ArtistIdentity previous, ArtistIdentity next);
    /// @notice A replacement's new-root acceptance was consumed; its digest is never staged again.
    /// @param artistId The account the replacement is for.
    /// @param digest The `Typehashes.REPLACEMENT_ACCEPTANCE` digest consumed.
    event ReplacementAcceptanceConsumed(uint256 indexed artistId, bytes32 digest);
    /// @notice A wallet of the account contested a pending replacement.
    /// @param artistId The account whose replacement is contested.
    /// @param by The contesting wallet.
    /// @param priorOutcome The account's latest dispute outcome at the contest (zero if none),
    ///        which `resolveContested` refuses: only a later outcome resolves the contest.
    event ChangeContested(uint256 indexed artistId, address indexed by, bytes32 priorOutcome);
    /// @notice The network applied a vote on a contested replacement.
    /// @param artistId The account whose contested replacement was resolved.
    /// @param upheld True if the vote upheld it, false if it voided it.
    /// @param executed True if the upheld replacement took effect.
    /// @param outcomeRef The entry hash of the DISPUTE_OUTCOME statement recording the vote.
    event ContestResolved(uint256 indexed artistId, bool upheld, bool executed, bytes32 outcomeRef);
    /// @notice A contested replacement lapsed unresolved after 90 days.
    /// @param artistId The account whose contested replacement was deleted.
    event ContestExpired(uint256 indexed artistId);
    /// @notice A wallet of the account burned its unused change nonce.
    /// @param artistId The account whose change nonce was burned.
    /// @param nonce The burned nonce; `changeNonce` is now one higher.
    event NonceRevoked(uint256 indexed artistId, uint256 nonce);
    /// @notice The network froze an account.
    /// @param artistId The frozen account.
    /// @param until The time the freeze ends.
    event AccountFrozen(uint256 indexed artistId, uint48 until);
    /// @notice The network ended an account's freeze early.
    /// @param artistId The account.
    event AccountUnfrozen(uint256 indexed artistId);
    /// @notice The consolidation source changed.
    /// @param previous The source before the change (zero at deployment).
    /// @param next The source after the change.
    /// @param codeHash The reviewed code hash pinned for `next`.
    event ConsolidationSourceSet(address previous, address next, bytes32 codeHash);
    /// @notice The network replaced the package registry, the only `register` caller.
    /// @param previous The package registry before.
    /// @param next The package registry after.
    event PackageRegistrySet(address previous, address next);
    /// @notice A contract was bound under `name` (PACKAGE_REGISTRY, STREAM, FEDERATION_REGISTRY,
    ///         SPLIT_FACTORY or STATEMENT_LOG), once.
    /// @param name The binding's name as a `bytes32` string.
    /// @param target The contract bound.
    event Bound(bytes32 indexed name, address target);
    /// @notice A federated contract was listed under an artist, ACTIVE (ADR 0001 section 16).
    /// @param artistId The artist the contract was listed under.
    /// @param token The federated token contract.
    /// @param codeHash `token`'s runtime code hash, read by this registry at listing.
    /// @param form The token's form as reported by the federation registry (0 for ERC-721, 1 for
    ///        ERC-1155 under `IFederationRegistry.Form`).
    /// @param partner The other half of a linked pair, or zero.
    /// @param feeShare The network's share of primary sales and royalties, out of 100,000, as
    ///        locked in the token; the directory's recorded share starts here.
    /// @param feeRecipient The network fee recipient locked in the token.
    event FederatedContractListed(
        uint256 indexed artistId,
        address indexed token,
        bytes32 codeHash,
        uint8 form,
        address partner,
        uint32 feeShare,
        address feeRecipient
    );
    /// @notice A federated contract's own status changed (ACTIVE or DELISTED).
    /// @param token The federated token contract.
    /// @param artistId The artist it is listed under.
    /// @param previous The status before.
    /// @param status The new status.
    /// @param ref The federation registry's reference for the decision.
    event FederatedContractStatus(
        address indexed token,
        uint256 indexed artistId,
        FederationStatus previous,
        FederationStatus status,
        bytes32 ref
    );
    /// @notice The network delisted a whole account from the federation, or ended that.
    /// @param artistId The account.
    /// @param previous Whether the account was delisted before the call.
    /// @param delisted Whether the account is now delisted.
    /// @param ref The network's reference for the decision.
    event FederationDelistedSet(
        uint256 indexed artistId, bool previous, bool delisted, bytes32 ref
    );
    /// @notice The network lowered a listed contract's recorded fee share.
    /// @param token The federated token contract.
    /// @param previous The share before, out of 100,000.
    /// @param share The share now, out of 100,000.
    event FederatedFeeShareLowered(address indexed token, uint32 previous, uint32 share);
    /// @notice The network replaced the federation registry.
    /// @param previous The federation registry before (zero if none was bound).
    /// @param next The federation registry after.
    event FederationRegistrySet(address previous, address next);

    /// @notice No artist has this ID.
    error UnknownArtist(uint256 artistId);
    /// @notice The address already belongs to another artist account, or is reserved by one.
    error AccountTaken(address account);
    /// @notice The caller may not act for this account now.
    error NotAuthorized(uint256 artistId, address account);
    /// @notice A change is already pending.
    error ChangePending(uint256 artistId);
    /// @notice No change (or no change of the kind the call needs) is pending.
    error NoPendingChange(uint256 artistId);
    /// @notice The change is not executable before `executableAt`.
    error ChangeNotDue(uint256 artistId, uint48 executableAt);
    /// @notice The next identity is not acceptable: a zero root or payout, a payout this
    ///         registry refuses, a new root that is not a wallet of the account (OWN), the same
    ///         root (REPLACEMENT), or a zero evidence hash.
    error InvalidIdentity();
    /// @notice A replacement acceptance with this digest was already consumed.
    error AcceptanceUsed(bytes32 digest);
    /// @notice `name` is already bound.
    error AlreadyBound(bytes32 name);
    /// @notice The statement log to bind does not name this registry as its `artistResolver()`.
    error InvalidBinding(address target);
    /// @notice The caller is not the bound contract for this function.
    error UnboundCaller(address caller);
    /// @notice A compare-and-set setter's expected current value is stale.
    error ExpectedValueMismatch();
    /// @notice The pending replacement is contested; only a vote, a withdrawal or the lapse
    ///         ends it.
    error ReplacementContested(uint256 artistId);
    /// @notice No live (unlapsed) contested replacement is pending.
    error NotContested(uint256 artistId);
    /// @notice `outcomeRef` is not the latest DISPUTE_OUTCOME recorded for the account.
    error OutcomeNotRecorded(uint256 artistId, bytes32 outcomeRef);
    /// @notice The contest does not lapse before `expiresAt`.
    error ContestNotExpired(uint256 artistId, uint48 expiresAt);
    /// @notice `outcomeRef` was already the latest DISPUTE_OUTCOME when the contest began.
    error OutcomePredatesContest(uint256 artistId, bytes32 outcomeRef);
    /// @notice The replacement's notice ended at `executableAt`; it can no longer be contested.
    error ContestWindowClosed(uint256 artistId, uint48 executableAt);
    /// @notice The account is frozen until `until`.
    error AccountIsFrozen(uint256 artistId, uint48 until);
    /// @notice The contract cannot be listed: it is already listed, has no code or is an
    ///         EIP-7702 delegated account, its account is delisted, or it, its partner or its fee
    ///         recipient is this registry, 6529 Stream, its Editions, or a bound contract.
    error FederatedContractRefused(address token);
    /// @notice The status write is refused: the token is unlisted, or the requested status is
    ///         not ACTIVE or DELISTED.
    error FederatedStatusRefused(address token, FederationStatus current);
    /// @notice The share is not lower than the recorded one, or the token is not listed.
    error FeeShareNotLowered(address token, uint32 current);

    /// @notice Binds the package registry (the only `register` caller), once, at genesis.
    /// @param target The package registry: a contract supporting `IPackageRegistry` (ERC-165),
    ///        not an EIP-7702 delegated account.
    function bindPackageRegistry(address target) external;
    /// @notice Replaces the package registry, the only `register` caller. A network action,
    ///         compare-and-set. Existing accounts are unaffected.
    /// @param expected The current package registry (`ExpectedValueMismatch` otherwise).
    /// @param next The successor: a contract supporting `IPackageRegistry` (ERC-165), not an
    ///        EIP-7702 delegated account.
    function setPackageRegistry(address expected, address next) external;
    /// @notice Binds 6529 Stream, which `isArtist` reads (`IStream.artistOf`), once.
    /// @param target 6529 Stream: a contract supporting `IStream` (ERC-165), not an EIP-7702
    ///        delegated account.
    function bindStream(address target) external;
    /// @notice Binds the federation registry (the only caller of `registerFederated` and of the
    ///         directory writes), once. A later replacement goes through `setFederationRegistry`.
    /// @param target The federation registry: a contract supporting `IFederationRegistry`.
    function bindFederationRegistry(address target) external;
    /// @notice Replaces the federation registry. A network action, compare-and-set. Existing
    ///         listings stay and the successor manages them with no artist signature.
    /// @param expected The current federation registry, zero if none (`ExpectedValueMismatch`
    ///        otherwise).
    /// @param next The successor: a contract supporting `IFederationRegistry` (ERC-165).
    function setFederationRegistry(address expected, address next) external;
    /// @notice Binds the economics split factory, once.
    /// @param target The split factory, whose wallets this registry refuses as payouts.
    function bindSplitFactory(address target) external;
    /// @notice Binds the statement log `resolveContested` reads, once; its artist resolver must
    ///         be this registry.
    /// @param target The statement log, whose `artistResolver()` returns this registry.
    function bindStatementLog(address target) external;
    /// @notice Swaps the consolidation source: ERC-165 checked, code hash `nextCodeHash`, not an
    ///         EIP-7702 delegated account. A network action, compare-and-set. The pinned code hash
    ///         is re-checked at every read; a source whose code changed answers "no".
    /// @param expected The source the proposer saw (`ExpectedValueMismatch` otherwise).
    /// @param next The new consolidation source.
    /// @param nextCodeHash The reviewed code hash `next` must have.
    function setConsolidationSource(
        IConsolidationSource expected,
        IConsolidationSource next,
        bytes32 nextCodeHash
    ) external;

    /// @notice Creates an account for `root` with ID `uint256(uint160(root))` and payout `root`.
    ///         Bound package registry only, after it verified the signed acceptance. Reverts with
    ///         `AccountTaken` if the address is mapped or reserved.
    /// @param root The accepting wallet, which becomes the root and the payout.
    /// @param profileId The artist's claimed 6529 profile ID, from the signed acceptance.
    /// @param profileDocHash The hash of the profile document, from the signed acceptance.
    /// @return artistId `uint256(uint160(root))`.
    function register(address root, bytes32 profileId, bytes32 profileDocHash)
        external
        returns (uint256 artistId);
    /// @notice Creates an account exactly as `register` does, for an uncurated (federated)
    ///         artist. Bound federation registry only. `account` signs `ArtistRegistration`
    ///         in this registry's EIP-712 domain (`registrationDigest`).
    /// @param account The consenting wallet, which becomes the root and the payout.
    /// @param profileId The artist's claimed 6529 profile ID, as signed.
    /// @param profileDocHash The hash of the profile document, as signed.
    /// @param deadline The Unix time in seconds after which the signature is expired.
    /// @param signature `account`'s signature (ECDSA, EIP-7702 or ERC-1271).
    /// @return artistId `uint256(uint160(account))`.
    function registerFederated(
        address account,
        bytes32 profileId,
        bytes32 profileDocHash,
        uint64 deadline,
        bytes calldata signature
    ) external returns (uint256 artistId);
    /// @notice Stages the account's own change: new root, payout or profile. Anyone relays it;
    ///         `proof` is a wallet of the account and its `Typehashes.IDENTITY_CHANGE` signature
    ///         at the current `changeNonce` (`requireSigned`). The new root must already be a
    ///         wallet of the account. Executable after 2 days.
    /// @param artistId The account to change.
    /// @param next The identity after the change.
    /// @param deadline The Unix time in seconds after which the signature is expired.
    /// @param proof `abi.encodePacked(wallet, signature)`.
    function stageChange(
        uint256 artistId,
        ArtistIdentity calldata next,
        uint64 deadline,
        bytes calldata proof
    ) external;
    /// @notice Stages a network replacement of the account's root, with 14 days' notice. A
    ///         network action (24 hours). It needs the new root's `REPLACEMENT_ACCEPTANCE`
    ///         signature, consumed once by digest, and replaces a pending OWN change.
    /// @param artistId The account to replace.
    /// @param next The identity after the replacement; its root differs from the current one.
    /// @param evidenceHash The nonzero hash of the replacement's public record.
    /// @param deadline The Unix time in seconds after which `rootAcceptance` is expired.
    /// @param rootAcceptance `next.root`'s acceptance signature.
    function stageReplacement(
        uint256 artistId,
        ArtistIdentity calldata next,
        bytes32 evidenceHash,
        uint64 deadline,
        bytes calldata rootAcceptance
    ) external;
    /// @notice Called by a wallet of the account: cancels a pending OWN change, or contests a
    ///         pending REPLACEMENT during its notice (it then waits for a vote). A repeat contest
    ///         does nothing. During a replacement the contesting wallet is checked against the
    ///         current root, ignoring the replacement itself; never while frozen.
    /// @param artistId The account whose pending change is cancelled or contested.
    function cancelChange(uint256 artistId) external;
    /// @notice The network withdraws its own pending replacement, contested or not. A network
    ///         action with no delay.
    /// @param artistId The account whose replacement is withdrawn.
    function cancelReplacement(uint256 artistId) external;
    /// @notice The network cancels an account's own pending change. A network action with no
    ///         delay; the account may stage a new one.
    /// @param artistId The account whose own change is cancelled.
    function cancelOwnChange(uint256 artistId) external;
    /// @notice Applies a vote on a contested replacement: upholding executes it (once its notice
    ///         passed), voiding deletes it. `outcomeRef` must be
    ///         `IStatementLog.latestDisputeOutcome(address(this), artistId)` and differ from the
    ///         outcome that was latest when the contest began. A network action (24 hours).
    ///         It is not held by a freeze: upholding executes during one, and the freeze keeps
    ///         running for the new identity.
    /// @param artistId The account whose contested replacement is resolved.
    /// @param uphold True to uphold (execute) it, false to void (delete) it.
    /// @param outcomeRef The entry hash of the DISPUTE_OUTCOME statement recording the vote.
    function resolveContested(uint256 artistId, bool uphold, bytes32 outcomeRef) external;
    /// @notice Deletes a contested replacement nobody resolved within 90 days of the contest.
    ///         Permissionless.
    /// @param artistId The account whose contested replacement lapsed.
    function expireContest(uint256 artistId) external;
    /// @notice Applies a due, uncontested change. Permissionless; refused while the account is
    ///         frozen. If the next identity is no longer valid (its payout is now refused, or an
    ///         OWN change's new root is no longer a wallet of the account) the change is cleared
    ///         with `ChangeCancelled(artistId, address(this), false)` instead.
    /// @param artistId The account whose due change is applied.
    function executeChange(uint256 artistId) external;
    /// @notice Burns the account's current change nonce, so a change signed for it can never be
    ///         staged. Any wallet of the account.
    /// @param artistId The account whose change nonce is burned.
    function revokeNonce(uint256 artistId) external;
    /// @notice Freezes the account for 14 days. A network action with no delay. Refused while a
    ///         freeze runs (`AccountIsFrozen`).
    /// @param artistId The account to freeze.
    function freeze(uint256 artistId) external;
    /// @notice Ends the account's freeze now. A network action with no delay.
    /// @param artistId The account to unfreeze.
    function unfreeze(uint256 artistId) external;

    /// @notice Lists `token` under the artist, ACTIVE. Bound federation registry only. Refused
    ///         (`FederatedContractRefused`) for a listed token, a token without code or
    ///         EIP-7702 delegated, a delisted account, and when the token, partner or fee
    ///         recipient is a contract this registry knows as canonical. `consent` is a wallet of
    ///         the artist's account and its EIP-712 `FederatedListing` signature in this
    ///         registry's domain (`requireSigned`).
    /// @param listing The entry's facts.
    /// @param consent `abi.encodePacked(wallet, signature)`.
    function listFederatedContract(FederatedListing calldata listing, bytes calldata consent)
        external;
    /// @notice Sets a listed token's own status to ACTIVE or DELISTED. Bound federation registry
    ///         only; no artist signature.
    /// @param token The federated token contract.
    /// @param status ACTIVE or DELISTED.
    /// @param ref The federation registry's reference for the decision.
    function setFederatedStatus(address token, FederationStatus status, bytes32 ref) external;
    /// @notice Delists (or relists) a whole account from the federation. A network action (24
    ///         hours). While set, the account cannot list new contracts and every contract it
    ///         listed reads DELISTED. Federation only: identity, payout and Stream works are
    ///         untouched.
    /// @param artistId The account.
    /// @param delisted Whether the account is delisted.
    /// @param ref The network's reference for the decision.
    function setFederationDelisted(uint256 artistId, bool delisted, bytes32 ref) external;
    /// @notice Lowers a listed contract's recorded fee share. A network action (24 hours).
    ///         Lower only (`FeeShareNotLowered`); the token uses the smaller of its own share and
    ///         this one.
    /// @param token The federated token contract.
    /// @param share The new share, out of 100,000, below the recorded one.
    function lowerFederatedFeeShare(address token, uint32 share) external;

    /// @notice An account's recorded fields and the end of its freeze. Reverts with
    ///         `UnknownArtist`.
    /// @param artistId The artist ID.
    /// @return identity The account's current identity.
    /// @return frozenUntil_ The time its freeze ends, zero or past when not frozen.
    function artist(uint256 artistId)
        external
        view
        returns (ArtistIdentity memory identity, uint48 frozenUntil_);
    /// @notice The artist ID of an address that is or was an account's root, or zero.
    /// @param account The address to look up.
    /// @return The artist ID, or zero.
    function artistIdOf(address account) external view returns (uint256);
    /// @notice The account whose pending change would make `account` its root, or zero.
    /// @param account The address to look up.
    /// @return The reserving account's ID, or zero.
    function reservedFor(address account) external view returns (uint256);
    /// @notice The account's root, which identifies it. Reverts with `UnknownArtist`.
    /// @param artistId The artist ID.
    /// @return The root.
    function authorityOf(uint256 artistId) external view returns (address);
    /// @notice The root, or zero while the account is frozen or a replacement is pending (and
    ///         has not lapsed). Used where one address is needed (a sale's `creator`). Reverts
    ///         with `UnknownArtist`.
    /// @param artistId The artist ID.
    /// @return The root, or zero.
    function activeAuthorityOf(uint256 artistId) external view returns (address);
    /// @notice The pending change (kind NONE if none).
    /// @param artistId The artist ID.
    /// @return The pending change.
    function pendingChange(uint256 artistId) external view returns (PendingChange memory);
    /// @notice The nonce the next signed OWN change must carry.
    /// @param artistId The artist ID.
    /// @return The nonce; every staging and every `revokeNonce` adds one.
    function changeNonce(uint256 artistId) external view returns (uint256);
    /// @notice The consolidation source.
    /// @return The source the registry reads consolidations from.
    function consolidationSource() external view returns (IConsolidationSource);
    /// @notice The code hash pinned when the consolidation source was installed.
    /// @return The pinned code hash.
    function consolidationSourceCodeHash() external view returns (bytes32);
    /// @notice A token's directory entry: its artist and status. DELISTED also when its account
    ///         is delisted (`isFederationDelisted`). NONE if never listed.
    /// @param token The token.
    /// @return artistId The artist it is listed under, or zero.
    /// @return status Its status.
    function federatedListing(address token)
        external
        view
        returns (uint256 artistId, FederationStatus status);
    /// @notice The package registry, the only `register` caller.
    /// @return The package registry, or zero before it is bound.
    function packageRegistry() external view returns (address);
    /// @notice The bound 6529 Stream.
    /// @return The 6529 Stream contract, or zero before it is bound.
    function stream() external view returns (address);
    /// @notice The current federation registry.
    /// @return The federation registry, or zero.
    function federationRegistry() external view returns (address);
    /// @notice The bound split factory.
    /// @return The split factory, or zero before it is bound.
    function splitFactory() external view returns (address);
    /// @notice The bound statement log.
    /// @return The statement log, or zero.
    function statementLog() external view returns (address);
}

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
contract ArtistRegistry is IArtistRegistryV1, AccessManaged, EIP712 {
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

    /// @inheritdoc IArtistRegistryV1
    mapping(address account => uint256) public override artistIdOf;
    /// @inheritdoc IArtistRegistryV1
    mapping(address account => uint256) public override reservedFor;
    /// @inheritdoc IArtistRegistryV1
    IConsolidationSource public override consolidationSource;
    /// @inheritdoc IArtistRegistryV1
    bytes32 public override consolidationSourceCodeHash;
    /// @inheritdoc IArtistRegistryV1
    address public override packageRegistry;
    /// @inheritdoc IArtistRegistryV1
    address public override stream;
    /// @inheritdoc IArtistRegistryV1
    address public override federationRegistry;
    /// @inheritdoc IArtistRegistryV1
    address public override splitFactory;
    /// @inheritdoc IArtistRegistryV1
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

    /// @inheritdoc IArtistRegistryV1
    function bindPackageRegistry(address target) external restricted {
        Dependency.check(target, type(IPackageRegistry).interfaceId);
        packageRegistry = _bind("PACKAGE_REGISTRY", packageRegistry, target);
    }

    /// @inheritdoc IArtistRegistryV1
    function setPackageRegistry(address expected, address next) external restricted {
        if (expected != packageRegistry) revert ExpectedValueMismatch();
        Dependency.check(next, type(IPackageRegistry).interfaceId);
        packageRegistry = next;
        emit PackageRegistrySet(expected, next);
    }

    /// @inheritdoc IArtistRegistryV1
    function bindStream(address target) external restricted {
        Dependency.check(target, type(IStream).interfaceId);
        stream = _bind("STREAM", stream, target);
    }

    /// @inheritdoc IArtistRegistryV1
    function bindFederationRegistry(address target) external restricted {
        Dependency.check(target, type(IFederationRegistry).interfaceId);
        federationRegistry = _bind("FEDERATION_REGISTRY", federationRegistry, target);
    }

    /// @inheritdoc IArtistRegistryV1
    /// @dev A zero successor is refused, so the pointer never returns to the unbound state.
    function setFederationRegistry(address expected, address next) external restricted {
        if (expected != federationRegistry) revert ExpectedValueMismatch();
        Dependency.check(next, type(IFederationRegistry).interfaceId);
        federationRegistry = next;
        emit FederationRegistrySet(expected, next);
    }

    /// @inheritdoc IArtistRegistryV1
    /// @dev The factory does not implement ERC-165, so only code and no EIP-7702 are checked.
    function bindSplitFactory(address target) external restricted {
        Dependency.check(target);
        splitFactory = _bind("SPLIT_FACTORY", splitFactory, target);
    }

    /// @inheritdoc IArtistRegistryV1
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

    /// @inheritdoc IArtistRegistryV1
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

    /// @inheritdoc IArtistRegistryV1
    function register(address root, bytes32 profileId, bytes32 profileDocHash)
        external
        returns (uint256)
    {
        if (msg.sender != packageRegistry) revert UnboundCaller(msg.sender);
        return _create(root, profileId, profileDocHash);
    }

    /// @inheritdoc IArtistRegistryV1
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

    /// @inheritdoc IArtistRegistryV1
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

    /// @inheritdoc IArtistRegistryV1
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

    /// @inheritdoc IArtistRegistryV1
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

    /// @inheritdoc IArtistRegistryV1
    function cancelReplacement(uint256 artistId) external restricted {
        if (_pending[artistId].kind != ChangeKind.REPLACEMENT) revert NoPendingChange(artistId);
        _clear(artistId, msg.sender, true);
    }

    /// @inheritdoc IArtistRegistryV1
    function cancelOwnChange(uint256 artistId) external restricted {
        if (_pending[artistId].kind != ChangeKind.OWN) revert NoPendingChange(artistId);
        _clear(artistId, msg.sender, true);
    }

    /// @inheritdoc IArtistRegistryV1
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

    /// @inheritdoc IArtistRegistryV1
    function expireContest(uint256 artistId) external {
        PendingChange storage p = _pending[artistId];
        if (p.contestedAt == 0) revert NotContested(artistId);
        if (!_lapsed(p)) revert ContestNotExpired(artistId, p.contestedAt + CONTEST_LAPSE);
        emit ContestExpired(artistId);
        _clear(artistId, address(this), false);
    }

    /// @inheritdoc IArtistRegistryV1
    function executeChange(uint256 artistId) external {
        PendingChange storage p = _pendingOf(artistId);
        if (p.contestedAt != 0) revert ReplacementContested(artistId);
        // Delays are wall-clock bounds; validator drift is immaterial.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < p.executableAt) revert ChangeNotDue(artistId, p.executableAt);
        _requireUnfrozen(artistId, _artists[artistId]);
        _apply(artistId, p);
    }

    /// @inheritdoc IArtistRegistryV1
    function revokeNonce(uint256 artistId) external {
        Artist storage a = _artist(artistId);
        if (!isWallet(artistId, msg.sender)) revert NotAuthorized(artistId, msg.sender);
        emit NonceRevoked(artistId, a.nonce++);
    }

    /// @inheritdoc IArtistRegistryV1
    function freeze(uint256 artistId) external restricted {
        Artist storage a = _artist(artistId);
        _requireUnfrozen(artistId, a);
        uint48 until = _now() + FREEZE_PERIOD;
        a.frozenUntil = until;
        emit AccountFrozen(artistId, until);
    }

    /// @inheritdoc IArtistRegistryV1
    function unfreeze(uint256 artistId) external restricted {
        _artist(artistId).frozenUntil = 0;
        emit AccountUnfrozen(artistId);
    }

    // ----- federation directory -----

    /// @inheritdoc IArtistRegistryV1
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

    /// @inheritdoc IArtistRegistryV1
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

    /// @inheritdoc IArtistRegistryV1
    function setFederationDelisted(uint256 artistId, bool delisted, bytes32 ref)
        external
        restricted
    {
        Artist storage a = _artist(artistId);
        emit FederationDelistedSet(artistId, a.delisted, delisted, ref);
        a.delisted = delisted;
    }

    /// @inheritdoc IArtistRegistryV1
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
            || interfaceId == type(IArtistRegistryV1).interfaceId;
    }

    /// @inheritdoc IArtistRegistryV1
    function artist(uint256 artistId)
        external
        view
        returns (ArtistIdentity memory identity, uint48 frozenUntil_)
    {
        Artist storage a = _artist(artistId);
        return (ArtistIdentity(a.root, a.payout, a.profileId, a.profileDocHash), a.frozenUntil);
    }

    /// @inheritdoc IArtistRegistryV1
    function authorityOf(uint256 artistId) external view returns (address) {
        return _artist(artistId).root;
    }

    /// @inheritdoc IArtistRegistryV1
    function activeAuthorityOf(uint256 artistId) external view returns (address) {
        Artist storage a = _artist(artistId);
        return _blocked(artistId, a) ? address(0) : a.root;
    }

    /// @inheritdoc IArtistRegistryV1
    function pendingChange(uint256 artistId) external view returns (PendingChange memory) {
        return _pending[artistId];
    }

    /// @inheritdoc IArtistRegistryV1
    function changeNonce(uint256 artistId) external view returns (uint256) {
        return _artists[artistId].nonce;
    }

    /// @inheritdoc IArtistRegistryV1
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
    ///      struct's fields (`abi.encode`), in this registry's domain.
    function _listingDigest(FederatedListing calldata listing) private view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(Typehashes.FEDERATED_LISTING, listing)));
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

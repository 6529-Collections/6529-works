// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistPayoutResolver } from "../economics/interfaces/IArtistPayoutResolver.sol";
import { IAccounts } from "./IAccounts.sol";
import { IArtistRoleResolver } from "./IArtistRoleResolver.sol";
import { ArtistIdentity, PendingChange } from "./types/IdentityTypes.sol";

/// @title IConsolidationSource
/// @notice Where the artist registry learns whether a wallet belongs to an account: whether it
///         is consolidated with the account's root (6529 consolidation).
/// @dev The v1 adapter reads the 6529 delegation contract
///      (`0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d`, use case 999, all collections): a live
///      two-way consolidation, with no minimum age. The network replaces the source with
///      `IArtistRegistry.setConsolidationSource` (a 6529-chain source later). The registry never
///      asks the source about the root itself, so a failing source never locks an account out:
///      a source that reverts answers "no" for every other wallet. A source that runs short of
///      gas must fail in a way the registry recognises (`BoundedCall`'s shortfall), never by
///      answering "no" while it still holds gas.
interface IConsolidationSource is IERC165 {
    /// @notice Whether `wallet` has a live two-way consolidation with `root`.
    /// @param root The account's root wallet.
    /// @param wallet The wallet to check.
    /// @return True if the two are consolidated both ways now.
    function isConsolidated(address root, address wallet) external view returns (bool);
}

/// @title IArtistRegistry
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
///        It waits 2 days and any wallet of the account may cancel it. A new root must already
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
///      reads zero (split wallets hold its money) and no pending change executes. A freeze
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
interface IArtistRegistry is IArtistRoleResolver, IArtistPayoutResolver, IAccounts {
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
    event ChangeContested(uint256 indexed artistId, address indexed by);
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
    /// @param delisted Whether the account is now delisted.
    /// @param ref The network's reference for the decision.
    event FederationDelistedSet(uint256 indexed artistId, bool delisted, bytes32 ref);
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
    /// @notice Applies a vote on a contested replacement: upholding executes it (once its notice
    ///         passed), voiding deletes it. `outcomeRef` must be
    ///         `IStatementLog.latestDisputeOutcome(address(this), artistId)` and differ from the
    ///         outcome that was latest when the contest began. A network action (24 hours).
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

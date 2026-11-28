// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistPayoutResolver } from "../economics/interfaces/IArtistPayoutResolver.sol";
import { IAccounts } from "./core/IAccounts.sol";
import { IArtistRoleResolver } from "./IArtistRoleResolver.sol";
import { ArtistIdentity, PendingChange } from "./types/IdentityTypes.sol";

/// @title IConsolidationSource
/// @notice Where the accounts module learns whether a wallet belongs to an account: whether it
///         is consolidated with the account's root (6529 consolidation).
/// @dev The v1 adapter reads the 6529 delegation contract
///      (`0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d`, use case 999, all collections): a live
///      two-way consolidation, with no minimum age. The network replaces the source with
///      `IArtistRegistry.setConsolidationSource` (a 6529-chain source later). The module never
///      asks the source about the root itself, so a failing source never locks an account out:
///      a source that reverts answers "no" for every other wallet. A source that runs short of
///      gas must fail in a way the module recognises (`BoundedCall`'s shortfall), never by
///      answering "no" while it still holds gas.
interface IConsolidationSource is IERC165 {
    /// @notice Whether `wallet` has a live two-way consolidation with `root`.
    /// @param root The account's root wallet.
    /// @param wallet The wallet to check.
    /// @return True if the two are consolidated both ways now.
    function isConsolidated(address root, address wallet) external view returns (bool);
}

/// @title IArtistRegistry
/// @notice The accounts module: artist accounts, their payout and profile. An account is a 6529
///         consolidated account: its root wallet and every wallet consolidated with the root act
///         for it with the same rights (`IAccounts`). The module is replaceable: the permanent
///         `StreamDirectory6529` names the current one (slot `ACCOUNTS`), and the split ledger
///         reaches it only through `StreamDirectory6529.payoutAddress`.
/// @dev Artist IDs: an account's ID is `artistIdOf(wallet)` when nonzero, otherwise
///      `uint256(uint160(wallet))`, the ID its first package acceptance creates. IDs fit 160 bits
///      and never change when the root does; every address that has been an account's root maps
///      to its ID forever. An address that never registered is its own single-wallet account.
///
///      Changes. One change may be pending per account:
///      - OWN: any wallet of the account signs `Typehashes.IDENTITY_CHANGE` (relayed by anyone).
///        It waits 2 days; any wallet of the account, or the network (`cancelOwnChange`), may
///        cancel it. A new root must already be a wallet of the account.
///      - REPLACEMENT: the network replaces the root (and with it payout and profile), with 14
///        days' public notice and the new root's signed acceptance. It replaces a pending OWN
///        change. Any wallet of the account may contest it during the notice, while the account
///        is not frozen; a contested replacement runs only if the network upholds it, citing a
///        DISPUTE_OUTCOME statement recorded after the contest, within 90 days of the contest;
///        otherwise it lapses. The network may withdraw its own replacement at any time
///        (`cancelReplacement`).
///      While a replacement is pending (and has not lapsed) the account has no acting wallet:
///      `isWallet` is false, `activeAuthorityOf` is zero.
///
///      Freeze. The network may freeze an account at once for 14 days (`freeze`), and end a
///      freeze early (`unfreeze`). While frozen the account has no acting wallet, its payout
///      reads zero (split wallets hold its money) and no pending change executes, with one
///      exception: the network's own `resolveContested` may uphold a contested replacement
///      while the account is frozen (the freeze then still runs for the new identity).
///      A freeze blocks a contest of a replacement: nobody can contest while the account is
///      frozen, so a freeze placed together with a replacement leaves no moment to contest it,
///      and a contest binds only a network that does not also freeze the account.
///      A freeze can be placed again: `freeze` is refused while a freeze runs, but once a freeze
///      ended, or the network ended it with `unfreeze`, the network may freeze the account again
///      at once for another 14 days.
///
///      The 2-day, 14-day, 90-day and 14-day numbers are compiled into this module. The module is
///      replaceable, so they are its current rules, not promises of the permanent contracts.
interface IArtistRegistry is IArtistRoleResolver, IArtistPayoutResolver, IAccounts {
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
    /// @param by The wallet or network caller that ended it, or this module when it cleared the
    ///        change itself (a lapsed contest, a failed execution re-check).
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
    /// @param previous The package registry before (zero at deployment).
    /// @param next The package registry after.
    event PackageRegistrySet(address previous, address next);

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
    /// @notice The next identity is not acceptable: a zero root or payout, a payout this module
    ///         refuses, a new root that is not a wallet of the account (OWN), the same root
    ///         (REPLACEMENT), or a zero evidence hash.
    error InvalidIdentity();
    /// @notice A replacement acceptance with this digest was already consumed.
    error AcceptanceUsed(bytes32 digest);
    /// @notice The caller is not the contract allowed to call this function.
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

    /// @notice Replaces the package registry, the only `register` caller. A network action,
    ///         compare-and-set. Existing accounts are unaffected.
    /// @param expected The current package registry (`ExpectedValueMismatch` otherwise).
    /// @param next The successor: a contract, not an EIP-7702 delegated account.
    function setPackageRegistry(address expected, address next) external;
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
    ///         The package registry only, after it verified the signed acceptance. Reverts with
    ///         `AccountTaken` if the address is mapped or reserved.
    /// @param root The accepting wallet, which becomes the root and the payout.
    /// @param profileId The artist's claimed 6529 profile ID, from the signed acceptance.
    /// @param profileDocHash The hash of the profile document, from the signed acceptance.
    /// @return artistId `uint256(uint160(root))`.
    function register(address root, bytes32 profileId, bytes32 profileDocHash)
        external
        returns (uint256 artistId);
    /// @notice Creates an account exactly as `register` does, for an uncurated (Independent Stream)
    ///         artist. The Independent Stream module only
    ///         (`StreamDirectory6529.moduleOf(Slots.INDEPENDENT_STREAM)`). `account` signs
    ///         `ArtistRegistration` in this module's EIP-712 domain (`registrationDigest`).
    /// @param account The consenting wallet, which becomes the root and the payout.
    /// @param profileId The artist's claimed 6529 profile ID, as signed.
    /// @param profileDocHash The hash of the profile document, as signed.
    /// @param deadline The Unix time in seconds after which the signature is expired.
    /// @param signature `account`'s signature (ECDSA, EIP-7702 or ERC-1271).
    /// @return artistId `uint256(uint160(account))`.
    function registerIndependent(
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
    ///         network action. It needs the new root's `REPLACEMENT_ACCEPTANCE` signature,
    ///         consumed once by digest, and replaces a pending OWN change.
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
    ///         current root, ignoring the replacement itself. Refused while the account is frozen
    ///         (`AccountIsFrozen`): a freeze blocks a contest.
    /// @param artistId The account whose pending change is cancelled or contested.
    function cancelChange(uint256 artistId) external;
    /// @notice The network withdraws its own pending replacement, contested or not. A network
    ///         action.
    /// @param artistId The account whose replacement is withdrawn.
    function cancelReplacement(uint256 artistId) external;
    /// @notice The network cancels an account's own pending change. A network action; the
    ///         account may stage a new one.
    /// @param artistId The account whose own change is cancelled.
    function cancelOwnChange(uint256 artistId) external;
    /// @notice Applies a vote on a contested replacement: upholding executes it (once its notice
    ///         passed), voiding deletes it. `outcomeRef` must be
    ///         `IStatementLog.latestDisputeOutcome(address(this), artistId)` and differ from the
    ///         outcome that was latest when the contest began. A network action. It is not held
    ///         by a freeze: upholding executes during one, and the freeze keeps running for the
    ///         new identity.
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
    /// @notice Freezes the account for 14 days from now. A network action. Refused while a
    ///         freeze runs (`AccountIsFrozen`); once it ended or was lifted (`unfreeze`) the
    ///         network may place a freeze again. A freeze blocks a contest of a replacement.
    /// @param artistId The account to freeze.
    function freeze(uint256 artistId) external;
    /// @notice Ends the account's freeze now. A network action. The network may freeze the
    ///         account again at once afterwards.
    /// @param artistId The account to unfreeze.
    function unfreeze(uint256 artistId) external;

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
    /// @dev A root lookup only: another wallet of the account (one consolidated with its root)
    ///      answers zero. The module stores no wallet-to-account index; membership is asked of
    ///      the consolidation source at the time, so to test a wallet against a known account
    ///      use `IAccounts.isWallet(artistId, wallet)`.
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
    /// @return The source the module reads consolidations from.
    function consolidationSource() external view returns (IConsolidationSource);
    /// @notice The code hash pinned when the consolidation source was installed.
    /// @return The pinned code hash.
    function consolidationSourceCodeHash() external view returns (bytes32);
    /// @notice The package registry, the only `register` caller.
    /// @return The package registry.
    function packageRegistry() external view returns (address);
    /// @notice The permanent directory that names this module and the Independent Stream module.
    /// @return The directory.
    function directory() external view returns (address);
    /// @notice 6529 Stream, whose address is refused as a payout.
    /// @return The 6529 Stream contract.
    function stream() external view returns (address);
    /// @notice 6529 Stream Editions, whose address is refused as a payout.
    /// @return The 6529 Stream Editions contract.
    function editions() external view returns (address);
    /// @notice The current Independent Stream module, the only `registerIndependent` caller: the
    ///         directory's `INDEPENDENT_STREAM` slot.
    /// @return The Independent Stream module, or zero.
    function independentStreamRegistry() external view returns (address);
    /// @notice The split factory, whose wallets are refused as payouts.
    /// @return The split factory.
    function splitFactory() external view returns (address);
    /// @notice The statement log `resolveContested` reads, or zero.
    /// @return The statement log.
    function statementLog() external view returns (address);

    /// @inheritdoc IAccounts
    function payoutAddress(uint256 artistId)
        external
        view
        override(IAccounts, IArtistPayoutResolver)
        returns (address);
}

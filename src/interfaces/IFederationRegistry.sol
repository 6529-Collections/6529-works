// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IFederationRegistry
/// @notice The replaceable admission layer of 6529 Stream Federated (ADR 0008): which code hashes
///         are reviewed template versions, which sale adapters may mint new federated works, and
///         the read surface the shared sale adapters and the templates use. The permanent,
///         logs-only directory is the artist registry's (`IArtistRegistry.federatedListing` and
///         its events), which a registry writes and which outlives every replacement of it.
/// @dev This interface is what other contracts call, so every registry the artist registry's
///      replaceable pointer ever names must answer it (ERC-165): the shared adapters read
///      `isActive` and `entry`, and every deployed template reads `canMint` for each new work
///      and calls `register` once, to join. A registry stores no entry: an entry is composed on
///      read from the artist registry's directory (artist and status), the token's own locked
///      storage (fee terms, partner), and the registry's table of template code hashes (form
///      and version). Nothing migrates when the registry is replaced.
///      Through the artist registry a registry may only create an identity for an account that
///      signed for it, list a non-canonical contract whose artist signed for it, and set a
///      listed contract ACTIVE or DELISTED; it has no authority over any artist's identity or
///      payout, nor over any token, work or fund. A listed contract stays listed for good (there
///      is no exit); the network delists it here, or every contract of an account at once in the
///      artist registry (`IAccounts.isFederationDelisted`).
interface IFederationRegistry is IERC165 {
    /// @notice What a federated contract is: the 1/1 template or the linked pair's editions.
    ///         `PAIR` is not used by the v1 templates (each half is listed on its own, with its
    ///         partner); it is kept so the encoding never changes.
    enum Form {
        ERC721,
        ERC1155,
        PAIR
    }

    /// @notice A contract's status as the adapters see it.
    enum Status {
        NONE,
        ACTIVE,
        DELISTED
    }

    /// @notice A contract's entry, composed on read. Every field but `status` is fixed for good
    ///         once the contract is listed.
    /// @param form The template's form.
    /// @param partner The other half of a linked pair, or zero.
    /// @param artistId The artist the contract is listed under.
    /// @param templateVersion The version the template table gives its code hash.
    /// @param codeHash The contract's runtime code hash.
    /// @param feeShare The network's share of primary sales and royalties now, out of 100,000:
    ///        the smaller of the share fixed in the contract at deployment and the artist
    ///        registry's record for it (`IAccounts.federatedFeeShare`), which can only fall.
    /// @param status Its status.
    struct Entry {
        Form form;
        address partner;
        uint256 artistId;
        uint32 templateVersion;
        bytes32 codeHash;
        uint32 feeShare;
        Status status;
    }

    /// @notice What a template passes to join (`IFederatedToken.joinFederation`, `register`).
    /// @param profileId The artist's claimed 6529 profile ID (used only to create an identity).
    /// @param profileDocHash The profile document's hash (likewise).
    /// @param deadline The expiry of both signatures below.
    /// @param registration The artist account's `ArtistRegistration` signature, or empty when the
    ///        artist already has an identity.
    /// @param consent The artist's active authority's `FederatedListing` signature for this
    ///        contract, which the artist registry verifies (`listFederatedContract`).
    struct Join {
        bytes32 profileId;
        bytes32 profileDocHash;
        uint64 deadline;
        bytes registration;
        bytes consent;
    }

    /// @notice A template contract joined: the artist registry listed it. Its deployer's
    ///         `Deployed` event names its constructor arguments.
    /// @param token The federated contract.
    /// @param artistId The artist it is listed under.
    /// @param codeHash Its runtime code hash, an approved template version.
    /// @param deployer The version's deployer, which recorded the contract.
    event Registered(
        address indexed token, uint256 indexed artistId, bytes32 codeHash, address deployer
    );

    /// @notice Unknown or unusable template code, or a contract this registry cannot list.
    /// @param token The contract.
    error NotListable(address token);

    /// @notice Lists the calling contract under its artist (`IArtistRegistry
    ///         .listFederatedContract`, which verifies the artist's consent), first creating the
    ///         artist's identity from the artist's own signature if it has none
    ///         (`IArtistRegistry.registerFederated`). The caller must run an approved,
    ///         unsuspended template version and be a copy that version's approved deployer
    ///         recorded (`IFederatedDeployer.deployed`); it must name the canonical artist
    ///         registry, split ledger and (a 1/1
    ///         template) content store, and lock the network's current federated fee share and
    ///         recipient (`NotListable`). A partner must run an approved template of the other
    ///         form and name the caller back, with the same artist and terms; a 1/1 template's
    ///         partner must already be listed ACTIVE under the same artist.
    /// @param j The identity fields and the artist's signatures (`Join`).
    function register(Join calldata j) external;

    /// @notice A contract's entry; all zero (`status` NONE) for a contract that is not listed or
    ///         whose code hash this registry does not know. Every
    ///         shared adapter locks a new sale's fee from this answer and requires its code hash
    ///         to be the token's, so a contract without an entry starts no sale there.
    /// @param token The federated contract.
    /// @return The entry.
    function entry(address token) external view returns (Entry memory);

    /// @notice Whether the shared adapters serve `token`'s running sales: listed ACTIVE and its
    ///         template version approved or suspended (not revoked). A delisted contract's running
    ///         sales end unsold with refunds. A new work or sale also needs `canMint`.
    /// @param token The federated contract.
    /// @return True while it is served.
    function isActive(address token) external view returns (bool);

    /// @notice Whether `adapter` may mint a new work into `token` now: an admitted adapter, a
    ///         contract listed ACTIVE, and a template version approved and not suspended; for an
    ///         editions contract, its partner listed ACTIVE too.
    /// @param token The federated contract (the caller, when a template asks).
    /// @param adapter The sale adapter asking to mint.
    /// @return True when the mint may proceed.
    function canMint(address token, address adapter) external view returns (bool);

    /// @notice Reverses a template revocation: REVOKED to APPROVED. The network. Contracts that
    ///         `propagateRevocation` delisted stay delisted until the network relists them.
    /// @param codeHash The template code hash.
    function reinstateTemplate(bytes32 codeHash) external;

    /// @notice The entropy module whose federated seeds (`IEntropyModule.federatedSeedOf`) a VRF
    ///         work of a federated contract stores at its first mint; zero when there is none.
    /// @return The entropy module.
    function entropyModule() external view returns (address);
}

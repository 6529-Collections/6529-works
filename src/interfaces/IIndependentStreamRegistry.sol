// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IIndependentStreamRegistry
/// @notice The Independent Stream module (replaceable, found through the permanent
///         `StreamDirectory6529`, slot `INDEPENDENT_STREAM`): the directory of Independent Stream
///         token contracts, which template versions may join, which sale contracts may mint for
///         them, delisting, each contract's network fee share, the artist's item approvals, and the
///         mint policy of Independent Stream works.
/// @dev The read surface the shared sale contracts use (`entry`, `isActive`, `canMint`,
///      `entropyModule`) keeps its shape. An Independent Stream token asks the module the directory
///      names now (`IIndependentStreamGate`), so a replacement takes effect for every Independent
///      Stream token at once, after the network's waiting period for the directory slot. A
///      replacement module is deployed naming its predecessor (`previous`) and inherits, without
///      any artist signature, every listing, account delisting, template version and sale contract
///      its predecessor answers, until it records its own. Item approvals and content releases are
///      not inherited: the artist approves again and the network releases again.
///
///      A listed contract stays listed for good (there is no exit). The network delists it, or
///      every contract of an account at once; a delisted contract mints nothing and opens no new
///      sale, and its running sales end unsold with refunds. The network's share of a contract
///      is recorded at listing and only ever lowered.
///
///      Template versions. Each copy of an Independent Stream token has its own runtime code (its
///      constructor arguments are immutables), so a version is identified by its ownerless
///      `IndependentStreamDeployer`, which holds one creation code and records every copy it
///      deploys. A contract joins only if an approved deployer recorded it.
interface IIndependentStreamRegistry is IERC165 {
    /// @notice What an Independent Stream contract is: the 1/1 token or its editions. `PAIR` is not
    ///         used; it is kept so the encoding never changes.
    enum Form {
        ERC721,
        ERC1155,
        PAIR
    }

    /// @notice A contract's status as the sale contracts see it.
    enum Status {
        NONE,
        ACTIVE,
        DELISTED
    }

    /// @notice A template version's status. The network can reinstate a REVOKED one.
    enum TemplateStatus {
        NONE,
        APPROVED,
        SUSPENDED,
        REVOKED
    }

    /// @notice A contract's entry, composed on read. Every field but `feeShare` and `status` is
    ///         fixed once the contract is listed (an ERC-721's `partner` is set once, when its
    ///         editions list).
    /// @param form The contract's form.
    /// @param partner The other half of a pair (an ERC-721's editions, an ERC-1155's stream),
    ///        or zero.
    /// @param artistId The artist the contract is listed under.
    /// @param templateVersion The version of the deployer that recorded it.
    /// @param codeHash The contract's runtime code hash.
    /// @param feeShare The network's share of primary sales and royalties now, out of 100,000.
    /// @param status Its status, DELISTED also when its account is delisted.
    struct Entry {
        Form form;
        address partner;
        uint256 artistId;
        uint32 templateVersion;
        bytes32 codeHash;
        uint32 feeShare;
        Status status;
    }

    /// @notice A template version: an approved `IndependentStreamDeployer`.
    /// @param version Its version number.
    /// @param form The form of the copies it deploys.
    /// @param status Its status.
    struct Template {
        uint32 version;
        Form form;
        TemplateStatus status;
    }

    /// @notice A listing as stored.
    /// @param artistId The artist the contract is listed under.
    /// @param status Its own status (NONE: not listed).
    /// @param form Its form.
    /// @param feeShare The network's share, out of 100,000: recorded at listing, only lowered.
    /// @param deployer The deployer that recorded it.
    /// @param partner The other half of its pair, or zero.
    struct Listing {
        uint160 artistId;
        Status status;
        Form form;
        uint32 feeShare;
        address deployer;
        address partner;
    }

    /// @notice What `register` takes besides the token.
    /// @param deployer The approved `IndependentStreamDeployer` that recorded the token.
    /// @param profileId The artist's claimed 6529 profile ID (used only to create an identity).
    /// @param profileDocHash The profile document's hash (likewise).
    /// @param deadline The expiry of both signatures below, inclusive.
    /// @param registration The artist account's `ArtistRegistration` signature in the accounts
    ///        module's domain, or empty when the artist already has an identity.
    /// @param consent `abi.encodePacked(wallet, signature)`: a wallet of the artist's account
    ///        consents to `listingSubject` for this module (`IAccounts.requireConsent`).
    struct Join {
        address deployer;
        bytes32 profileId;
        bytes32 profileDocHash;
        uint64 deadline;
        bytes registration;
        bytes consent;
    }

    /// @notice An item the artist approved for one mint.
    /// @param approved Whether a mint of it may proceed.
    /// @param used Whether it was minted (an item mints once).
    /// @param royaltyRate The royalty rate a work of it gets, out of 100,000.
    struct Item {
        bool approved;
        bool used;
        uint24 royaltyRate;
    }

    /// @notice An Independent Stream sale contract's standing.
    /// @param addedAt When the network added it; zero if never.
    /// @param removedAt When the network removed it; zero while it is not removed.
    /// @param form The one form of token it mints for: ERC721 (1/1 works) or ERC1155
    ///        (editions).
    struct SaleContract {
        uint48 addedAt;
        uint48 removedAt;
        Form form;
    }

    /// @notice A burned work's content released by the network.
    /// @param tokenId The burned token the release is for.
    /// @param beneficiary The artist the content is released to (the token's artist).
    struct Release {
        uint256 tokenId;
        uint256 beneficiary;
    }

    /// @notice A template version was approved or its status changed.
    /// @param deployer The version's deployer.
    /// @param creationHash The keccak256 of the creation code it deploys.
    /// @param version Its version.
    /// @param form Its form.
    /// @param status Its status now.
    event TemplateSet(
        address indexed deployer,
        bytes32 creationHash,
        uint32 version,
        Form form,
        TemplateStatus status
    );
    /// @notice A contract was listed, ACTIVE.
    /// @param token The Independent Stream contract.
    /// @param artistId The artist it is listed under.
    /// @param deployer The deployer that recorded it.
    /// @param form Its form.
    /// @param partner The other half of its pair, or zero.
    /// @param feeShare The network's share recorded, out of 100,000.
    event Registered(
        address indexed token,
        uint256 indexed artistId,
        address deployer,
        Form form,
        address partner,
        uint32 feeShare
    );
    /// @notice A contract's own status changed.
    /// @param token The contract.
    /// @param previous The status before.
    /// @param status The status now.
    /// @param ref The network's reference for the decision.
    event StatusSet(address indexed token, Status previous, Status status, bytes32 ref);
    /// @notice The network delisted a whole account, or ended that.
    /// @param artistId The account.
    /// @param delisted Whether it is delisted now.
    /// @param ref The network's reference for the decision.
    event AccountDelistedSet(uint256 indexed artistId, bool delisted, bytes32 ref);
    /// @notice The network lowered a contract's fee share.
    /// @param token The contract.
    /// @param previous The share before.
    /// @param share The share now.
    event FeeShareLowered(address indexed token, uint32 previous, uint32 share);
    /// @notice An Independent Stream sale contract was added or removed.
    /// @param minter The sale contract.
    /// @param form The form of token it mints for.
    /// @param addedAt When it was added.
    /// @param removedAt When it was removed, zero while it is not.
    event SaleContractSet(address indexed minter, Form form, uint48 addedAt, uint48 removedAt);
    /// @notice The artist approved an item for one mint, or withdrew it.
    /// @param token The Independent Stream contract.
    /// @param itemHash The item hash.
    /// @param royaltyRate The royalty rate a work of it gets.
    /// @param approved Whether a mint of it may proceed.
    event ItemApproval(
        address indexed token, bytes32 indexed itemHash, uint24 royaltyRate, bool approved
    );
    /// @notice A sale contract consumed an approved item to mint it.
    /// @param token The Independent Stream contract.
    /// @param itemHash The item hash.
    /// @param minter The sale contract.
    /// @param seller The seller vault, deployed.
    /// @param royaltyReceiver The royalty receiver, deployed.
    event ItemMinted(
        address indexed token,
        bytes32 indexed itemHash,
        address indexed minter,
        address seller,
        address royaltyReceiver
    );
    /// @notice An item was barred for good by a content release.
    /// @param itemHash The burned work's item hash.
    event ItemBarred(bytes32 indexed itemHash);
    /// @notice The network changed the entropy module of Independent Stream VRF works.
    /// @param previous The module before.
    /// @param next The module now.
    event EntropyModuleSet(address previous, address next);

    /// @notice The contract cannot be listed: already listed, not recorded by the named approved
    ///         deployer, its account delisted, its directory or record contract not this
    ///         deployment's, or (editions) its stream not listed ACTIVE under the same artist or
    ///         already paired.
    /// @param token The contract.
    error NotListable(address token);
    /// @notice The transition is not allowed from the template's current status.
    error TemplateStatusInvalid(address deployer, TemplateStatus current);
    /// @notice The token is not listed.
    error NotListed(address token);
    /// @notice The share is not lower than the current one.
    error FeeShareNotLowered(address token, uint32 current);
    /// @notice The sale contract is not one, or already one.
    error SaleContractInvalid(address minter);
    /// @notice A batch longer than `MAX_BATCH`.
    error BatchTooLarge(uint256 length);
    /// @notice The caller is not a wallet of the token's artist's account.
    error NotArtist(address token, address caller);
    /// @notice The item is not approved for this token, already minted, or barred.
    error ItemNotApproved(address token, bytes32 itemHash);
    /// @notice The royalty rate is over 100,000.
    error InvalidRoyaltyRate(uint256 rate);
    /// @notice The artist's account may not act now: it is frozen, or a replacement is pending.
    error AccountCannotAct(uint256 artistId);
    /// @notice The mint request breaks a rule: currency, media, kind, seed policy, license,
    ///         parties, payees, or an edition master without listed editions.
    error InvalidMintRequest();
    /// @notice The VRF seed for this token and content is not delivered.
    error SeedNotDelivered(address token, bytes32 contentHash);
    /// @notice The release is refused: the token is live or not the content's token, or the
    ///         beneficiary is not the token's artist.
    error ReleaseRefused(address token, uint256 tokenId);

    /// @notice Lists `token` under its artist, ACTIVE, with the network's current Independent
    ///         Stream share (`IEconomicsResolver.economics(PRODUCT_INDEPENDENT).feeShare`). Anyone
    ///         may relay it. `j.deployer` must be an APPROVED template version that recorded
    ///         `token`; the token must name this deployment's directory (and, a 1/1, its record
    ///         contract); its account must not be delisted. An editions contract lists after its
    ///         stream, which must be listed ACTIVE under the same artist and not yet paired. If the
    ///         artist has no identity, it is created from its own signature
    ///         (`IArtistRegistry.registerIndependent`). A wallet of the artist's account must
    ///         consent (`listingSubject`).
    /// @param token The Independent Stream contract.
    /// @param j The deployer, identity fields and signatures (`Join`).
    function register(address token, Join calldata j) external;

    /// @notice What a wallet of the artist's account consents to when `token` is listed.
    /// @param token The contract.
    /// @param form Its form.
    /// @param partner Its stream (editions) or zero.
    /// @param feeShare The share it is listed with.
    /// @param deadline The consent's expiry.
    /// @return The consent subject passed to `IAccounts.requireConsent`.
    function listingSubject(
        address token,
        Form form,
        address partner,
        uint32 feeShare,
        uint64 deadline
    ) external pure returns (bytes32);

    /// @notice A contract's entry; all zero (`status` NONE) for a contract that is not listed.
    ///         Every shared sale contract locks a new sale's fee from this answer.
    /// @param token The Independent Stream contract.
    /// @return The entry.
    function entry(address token) external view returns (Entry memory);

    /// @notice Whether the shared sale contracts serve `token`'s running sales: listed ACTIVE,
    ///         its account not delisted, and its template version approved or suspended (not
    ///         revoked). A new work or sale also needs `canMint`.
    /// @param token The Independent Stream contract.
    /// @return True while it is served.
    function isActive(address token) external view returns (bool);

    /// @notice Whether `minter` may mint into `token` now: an Independent Stream sale contract
    ///         added and not removed, a contract listed ACTIVE whose account is not delisted, and a
    ///         template version APPROVED; for an editions contract, its stream likewise.
    /// @param token The Independent Stream contract.
    /// @param minter The sale contract.
    /// @return True when the mint may proceed.
    function canMint(address token, address minter) external view returns (bool);

    /// @notice The entropy module whose Independent Stream seeds
    ///         (`IEntropyModule.independentSeedOf`) a VRF work of an Independent Stream contract is
    ///         minted with; zero when there is none.
    /// @return The entropy module.
    function entropyModule() external view returns (address);
}

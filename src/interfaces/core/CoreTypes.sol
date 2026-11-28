// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

/// @notice How a token's first sale ended. `NONE` until its sale contract records it.
enum Outcome {
    NONE,
    SOLD,
    UNSOLD,
    RESCUED
}

/// @notice What a token contract keeps for each work: three storage slots, a fourth only for a
///         work with a seed.
/// @param itemHash The approved item the work was minted from. It commits to the content, the
///        media, the parties, the payees, the license and the sale terms.
/// @param artistId The lead artist's ID (the address the artist first registered with, as a
///        number). Never changes.
/// @param collectionId The collection the work belongs to.
/// @param serial The work's number in its collection, from 1.
/// @param kind The item kind (0 original, 1 edition master). Recorded, never interpreted.
/// @param seedPolicy The seed policy (0 none, 1 artist, 2 VRF). Recorded, never interpreted.
/// @param outcome How the first sale ended: an `Outcome` (0 NONE, 1 SOLD, 2 UNSOLD, 3 RESCUED).
/// @param royaltyReceiver Where ERC-2981 royalties are paid.
/// @param royaltyRate The royalty rate, out of 100,000.
/// @param royaltyRateLocked True once the rate can never change again.
/// @param seed The work's seed, zero if it has none. Fixed at mint.
struct Work {
    bytes32 itemHash;
    uint160 artistId;
    uint32 collectionId;
    uint32 serial;
    uint8 kind;
    uint8 seedPolicy;
    Outcome outcome;
    address royaltyReceiver;
    uint24 royaltyRate;
    bool royaltyRateLocked;
    bytes32 seed;
}

/// @notice What a minter states about a new work. The token contract stores the fields up to
///         `royaltyRate` and logs all of them in `WorkMinted`.
/// @param itemHash The hash of the approved item (nonzero).
/// @param contentHash The SHA-256 of the primary media (nonzero). One live token per content.
/// @param artistId The lead artist's ID (nonzero, at most 160 bits).
/// @param collectionId An existing collection.
/// @param kind The item kind.
/// @param seedPolicy The seed policy.
/// @param seed The seed, or zero.
/// @param royaltyReceiver The royalty receiver.
/// @param royaltyRate The royalty rate, out of 100,000.
/// @param packageRoot The approved package root the item was proved against (logged only).
/// @param mediaHash The commitment to the media list (logged only).
/// @param recordFileId The approved descriptive record's file ID (logged only).
/// @param seller The wallet the artist side of the sale is paid to (logged only).
struct MintFacts {
    bytes32 itemHash;
    bytes32 contentHash;
    uint256 artistId;
    uint256 collectionId;
    uint8 kind;
    uint8 seedPolicy;
    bytes32 seed;
    address royaltyReceiver;
    uint24 royaltyRate;
    bytes32 packageRoot;
    bytes32 mediaHash;
    bytes32 recordFileId;
    address seller;
}

/// @notice A collection of works in one token contract.
/// @param exists True once created.
/// @param minted How many works were minted into it.
/// @param metadataHash The hash of the collection's metadata document.
/// @param name The collection's name. Never changes.
struct Collection {
    bool exists;
    uint32 minted;
    bytes32 metadataHash;
    string name;
}

/// @notice An edition: two storage slots.
/// @param minter The one sale contract that may mint it; zero until the edition is created.
/// @param maxSupply The most copies that may ever exist. Until the seal it is the creator's cap
///        (`type(uint40).max` for no cap); the seal overwrites it with the final maximum,
///        which is at least the count minted and at most that cap (copies up to it may still
///        be minted by the edition's minter). The cap itself is not stored after the seal: it
///        stays in the `EditionCreated` event.
/// @param minted Copies minted so far. Burned copies still count.
/// @param supplySealed True once the supply is fixed for good.
/// @param royaltyReceiver Where ERC-2981 royalties are paid.
/// @param royaltyRate The royalty rate, out of 100,000.
struct Edition {
    address minter;
    uint40 maxSupply;
    uint40 minted;
    bool supplySealed;
    address royaltyReceiver;
    uint24 royaltyRate;
}

/// @notice One media file of a work.
/// @param fileId The content-store file ID.
/// @param role The file's role (0 is the primary file).
struct Media {
    bytes32 fileId;
    uint8 role;
}

/// @notice The permanent record of a work.
/// @param recordFileId The descriptive record's file ID. Frozen at finalize.
/// @param licenseTextFileId The license text's file ID.
/// @param renderer The renderer pinned at finalize, zero before.
/// @param opened True once the record was opened.
/// @param finalized True once finalized. Never reverts to false.
/// @param onChainComplete True once every media file was found complete in the content store.
/// @param licenseLocked True once the license can never change again.
/// @param repinLocked True once the pinned renderer can never change again.
/// @param rendererCodeHash The code hash of the pinned renderer when it was pinned.
/// @param licenseId The SPDX license ID.
/// @param media The media files, primary first. Fixed when the record opens.
struct Facts {
    bytes32 recordFileId;
    bytes32 licenseTextFileId;
    address renderer;
    bool opened;
    bool finalized;
    bool onChainComplete;
    bool licenseLocked;
    bool repinLocked;
    bytes32 rendererCodeHash;
    string licenseId;
    Media[] media;
}

/// @notice A minter's standing in a token contract.
/// @param activeFrom When it may first mint; zero if it was never added.
/// @param removedAt When the network removed it; zero while it is not removed.
/// @param firstActiveFrom When it was first to become active; kept when it is removed and added
///        again. Zero if it was never added; a first addition removed before it became active is
///        cancelled and its whole record deleted.
struct Minter {
    uint48 activeFrom;
    uint48 removedAt;
    uint48 firstActiveFrom;
}

/// @notice A module announced for a slot and not yet installed.
/// @param module The announced module.
/// @param readyAt When anyone may install it.
struct PendingModule {
    address module;
    uint48 readyAt;
}

/// @notice The terms of a primary sale, as the mint policy answers them to the sale contract.
/// @param saleKind The item's sale kind.
/// @param params The sale method's parameters as approved.
/// @param seller The wallet the artist side is paid to.
/// @param feeRecipient The network's fee recipient when the sale starts.
/// @param feeShare The network's share of the price, out of 100,000.
/// @param creator The lead artist's acting wallet, which signed the move.
struct MintTerms {
    bytes32 saleKind;
    bytes params;
    address seller;
    address feeRecipient;
    uint32 feeShare;
    address creator;
}

/// @notice The names of the module slots.
library Slots {
    /// @dev Token contracts: the module that sets royalty receivers and rates.
    bytes32 internal constant TERMS = "TERMS";
    /// @dev Token contracts: the renderer of works that are not finalized.
    bytes32 internal constant RENDERER = "RENDERER";
    /// @dev Token contracts: the module that may change a work's record within `IWorkFacts`.
    bytes32 internal constant RECORDS = "RECORDS";
    /// @dev Directory: the accounts module (`IAccounts`).
    bytes32 internal constant ACCOUNTS = "ACCOUNTS";
    /// @dev Directory: the Independent Stream module (`IIndependentStreamGate`).
    bytes32 internal constant INDEPENDENT_STREAM = "INDEPENDENT_STREAM";
    /// @dev Directory: the TERMS module of every Independent Stream token.
    bytes32 internal constant INDEPENDENT_TERMS = "INDEPENDENT_TERMS";
    /// @dev Directory: the RECORDS module of every Independent Stream token.
    bytes32 internal constant INDEPENDENT_RECORDS = "INDEPENDENT_RECORDS";
}

/// @notice Shared numbers and hashes of the permanent core.
library Core {
    /// @dev Rates and shares are out of this.
    uint256 internal constant DENOMINATOR = 100_000;

    /// @dev The domain of an Independent Stream collaborator's consent
    ///      ({independentConsent}).
    bytes32 internal constant INDEPENDENT_CONSENT_DOMAIN =
        keccak256("6529STREAM_INDEPENDENT_CONSENT_V1");

    /// @notice What a collaborator of an Independent Stream work consents to: the item and the
    ///         royalty rate (ADR 0010). Passed as `what` to `IAccounts.requireConsent`.
    /// @dev `keccak256(abi.encode(INDEPENDENT_CONSENT_DOMAIN, itemHash, royaltyRate))`, three
    ///      whole words of types `(bytes32, bytes32, uint24)`, with
    ///      `INDEPENDENT_CONSENT_DOMAIN = keccak256("6529STREAM_INDEPENDENT_CONSENT_V1")`.
    /// @param itemHash The item hash.
    /// @param royaltyRate The royalty rate, out of 100,000.
    /// @return The consent subject.
    function independentConsent(bytes32 itemHash, uint24 royaltyRate)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(INDEPENDENT_CONSENT_DOMAIN, itemHash, royaltyRate));
    }
}

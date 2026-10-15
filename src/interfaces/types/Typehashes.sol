// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Typehashes
/// @notice Every EIP-712 domain name and typehash, and every Permit2 witness, the v1 interfaces
///         define. Implementations use these constants; golden tests in `test/interfaces/` pin
///         their values (ADR 0001 section 17 "golden typehash tests").
/// @dev Each signing contract uses the EIP-712 domain `(name, DOMAIN_VERSION, chainid, itself)`.
///      Every artist or party signature binds a deadline and either a single-use nonce or a
///      work's state hash. Constants only; nothing here is linked bytecode.
library Typehashes {
    /// @notice The EIP-712 domain version of every v1 contract.
    string internal constant DOMAIN_VERSION = "1";
    /// @notice Domain name of the package registry.
    string internal constant PACKAGE_REGISTRY_NAME = "6529 Works Package Registry";
    /// @notice Domain name of the v1 curation verifier.
    string internal constant CURATION_VERIFIER_NAME = "6529 Works Curation Verifier";
    /// @notice Domain name of the work records satellite.
    string internal constant WORK_RECORDS_NAME = "6529 Works Records";
    /// @notice Domain name of the artist registry.
    string internal constant ARTIST_REGISTRY_NAME = "6529 Works Artist Registry";
    /// @notice Domain name of the fixed-price sale adapter.
    string internal constant FIXED_PRICE_SALE_NAME = "6529 Works Fixed Price Sale";

    /// @notice The lead artist moves an approved item to Stream (package registry domain).
    bytes32 internal constant MOVE_TO_STREAM = keccak256(
        "MoveToStream(bytes32 packageRoot,bytes32 itemHash,uint256 nonce,uint64 deadline)"
    );
    /// @notice A party accepts a package root (package registry domain).
    bytes32 internal constant PACKAGE_ACCEPTANCE = keccak256(
        "PackageAcceptance(bytes32 packageRoot,address account,bytes32 profileId,"
        "bytes32 profileDocHash,uint64 deadline)"
    );
    /// @notice A curation signer approves a package root at its epoch (curation verifier
    ///         domain).
    bytes32 internal constant PACKAGE_APPROVAL = keccak256(
        "PackageApproval(bytes32 packageRoot,bytes32 evidenceHash,uint256 signerEpoch)"
    );
    /// @notice Every party agrees to relicense a work (work records domain).
    bytes32 internal constant RELICENSE = keccak256(
        "Relicense(uint256 tokenId,bytes32 licenseKey,bytes32 textFileId,bytes32 stateHash,"
        "uint64 deadline)"
    );
    /// @notice Every party agrees to change a work's royalty rate (work records domain).
    bytes32 internal constant ROYALTY_RATE_CHANGE = keccak256(
        "RoyaltyRateChange(uint256 tokenId,uint32 rate,bytes32 stateHash,uint64 deadline)"
    );
    /// @notice The lead artist agrees to an errata renderer pin (work records domain).
    bytes32 internal constant RENDERER_REPIN = keccak256(
        "RendererRepin(uint256 tokenId,address renderer,bytes32 rendererCodeHash,"
        "bytes32 stateHash,uint64 deadline)"
    );
    /// @notice An artist identity change, and the new authority's acceptance of it (artist
    ///         registry domain).
    bytes32 internal constant IDENTITY_CHANGE = keccak256(
        "IdentityChange(uint256 artistId,address authority,address payout,bytes32 profileId,"
        "bytes32 profileDocHash,uint256 nonce,uint64 deadline)"
    );
    /// @notice The new authority accepts a network override (artist registry domain). It binds
    ///         no change nonce, so a key holder cannot void it by burning nonces; the registry
    ///         consumes it once by digest.
    bytes32 internal constant OVERRIDE_ACCEPTANCE = keccak256(
        "OverrideAcceptance(uint256 artistId,uint8 kind,address authority,address payout,"
        "bytes32 profileId,bytes32 profileDocHash,bytes32 evidenceHash,uint64 deadline)"
    );
    /// @notice One fixed-price phase, as typed inside `PHASE_CONFIGURATION`.
    bytes32 internal constant PHASE = keccak256(
        "Phase(uint64 start,uint64 end,bytes32 root,uint32 walletCap,bool payerKeyed,"
        "bool leafPriced)"
    );
    /// @notice The creator approves a fixed-price phase configuration, binding the resolved
    ///         currency, the package unit price and every phase (fixed-price domain). The phases
    ///         hash as an EIP-712 array: `keccak256` of the concatenated
    ///         `keccak256(abi.encode(PHASE, phase))` of each phase.
    bytes32 internal constant PHASE_CONFIGURATION = keccak256(
        "PhaseConfiguration(address token,uint256 id,address currency,uint256 packagePrice,"
        "Phase[] phases,uint256 nonce,uint64 deadline)Phase(uint64 start,uint64 end,bytes32 root,"
        "uint32 walletCap,bool payerKeyed,bool leafPriced)"
    );

    // ----- Permit2 witnesses (relayable payment intents, signed in Permit2's own domain) -----

    /// @notice An English-auction bid.
    bytes32 internal constant BID_WITNESS =
        keccak256("Bid(uint256 saleId,address recipient,uint256 amount,uint256 deadline)");
    /// @notice The `witnessTypeString` for `BID_WITNESS`.
    string internal constant BID_WITNESS_TYPE = "Bid witness)Bid(uint256 saleId,address recipient,"
        "uint256 amount,uint256 deadline)TokenPermissions(address token,uint256 amount)";
    /// @notice A start-with-bid; `mintDataHash` is `keccak256(mintData)`, as no sale ID exists yet.
    bytes32 internal constant START_BID_WITNESS = keccak256(
        "StartBid(address token,bytes32 mintDataHash,address recipient,uint256 amount,"
        "uint256 deadline)"
    );
    /// @notice The `witnessTypeString` for `START_BID_WITNESS`.
    string internal constant START_BID_WITNESS_TYPE = "StartBid witness)StartBid(address token,"
        "bytes32 mintDataHash,address recipient,uint256 amount,uint256 deadline)"
        "TokenPermissions(address token,uint256 amount)";
    /// @notice A fixed-price purchase; `amount` is the exact total charged.
    bytes32 internal constant PURCHASE_WITNESS = keccak256(
        "Purchase(uint256 saleId,uint256 phase,address recipient,uint256 quantity,uint256 amount,"
        "uint256 deadline)"
    );
    /// @notice The `witnessTypeString` for `PURCHASE_WITNESS`.
    string internal constant PURCHASE_WITNESS_TYPE = "Purchase witness)Purchase(uint256 saleId,"
        "uint256 phase,address recipient,uint256 quantity,uint256 amount,uint256 deadline)"
        "TokenPermissions(address token,uint256 amount)";
    /// @notice A Dutch purchase; the sale charges the current price, at most `maxUnitPrice` each.
    bytes32 internal constant DUTCH_PURCHASE_WITNESS = keccak256(
        "DutchPurchase(uint256 saleId,address recipient,uint256 quantity,uint256 maxUnitPrice,"
        "uint256 deadline)"
    );
    /// @notice The `witnessTypeString` for `DUTCH_PURCHASE_WITNESS`.
    string internal constant DUTCH_PURCHASE_WITNESS_TYPE = "DutchPurchase witness)DutchPurchase("
        "uint256 saleId,address recipient,uint256 quantity,uint256 maxUnitPrice,uint256 deadline)"
        "TokenPermissions(address token,uint256 amount)";
}

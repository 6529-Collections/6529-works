// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { BoundedParameter } from "../governance/BoundedParameter.sol";
import { IEntropyModule } from "../interfaces/IEntropyModule.sol";
import { IPackageRegistry } from "../interfaces/IPackageRegistry.sol";
import { PackageItem, SeedPolicy } from "../interfaces/types/PackageTypes.sol";
import { WorksHashing } from "../interfaces/types/WorksHashing.sol";
import { Dependency } from "../libraries/Dependency.sol";
import { IVRFCoordinatorV2Plus } from "./IVRFCoordinatorV2Plus.sol";

/// @title VrfEntropyModule
/// @notice The optional VRF module of seeded 1/1s revealed before bidding (ADR 0001 section 9),
///         on Chainlink VRF v2.5 with a subscription. One seed per work, keyed by the work's
///         content hash, never per copy or per package item.
/// @dev Flow (review decision D4). The seed is requested BEFORE a token exists: anyone calls
///      {requestSeed} for a VRF item of an approved package; the coordinator later calls
///      {rawFulfillRandomWords}, which stores the seed and emits `SeedDelivered`, with no call into
///      the token or the auction. The auction never calls this module: its `start` calls 6529
///      Stream's `mint`, which consumes the item and then requires {isDelivered} before it mints;
///      the work-records satellite and the renderer read the seed through {seedOf} by item hash.
///      Nothing is in custody while a seed is outstanding, so nothing can be stuck.
///
///      One draw per content. The draw is keyed by the item's content hash, the registry's
///      per-product uniqueness key, so every approved item carrying the same work (a revised
///      package, or the rightful artist's item after an upheld dispute released the content)
///      reads the same seed: a work has exactly one seed, whichever package lists it.
///      {requestSeed} links the item to its content's draw. For a content with no draw it
///      requests one; for a content whose draw is delivered or still pending, it only links the
///      item and returns zero, and the coordinator is not asked. The reads stay keyed by item
///      hash, through the link, so an item that never called {requestSeed} reads as undelivered.
///
///      Spam gate. Each request spends subscription funds, so a request is accepted only for an
///      item that the network already curated and that needs a seed: the caller passes the whole
///      item, the module hashes it itself, the item's seed policy must be VRF, the package root
///      must be approved (not revoked) in the package registry, `proof` must place the item in
///      that root, and the item's content hash must not be consumed. Every failure of the gate is
///      `NotRequestable(itemHash)`. This keeps {requestSeed} open to anyone (the
///      artist, a relayer, a bot) with no privileged step, while the total possible spend is one
///      draw per approved VRF content, plus a repeat per `retryDelay` for each one whose draw
///      never arrived. A guardian's `revokePackage` stops further requests at once. The gate is
///      checked on every call, repeats included.
///
///      Repeat. A request still undelivered `retryDelay` seconds after it was made may be
///      requested again by anyone. A repeat ADDS a request and never invalidates an earlier one:
///      Chainlink VRF v2.5 does not expire a pending request on-chain, so the oracle may still
///      deliver an earlier request late, and a delivery for any outstanding request is accepted.
///      The first delivery fixes the seed; every later delivery for the content is a silent no-op
///      (it must not revert, so the oracle's fulfilment succeeds). Superseding the old request
///      would let an observer who sees a disliked late delivery pending in the mempool front-run
///      a repeat to discard it. Residual risk: while two requests are outstanding at once, whoever
///      orders the two deliveries (a searcher or block builder) chooses which of two independent
///      random words becomes the seed; `retryDelay` (3 days at least) keeps that window rare.
///
///      Trust. The coordinator can only deliver the seed of a content it was asked for, and the
///      first delivery is final: a delivered seed never changes. Governance chooses the
///      coordinator ({setCoordinator}, 30-day class, compare-and-set, code hash pinned and
///      checked again at every request and delivery, so code that replaced the reviewed code at
///      the pinned address is refused) and the request parameters ({setConfig}, 48-hour class,
///      compare-and-set, with a raise-only callback gas limit; {lowerCallbackGasLimit} lowers it
///      in the 30-day class). Request IDs are scoped to their coordinator, so a coordinator swap
///      orphans in-flight requests of the old one; each is requested again after `retryDelay`.
contract VrfEntropyModule is IEntropyModule, AccessManaged, ERC165 {
    /// @notice The request parameters.
    /// @param subscriptionId The funded VRF v2.5 subscription; this module must be its consumer.
    /// @param keyHash The gas lane.
    /// @param callbackGasLimit Gas the coordinator forwards to {rawFulfillRandomWords}.
    /// @param confirmations Blocks the oracle waits before answering.
    /// @param nativePayment Whether the subscription pays in native currency instead of LINK.
    struct VrfConfig {
        uint256 subscriptionId;
        bytes32 keyHash;
        uint32 callbackGasLimit;
        uint16 confirmations;
        bool nativePayment;
    }

    /// @dev One content's randomness. `value` is the latest request ID until `delivered`, then
    ///      the seed: the callback overwrites a word `requestSeed` already made nonzero, so a
    ///      delivery creates no storage slot (about 111,000 gas each under Glamsterdam).
    struct Seed {
        uint256 value;
        uint64 requestedAt;
        bool delivered;
    }

    /// @notice The lowest callback gas limit. The callback creates no storage slot (the seed
    ///         overwrites the request ID), so with every slot cold it costs about 20,000 Prague
    ///         gas and about 34,000 under Glamsterdam's storage pricing: about a third of it.
    uint32 public constant MIN_CALLBACK_GAS = 100_000;
    /// @notice The absolute ceiling of the callback gas limit (the coordinator's own maximum).
    uint32 public constant MAX_CALLBACK_GAS = 2_500_000;
    /// @notice The fewest confirmations accepted (Ethereum mainnet's coordinator minimum).
    uint16 public constant MIN_CONFIRMATIONS = 3;
    /// @notice The most confirmations the coordinator accepts.
    uint16 public constant MAX_CONFIRMATIONS = 200;
    /// @notice The shortest `retryDelay`. Not an expiry (VRF v2.5 requests never expire on-chain):
    ///         a repeat is only worth its cost once a delivery is plainly overdue.
    uint64 public constant MIN_RETRY_DELAY = 3 days;
    /// @notice The longest `retryDelay`.
    uint64 public constant MAX_RETRY_DELAY = 30 days;
    /// @notice The longest Merkle proof accepted: a package of 2^32 items.
    uint256 public constant MAX_PROOF_LENGTH = 32;

    /// @dev `bytes4(keccak256("VRF ExtraArgsV1"))`, the tag of the v2.5 request options.
    bytes4 private constant EXTRA_ARGS_V1_TAG = 0x92fd1338;

    /// @inheritdoc IEntropyModule
    uint64 public immutable retryDelay;
    /// @notice The package registry whose approved packages and consumed items gate requests
    ///         (immutable).
    IPackageRegistry public immutable packageRegistry;
    /// @inheritdoc IEntropyModule
    /// @dev The only caller of {rawFulfillRandomWords}.
    address public coordinator;
    /// @dev The coordinator's pinned code hash, checked again at every use, not only at
    ///      install.
    bytes32 private _coordinatorCodeHash;

    VrfConfig private _config;
    /// @dev The draw of each content hash.
    mapping(bytes32 contentHash => Seed) private _seeds;
    /// @dev The content hash each item linked through {requestSeed}; zero if never linked.
    mapping(bytes32 itemHash => bytes32 contentHash) private _contentOf;
    /// @dev Every request ever made, never removed: a delivery for any of them is accepted. Keyed
    ///      by coordinator too, so IDs of different coordinators can never collide (not even after
    ///      A to B to A) and a coordinator can only deliver the requests it was given.
    mapping(address coordinator => mapping(uint256 requestId => bytes32 contentHash)) private
        _requests;

    /// @notice The request parameters changed.
    event ConfigSet(VrfConfig previous, VrfConfig next);

    /// @param authority_ The AccessManager that governs this module.
    /// @param coordinator_ The VRF v2.5 coordinator.
    /// @param coordinatorCodeHash The reviewed code hash `coordinator_` must have.
    /// @param config_ The initial request parameters.
    /// @param retryDelay_ Seconds before an undelivered request may be requested again.
    /// @param packageRegistry_ The package registry that gates requests.
    /// @param packageRegistryCodeHash The reviewed code hash `packageRegistry_` must have.
    constructor(
        address authority_,
        address coordinator_,
        bytes32 coordinatorCodeHash,
        VrfConfig memory config_,
        uint64 retryDelay_,
        IPackageRegistry packageRegistry_,
        bytes32 packageRegistryCodeHash
    ) AccessManaged(authority_) {
        if (retryDelay_ < MIN_RETRY_DELAY || retryDelay_ > MAX_RETRY_DELAY) {
            revert InvalidRetryDelay(retryDelay_);
        }
        // The coordinator implements no ERC-165.
        Dependency.checkPinned(coordinator_, coordinatorCodeHash);
        Dependency.checkPinned(
            address(packageRegistry_), type(IPackageRegistry).interfaceId, packageRegistryCodeHash
        );
        VrfConfig memory c = config_;
        c.callbackGasLimit =
            SafeCast.toUint32(BoundedParameter.initial(c.callbackGasLimit, MAX_CALLBACK_GAS));
        _validate(c);
        retryDelay = retryDelay_;
        packageRegistry = packageRegistry_;
        coordinator = coordinator_;
        _coordinatorCodeHash = coordinatorCodeHash;
        _config = c;
        emit CoordinatorSet(address(0), coordinator_, coordinatorCodeHash);
        emit ConfigSet(VrfConfig(0, 0, 0, 0, false), c);
    }

    /// @inheritdoc IEntropyModule
    /// @dev Reverts with `NotRequestable` unless `item.seedPolicy` is VRF, `packageRoot` is
    ///      approved in the package registry, `proof` places the item in it, and the item's content
    ///      hash is nonzero and unconsumed. An item not yet linked is linked to its content's draw
    ///      (`SeedLinked`); if that draw is delivered or pending, the call ends there and returns
    ///      zero. Otherwise, if the content's seed is not delivered and no request is outstanding
    ///      (or `retryDelay` has passed since the last one), requests one random word. A repeat
    ///      adds a request; every outstanding request may still deliver, and the first delivery
    ///      wins. The request time is written before the coordinator is called and the request ID
    ///      only after, so a reentrant call finds a pending request and cannot deliver the new ID,
    ///      which is not yet recorded. A reentrant delivery of an EARLIER request is valid; the
    ///      seed is then already delivered when the call returns, and the new request is recorded
    ///      (its late delivery is a no-op) but is not announced as the item's current request.
    /// @param item The package item; the module computes its hash (`WorksHashing.itemHash`).
    /// @param packageRoot An approved package root.
    /// @param proof The Merkle proof of `WorksHashing.leaf(itemHash)` under `packageRoot`.
    /// @return requestId The coordinator's ID for the new request, or zero when the item only
    ///         joined its content's delivered or pending draw.
    function requestSeed(PackageItem calldata item, bytes32 packageRoot, bytes32[] calldata proof)
        external
        returns (uint256 requestId)
    {
        bytes32 itemHash = WorksHashing.itemHashCalldata(item);
        if (!_requestable(item, itemHash, packageRoot, proof)) revert NotRequestable(itemHash);
        bytes32 contentHash = item.contentHash;
        Seed storage seed = _seeds[contentHash];
        bool joined = _contentOf[itemHash] == 0;
        if (joined) {
            _contentOf[itemHash] = contentHash;
            emit SeedLinked(itemHash, contentHash);
        }
        if (seed.delivered) {
            if (joined) return 0;
            revert SeedAlreadyDelivered(itemHash);
        }
        if (seed.requestedAt != 0) {
            uint64 retryAt = seed.requestedAt + retryDelay;
            // The delay is a day or more; validator timestamp drift is immaterial.
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp < retryAt) {
                if (joined) return 0;
                revert RequestPending(itemHash, retryAt);
            }
        }
        seed.requestedAt = uint64(block.timestamp);

        VrfConfig memory c = _config;
        address coord = coordinator;
        Dependency.checkUnchanged(coord, _coordinatorCodeHash);
        requestId = IVRFCoordinatorV2Plus(coord)
            .requestRandomWords(
                IVRFCoordinatorV2Plus.RandomWordsRequest({
                keyHash: c.keyHash,
                subId: c.subscriptionId,
                requestConfirmations: c.confirmations,
                callbackGasLimit: c.callbackGasLimit,
                numWords: 1,
                extraArgs: abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, c.nativePayment)
            })
            );
        if (requestId == 0 || _requests[coord][requestId] != 0) {
            revert InvalidRequestId(requestId);
        }
        _requests[coord][requestId] = contentHash;
        // The coordinator may have delivered an earlier request while this one was being made.
        if (!seed.delivered) {
            seed.value = requestId;
            emit SeedRequested(itemHash, requestId);
        }
    }

    /// @notice The VRF callback: stores the seed of the content `requestId` was made for.
    /// @dev Only the coordinator may call it, for a request ID it was issued by this module's
    ///      request. Any outstanding request of an undelivered content delivers, and the first
    ///      delivery is final: a later delivery for the same content is a silent no-op that does
    ///      not revert, so the oracle's fulfilment succeeds and nothing can be re-drawn. The seed
    ///      is the random word unchanged, so anyone can check it against the oracle's proof. A
    ///      malformed delivery, or code at the coordinator's address that no longer has the
    ///      pinned hash, reverts and is absorbed by the coordinator.
    /// @param requestId The coordinator's request ID.
    /// @param randomWords The delivered words: exactly one.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != coordinator) revert OnlyCoordinatorCanFulfill(msg.sender, coordinator);
        Dependency.checkUnchanged(msg.sender, _coordinatorCodeHash);
        bytes32 contentHash = _requests[msg.sender][requestId];
        if (contentHash == 0) revert UnknownRequest(requestId);
        Seed storage seed = _seeds[contentHash];
        if (seed.delivered) return;
        if (randomWords.length != 1) revert InvalidRandomWords(requestId);
        bytes32 word = bytes32(randomWords[0]);
        seed.value = uint256(word);
        seed.delivered = true;
        emit SeedDelivered(contentHash, requestId, word);
    }

    /// @notice Sets the request parameters. Governed (map to the 48-hour `PARAMETER_SETTER`
    ///         class), non-payable, compare-and-set: `expected` must equal the current value.
    /// @dev The callback gas limit may only be raised (`BoundedParameter.raise`: at most doubled
    ///      per step, never above `MAX_CALLBACK_GAS`) or left as it is, so a hostile or mistaken
    ///      setter can neither starve the callback nor overspend the subscription.
    /// @param expected The current parameters.
    /// @param next The new parameters.
    function setConfig(VrfConfig calldata expected, VrfConfig calldata next) external restricted {
        VrfConfig memory current = _config;
        if (keccak256(abi.encode(expected)) != keccak256(abi.encode(current))) {
            revert ExpectedValueMismatch();
        }
        _validate(next);
        VrfConfig memory updated = next;
        if (next.callbackGasLimit != current.callbackGasLimit) {
            updated.callbackGasLimit = SafeCast.toUint32(
                BoundedParameter.raise(
                    current.callbackGasLimit, next.callbackGasLimit, MAX_CALLBACK_GAS
                )
            );
        }
        _config = updated;
        emit ConfigSet(current, updated);
    }

    /// @notice Lowers the callback gas limit, never below `MIN_CALLBACK_GAS`. Governed (map to
    ///         the 30-day `SUCCESSOR_SETTER` class), non-payable, compare-and-set: `expected` must
    ///         equal the current limit.
    /// @dev The coordinator refuses a request whose limit exceeds its own maximum, and Chainlink
    ///      may lower that maximum. {setConfig} only raises the limit, so that a 48-hour setter
    ///      cannot starve the callback; this slower path lets the module follow the coordinator
    ///      down (6529 Stream pins the module, so a limit stuck above the maximum would end VRF
    ///      works for the deployment), while the floor and the guardians' 30-day veto still
    ///      protect the callback.
    /// @param expected The current callback gas limit.
    /// @param next The new, lower limit.
    function lowerCallbackGasLimit(uint32 expected, uint32 next) external restricted {
        VrfConfig memory previous = _config;
        if (expected != previous.callbackGasLimit) revert ExpectedValueMismatch();
        if (next >= expected || next < MIN_CALLBACK_GAS) revert InvalidConfig();
        _config.callbackGasLimit = next;
        emit ConfigSet(previous, _config);
    }

    /// @inheritdoc IEntropyModule
    /// @dev Request IDs are scoped to their coordinator, so requests made through the old one can
    ///      no longer be delivered; they are requested again after `retryDelay`. Delivered seeds
    ///      are unaffected. `next` must differ from the current coordinator, have code, not be an
    ///      EIP-7702 delegated account, and have the pinned code hash. Switching coordinators
    ///      also needs a new subscription: see the README's runbook.
    function setCoordinator(address expected, address next, bytes32 nextCodeHash)
        external
        restricted
    {
        if (expected != coordinator) revert ExpectedValueMismatch();
        if (next == expected) revert Dependency.InvalidDependency(next);
        Dependency.checkPinned(next, nextCodeHash);
        emit CoordinatorSet(expected, next, nextCodeHash);
        coordinator = next;
        _coordinatorCodeHash = nextCodeHash;
    }

    /// @notice The request parameters.
    /// @return The current parameters.
    function config() external view returns (VrfConfig memory) {
        return _config;
    }

    /// @inheritdoc IEntropyModule
    function isDelivered(bytes32 itemHash) external view returns (bool) {
        return _seeds[_contentOf[itemHash]].delivered;
    }

    /// @inheritdoc IEntropyModule
    function seedOf(bytes32 itemHash) external view returns (bytes32) {
        Seed storage seed = _seeds[_contentOf[itemHash]];
        if (!seed.delivered) revert SeedNotDelivered(itemHash);
        return bytes32(seed.value);
    }

    /// @inheritdoc IEntropyModule
    /// @dev The request ID reads zero once the seed is delivered: no request is outstanding
    ///      then, and the word holds the seed.
    function requestOf(bytes32 itemHash)
        external
        view
        returns (uint256 requestId, uint64 requestedAt)
    {
        Seed storage seed = _seeds[_contentOf[itemHash]];
        return (seed.delivered ? 0 : seed.value, seed.requestedAt);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IERC165)
        returns (bool)
    {
        return interfaceId == type(IEntropyModule).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @dev The spam gate: a VRF item with a content hash, an approved package root, a proof that
    ///      places the item in it, and an item whose content hash the registry has not consumed (by
    ///      this item or, if the hash was claimed by another item, by that one: either way it can
    ///      never mint).
    function _requestable(
        PackageItem calldata item,
        bytes32 itemHash,
        bytes32 packageRoot,
        bytes32[] calldata proof
    ) private view returns (bool) {
        if (
            item.seedPolicy != SeedPolicy.VRF || item.contentHash == 0
                || proof.length > MAX_PROOF_LENGTH
        ) return false;
        (IPackageRegistry.PackageStatus status,,) = packageRegistry.packageOf(packageRoot);
        return status == IPackageRegistry.PackageStatus.APPROVED
            && MerkleProof.verifyCalldata(proof, packageRoot, WorksHashing.leaf(itemHash))
            && packageRegistry.consumedItemOf(item.contentHash) == 0;
    }

    function _validate(VrfConfig memory c) private pure {
        if (
            c.subscriptionId == 0 || c.keyHash == 0 || c.callbackGasLimit < MIN_CALLBACK_GAS
                || c.confirmations < MIN_CONFIRMATIONS || c.confirmations > MAX_CONFIRMATIONS
        ) revert InvalidConfig();
    }
}

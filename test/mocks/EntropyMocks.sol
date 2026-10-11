// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IVRFCoordinatorV2Plus } from "src/entropy/IVRFCoordinatorV2Plus.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";

/// @notice Mocks for the entropy lane: a VRF v2.5 coordinator that delivers on demand, a coordinator
///         that attacks the module while a request is in flight, and the two package registry
///         reads that gate a request.

/// @dev A VRF v2.5 coordinator stand-in. It issues sequential request IDs (or a forced one),
///      emits every request in full so tests can check the parameters, and delivers like the real
///      coordinator does: it forwards exactly the request's `callbackGasLimit` to the consumer.
contract MockVrfCoordinator is IVRFCoordinatorV2Plus {
    struct Pending {
        address consumer;
        uint32 gasLimit;
    }

    /// @dev Every parameter of a request, plus the ID issued and the consumer that asked.
    event RandomWordsRequested(
        uint256 indexed requestId,
        address indexed consumer,
        bytes32 keyHash,
        uint256 subId,
        uint16 requestConfirmations,
        uint32 callbackGasLimit,
        uint32 numWords,
        bytes extraArgs
    );

    error RequestsDisabled();

    uint256 public nextId = 1;
    /// @dev When nonzero, every request returns this ID (zero and duplicate-ID tests).
    uint256 public forcedId;
    bool public forceZero;
    bool public disabled;
    mapping(uint256 requestId => Pending) public pending;

    function setNextId(uint256 id) external {
        nextId = id;
    }

    function force(uint256 id, bool zero) external {
        forcedId = id;
        forceZero = zero;
    }

    function setDisabled(bool value) external {
        disabled = value;
    }

    function requestRandomWords(RandomWordsRequest calldata req)
        external
        virtual
        returns (uint256 requestId)
    {
        if (disabled) revert RequestsDisabled();
        requestId = forceZero ? 0 : (forcedId != 0 ? forcedId : nextId++);
        pending[requestId] = Pending(msg.sender, req.callbackGasLimit);
        emit RandomWordsRequested(
            requestId,
            msg.sender,
            req.keyHash,
            req.subId,
            req.requestConfirmations,
            req.callbackGasLimit,
            req.numWords,
            req.extraArgs
        );
    }

    /// @dev Delivers `word` as the real coordinator would, with exactly the request's gas limit.
    ///      Reverts bubble up so tests can assert the module's selectors. Returns the gas used.
    function fulfill(uint256 requestId, uint256 word) external returns (uint256 gasUsed) {
        Pending memory p = pending[requestId];
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        uint256 before = gasleft();
        VrfEntropyModule(p.consumer).rawFulfillRandomWords{ gas: p.gasLimit }(requestId, words);
        gasUsed = before - gasleft();
    }

    /// @dev Delivers arbitrary words for an arbitrary ID to an arbitrary consumer.
    function deliver(address consumer, uint256 requestId, uint256[] calldata words) external {
        VrfEntropyModule(consumer).rawFulfillRandomWords(requestId, words);
    }

    /// @dev Like the real coordinator, absorbs a reverting callback and reports success.
    function tryFulfill(uint256 requestId, uint256 word) external returns (bool ok) {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        (ok,) = pending[requestId].consumer
            .call(abi.encodeCall(VrfEntropyModule.rawFulfillRandomWords, (requestId, words)));
    }
}

/// @dev A coordinator that, while the module is inside `requestSeed`, calls back into the module to
///      request again, to fulfil the ID it is about to return (not yet recorded), and optionally to
///      deliver an earlier ID, recording whether each succeeded and how it failed. IDs are
///      `ISSUED_ID`, `ISSUED_ID + 1`, and so on.
contract ReentrantVrfCoordinator is IVRFCoordinatorV2Plus {
    uint256 public constant ISSUED_ID = 77;

    VrfEntropyModule public immutable module;
    bytes32 public packageRoot;
    /// @dev `abi.encode(item)`: a `PackageItem` holds arrays of structs, which cannot be copied
    ///      from memory to storage directly.
    bytes internal itemData;
    bytes32[] internal proof;
    uint256 public issued;
    uint256 public earlierId;
    uint256 public earlierWord;
    bool public repeatSucceeded;
    bool public fulfilSucceeded;
    bool public earlierSucceeded;
    bytes public repeatError;
    bytes public fulfilError;

    constructor(VrfEntropyModule module_) {
        module = module_;
    }

    function aim(PackageItem calldata item, bytes32 packageRoot_, bytes32[] calldata proof_)
        external
    {
        itemData = abi.encode(item);
        packageRoot = packageRoot_;
        proof = proof_;
    }

    /// @dev From the next request on, deliver `word` for the earlier request `id` while the
    ///      module is inside that request.
    function armEarlierDelivery(uint256 id, uint256 word) external {
        earlierId = id;
        earlierWord = word;
    }

    /// @dev A plain delivery as the coordinator.
    function deliver(uint256 id, uint256 word) external {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        module.rawFulfillRandomWords(id, words);
    }

    function requestRandomWords(RandomWordsRequest calldata) external returns (uint256) {
        try module.requestSeed(abi.decode(itemData, (PackageItem)), packageRoot, proof) {
            repeatSucceeded = true;
        } catch (bytes memory err) {
            repeatError = err;
        }
        uint256 id = ISSUED_ID + issued++;
        uint256[] memory words = new uint256[](1);
        try module.rawFulfillRandomWords(id, words) {
            fulfilSucceeded = true;
        } catch (bytes memory err) {
            fulfilError = err;
        }
        if (earlierId != 0) {
            words[0] = earlierWord;
            try module.rawFulfillRandomWords(earlierId, words) {
                earlierSucceeded = true;
            } catch { }
        }
        return id;
    }
}

/// @dev The reads of the package registry that gate a seed request: `packageOf` and
///      `consumedItemOf`, and ERC-165 for `IPackageRegistry` (the install check).
contract MockPackageRegistry {
    mapping(bytes32 packageRoot => IPackageRegistry.PackageStatus) public statusOf;
    mapping(bytes32 contentHash => bytes32 itemHash) public consumedBy;

    function setStatus(bytes32 packageRoot, IPackageRegistry.PackageStatus status) external {
        statusOf[packageRoot] = status;
    }

    /// @dev Marks `contentHash` as consumed by `itemHash` (zero clears it).
    function setConsumedBy(bytes32 contentHash, bytes32 itemHash) external {
        consumedBy[contentHash] = itemHash;
    }

    function packageOf(bytes32 packageRoot)
        external
        view
        returns (IPackageRegistry.PackageStatus status, bytes32 evidenceHash, address signer)
    {
        return (statusOf[packageRoot], keccak256(abi.encode(packageRoot)), address(0xC0FFEE));
    }

    function consumedItemOf(bytes32 contentHash) external view returns (bytes32) {
        return consumedBy[contentHash];
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IPackageRegistry).interfaceId;
    }
}

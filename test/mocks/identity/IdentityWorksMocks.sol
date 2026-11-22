// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistPayoutResolver } from "src/economics/interfaces/IArtistPayoutResolver.sol";
import { IConsolidationSource } from "src/interfaces/IArtistRegistry.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IStream } from "src/interfaces/core/IStream.sol";

/// @notice Answers ERC-165 for one interface (plus ERC-165 itself), as a binding target.
contract InterfaceStub {
    bytes4 internal immutable _interfaceId;

    constructor(bytes4 interfaceId_) {
        _interfaceId = interfaceId_;
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        return interfaceId == _interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Stands in for the curation lane's package registry: the artist registry binds it and
///         tests call from its address.
contract PackageRegistryStub is InterfaceStub {
    constructor() InterfaceStub(type(IPackageRegistry).interfaceId) { }
}

/// @notice Stands in for the v1.1 Independent Stream registry.
contract IndependentStreamRegistryStub is InterfaceStub {
    constructor() InterfaceStub(type(IIndependentStreamRegistry).interfaceId) { }
}

/// @notice The 6529 Stream Editions read the artist registry makes: `masterOf(id)`, which reverts
///         with `UnknownEdition` for an unknown edition. `master` may be set to a foreign Stream.
contract EditionsMastersMock {
    mapping(uint256 => address) internal _masterStream;

    function setEdition(uint256 editionId, address masterStream) external {
        _masterStream[editionId] = masterStream;
    }

    function masterOf(uint256 editionId) external view returns (address, uint256, bytes32) {
        if (_masterStream[editionId] == address(0)) revert IEditions.UnknownEdition(editionId);
        return (_masterStream[editionId], editionId, keccak256("content"));
    }
}

/// @notice A consolidation source with settable pairs (one direction set means consolidated),
///         that can instead revert or answer a malformed word for every read.
contract ConsolidationSourceMock is InterfaceStub {
    enum Mode {
        ANSWER,
        REVERT,
        MALFORMED
    }

    Mode public mode;
    mapping(address root => mapping(address wallet => bool)) internal _pairs;

    constructor() InterfaceStub(type(IConsolidationSource).interfaceId) { }

    function set(address root, address wallet, bool consolidated) external {
        _pairs[root][wallet] = consolidated;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function isConsolidated(address root, address wallet) external view returns (bool) {
        if (mode == Mode.REVERT) revert("source down");
        if (mode == Mode.MALFORMED) {
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return _pairs[root][wallet];
    }
}

/// @notice The economics split factory's `isWallet`, settable by tests.
contract SplitFactoryWalletsMock {
    mapping(address => bool) public isWallet;

    function setWallet(address wallet, bool deployed) external {
        isWallet[wallet] = deployed;
    }
}

/// @notice A pull-only artist-resolved split payee, as the economics lane defines it: only the
///         current `payoutAddress` may pull, and zero means unresolved, so nothing releases.
contract PullOnlyPayeeMock {
    IArtistPayoutResolver public immutable resolver;
    uint256 public immutable artistId;

    error NotPayoutAddress(address caller, address payoutAddress);

    constructor(IArtistPayoutResolver resolver_, uint256 artistId_) payable {
        resolver = resolver_;
        artistId = artistId_;
    }

    function release() external {
        address payoutAddress = resolver.payoutAddress(artistId);
        if (payoutAddress == address(0) || msg.sender != payoutAddress) {
            revert NotPayoutAddress(msg.sender, payoutAddress);
        }
        (bool ok,) = payoutAddress.call{ value: address(this).balance }("");
        require(ok, "transfer failed");
    }
}

/// @notice The statement log's `latestDisputeOutcome` (settable by tests) and `artistResolver`.
contract DisputeOutcomeLogMock {
    address public immutable artistResolver;
    mapping(address => mapping(uint256 => bytes32)) public latestDisputeOutcome;

    constructor(address resolver) {
        artistResolver = resolver;
    }

    function setOutcome(address token, uint256 id, bytes32 outcome) external {
        latestDisputeOutcome[token][id] = outcome;
    }
}

/// @notice Answers any call with `resolver` as its first word, after burning `burn` gas, in a
///         return of `size` bytes (below 32, that word's first `size` bytes).
contract HostileResolverMock {
    address private immutable resolver;
    uint256 private immutable burn;
    uint256 private immutable size;

    constructor(address resolver_, uint256 burn_, uint256 size_) {
        resolver = resolver_;
        burn = burn_;
        size = size_;
    }

    fallback() external {
        uint256 start = gasleft();
        while (start - gasleft() < burn) { }
        address r = resolver;
        uint256 n = size;
        assembly {
            mstore(0, r)
            return(0, n)
        }
    }
}

/// @dev A consolidation source that says yes to every pair: different code from the pinned
///      adapter.
contract AlwaysConsolidated {
    function isConsolidated(address, address) external pure returns (bool) {
        return true;
    }
}

/// @dev Editions whose edition `editionId` is the master work `workId` of `stream`.
contract RemappedEditionsMock {
    address public immutable stream;
    uint256 public immutable editionId;
    uint256 public immutable workId;

    constructor(address stream_, uint256 editionId_, uint256 workId_) {
        (stream, editionId, workId) = (stream_, editionId_, workId_);
    }

    function masterOf(uint256 id) external view returns (address, uint256, bytes32) {
        require(id == editionId, "unknown");
        return (stream, workId, keccak256("content"));
    }
}

/// @dev A Stream whose `artistOf` burns all the gas it is given.
contract BurningArtistStream {
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC165).interfaceId || id == type(IStream).interfaceId;
    }

    function editions() external pure returns (address) {
        return address(0);
    }

    function artistOf(uint256) external view returns (uint256) {
        while (gasleft() > 0) { }
        return 0;
    }
}

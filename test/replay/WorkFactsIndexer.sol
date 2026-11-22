// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { Facts, Media } from "src/interfaces/core/CoreTypes.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License, PackageItem } from "src/interfaces/types/PackageTypes.sol";

/// @notice Rebuilds every `WorkFacts` record from the contract's logs alone: no call to any
///         contract. An indexer that keeps only these events answers `factsOf` exactly.
contract WorkFactsIndexer {
    address public immutable source;
    mapping(address token => mapping(uint256 tokenId => Facts)) internal _facts;

    constructor(address source_) {
        source = source_;
    }

    /// @notice Applies a batch of logs in order; logs of other contracts are ignored.
    function apply_(Vm.Log[] memory logs) external {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != source || l.topics.length < 3) continue;
            Facts storage f = _facts[address(uint160(uint256(l.topics[1])))][uint256(l.topics[2])];
            bytes32 sig = l.topics[0];
            if (sig == IWorkFacts.RecordOpened.selector) {
                (PackageItem memory item, MediaFile[] memory media) =
                    abi.decode(l.data, (PackageItem, MediaFile[]));
                f.opened = true;
                f.recordFileId = item.recordFileId;
                f.licenseId = item.license.spdxId;
                f.licenseTextFileId = item.license.textFileId;
                for (uint256 m; m < media.length; ++m) {
                    f.media.push(Media(media[m].fileId, media[m].role));
                }
            } else if (sig == IWorkFacts.RecordSet.selector) {
                f.recordFileId = abi.decode(l.data, (bytes32));
            } else if (sig == IWorkFacts.LicenseSet.selector) {
                License memory license = abi.decode(l.data, (License));
                f.licenseId = license.spdxId;
                f.licenseTextFileId = license.textFileId;
            } else if (sig == IWorkFacts.Finalized.selector) {
                f.finalized = true;
                (f.renderer, f.rendererCodeHash) = abi.decode(l.data, (address, bytes32));
            } else if (sig == IWorkFacts.RendererRepinned.selector) {
                (f.renderer, f.rendererCodeHash) = abi.decode(l.data, (address, bytes32));
            } else if (sig == IWorkFacts.Locked.selector) {
                (f.licenseLocked, f.repinLocked) = abi.decode(l.data, (bool, bool));
            } else if (sig == IWorkFacts.OnChainComplete.selector) {
                f.onChainComplete = true;
            }
        }
    }

    /// @notice The rebuilt record, in the shape of `IWorkFacts.factsOf`.
    function factsOf(address token, uint256 tokenId) external view returns (Facts memory) {
        return _facts[token][tokenId];
    }
}

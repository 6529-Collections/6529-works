// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { Facts, Media } from "src/interfaces/core/CoreTypes.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { ReplayIndexer } from "./ReplayIndexer.sol";

/// @notice Rebuilds every `WorkFacts` record from the contract's logs alone, for every token
///         contract it serves (6529 Stream and each federated token): opens, record and license
///         changes, finalize, repins, locks and on-chain completion. `assertMatches` compares
///         `factsOf` of every work a log named, and of the token after each, with the contract.
contract WorkFactsIndexer is ReplayIndexer {
    struct Key {
        address token;
        uint256 tokenId;
    }

    mapping(address token => mapping(uint256 tokenId => Facts)) internal _facts;
    mapping(address token => mapping(uint256 tokenId => bool)) internal _known;
    Key[] internal _keys;

    constructor(address facts_) ReplayIndexer(facts_) { }

    function _apply(Vm.Log memory l) internal override {
        bytes32 sig = l.topics[0];
        address token = _addr(l.topics[1]);
        uint256 tokenId = uint256(l.topics[2]);
        if (!_known[token][tokenId]) {
            _known[token][tokenId] = true;
            _keys.push(Key(token, tokenId));
        }
        Facts storage f = _facts[token][tokenId];
        if (sig == IWorkFacts.RecordOpened.selector) {
            (PackageItem memory item, MediaFile[] memory media) =
                abi.decode(l.data, (PackageItem, MediaFile[]));
            assertFalse(f.opened, "indexer: opened twice");
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
            // The log carries both locks as they stand after the call.
            (f.licenseLocked, f.repinLocked) = abi.decode(l.data, (bool, bool));
        } else if (sig == IWorkFacts.OnChainComplete.selector) {
            f.onChainComplete = true;
        } else {
            _unknown(sig);
        }
    }

    /// @notice The rebuilt record, in the shape of `IWorkFacts.factsOf`.
    function factsOf(address token, uint256 tokenId) external view returns (Facts memory) {
        return _facts[token][tokenId];
    }

    function keyCount() external view returns (uint256) {
        return _keys.length;
    }

    function assertMatches() external view override {
        IWorkFacts w = IWorkFacts(target);
        for (uint256 i; i < _keys.length; ++i) {
            Key memory k = _keys[i];
            assertEq(
                keccak256(abi.encode(w.factsOf(k.token, k.tokenId))),
                keccak256(abi.encode(_facts[k.token][k.tokenId])),
                "factsOf"
            );
            assertEq(
                keccak256(abi.encode(w.factsOf(k.token, k.tokenId + 1))),
                keccak256(abi.encode(_facts[k.token][k.tokenId + 1])),
                "factsOf (next token)"
            );
        }
    }
}

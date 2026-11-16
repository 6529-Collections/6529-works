// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IMintPolicy } from "src/interfaces/IMintPolicy.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { PRODUCT_STREAM } from "src/interfaces/types/EconomicsTypes.sol";

/// @dev A stand-in for 6529 Stream in the package registry's tests: it answers ERC-165 for
///      `IStream` and holds content uniqueness by Stream's rule (AUC-44), so a test can mint
///      through the registry as Stream does (`mintThrough`) and release a burned work's content
///      (`release`). The registry reads `consumedItemOf`, `releasedTo` and `isReleased` from it.
contract StreamContentMock is IERC165 {
    mapping(bytes32 contentHash => bytes32 itemHash) internal _consumed;
    mapping(bytes32 contentHash => uint256 artistId) public releasedTo;
    mapping(bytes32 contentHash => bool) internal _released;
    mapping(bytes32 itemHash => bool) public isReleased;

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IStream).interfaceId;
    }

    function consumedItemOf(bytes32 contentHash) external view returns (bytes32) {
        return _consumed[contentHash];
    }

    /// @dev Records `contentHash` as minted by `itemHash`, for a test that called the registry
    ///      itself (as when measuring `authorize` alone).
    function setConsumed(bytes32 contentHash, bytes32 itemHash) external {
        _consumed[contentHash] = itemHash;
    }

    /// @dev `IMintPolicy.authorize` from the bound Stream, then Stream's content rule.
    function mintThrough(IMintPolicy policy, IMintPolicy.MintContext calldata c, bytes calldata r)
        external
        returns (IMintPolicy.MintRecord memory record)
    {
        record = policy.authorize(c, r);
        bytes32 content = record.contentHash;
        bytes32 held = _consumed[content];
        if (held != 0) revert IStream.ContentUsed(PRODUCT_STREAM, content, held);
        if (_released[content]) {
            if (isReleased[record.itemHash]) {
                revert IStream.ContentUsed(PRODUCT_STREAM, content, record.itemHash);
            }
            if (record.artistId != releasedTo[content]) {
                revert IStream.ContentReserved(content, releasedTo[content]);
            }
            _released[content] = false;
        }
        _consumed[content] = record.itemHash;
    }

    /// @dev Stream's `releaseContent` rule for the burned work of `itemHash`.
    function release(bytes32 contentHash, bytes32 itemHash, uint256 beneficiary, address artists)
        external
    {
        if (itemHash == 0 || _consumed[contentHash] != itemHash) {
            revert IStream.ClaimNotAllowed(PRODUCT_STREAM, contentHash);
        }
        if (IArtistRegistry(artists).authorityOf(beneficiary) == address(0)) {
            revert IArtistRegistry.UnknownArtist(beneficiary);
        }
        _consumed[contentHash] = 0;
        _released[contentHash] = true;
        releasedTo[contentHash] = beneficiary;
        isReleased[itemHash] = true;
    }
}

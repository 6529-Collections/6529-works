// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IStream } from "../interfaces/IStream.sol";
import { IStreamViews } from "../interfaces/IStreamViews.sol";
import { IStreamExtension } from "../interfaces/IStreamExtension.sol";
import { Utf8 } from "../libraries/Utf8.sol";

/// @title StreamViews
/// @notice 6529 Stream's genesis read-only extension (`IStreamExtension`): the informational
///         views of `IStream` and the collection-name rule. Stream reaches it only by STATICCALL
///         from its fallback, so it can write nothing.
/// @dev Stateless and bound to no Stream: the token it answers for is the caller, the Stream
///      whose fallback forwarded the call (`msg.sender`). It reads that Stream's native views
///      and, through `IStream.extsload`, the storage words of `Stream`'s layout (the slot
///      constants below, checked against `forge inspect Stream storage-layout` by the tests).
///      Called directly by anyone else it answers about the caller, which is harmless.
contract StreamViews is IStreamExtension, IStreamViews {
    /// @notice The longest accepted collection name, in bytes.
    uint256 public constant MAX_NAME_BYTES = 256;

    /// @dev `Stream`'s storage slots (its layout is fixed for good: Stream is never redeployed).
    uint256 private constant COUNTS_SLOT = 11;
    uint256 private constant OWNER_SLOT = 12;
    uint256 private constant CONTRACT_URI_SLOT = 13;
    uint256 private constant COLLECTIONS_SLOT = 17;
    uint256 private constant TOKENS_SLOT = 18;

    /// @inheritdoc IStreamExtension
    /// @dev The name goes into every work's metadata, where a control character, `<`, `"` or
    ///      `\` is escaped to up to six bytes: refusing them keeps `tokenURI` within its gas
    ///      budget (the content README's budget proof).
    function isValidCollectionName(string calldata name) external pure returns (bool) {
        bytes calldata raw = bytes(name);
        if (raw.length == 0 || raw.length > MAX_NAME_BYTES || !Utf8.isValid(raw)) return false;
        for (uint256 i; i < raw.length; ++i) {
            bytes1 b = raw[i];
            if (b < 0x20 || b == 0x7f || b == "<" || b == '"' || b == "\\") return false;
        }
        return true;
    }

    /// @notice `IStream.work` of the calling Stream.
    /// @param tokenId A live token ID (the Stream's `UnknownWork` otherwise).
    /// @return The work's stored fields and its royalty receiver.
    function work(uint256 tokenId) external view returns (IStreamViews.WorkCore memory) {
        IStream s = IStream(msg.sender);
        IStreamViews.WorkCore memory w;
        (w.itemHash, w.artistId, w.collectionId, w.kind, w.seedPolicy, w.royaltyRate) =
            s.coreOf(tokenId);
        uint256 word = uint256(_word(s, keccak256(abi.encode(tokenId, TOKENS_SLOT))));
        // The token word packs the seller (low 160 bits) and the serial (the next 32).
        // forge-lint: disable-next-line(unsafe-typecast)
        w.seller = address(uint160(word));
        // forge-lint: disable-next-line(unsafe-typecast)
        w.serial = uint32(word >> 160);
        (w.royaltyReceiver,) = IERC2981(address(s)).royaltyInfo(tokenId, 0);
        return w;
    }

    /// @notice `IStream.collection` of the calling Stream.
    /// @param collectionId A collection ID (`IStream.UnknownCollection` otherwise).
    /// @return The collection's name, metadata hash and minted count.
    function collection(uint256 collectionId) external view returns (IStreamViews.Collection memory) {
        IStream s = IStream(msg.sender);
        bytes32 base = keccak256(abi.encode(collectionId, COLLECTIONS_SLOT));
        bytes32[] memory head = s.extsload(base, 2);
        uint256 word = uint256(head[0]);
        if (word & 0xff == 0) revert IStream.UnknownCollection(collectionId);
        // The counter word packs `exists` (low byte) and `minted` (the next 32 bits).
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 minted = uint32(word >> 8);
        return IStreamViews.Collection(_string(s, uint256(base) + 2), head[1], minted);
    }

    /// @notice `IStream.totalSupply` of the calling Stream.
    /// @return The number of live tokens.
    function totalSupply() external view returns (uint256) {
        uint256 counts = _counts();
        return uint64(counts) - uint64(counts >> 64);
    }

    /// @notice `IStream.contractURI` of the calling Stream (ERC-7572).
    /// @return The URI, empty until set.
    function contractURI() external view returns (string memory) {
        return _string(IStream(msg.sender), CONTRACT_URI_SLOT);
    }

    /// @notice `IStream.owner` of the calling Stream (the marketplace owner).
    /// @return The marketplace owner.
    function owner() external view returns (address) {
        return address(uint160(uint256(_word(IStream(msg.sender), bytes32(OWNER_SLOT)))));
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IStreamExtension).interfaceId;
    }

    function _counts() private view returns (uint256) {
        return uint256(_word(IStream(msg.sender), bytes32(COUNTS_SLOT)));
    }

    function _word(IStream s, bytes32 slot) private view returns (bytes32) {
        return s.extsload(slot, 1)[0];
    }

    /// @dev A storage `string` at `slot` (Solidity's layout: short strings in place with twice
    ///      their length in the low byte; long ones as `2 * length + 1`, data at `keccak(slot)`).
    function _string(IStream s, uint256 slot) private view returns (string memory text) {
        uint256 head = uint256(_word(s, bytes32(slot)));
        if (head & 1 == 0) {
            uint256 length = (head & 0xff) >> 1;
            text = new string(length);
            assembly ("memory-safe") {
                mstore(add(text, 0x20), and(head, not(0xff)))
            }
            return text;
        }
        uint256 size = (head - 1) >> 1;
        bytes32[] memory words =
            s.extsload(keccak256(abi.encode(slot)), (size + 31) >> 5);
        text = new string(size);
        assembly ("memory-safe") {
            let n := mload(words)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                mstore(add(add(text, 0x20), shl(5, i)), mload(add(add(words, 0x20), shl(5, i))))
            }
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { Locator, LocatorKind } from "src/interfaces/types/ContentTypes.sol";
import { ContentAddresses } from "../../helpers/ContentAddresses.sol";
import { IntegrationBase } from "../../integration/IntegrationBase.sol";
import { CidGoldenData as Golden } from "./CidGoldenData.sol";

/// @dev Cross-language agreement between the `cid` helper (`tools/content/cid.py`) and the real
///      `WorkRecords`: every CID the helper computes for the golden files is accepted as an
///      `ipfs://` locator, and Solidity re-derives each single-block (raw) CID from the SHA-256
///      of the file. The vectors come from `CidGoldenData`, generated from
///      `tools/content/golden/cid-vectors.json`.
contract CidGoldenTest is IntegrationBase {
    uint256 internal tokenId;
    bytes32 internal fileId;
    address internal artist;

    function setUp() public override {
        super.setUp();
        artist = _actor("cidGoldenArtist");
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        tokenId = _sell(root, works, 0, makeAddr("cidGoldenCollector"), 1 ether);
        records.openRecord(tokenId, works[0].item, works[0].media);
        fileId = works[0].media[0].fileId;
    }

    function test_EveryHelperCidIsAnAcceptedLocator() public {
        Golden.Vector[] memory v = Golden.vectors();
        for (uint256 i; i < v.length; ++i) {
            vm.prank(artist);
            records.addLocator(tokenId, fileId, Locator(LocatorKind.IPFS, v[i].uri));
        }
        Locator[] memory stored = records.locators(tokenId, fileId);
        assertEq(stored.length, v.length);
        for (uint256 i; i < v.length; ++i) {
            assertEq(stored[i].uri, v[i].uri, v[i].name);
        }
    }

    /// @dev A single-block file's CID is the raw codec over the SHA-256 of its bytes: Solidity
    ///      spells it as the helper does. A larger file's root is a dag-pb node.
    function test_RawCidsAreTheSha256OfTheFile() public pure {
        Golden.Vector[] memory v = Golden.vectors();
        for (uint256 i; i < v.length; ++i) {
            if (v[i].raw) {
                assertEq(
                    string.concat("ipfs://", string(ContentAddresses.cid(0x55, v[i].sha256))),
                    v[i].uri,
                    v[i].name
                );
                assertLe(v[i].size, 262_144, "one chunk");
            } else {
                assertEq(_prefix(v[i].uri), "ipfs://bafybei", v[i].name);
                assertGt(v[i].size, 262_144, "more than one chunk");
            }
        }
    }

    /// @dev What a careless upload produces is refused: a directory-wrapped path (`ipfs add -w`),
    ///      a CIDv0, upper case, or a truncated CID.
    function test_CarelessSpellingsAreRefused() public {
        string memory good = Golden.vectors()[1].uri;
        string[4] memory bad = [
            string.concat(good, "/hello.txt"),
            "ipfs://QmWATWQ7fVPP2EFGu71UkfnqhYXDYH566qy47CnJDgvs8u",
            vm.toUppercase(good),
            _prefix(good)
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(artist);
            vm.expectRevert(IWorkRecords.InvalidLocator.selector);
            records.addLocator(tokenId, fileId, Locator(LocatorKind.IPFS, bad[i]));
        }
    }

    function _prefix(string memory uri) internal pure returns (string memory) {
        bytes memory out = new bytes(14);
        for (uint256 i; i < 14; ++i) {
            out[i] = bytes(uri)[i];
        }
        return string(out);
    }
}

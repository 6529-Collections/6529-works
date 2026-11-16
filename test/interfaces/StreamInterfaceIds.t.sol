// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IMintPolicy } from "../../src/interfaces/IMintPolicy.sol";
import { IStream } from "../../src/interfaces/IStream.sol";
import { IStreamExtension } from "../../src/interfaces/IStreamExtension.sol";
import { IStreamViews } from "../../src/interfaces/IStreamViews.sol";

/// @notice Golden ERC-165 ids of 6529 Stream's interfaces, recomputed from every selector. `IStream`
///         is flat: it declares every function Stream answers natively (the sale-adapter and
///         ERC-2981 functions included), so its one id covers the whole permanent surface other
///         contracts rely on; the ERC-721 functions are covered by ERC-721's own ids. The views the
///         read-only extension serves have their own id (`IStreamViews`). A failing check means a
///         function was added, removed or changed: update it only with every implementation and
///         every contract that checks the id.
contract StreamInterfaceIdsTest is Test {
    function _xor(string[] memory signatures) internal pure returns (bytes4 id) {
        for (uint256 i; i < signatures.length; ++i) {
            id ^= bytes4(keccak256(bytes(signatures[i])));
        }
    }

    function _streamSignatures() internal pure returns (string[] memory s) {
        s = new string[](46);
        s[0] = "mint(address,uint256,uint256,bytes)";
        s[1] = "primaryTerms(uint256,bytes)";
        s[2] = "burn(uint256,uint256)";
        s[3] = "settlePrimary(uint256,uint8,address,address,uint256)";
        s[4] = "isAdmittedMinter(address)";
        s[5] = "setAdmittedMinter(address,bool)";
        s[6] = "royaltyInfo(uint256,uint256)";
        s[7] = "bindWorkRecords(address)";
        s[8] = "bindEditions(address)";
        s[9] = "splitFactory()";
        s[10] = "workRecords()";
        s[11] = "editions()";
        s[12] = "packageRegistry()";
        s[13] = "artistRegistry()";
        s[14] = "economics()";
        s[15] = "entropyModule()";
        s[16] = "entropyModuleOf(uint256)";
        s[17] = "setDependency(bytes32,address,address)";
        s[18] = "rescueToMuseum(uint256)";
        s[19] = "rescueDelay()";
        s[20] = "RESCUE_DELAY_FLOOR()";
        s[21] = "setRescueDelay(uint256)";
        s[22] = "extsload(bytes32,uint256)";
        s[23] = "collectionCount()";
        s[24] = "totalMinted()";
        s[25] = "createCollection(string,bytes32)";
        s[26] = "coreOf(uint256)";
        s[27] = "releaseContent(uint256,bytes32,uint256)";
        s[28] = "artistOf(uint256)";
        s[29] = "primarySaleSettled(uint256)";
        s[30] = "primarySale(uint256)";
        s[31] = "defaultRenderer()";
        s[32] = "setDefaultRenderer(address,address,bytes32)";
        s[33] = "rendererOf(uint256)";
        s[34] = "setRoyaltyRate(uint256,uint32)";
        s[35] = "emitMetadataUpdate(uint256,uint256)";
        s[36] = "editionOf(uint256)";
        s[37] = "linkEdition(uint256,uint256)";
        s[38] = "setContractURI(string)";
        s[39] = "setOwner(address,address)";
        s[40] = "consumedItemOf(bytes32)";
        s[41] = "releasedTo(bytes32)";
        s[42] = "isReleased(bytes32)";
        s[43] = "contractURI()";
        s[44] = "owner()";
        s[45] = "extension()";
    }

    function test_IStreamIdIsTheWholeNativeSurface() public pure {
        assertEq(type(IStream).interfaceId, _xor(_streamSignatures()), "IStream from its selectors");
        assertEq(type(IStream).interfaceId, bytes4(0x829e6c7d), "IStream golden");
    }

    function test_IStreamViewsId() public pure {
        string[] memory s = new string[](3);
        s[0] = "work(uint256)";
        s[1] = "collection(uint256)";
        s[2] = "totalSupply()";
        assertEq(type(IStreamViews).interfaceId, _xor(s), "IStreamViews from its selectors");
        assertEq(type(IStreamViews).interfaceId, bytes4(0xb039ffcb), "IStreamViews golden");
    }

    function test_IMintPolicyAndExtensionIds() public pure {
        string[] memory p = new string[](3);
        p[0] = "authorize((address,address,address,address),bytes)";
        p[1] = "preview((address,address,address,address),bytes)";
        p[2] = "artistRegistry()";
        assertEq(type(IMintPolicy).interfaceId, _xor(p), "IMintPolicy from its selectors");
        assertEq(type(IMintPolicy).interfaceId, bytes4(0x621ba19b), "IMintPolicy golden");
        // Flat: the collection-name rule and the three views it serves.
        string[] memory e = new string[](4);
        e[0] = "isValidCollectionName(string)";
        e[1] = "work(uint256)";
        e[2] = "collection(uint256)";
        e[3] = "totalSupply()";
        assertEq(type(IStreamExtension).interfaceId, _xor(e), "IStreamExtension");
    }

    /// @dev Every selector named above is the one the interface declares.
    function test_selectorsMatchTheDeclarations() public pure {
        assertEq(IStream.mint.selector, bytes4(keccak256("mint(address,uint256,uint256,bytes)")));
        assertEq(
            IStream.settlePrimary.selector,
            bytes4(keccak256("settlePrimary(uint256,uint8,address,address,uint256)"))
        );
        assertEq(IStream.coreOf.selector, bytes4(keccak256("coreOf(uint256)")));
        assertEq(IStream.extsload.selector, bytes4(keccak256("extsload(bytes32,uint256)")));
        assertEq(IStreamViews.work.selector, bytes4(keccak256("work(uint256)")));
        assertEq(
            IMintPolicy.authorize.selector,
            bytes4(keccak256("authorize((address,address,address,address),bytes)"))
        );
    }
}

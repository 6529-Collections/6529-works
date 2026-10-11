// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistRegistry, IConsolidationSource } from "../../src/interfaces/IArtistRegistry.sol";
import { IArtistRoleResolver } from "../../src/interfaces/IArtistRoleResolver.sol";
import { IContentStore } from "../../src/interfaces/IContentStore.sol";
import { ICurationVerifier } from "../../src/interfaces/ICurationVerifier.sol";
import { IDependencyRegistry } from "../../src/interfaces/IDependencyRegistry.sol";
import { IDutchSale } from "../../src/interfaces/IDutchSale.sol";
import { IEconomicsResolver } from "../../src/interfaces/IEconomicsResolver.sol";
import { IEditions } from "../../src/interfaces/IEditions.sol";
import { IEnglishAuction } from "../../src/interfaces/IEnglishAuction.sol";
import { IEntropyModule } from "../../src/interfaces/IEntropyModule.sol";
import { IFederationRegistry } from "../../src/interfaces/IFederationRegistry.sol";
import { IFixedPriceSale } from "../../src/interfaces/IFixedPriceSale.sol";
import { IMintTarget } from "../../src/interfaces/IMintTarget.sol";
import { IPackageRegistry } from "../../src/interfaces/IPackageRegistry.sol";
import { IRenderer } from "../../src/interfaces/IRenderer.sol";
import { ISaleAdapter } from "../../src/interfaces/ISaleAdapter.sol";
import { IStream } from "../../src/interfaces/IStream.sol";
import { Limits } from "../../src/interfaces/types/Limits.sol";

/// @notice Imports every interface so the whole surface compiles, and pins each ERC-165
///         interface ID. A failing ID means an external function was added, removed or changed:
///         update the golden value only together with every implementation and caller.
/// @dev An ID covers the functions an interface declares itself, not inherited ones.
contract InterfacesCompileTest is Test {
    function test_interfaceIds() public pure {
        assertEq(type(IMintTarget).interfaceId, bytes4(0xc488ca68), "IMintTarget");
        assertEq(type(IStream).interfaceId, bytes4(0xddf03480), "IStream");
        assertEq(type(IEditions).interfaceId, bytes4(0xf1fda5e4), "IEditions");
        assertEq(type(ISaleAdapter).interfaceId, bytes4(0x0f69444d), "ISaleAdapter");
        assertEq(type(IEnglishAuction).interfaceId, bytes4(0x784c9e1c), "IEnglishAuction");
        assertEq(type(IFixedPriceSale).interfaceId, bytes4(0x4b904dda), "IFixedPriceSale");
        assertEq(type(IDutchSale).interfaceId, bytes4(0x5a75af36), "IDutchSale");
        assertEq(type(ICurationVerifier).interfaceId, bytes4(0x492733ca), "ICurationVerifier");
        assertEq(type(IPackageRegistry).interfaceId, bytes4(0x8b682b8a), "IPackageRegistry");
        assertEq(type(IContentStore).interfaceId, bytes4(0xcce4e4aa), "IContentStore");
        assertEq(type(IDependencyRegistry).interfaceId, bytes4(0xe5338d57), "IDependencyRegistry");
        assertEq(type(IRenderer).interfaceId, bytes4(0xa772216d), "IRenderer");
        assertEq(type(IEconomicsResolver).interfaceId, bytes4(0x70039a3b), "IEconomicsResolver");
        assertEq(type(IArtistRegistry).interfaceId, bytes4(0xa31364a7), "IArtistRegistry");
        assertEq(type(IConsolidationSource).interfaceId, bytes4(0xc99f1cff), "IConsolidationSource");
        assertEq(type(IEntropyModule).interfaceId, bytes4(0xe3ffb038), "IEntropyModule");
        assertEq(type(IFederationRegistry).interfaceId, bytes4(0x826099fe), "IFederationRegistry");
    }

    /// @dev The minimal mint surface stays tiny: three functions.
    function test_mintTargetIsMinimal() public pure {
        assertEq(
            type(IMintTarget).interfaceId,
            IMintTarget.mint.selector ^ IMintTarget.primaryTerms.selector
                ^ IMintTarget.burn.selector
        );
    }

    /// @dev The artist registry answers the statement log's artist question.
    function test_artistRegistryIsArtistRoleResolver() public pure {
        assertEq(type(IArtistRoleResolver).interfaceId, IArtistRoleResolver.isArtist.selector);
        // Compiles only while IArtistRegistry extends IArtistRoleResolver, which extends
        // IERC165: an implementation reports both interface IDs.
        IArtistRoleResolver resolver = IArtistRegistry(address(0x6529));
        IERC165 introspection = resolver;
        assertEq(address(introspection), address(0x6529));
    }

    /// @dev Split wallets resolve artist payouts through the economics lane's
    ///      `IArtistPayoutResolver.payoutAddress(uint256)`, which the artist registry implements.
    function test_artistRegistryIsPayoutResolver() public pure {
        assertEq(
            IArtistRegistry.payoutAddress.selector, bytes4(keccak256("payoutAddress(uint256)"))
        );
    }

    function test_limits() public pure {
        assertEq(Limits.MAX_PARTIES, 16);
        assertEq(Limits.MAX_WORK_RECORD_BYTES, 24_575);
        assertEq(Limits.MAX_URI_BYTES, 2_048);
    }
}

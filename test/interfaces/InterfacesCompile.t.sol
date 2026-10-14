// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistPayoutResolver } from "../../src/economics/interfaces/IArtistPayoutResolver.sol";
import { IArtistRegistry, IConsolidationSource } from "../../src/interfaces/IArtistRegistry.sol";
import { IArtistRoleResolver } from "../../src/interfaces/IArtistRoleResolver.sol";
import { IContentStore } from "../../src/interfaces/IContentStore.sol";
import {
    ICurationSignerVerifier,
    ICurationVerifier
} from "../../src/interfaces/ICurationVerifier.sol";
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
import { IStatementLog } from "../../src/interfaces/IStatementLog.sol";
import { IStream } from "../../src/interfaces/IStream.sol";
import { IWorkRecords } from "../../src/interfaces/IWorkRecords.sol";
import { Limits } from "../../src/interfaces/types/Limits.sol";

/// @notice Imports every interface so the whole surface compiles, and pins each ERC-165
///         interface ID. A failing ID means an external function was added, removed or changed:
///         update the golden value only together with every implementation and caller.
/// @dev An ID covers the functions an interface declares itself, not inherited ones.
contract InterfacesCompileTest is Test {
    function test_interfaceIds() public pure {
        assertEq(type(IMintTarget).interfaceId, bytes4(0x4f4f5133), "IMintTarget");
        assertEq(type(IStream).interfaceId, bytes4(0x6d0d5203), "IStream");
        assertEq(type(IWorkRecords).interfaceId, bytes4(0x3f3d6835), "IWorkRecords");
        assertEq(type(IEditions).interfaceId, bytes4(0xa5bd946e), "IEditions");
        assertEq(type(ISaleAdapter).interfaceId, bytes4(0x312dc1e1), "ISaleAdapter");
        assertEq(type(IEnglishAuction).interfaceId, bytes4(0xc1a8b12f), "IEnglishAuction");
        assertEq(type(IFixedPriceSale).interfaceId, bytes4(0xfedd2754), "IFixedPriceSale");
        assertEq(type(IDutchSale).interfaceId, bytes4(0xb1c10995), "IDutchSale");
        assertEq(type(ICurationVerifier).interfaceId, bytes4(0x492733ca), "ICurationVerifier");
        assertEq(
            type(ICurationSignerVerifier).interfaceId, bytes4(0x9f12d97a), "ICurationSignerVerifier"
        );
        assertEq(type(IPackageRegistry).interfaceId, bytes4(0xe69cc8c7), "IPackageRegistry");
        assertEq(type(IContentStore).interfaceId, bytes4(0x3f437f81), "IContentStore");
        assertEq(type(IDependencyRegistry).interfaceId, bytes4(0xe5338d57), "IDependencyRegistry");
        assertEq(type(IRenderer).interfaceId, bytes4(0xa772216d), "IRenderer");
        assertEq(type(IEconomicsResolver).interfaceId, bytes4(0x310247d8), "IEconomicsResolver");
        assertEq(type(IStatementLog).interfaceId, bytes4(0x276fbc56), "IStatementLog");
        assertEq(type(IArtistRoleResolver).interfaceId, bytes4(0x3074ca00), "IArtistRoleResolver");
        assertEq(
            type(IArtistPayoutResolver).interfaceId, bytes4(0x9b2c1793), "IArtistPayoutResolver"
        );
        assertEq(type(IArtistRegistry).interfaceId, bytes4(0x25e33e82), "IArtistRegistry");
        assertEq(type(IConsolidationSource).interfaceId, bytes4(0x88836e34), "IConsolidationSource");
        assertEq(type(IEntropyModule).interfaceId, bytes4(0x3a410101), "IEntropyModule");
        assertEq(type(IFederationRegistry).interfaceId, bytes4(0xeefee933), "IFederationRegistry");
    }

    /// @dev The mint surface stays small: four adapter calls plus the admitted-minter mapping.
    function test_mintTargetIsMinimal() public pure {
        assertEq(
            type(IMintTarget).interfaceId,
            IMintTarget.mint.selector ^ IMintTarget.primaryTerms.selector
                ^ IMintTarget.burn.selector ^ IMintTarget.isAdmittedMinter.selector
                ^ IMintTarget.setAdmittedMinter.selector ^ IMintTarget.markPrimarySettled.selector
        );
    }

    /// @dev Decision D8: every interface a contract installs as a dependency extends IERC165, so
    ///      installs can check it. These conversions compile only while that holds.
    function test_installableDependenciesAreIERC165() public pure {
        address a = address(0x6529);
        IERC165[9] memory installable = [
            IERC165(ICurationVerifier(a)),
            IERC165(IRenderer(a)),
            IERC165(IConsolidationSource(a)),
            IERC165(IEntropyModule(a)),
            IERC165(IEconomicsResolver(a)),
            IERC165(IPackageRegistry(a)),
            IERC165(ISaleAdapter(a)),
            IERC165(IFederationRegistry(a)),
            IERC165(IArtistRoleResolver(a))
        ];
        for (uint256 i; i < installable.length; ++i) {
            assertEq(address(installable[i]), a);
        }
    }

    /// @dev The package registry depends only on the pluggable verifier, which the v1 signer
    ///      verifier extends; the pluggable surface stays one function.
    function test_signerVerifierIsCurationVerifier() public pure {
        ICurationVerifier verifier = ICurationSignerVerifier(address(0x6529));
        assertEq(address(verifier), address(0x6529));
        assertEq(type(ICurationVerifier).interfaceId, ICurationVerifier.isApproved.selector);
    }

    /// @dev The artist registry answers the statement log's artist question and the economics
    ///      lane's payout question (`IArtistPayoutResolver.payoutAddress(uint256)`).
    function test_artistRegistryResolvers() public pure {
        IArtistRoleResolver resolver = IArtistRegistry(address(0x6529));
        IArtistPayoutResolver payouts = IArtistRegistry(address(0x6529));
        assertEq(address(resolver), address(payouts));
        assertEq(type(IArtistRoleResolver).interfaceId, IArtistRoleResolver.isArtist.selector);
        assertEq(
            type(IArtistPayoutResolver).interfaceId, bytes4(keccak256("payoutAddress(uint256)"))
        );
    }

    function test_limits() public pure {
        assertEq(Limits.MAX_PARTIES, 16);
        assertEq(Limits.MAX_MEDIA_FILES, 32);
        assertEq(Limits.MAX_LICENSE_ID_BYTES, 64);
        assertEq(Limits.MAX_URI_BYTES, 2_048);
        assertEq(Limits.MAX_PROOF_DEPTH, 32);
        assertEq(Limits.MAX_RECORD_BYTES, 12_288);
        assertEq(Limits.MAX_ARTISTS, 16);
    }
}

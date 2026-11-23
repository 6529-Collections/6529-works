// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistPayoutResolver } from "../../src/economics/interfaces/IArtistPayoutResolver.sol";
import { IAccounts } from "../../src/interfaces/core/IAccounts.sol";
import { IArtistRegistry, IConsolidationSource } from "../../src/interfaces/IArtistRegistry.sol";
import { IItemApprovals } from "../../src/interfaces/IItemApprovals.sol";
import { IArtistRoleResolver } from "../../src/interfaces/IArtistRoleResolver.sol";
import { IContentStore } from "../../src/interfaces/IContentStore.sol";
import {
    ICurationSignerVerifier,
    ICurationVerifier
} from "../../src/interfaces/ICurationVerifier.sol";
import { IDependencyRegistry } from "../../src/interfaces/IDependencyRegistry.sol";
import { IEconomicsResolver } from "../../src/interfaces/IEconomicsResolver.sol";
import { IEditions } from "../../src/interfaces/core/IEditions.sol";
import { IEnglishAuction } from "../../src/interfaces/IEnglishAuction.sol";
import { IEnglishAuctionClock } from "../../src/interfaces/IEnglishAuctionClock.sol";
import { IEnglishAuctionRefusal } from "../../src/interfaces/IEnglishAuctionRefusal.sol";
import { IEntropyModule } from "../../src/interfaces/IEntropyModule.sol";
import { IIndependentStreamRegistry } from "../../src/interfaces/IIndependentStreamRegistry.sol";
import { IPackageRegistry } from "../../src/interfaces/IPackageRegistry.sol";
import { IRenderer } from "../../src/interfaces/IRenderer.sol";
import { ISaleAdapter } from "../../src/interfaces/ISaleAdapter.sol";
import { IStatementLog } from "../../src/interfaces/IStatementLog.sol";
import { IStream } from "../../src/interfaces/core/IStream.sol";
import { IUniformEditionAuction } from "../../src/interfaces/IUniformEditionAuction.sol";
import { IWorkPowers } from "../../src/interfaces/IWorkPowers.sol";
import { Limits } from "../../src/interfaces/types/Limits.sol";
import { SaleKind } from "../../src/interfaces/types/SaleTypes.sol";

/// @notice Imports every interface so the whole surface compiles, and pins each ERC-165
///         interface ID. A failing ID means an external function was added, removed or changed:
///         update the golden value only together with every implementation and caller.
/// @dev An ID covers the functions an interface declares itself, not inherited ones.
contract InterfacesCompileTest is Test {
    function test_interfaceIds() public pure {
        assertEq(type(IStream).interfaceId, bytes4(0xe38078e5), "IStream");
        assertEq(type(IWorkPowers).interfaceId, bytes4(0xf2f560e3), "IWorkPowers");
        assertEq(type(IEditions).interfaceId, bytes4(0xb4dad938), "IEditions");
        assertEq(type(ISaleAdapter).interfaceId, bytes4(0xd15ddb3f), "ISaleAdapter");
        assertEq(type(IEnglishAuction).interfaceId, bytes4(0x54df3713), "IEnglishAuction");
        // An integration view, never reported through ERC-165.
        assertEq(type(IEnglishAuctionClock).interfaceId, bytes4(0x968c7b07), "IEnglishAuctionClock");
        // The refusal exit (AUC-38), never reported through ERC-165.
        assertEq(
            type(IEnglishAuctionRefusal).interfaceId, bytes4(0x625761b5), "IEnglishAuctionRefusal"
        );
        assertEq(
            type(IUniformEditionAuction).interfaceId, bytes4(0x327daaaf), "IUniformEditionAuction"
        );
        // Errors only: no function, so the ID is zero and nothing reports it.
        assertEq(type(ICurationVerifier).interfaceId, bytes4(0x492733ca), "ICurationVerifier");
        assertEq(
            type(ICurationSignerVerifier).interfaceId, bytes4(0x9f12d97a), "ICurationSignerVerifier"
        );
        assertEq(type(IPackageRegistry).interfaceId, bytes4(0xfecfa933), "IPackageRegistry");
        assertEq(type(IContentStore).interfaceId, bytes4(0xe5a30736), "IContentStore");
        assertEq(type(IDependencyRegistry).interfaceId, bytes4(0xe5338d57), "IDependencyRegistry");
        assertEq(type(IRenderer).interfaceId, bytes4(0xa772216d), "IRenderer");
        assertEq(type(IEconomicsResolver).interfaceId, bytes4(0xf67d097b), "IEconomicsResolver");
        assertEq(type(IStatementLog).interfaceId, bytes4(0xbb5574c7), "IStatementLog");
        assertEq(type(IArtistRoleResolver).interfaceId, bytes4(0x3074ca00), "IArtistRoleResolver");
        assertEq(
            type(IArtistPayoutResolver).interfaceId, bytes4(0x9b2c1793), "IArtistPayoutResolver"
        );
        assertEq(type(IArtistRegistry).interfaceId, bytes4(0x1bec3945), "IArtistRegistry");
        assertEq(type(IAccounts).interfaceId, bytes4(0xc27b4543), "IAccounts");
        assertEq(type(IItemApprovals).interfaceId, bytes4(0x881b19aa), "IItemApprovals");
        assertEq(type(IConsolidationSource).interfaceId, bytes4(0x42129132), "IConsolidationSource");
        assertEq(type(IEntropyModule).interfaceId, bytes4(0x549d75c9), "IEntropyModule");
        assertEq(
            type(IIndependentStreamRegistry).interfaceId,
            bytes4(0x74a7e21a),
            "IIndependentStreamRegistry"
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
            IERC165(IIndependentStreamRegistry(a)),
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

    /// @dev ADR 0005, owner decision 14: the edition auction is a sale adapter like any other,
    ///      claiming its own kind label, so tokens admit it through the generic minter mapping
    ///      and later methods claim new labels. Its sale IDs derive as the English auction's do.
    function test_editionAuctionIsASaleAdapter() public pure {
        ISaleAdapter adapter = IUniformEditionAuction(address(0x6529));
        assertEq(address(adapter), address(0x6529));
        assertEq(SaleKind.UNIFORM_AUCTION, keccak256("UNIFORM_AUCTION"));
        bytes32[4] memory kinds = [
            SaleKind.ENGLISH_AUCTION, SaleKind.FIXED_PRICE, SaleKind.DUTCH, SaleKind.UNIFORM_AUCTION
        ];
        for (uint256 i; i < kinds.length; ++i) {
            for (uint256 j = i + 1; j < kinds.length; ++j) {
                assertTrue(kinds[i] != kinds[j]);
            }
        }
        assertEq(IUniformEditionAuction.saleIdOf.selector, IEnglishAuction.saleIdOf.selector);
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

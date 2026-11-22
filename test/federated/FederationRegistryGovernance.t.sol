// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { FederatedDeployer } from "src/federated/FederatedDeployer.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { FederationRegistry } from "src/federated/FederationRegistry.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IFederationGate } from "src/interfaces/core/IFederationGate.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { FederationFixture, FedSale } from "./FederationFixture.sol";

/// @notice The federation module's governed functions and its gate answers.
contract FederationRegistryGovernanceTest is FederationFixture {
    IFederationRegistry.Form internal constant ERC721 = IFederationRegistry.Form.ERC721;
    IFederationRegistry.Form internal constant ERC1155 = IFederationRegistry.Form.ERC1155;

    function _unauthorized(address caller) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller);
    }

    function _status(address deployer) internal view returns (IFederationRegistry.TemplateStatus) {
        return registry.templateOf(deployer).status;
    }

    function _tokens(address a) internal pure returns (address[] memory t) {
        t = new address[](1);
        t[0] = a;
    }

    // ------------------------------------------------------------------ templates

    function test_ApproveTemplate_RecordsAndLogs() public {
        FederatedDeployer d = new FederatedDeployer(type(FederatedStream).creationCode);
        vm.expectEmit(address(registry));
        emit IFederationRegistry.TemplateSet(
            address(d), d.creationHash(), 7, ERC721, IFederationRegistry.TemplateStatus.APPROVED
        );
        registry.approveTemplate(address(d), 7, ERC721);
        IFederationRegistry.Template memory t = registry.templateOf(address(d));
        assertEq(t.version, 7);
        assertEq(uint8(t.form), uint8(ERC721));
        assertEq(uint8(t.status), uint8(IFederationRegistry.TemplateStatus.APPROVED));
    }

    function test_ApproveTemplate_OncePerDeployer() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederationRegistry.TemplateStatusInvalid.selector,
                address(streamDeployer),
                IFederationRegistry.TemplateStatus.APPROVED
            )
        );
        registry.approveTemplate(address(streamDeployer), 2, ERC721);
    }

    function test_ApproveTemplate_RefusesPairAndNoCode() public {
        FederatedDeployer d = new FederatedDeployer(type(FederatedStream).creationCode);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederationRegistry.TemplateStatusInvalid.selector,
                address(d),
                IFederationRegistry.TemplateStatus.NONE
            )
        );
        registry.approveTemplate(address(d), 1, IFederationRegistry.Form.PAIR);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederationRegistry.TemplateStatusInvalid.selector,
                address(0xBEEF),
                IFederationRegistry.TemplateStatus.NONE
            )
        );
        registry.approveTemplate(address(0xBEEF), 1, ERC721);
    }

    function test_Templates_TransitionsAndTheirRefusals() public {
        address d = address(streamDeployer);
        registry.suspendTemplate(d);
        assertEq(uint8(_status(d)), uint8(IFederationRegistry.TemplateStatus.SUSPENDED));
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederationRegistry.TemplateStatusInvalid.selector,
                d,
                IFederationRegistry.TemplateStatus.SUSPENDED
            )
        );
        registry.suspendTemplate(d);
        registry.resumeTemplate(d);
        assertEq(uint8(_status(d)), uint8(IFederationRegistry.TemplateStatus.APPROVED));
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederationRegistry.TemplateStatusInvalid.selector,
                d,
                IFederationRegistry.TemplateStatus.APPROVED
            )
        );
        registry.resumeTemplate(d);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederationRegistry.TemplateStatusInvalid.selector,
                d,
                IFederationRegistry.TemplateStatus.APPROVED
            )
        );
        registry.reinstateTemplate(d);
        registry.revokeTemplate(d);
        assertEq(uint8(_status(d)), uint8(IFederationRegistry.TemplateStatus.REVOKED));
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederationRegistry.TemplateStatusInvalid.selector,
                d,
                IFederationRegistry.TemplateStatus.REVOKED
            )
        );
        registry.revokeTemplate(d);
        registry.reinstateTemplate(d);
        assertEq(uint8(_status(d)), uint8(IFederationRegistry.TemplateStatus.APPROVED));
    }

    function test_RevokeTemplate_FromSuspended() public {
        registry.suspendTemplate(address(streamDeployer));
        registry.revokeTemplate(address(streamDeployer));
        assertEq(
            uint8(_status(address(streamDeployer))),
            uint8(IFederationRegistry.TemplateStatus.REVOKED)
        );
    }

    function test_RevokeTemplate_RefusesUnknown() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederationRegistry.TemplateStatusInvalid.selector,
                address(0xBEEF),
                IFederationRegistry.TemplateStatus.NONE
            )
        );
        registry.revokeTemplate(address(0xBEEF));
    }

    function test_Governance_EveryWriterIsRestricted() public {
        vm.startPrank(stranger);
        vm.expectRevert(_unauthorized(stranger));
        registry.approveTemplate(address(streamDeployer), 1, ERC721);
        vm.expectRevert(_unauthorized(stranger));
        registry.suspendTemplate(address(streamDeployer));
        vm.expectRevert(_unauthorized(stranger));
        registry.resumeTemplate(address(streamDeployer));
        vm.expectRevert(_unauthorized(stranger));
        registry.revokeTemplate(address(streamDeployer));
        vm.expectRevert(_unauthorized(stranger));
        registry.reinstateTemplate(address(streamDeployer));
        vm.expectRevert(_unauthorized(stranger));
        registry.setAdapter(address(fedSale), false);
        vm.expectRevert(_unauthorized(stranger));
        registry.setStatus(_tokens(address(fStream)), IFederationRegistry.Status.DELISTED, 0);
        vm.expectRevert(_unauthorized(stranger));
        registry.setAccountDelisted(fArtistId, true, 0);
        vm.expectRevert(_unauthorized(stranger));
        registry.lowerFeeShare(address(fStream), 0);
        vm.expectRevert(_unauthorized(stranger));
        registry.setEntropyModule(address(1));
        vm.expectRevert(_unauthorized(stranger));
        registry.releaseContent(address(fStream), 1, bytes32(uint256(1)), fArtistId);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ sale contracts

    function test_SetAdapter_AddRemoveReAdd() public {
        FedSale s = new FedSale();
        assertFalse(registry.wasMinter(address(s)));
        vm.warp(1_800_000_100);
        vm.expectEmit(address(registry));
        emit IFederationRegistry.SaleContractSet(address(s), 1_800_000_100, 0);
        registry.setAdapter(address(s), true);
        assertTrue(registry.wasMinter(address(s)));
        assertEq(registry.minterRemovedAt(address(s)), 0);
        assertTrue(registry.canMint(address(fStream), address(s)));

        vm.warp(1_800_000_200);
        vm.expectEmit(address(registry));
        emit IFederationRegistry.SaleContractSet(address(s), 1_800_000_100, 1_800_000_200);
        registry.setAdapter(address(s), false);
        assertTrue(registry.wasMinter(address(s)), "a removed one still was one");
        assertEq(registry.minterRemovedAt(address(s)), 1_800_000_200);
        assertFalse(registry.canMint(address(fStream), address(s)));

        vm.warp(1_800_000_300);
        registry.setAdapter(address(s), true);
        assertEq(registry.minterRemovedAt(address(s)), 0, "re-adding clears the removal");
        assertEq(registry.saleContractOf(address(s)).addedAt, 1_800_000_300);
        assertTrue(registry.canMint(address(fStream), address(s)));
    }

    function test_SetAdapter_Refusals() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederationRegistry.SaleContractInvalid.selector, address(fedSale)
            )
        );
        registry.setAdapter(address(fedSale), true);
        vm.expectRevert(
            abi.encodeWithSelector(IFederationRegistry.SaleContractInvalid.selector, stranger)
        );
        registry.setAdapter(stranger, true);
        vm.expectRevert(
            abi.encodeWithSelector(IFederationRegistry.SaleContractInvalid.selector, stranger)
        );
        registry.setAdapter(stranger, false);
        registry.setAdapter(address(fedSale), false);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederationRegistry.SaleContractInvalid.selector, address(fedSale)
            )
        );
        registry.setAdapter(address(fedSale), false);
    }

    // ------------------------------------------------------------------ status

    function test_SetStatus_DelistsAndRelistsWithEvents() public {
        vm.expectEmit(address(registry));
        emit IFederationRegistry.StatusSet(
            address(fStream),
            IFederationRegistry.Status.ACTIVE,
            IFederationRegistry.Status.DELISTED,
            "v"
        );
        registry.setStatus(_tokens(address(fStream)), IFederationRegistry.Status.DELISTED, "v");
        assertEq(
            uint8(registry.entry(address(fStream)).status),
            uint8(IFederationRegistry.Status.DELISTED)
        );
        assertFalse(registry.isActive(address(fStream)));
        assertFalse(registry.canMint(address(fStream), address(fedSale)));
        registry.setStatus(_tokens(address(fStream)), IFederationRegistry.Status.ACTIVE, "w");
        assertTrue(registry.isActive(address(fStream)));
        assertTrue(registry.canMint(address(fStream), address(fedSale)));
    }

    function test_SetStatus_SkipsUnlistedAndRefusesNone() public {
        address[] memory t = new address[](2);
        t[0] = stranger;
        t[1] = address(fStream);
        registry.setStatus(t, IFederationRegistry.Status.DELISTED, 0);
        assertEq(uint8(registry.listingOf(stranger).status), 0, "unlisted stays unlisted");
        assertEq(
            uint8(registry.listingOf(address(fStream)).status),
            uint8(IFederationRegistry.Status.DELISTED)
        );
        vm.expectRevert(abi.encodeWithSelector(IFederationRegistry.NotListed.selector, address(0)));
        registry.setStatus(t, IFederationRegistry.Status.NONE, 0);
    }

    function test_SetStatus_BatchBound() public {
        uint256 max = registry.MAX_BATCH();
        registry.setStatus(new address[](max), IFederationRegistry.Status.DELISTED, 0);
        vm.expectRevert(abi.encodeWithSelector(IFederationRegistry.BatchTooLarge.selector, max + 1));
        registry.setStatus(new address[](max + 1), IFederationRegistry.Status.DELISTED, 0);
    }

    function test_SetAccountDelisted_DelistsEveryContractOfTheAccount() public {
        vm.expectEmit(address(registry));
        emit IFederationRegistry.AccountDelistedSet(fArtistId, true, "r");
        registry.setAccountDelisted(fArtistId, true, "r");
        assertTrue(registry.isAccountDelisted(fArtistId));
        assertEq(
            uint8(registry.entry(address(fStream)).status),
            uint8(IFederationRegistry.Status.DELISTED)
        );
        assertEq(
            uint8(registry.entry(address(fEditions)).status),
            uint8(IFederationRegistry.Status.DELISTED)
        );
        assertEq(
            uint8(registry.listingOf(address(fStream)).status),
            uint8(IFederationRegistry.Status.ACTIVE),
            "own status untouched"
        );
        assertFalse(registry.isActive(address(fStream)));
        assertFalse(registry.canMint(address(fEditions), address(fedSale)));
        registry.setAccountDelisted(fArtistId, false, "r2");
        assertTrue(registry.canMint(address(fEditions), address(fedSale)));
    }

    // ------------------------------------------------------------------ fee share

    function test_LowerFeeShare_LowersAndLogs() public {
        vm.expectEmit(address(registry));
        emit IFederationRegistry.FeeShareLowered(address(fStream), SHARE, 2_000);
        registry.lowerFeeShare(address(fStream), 2_000);
        assertEq(registry.feeShareOf(address(fStream)), 2_000);
        assertEq(registry.entry(address(fStream)).feeShare, 2_000);
        registry.lowerFeeShare(address(fStream), 0);
        assertEq(registry.feeShareOf(address(fStream)), 0);
    }

    function testFuzz_LowerFeeShare_NeverRaises(uint32 lowered, uint32 attempt) public {
        lowered = uint32(bound(lowered, 0, SHARE - 1));
        registry.lowerFeeShare(address(fStream), lowered);
        attempt = uint32(bound(attempt, lowered, type(uint32).max));
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederationRegistry.FeeShareNotLowered.selector, address(fStream), lowered
            )
        );
        registry.lowerFeeShare(address(fStream), attempt);
        assertEq(registry.feeShareOf(address(fStream)), lowered);
    }

    function test_LowerFeeShare_RefusesUnlisted() public {
        vm.expectRevert(abi.encodeWithSelector(IFederationRegistry.NotListed.selector, stranger));
        registry.lowerFeeShare(stranger, 0);
        assertEq(registry.feeShareOf(stranger), 0);
    }

    function test_FeeShare_LaterEconomicsChangeLeavesListingAlone() public {
        econ.setFeeShare(20_000);
        assertEq(registry.feeShareOf(address(fStream)), SHARE, "recorded at listing");
    }

    // ------------------------------------------------------------------ entropy, interfaces

    function test_SetEntropyModule_SetsAndLogs() public {
        vm.expectEmit(address(registry));
        emit IFederationRegistry.EntropyModuleSet(address(0), address(0xE));
        registry.setEntropyModule(address(0xE));
        assertEq(registry.entropyModule(), address(0xE));
        registry.setEntropyModule(address(0));
        assertEq(registry.entropyModule(), address(0));
    }

    function test_SupportsInterface() public view {
        assertTrue(registry.supportsInterface(type(IFederationRegistry).interfaceId));
        assertTrue(registry.supportsInterface(type(IFederationGate).interfaceId));
        assertTrue(registry.supportsInterface(type(IMintPolicy).interfaceId));
        assertTrue(registry.supportsInterface(type(IERC165).interfaceId));
        assertFalse(registry.supportsInterface(0xffffffff));
    }

    // ------------------------------------------------------------------ the gate matrix

    function test_Entry_FieldsOfAListedPair() public view {
        IFederationRegistry.Entry memory e = registry.entry(address(fStream));
        assertEq(uint8(e.form), uint8(ERC721));
        assertEq(e.partner, address(fEditions));
        assertEq(e.artistId, fArtistId);
        assertEq(e.templateVersion, 1);
        assertEq(e.codeHash, address(fStream).codehash);
        assertEq(e.feeShare, SHARE);
        assertEq(uint8(e.status), uint8(IFederationRegistry.Status.ACTIVE));
        IFederationRegistry.Entry memory x = registry.entry(address(fEditions));
        assertEq(uint8(x.form), uint8(ERC1155));
        assertEq(x.partner, address(fStream));
    }

    function test_Entry_UnlistedIsZero() public view {
        IFederationRegistry.Entry memory e = registry.entry(stranger);
        assertEq(uint8(e.status), 0);
        assertEq(e.artistId, 0);
        assertEq(e.codeHash, bytes32(0));
        assertFalse(registry.isActive(stranger));
        assertFalse(registry.canMint(stranger, address(fedSale)));
    }

    /// @dev Every combination: template status (approved, suspended, revoked) x own status x
    ///      account delisting x adapter active.
    function testFuzz_GateMatrix(uint8 tpl, bool delisted, bool accountDelisted, bool adapterOn)
        public
    {
        tpl = uint8(bound(tpl, 0, 2));
        address d = address(streamDeployer);
        if (tpl == 1) registry.suspendTemplate(d);
        if (tpl == 2) registry.revokeTemplate(d);
        if (delisted) {
            registry.setStatus(_tokens(address(fStream)), IFederationRegistry.Status.DELISTED, 0);
        }
        if (accountDelisted) registry.setAccountDelisted(fArtistId, true, 0);
        if (!adapterOn) registry.setAdapter(address(fedSale), false);

        bool listedActive = !delisted && !accountDelisted;
        assertEq(registry.isActive(address(fStream)), listedActive && tpl != 2, "isActive");
        assertEq(
            registry.canMint(address(fStream), address(fedSale)),
            listedActive && tpl == 0 && adapterOn,
            "canMint"
        );
        assertEq(
            uint8(registry.entry(address(fStream)).status),
            uint8(
                listedActive
                    ? IFederationRegistry.Status.ACTIVE
                    : IFederationRegistry.Status.DELISTED
            )
        );
    }

    function test_Editions_MintOnlyWhileTheirStreamIsMintable() public {
        assertTrue(registry.canMint(address(fEditions), address(fedSale)));
        registry.suspendTemplate(address(streamDeployer));
        assertFalse(registry.canMint(address(fEditions), address(fedSale)), "stream suspended");
        assertTrue(registry.isActive(address(fEditions)), "editions still served");
        registry.resumeTemplate(address(streamDeployer));
        registry.setStatus(_tokens(address(fStream)), IFederationRegistry.Status.DELISTED, 0);
        assertFalse(registry.canMint(address(fEditions), address(fedSale)), "stream delisted");
        registry.setStatus(_tokens(address(fStream)), IFederationRegistry.Status.ACTIVE, 0);
        registry.suspendTemplate(address(editionsDeployer));
        assertFalse(registry.canMint(address(fEditions), address(fedSale)), "editions suspended");
        assertTrue(registry.canMint(address(fStream), address(fedSale)), "stream unaffected");
    }

    function test_Gate_TokensAskTheRegistry() public {
        assertTrue(fStream.isMinter(address(fedSale)));
        assertTrue(fEditions.isMinter(address(fedSale)));
        registry.setAdapter(address(fedSale), false);
        assertFalse(fStream.isMinter(address(fedSale)));
        assertFalse(fEditions.isMinter(address(fedSale)));
    }

    function test_FeeShareOf_UnlistedIsZero() public view {
        assertEq(registry.feeShareOf(stranger), 0);
        assertEq(registry.minterRemovedAt(stranger), 0);
        assertFalse(registry.wasMinter(stranger));
    }

    function test_Constructor_ReadsSplitFactoryAndPrevious() public {
        registry.setEntropyModule(address(0xE));
        FederationRegistry next = new FederationRegistry(
            address(manager),
            address(fedDirectory),
            address(facts),
            address(econ),
            address(store),
            address(registry)
        );
        assertEq(next.splitFactory(), address(ledger));
        assertEq(next.previous(), address(registry));
        assertEq(next.entropyModule(), address(0xE), "entropy module carried over");
        assertEq(next.directory(), address(fedDirectory));
        assertEq(next.facts(), address(facts));
        assertEq(next.contentStore(), address(store));
    }
}

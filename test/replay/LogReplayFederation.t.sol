// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";
import { MockRenderer } from "../mocks/core/CoreMocks.sol";
import { FedSale, FederationFixture } from "../federated/FederationFixture.sol";
import {
    AccountsIndexer,
    FederatedStreamIndexer,
    FederationRegistryIndexer
} from "./FederationIndexer.sol";

/// @notice Log replay of the federation area: a history that emits every event of the federation
///         module, of a federated artist's `FederatedStream` and of the accounts module rebuilds,
///         from those logs alone, every value their views answer. Every log is recorded from
///         before the fixture's first deployment.
contract LogReplayFederationTest is FederationFixture {
    FederationRegistryIndexer internal regIdx;
    FederatedStreamIndexer internal streamIdx;
    AccountsIndexer internal accIdx;
    uint256 internal newRootKey = 0xE5;

    function setUp() public override {
        vm.recordLogs();
        super.setUp();
        regIdx = new FederationRegistryIndexer(address(registry));
        streamIdx = new FederatedStreamIndexer(address(fStream));
        accIdx = new AccountsIndexer(address(accountsModule));
        _sync();
    }

    function _sync() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        regIdx.ingest(logs, block.timestamp);
        streamIdx.ingest(logs, block.timestamp);
        accIdx.ingest(logs, block.timestamp);
    }

    function _matches() internal {
        _sync();
        regIdx.assertMatches();
        streamIdx.assertMatches();
        accIdx.assertMatches();
    }

    function test_EveryEventReplaysToTheSameState() public {
        _matches();

        // Governance of the module.
        FedSale second = new FedSale();
        registry.setAdapter(address(second), IFederationRegistry.Form.ERC721, true);
        registry.setEntropyModule(address(0xE7));
        address[] memory tokens = new address[](1);
        tokens[0] = address(fEditions);
        registry.setStatus(tokens, IFederationRegistry.Status.DELISTED, "token");
        registry.setAccountDelisted(uint160(0xBAD), true, "account");
        registry.lowerFeeShare(address(fStream), 7_000);
        registry.suspendTemplate(address(editionsDeployer));
        _matches();
        registry.resumeTemplate(address(editionsDeployer));
        registry.setStatus(tokens, IFederationRegistry.Status.ACTIVE, "relisted");
        registry.setAccountDelisted(uint160(0xBAD), false, "relisted");
        registry.setAdapter(address(second), IFederationRegistry.Form.ERC721, false);
        _matches();

        // Items, mints and sales.
        vm.prank(artist);
        registry.approveItem(address(fStream), bytes32(uint256(77)), 100);
        vm.prank(wallet);
        registry.revokeItem(address(fStream), bytes32(uint256(77)));
        uint256 sold = _fedSell(1, collector);
        uint256 unsold = _fedMint(2);
        fedSale.record(address(fStream), unsold, false, address(0), 0);
        uint256 burned = _fedMint(3);
        fedSale.burn(address(fStream), burned);
        registry.releaseContent(
            address(fStream),
            burned,
            sha256(abi.encodePacked("federated work ", uint256(3))),
            fArtistId
        );
        terms.setRoyalty(address(fStream), sold, address(0xFEE), 1234);
        terms.lockRoyaltyRate(address(fStream), sold);
        vm.startPrank(collector);
        fStream.approve(stranger, sold);
        fStream.setApprovalForAll(stranger, true);
        fStream.transferFrom(collector, other, sold);
        vm.stopPrank();
        _matches();

        // The token's settings and the artist's renderer and page.
        fStream.setModuleDelay(1 days);
        fStream.setRescueDelay(3 days);
        MockRenderer next = new MockRenderer();
        vm.prank(wallet);
        fStream.proposeModule(Slots.RENDERER, address(next));
        _matches();
        vm.warp(block.timestamp + 1 days);
        fStream.activateModule(Slots.RENDERER);
        vm.startPrank(artist);
        fStream.setOwner(stranger);
        fStream.setContractURI("ipfs://page");
        vm.stopPrank();
        terms.refresh(address(fStream), 1, 1);
        _matches();

        // A removed sale contract's unsold token is rescued after the delay.
        uint256 stuck = _fedMint(4);
        registry.setAdapter(address(fedSale), IFederationRegistry.Form.ERC721, false);
        vm.warp(block.timestamp + 3 days);
        fStream.rescue(stuck, collector);
        _matches();

        // Accounts: a freeze, an own change executed, a nonce burned, a contested replacement.
        accountsModule.freeze(fArtistId);
        _matches();
        accountsModule.unfreeze(fArtistId);
        ArtistIdentity memory own =
            ArtistIdentity(artist, makeAddr("newPayout"), PROFILE, keccak256("doc 2"));
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = accountsModule.changeDigest(
            fArtistId, own, accountsModule.changeNonce(fArtistId), deadline
        );
        accountsModule.stageChange(fArtistId, own, deadline, _proof(walletKey, digest));
        _matches();
        vm.warp(block.timestamp + 2 days);
        accountsModule.executeChange(fArtistId);
        vm.prank(wallet);
        accountsModule.revokeNonce(fArtistId);
        address newRoot = vm.addr(newRootKey);
        ArtistIdentity memory repl = ArtistIdentity(newRoot, newRoot, PROFILE, keccak256("doc 3"));
        bytes32 evidence = keccak256("evidence");
        deadline = uint64(block.timestamp + 1 days);
        bytes memory acceptance = _sign(
            newRootKey, accountsModule.replacementDigest(fArtistId, repl, evidence, deadline)
        );
        accountsModule.stageReplacement(fArtistId, repl, evidence, deadline, acceptance);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(wallet);
        accountsModule.cancelChange(fArtistId);
        _matches();
        vm.warp(block.timestamp + 91 days);
        accountsModule.expireContest(fArtistId);
        _matches();

        // Every event of the three contracts was replayed at least once.
        _assertSeen(address(regIdx), _registryEvents());
        _assertSeen(address(streamIdx), _streamEvents());
        _assertSeen(address(accIdx), _accountEvents());
    }

    function _assertSeen(address idx, string[] memory events) internal view {
        for (uint256 i; i < events.length; ++i) {
            assertGt(
                FederationRegistryIndexer(idx).seen(keccak256(bytes(events[i]))),
                0,
                string.concat("not replayed: ", events[i])
            );
        }
    }

    function _registryEvents() internal pure returns (string[] memory l) {
        l = new string[](12);
        l[0] = "TemplateSet(address,bytes32,uint32,uint8,uint8)";
        l[1] = "Registered(address,uint256,address,uint8,address,uint32)";
        l[2] = "StatusSet(address,uint8,uint8,bytes32)";
        l[3] = "AccountDelistedSet(uint256,bool,bytes32)";
        l[4] = "FeeShareLowered(address,uint32,uint32)";
        l[5] = "SaleContractSet(address,uint8,uint48,uint48)";
        l[6] = "ItemApproval(address,bytes32,uint24,bool)";
        l[7] = "ItemMinted(address,bytes32,address,address,address)";
        l[8] = "ItemBarred(bytes32)";
        l[9] = "EntropyModuleSet(address,address)";
        l[10] = "ContentReleased(address,uint256,bytes32,uint256)";
        l[11] = "TemplateSet(address,bytes32,uint32,uint8,uint8)";
    }

    function _streamEvents() internal pure returns (string[] memory l) {
        l = new string[](16);
        l[0] = "Transfer(address,address,uint256)";
        l[1] = "Approval(address,address,uint256)";
        l[2] = "ApprovalForAll(address,address,bool)";
        l[3] =
            "WorkMinted(uint256,uint256,uint256,address,uint32,(bytes32,bytes32,uint256,uint256,uint8,uint8,bytes32,address,uint24,bytes32,bytes32,bytes32,address))";
        l[4] = "PrimarySale(uint256,uint8,address,uint256)";
        l[5] = "WorkRescued(uint256,address,address)";
        l[6] = "RoyaltySet(uint256,address,uint24)";
        l[7] = "RoyaltyRateLocked(uint256)";
        l[8] = "CollectionCreated(uint256,string,bytes32)";
        l[9] = "OwnershipTransferred(address,address)";
        l[10] = "RescueDelaySet(uint48,uint48)";
        l[11] = "ModuleDelaySet(uint48,uint48)";
        l[12] = "ModuleProposed(bytes32,address,uint48)";
        l[13] = "ModuleSet(bytes32,address,address)";
        l[14] = "ContractURIUpdated()";
        l[15] = "MetadataUpdate(uint256)";
    }

    function _accountEvents() internal pure returns (string[] memory l) {
        l = new string[](13);
        l[0] = "ArtistRegistered(uint256,(address,address,bytes32,bytes32))";
        l[1] =
            "ChangeStaged(uint256,(uint8,uint48,uint48,(address,address,bytes32,bytes32),bytes32,bytes32))";
        l[2] = "ChangeCancelled(uint256,address,bool)";
        l[3] =
            "ChangeExecuted(uint256,(address,address,bytes32,bytes32),(address,address,bytes32,bytes32))";
        l[4] = "ReplacementAcceptanceConsumed(uint256,bytes32)";
        l[5] = "ChangeContested(uint256,address,bytes32)";
        l[6] = "ContestExpired(uint256)";
        l[7] = "NonceRevoked(uint256,uint256)";
        l[8] = "AccountFrozen(uint256,uint48)";
        l[9] = "AccountUnfrozen(uint256)";
        l[10] = "PackageRegistrySet(address,address)";
        l[11] = "ConsolidationSourceSet(address,address,bytes32)";
        l[12] = "ArtistRegistered(uint256,(address,address,bytes32,bytes32))";
    }

    // -------------------------------------------------------- state the logs do not explain

    function _slot(address target, bytes32 slot, bytes32 value) internal {
        vm.store(target, slot, value);
    }

    function test_RegistryIndexerDetectsStateThatLogsDoNotExplain() public {
        _matches();
        // The entropy module, written without its event.
        _slot(address(registry), bytes32(uint256(1)), bytes32(uint256(0xBEEF)));
        vm.expectRevert();
        regIdx.assertMatches();
    }

    function test_StreamIndexerDetectsStateThatLogsDoNotExplain() public {
        _fedMint(1);
        _matches();
        // The ERC-721 balance of the sale contract (OpenZeppelin slot 3), raised silently.
        bytes32 balanceSlot = keccak256(abi.encode(address(fedSale), uint256(3)));
        _slot(address(fStream), balanceSlot, bytes32(uint256(5)));
        vm.expectRevert();
        streamIdx.assertMatches();
    }

    function test_AccountsIndexerDetectsStateThatLogsDoNotExplain() public {
        _matches();
        // The package registry pointer, rewritten without its event.
        _slot(address(accountsModule), _packageRegistrySlot(), bytes32(uint256(0xBEEF)));
        vm.expectRevert();
        accIdx.assertMatches();
    }

    /// @dev Finds the package registry's slot by its known value.
    function _packageRegistrySlot() internal view returns (bytes32) {
        for (uint256 i; i < 32; ++i) {
            if (
                vm.load(address(accountsModule), bytes32(i))
                    == bytes32(uint256(uint160(packageRegistry)))
            ) return bytes32(i);
        }
        revert("slot not found");
    }
}

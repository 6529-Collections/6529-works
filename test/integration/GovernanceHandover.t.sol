// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Roles } from "src/governance/Roles.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { IntegrationBase } from "./IntegrationBase.sol";
import { MinimalAuthority } from "../mocks/governance/SuccessionMocks.sol";

/// @notice The governance handover on the real genesis stack (GV-44, GV-45): the admins
///         register a deliberately non-OpenZeppelin successor through the slow lane, anyone runs
///         `migrate` once, and every governed contract then answers to the successor. Under it
///         an immediate call, a delayed call consumed through `consumeScheduledOp`, a cancelled
///         call and a whole curated sale work; nothing is left under the old manager, which
///         keeps no power; and the successor can move the contracts on again.
contract GovernanceHandoverTest is IntegrationBase {
    MinimalAuthority internal next;
    address internal executor = makeAddr("tdhExecutor");

    function setUp() public override {
        super.setUp();
        next = new MinimalAuthority(executor);
        // The successor's own configuration, set up before the move: the emergency lane, a
        // 48-hour parameter setter, the curator and platform keys, and the curation signers.
        vm.startPrank(executor);
        next.permit(guardian1, address(auction), ISaleAdapter.pause.selector, 0);
        next.setEmergency(guardian1, true);
        next.permit(hotAdmin, address(allowlist), allowlist.setOpeningBid.selector, Roles.STANDARD);
        next.permit(curator, address(statements), IStatementLog.appendCurator.selector, 0);
        next.permit(platform, address(stream), stream.createCollection.selector, 0);
        next.setMember(Roles.CURATION_SIGNER, signer1, true);
        next.setMember(Roles.CURATION_SIGNER, signer2, true);
        vm.stopPrank();
    }

    /// @dev Every contract the genesis deployment creates.
    function _deployed() internal view returns (address[] memory all) {
        address[27] memory list = [
            address(configurator),
            address(manager),
            address(store),
            address(dependencies),
            address(consolidation),
            address(artists),
            address(releaseVerifier),
            address(splitFactory),
            networkFee,
            museum,
            address(claimRouter),
            address(allowlist),
            address(economics),
            address(escrow),
            address(verifier),
            address(registry),
            address(statements),
            address(entropy),
            address(auction),
            address(editionAuction),
            deployment.editionAuctionLens,
            address(deployment.englishAuctionLens),
            address(renderer),
            address(stream),
            address(records),
            address(delivery),
            address(editions)
        ];
        all = new address[](27);
        for (uint256 i; i < 27; ++i) {
            all[i] = list[i];
        }
    }

    /// @dev The deployed contracts whose authority is `authority`.
    function _governedBy(address authority) internal view returns (address[] memory out) {
        address[] memory all = _deployed();
        out = new address[](all.length);
        uint256 n;
        for (uint256 i; i < all.length; ++i) {
            (bool ok, bytes memory ret) =
                all[i].staticcall(abi.encodeCall(IAccessManaged.authority, ()));
            if (ok && ret.length == 32 && abi.decode(ret, (address)) == authority) {
                out[n++] = all[i];
            }
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    function _handOver() internal returns (uint256 migrateGas) {
        bytes memory register =
            abi.encodeCall(WorksAccessManager.registerSuccessor, (address(next)));
        vm.prank(hotAdmin);
        manager.schedule(address(manager), register, 0);
        vm.warp(block.timestamp + manager.parameter(WorksAccessManager.Parameter.SLOW_DELAY));
        vm.prank(hotAdmin);
        manager.registerSuccessor(address(next));
        vm.prank(makeAddr("anyone"));
        uint256 before = gasleft();
        manager.migrate(0, type(uint256).max);
        migrateGas = before - gasleft();
    }

    // ------------------------------------------------------------------ nothing stranded

    function test_EveryGovernedContractMovesInOneTransaction() public {
        address[] memory governed = _governedBy(address(manager));
        address[] memory managed = manager.managedTargets();
        assertEq(governed.length, 17, "the genesis stack's governed contracts");
        assertEq(managed.length, governed.length, "each one is on the managed list");
        for (uint256 i; i < governed.length; ++i) {
            bool listed;
            for (uint256 j; j < managed.length; ++j) {
                listed = listed || managed[j] == governed[i];
            }
            assertTrue(listed, "managed");
        }
        uint256 gasUsed = _handOver();
        console2.log("migrate gas, whole genesis stack:", gasUsed);
        assertLt(gasUsed, (1 << 24) / 4, "far inside one transaction");
        assertEq(_governedBy(address(manager)).length, 0, "nothing stranded");
        assertEq(_governedBy(address(next)).length, governed.length, "all under the successor");
    }

    function test_AContractAddedAfterGenesisMovesToo() public {
        // A governed module deployed after genesis, onboarded by its 30-day admin delay.
        IAccessManaged late = IAccessManaged(address(new LateModule(address(manager))));
        bytes memory delay =
            abi.encodeCall(IAccessManager.setTargetAdminDelay, (address(late), Roles.SUCCESSOR));
        _govern(hotAdmin, address(manager), delay);
        _handOver();
        assertEq(late.authority(), address(next));
    }

    function test_TheOldManagerKeepsNoPower() public {
        _handOver();
        (bool immediate, uint32 delay) =
            manager.canCall(hotAdmin, address(allowlist), allowlist.setOpeningBid.selector);
        assertFalse(immediate);
        assertEq(delay, 0);
        (bool member,) = manager.hasRole(Roles.ADMIN, hotAdmin);
        assertFalse(member);
        // The old admin's operations on the old manager are refused, and so is a direct call.
        bytes memory back =
            abi.encodeCall(IAccessManager.updateAuthority, (address(stream), address(manager)));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector,
                hotAdmin,
                address(manager),
                IAccessManager.updateAuthority.selector
            )
        );
        vm.prank(hotAdmin);
        manager.schedule(address(manager), back, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManaged.AccessManagedUnauthorized.selector, address(manager)
            )
        );
        vm.prank(address(manager));
        IAccessManaged(address(stream)).setAuthority(address(manager));
        assertEq(stream.authority(), address(next));
        vm.expectRevert( // the old guardians are nobody to the successor's targets
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardian2)
        );
        vm.prank(guardian2);
        auction.pause();
        // The curation verifier now reads signers from the successor.
        assertTrue(verifier.isSignerActive(signer1));
    }

    // ------------------------------------------------------------------ under the successor

    function test_ImmediateDelayedAndCancelledCallsWorkUnderTheSuccessor() public {
        _handOver();

        // Immediate: the emergency pause, and a platform call.
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Paused(guardian1);
        vm.prank(guardian1);
        auction.pause();
        vm.prank(platform);
        stream.createCollection("After the handover", keccak256("after"));

        // Delayed: scheduled on the successor, consumed by the target's own check.
        // (The opening bid, which the English auction locks at start, is the allowlist's.)
        uint256 current = auction.openingBid(CURRENCY_ETH);
        (,, uint64 revision) = allowlist.assetConfig(CURRENCY_ETH);
        bytes memory raise =
            abi.encodeCall(allowlist.setOpeningBid, (CURRENCY_ETH, revision, current + 1));
        vm.prank(hotAdmin);
        bytes32 id = next.schedule(address(allowlist), raise);
        vm.expectRevert(abi.encodeWithSelector(MinimalAuthority.NotReady.selector, id));
        vm.prank(hotAdmin);
        allowlist.setOpeningBid(CURRENCY_ETH, revision, current + 1);
        vm.warp(block.timestamp + Roles.STANDARD);
        vm.expectEmit(address(next));
        emit MinimalAuthority.Consumed(id);
        vm.prank(hotAdmin);
        allowlist.setOpeningBid(CURRENCY_ETH, revision, current + 1);
        assertEq(auction.openingBid(CURRENCY_ETH), current + 1);

        // Cancelled: the emergency account stops a scheduled call.
        bytes memory again =
            abi.encodeCall(allowlist.setOpeningBid, (CURRENCY_ETH, revision + 1, current + 2));
        vm.prank(hotAdmin);
        bytes32 id2 = next.schedule(address(allowlist), again);
        vm.prank(guardian1);
        next.cancel(hotAdmin, address(allowlist), again);
        vm.warp(block.timestamp + Roles.STANDARD);
        vm.expectRevert(abi.encodeWithSelector(MinimalAuthority.NotScheduled.selector, id2));
        vm.prank(hotAdmin);
        allowlist.setOpeningBid(CURRENCY_ETH, revision + 1, current + 2);
    }

    function test_ACuratedSaleRunsUnderTheSuccessor() public {
        _handOver();
        address artist = _actor("handover artist");
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        uint256 tokenId = _sell(root, works, 0, makeAddr("collector"), 1 ether);
        assertEq(stream.ownerOf(tokenId), makeAddr("collector"));
    }

    function test_TheSuccessorCanMoveContractsOnAgain() public {
        _handOver();
        address third = address(new AccessManager(makeAddr("third")));
        vm.prank(executor);
        next.execute(address(stream), abi.encodeCall(IAccessManaged.setAuthority, (third)));
        assertEq(stream.authority(), third);
        // Its self-execution guard: outside `execute` it grants itself nothing.
        (bool immediate,) =
            next.canCall(address(next), address(records), IAccessManaged.setAuthority.selector);
        assertFalse(immediate);
    }
}

/// @notice A governed module deployed after genesis.
contract LateModule is AccessManaged {
    constructor(address authority_) AccessManaged(authority_) { }
}

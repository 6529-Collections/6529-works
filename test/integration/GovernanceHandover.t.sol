// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Roles } from "src/governance/Roles.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { GovernedVault } from "src/economics/GovernedVault.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IStatementLog, Role, Statement } from "src/interfaces/IStatementLog.sol";
import { Locator, LocatorKind } from "src/interfaces/types/ContentTypes.sol";
import {
    CURRENCY_ETH,
    PRODUCT_EDITIONS,
    PRODUCT_STREAM
} from "src/interfaces/types/EconomicsTypes.sol";
import { HASH_SHA256, HashRef } from "src/interfaces/types/HashRef.sol";
import { ArtistIdentity, ChangeKind } from "src/interfaces/types/IdentityTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { WorkDelivery } from "src/stream/WorkDelivery.sol";
import { FederationRegistry } from "src/federated/FederationRegistry.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { IntegrationBase } from "./IntegrationBase.sol";
import {
    CanCallOnlyAuthorityMock,
    MinimalAuthority
} from "../mocks/governance/SuccessionMocks.sol";

/// @notice The governance handover on the real genesis stack (GV-43 to GV-45): the admins
///         propose a deliberately non-OpenZeppelin successor through the slow lane, the
///         successor proves it can act (re-points its probe, accepts), anyone runs `migrate`
///         once, and every governed contract then answers to the successor. Under it, on every
///         managed contract, an immediate call, a delayed call consumed through
///         `consumeScheduledOp` and a cancelled call work, as do the governance manifest, a
///         relayed platform statement, the delivery contract's own locator check and a whole
///         curated sale; nothing is left under the old manager, which keeps no power; the
///         successor moves every contract on again; and a successor that cannot act never
///         takes over.
contract GovernanceHandoverTest is IntegrationBase {
    MinimalAuthority internal next;
    address internal executor = makeAddr("tdhExecutor");
    /// @dev Holds the successor's 48-hour permissions in the per-contract checks.
    address internal operator = makeAddr("successor operator");

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
        address[30] memory list = [
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
            address(editions),
            address(deployment.federationRegistry),
            deployment.federatedEditionAuctionLens,
            address(deployment.federatedEditionAuction)
        ];
        all = new address[](30);
        for (uint256 i; i < 30; ++i) {
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

    /// @dev The admins propose `successor_` through the slow lane.
    function _propose(address successor_) internal {
        bytes memory register = abi.encodeCall(WorksAccessManager.registerSuccessor, (successor_));
        vm.prank(hotAdmin);
        manager.schedule(address(manager), register, 0);
        vm.warp(block.timestamp + manager.parameter(WorksAccessManager.Parameter.SLOW_DELAY));
        vm.prank(hotAdmin);
        manager.registerSuccessor(successor_);
    }

    /// @dev Proposes `next`; its governor re-points the probe to the manager and accepts; then
    ///      anyone migrates. Returns the gas of the migration.
    function _handOver() internal returns (uint256 migrateGas) {
        _propose(address(next));
        vm.startPrank(executor);
        next.execute(
            manager.successionProbe(),
            abi.encodeCall(IAccessManaged.setAuthority, (address(manager)))
        );
        next.execute(address(manager), abi.encodeCall(WorksAccessManager.acceptSuccession, ()));
        vm.stopPrank();
        assertEq(manager.successor(), address(next));
        vm.prank(makeAddr("anyone"));
        uint256 before = gasleft();
        manager.migrate(0, type(uint256).max);
        migrateGas = before - gasleft();
    }

    // ------------------------------------------------------------------ nothing stranded

    function test_EveryGovernedContractMovesInOneTransaction() public {
        address[] memory governed = _governedBy(address(manager));
        address[] memory managed = manager.managedTargets();
        assertEq(governed.length, 19, "the genesis stack's governed contracts");
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

    // ------------------------------------------------------------------ every permanent contract

    /// @dev Under the successor, `operator` holds a 48-hour permission for `delayed`'s and
    ///      `cancelled`'s selectors on `target`: `delayed` is refused before its delay and
    ///      consumed through `consumeScheduledOp` after it; `cancelled` is scheduled, the
    ///      emergency account cancels it, and the target refuses it.
    function _delayedAndCancelled(address target, bytes memory delayed, bytes memory cancelled)
        internal
    {
        vm.startPrank(executor);
        next.permit(operator, target, bytes4(delayed), Roles.STANDARD);
        next.permit(operator, target, bytes4(cancelled), Roles.STANDARD);
        vm.stopPrank();
        vm.prank(operator);
        bytes32 id = next.schedule(target, delayed);
        _expectFailure(
            operator,
            target,
            delayed,
            abi.encodeWithSelector(MinimalAuthority.NotReady.selector, id)
        );
        vm.warp(block.timestamp + Roles.STANDARD);
        vm.expectEmit(address(next));
        emit MinimalAuthority.Consumed(id);
        _succeed(operator, target, delayed);
        assertEq(next.readyAt(id), 0, "consumed");

        vm.prank(operator);
        bytes32 id2 = next.schedule(target, cancelled);
        vm.prank(guardian1);
        next.cancel(operator, target, cancelled);
        vm.warp(block.timestamp + Roles.STANDARD);
        _expectFailure(
            operator,
            target,
            cancelled,
            abi.encodeWithSelector(MinimalAuthority.NotScheduled.selector, id2)
        );
    }

    /// @dev `caller` gets an immediate permission for `data`'s selector on `target` (unless it
    ///      already has one) and the call succeeds at once.
    function _immediate(address caller, address target, bytes memory data) internal {
        (bool allowed, uint32 delay) = next.permissions(target, bytes4(data), caller);
        if (!allowed || delay != 0) {
            vm.prank(executor);
            next.permit(caller, target, bytes4(data), 0);
        }
        _succeed(caller, target, data);
    }

    function _succeed(address caller, address target, bytes memory data) internal {
        vm.prank(caller);
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function _expectFailure(address caller, address target, bytes memory data, bytes memory err)
        internal
    {
        vm.prank(caller);
        (bool ok, bytes memory ret) = target.call(data);
        assertFalse(ok, "refused");
        assertEq(ret, err, "with the authority's error");
    }

    function _statement(bytes32 kind, address token, uint256 id, string memory uri)
        internal
        pure
        returns (Statement memory)
    {
        return Statement(
            token,
            id,
            kind,
            kind == StatementKinds.GOVERNANCE_MANIFEST
                ? keccak256("6529-works/governance-manifest/1")
                : keccak256("6529-works/dispute-outcome/1"),
            HashRef(HASH_SHA256, keccak256(bytes(uri))),
            uri,
            bytes32(0),
            bytes32(0)
        );
    }

    /// @dev Each permanent and replaceable contract on the managed list, under the
    ///      non-OpenZeppelin successor: an immediate call (a guardian's where the genesis map
    ///      has a GUARDIAN or PAUSER selector, otherwise the successor's own immediate lane), a
    ///      delayed call consumed through `consumeScheduledOp`, and a cancelled call.
    function test_EveryManagedContractOperatesUnderTheSuccessor() public {
        address artist = _actor("handover artist");
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        uint256 tokenId = _sell(root, works, 0, makeAddr("collector"), 1 ether);
        records.openRecord(tokenId, works[0].item, works[0].media);
        _handOver();
        uint256 operated;
        operated += _operateStreamAndRecords(tokenId);
        operated += _operateCurationAndIdentity(artist);
        operated += _operateStatementsAndSales(tokenId);
        operated += _operateMoney();
        operated += _operateContentAndEntropy();
        assertEq(operated, manager.managedTargets().length, "every managed contract operated");
    }

    function _operateStreamAndRecords(uint256 tokenId) internal returns (uint256 operated) {
        // Stream (permanent): no guardian selector; PLATFORM is its immediate lane.
        uint256 rescue = stream.rescueDelay();
        _immediate(platform, address(stream), abi.encodeCall(stream.createCollection, ("H", "h")));
        _delayedAndCancelled(
            address(stream),
            abi.encodeCall(stream.setRescueDelay, (rescue + 1)),
            abi.encodeCall(stream.setContractURI, ("ar://cancelled"))
        );
        assertEq(stream.rescueDelay(), rescue + 1);
        ++operated;

        // WorkDelivery (replaceable satellite of WorkRecords).
        _delayedAndCancelled(
            address(delivery),
            abi.encodeCall(delivery.setPreferredKind, (LocatorKind.IPFS)),
            abi.encodeCall(delivery.setPreferredKind, (LocatorKind.ARWEAVE))
        );
        assertEq(uint8(delivery.preferredKind()), uint8(LocatorKind.IPFS));
        _immediate(
            storageOperator,
            address(delivery),
            abi.encodeCall(delivery.setPreferredKind, (LocatorKind.NONE))
        );
        ++operated;

        // WorkRecords (permanent): a new delivery contract, delayed; a store, at once.
        WorkDelivery nextDelivery =
            new WorkDelivery(address(next), address(records), address(stream), address(delivery));
        _delayedAndCancelled(
            address(records),
            abi.encodeCall(records.setDelivery, (address(delivery), address(nextDelivery))),
            abi.encodeCall(records.addStore, (address(store), bytes32(0)))
        );
        assertEq(records.delivery(), address(nextDelivery));
        _immediate(
            hotAdmin,
            address(records),
            abi.encodeCall(records.addStore, (address(store), address(store).codehash))
        );
        ++operated;

        // Editions (permanent): no immediate selector at genesis; the successor's own lane.
        address newOwner = makeAddr("new market owner");
        _delayedAndCancelled(
            address(editions),
            abi.encodeCall(editions.setOwner, (marketOwner, newOwner)),
            abi.encodeCall(editions.setContractURI, ("ar://cancelled"))
        );
        assertEq(editions.owner(), newOwner);
        _immediate(
            hotAdmin, address(editions), abi.encodeCall(editions.setContractURI, ("ar://now"))
        );
        ++operated;
    }

    function _operateCurationAndIdentity(address artist) internal returns (uint256 operated) {
        // PackageRegistry: a guardian's revocation at once, another delayed.
        _immediate(
            guardian1,
            address(registry),
            abi.encodeCall(registry.revokePackage, (keccak256("package a"), keccak256("reason")))
        );
        _delayedAndCancelled(
            address(registry),
            abi.encodeCall(registry.revokePackage, (keccak256("package b"), keccak256("reason"))),
            abi.encodeCall(registry.revokePackage, (keccak256("package c"), keccak256("reason")))
        );
        ++operated;

        // CurationVerifier: a guardian disables a signer at once; re-enabling is delayed.
        _immediate(guardian1, address(verifier), abi.encodeCall(verifier.disableSigner, (signer2)));
        _delayedAndCancelled(
            address(verifier),
            abi.encodeCall(verifier.enableSigner, (signer2)),
            abi.encodeCall(verifier.disableSigner, (signer2))
        );
        assertFalse(verifier.isDisabled(signer2));
        ++operated;

        // ArtistRegistry (permanent): the account's own change, staged and cancelled by it.
        // (Identity lane local patch: guardian veto and governed timers no longer exist.)
        {
            uint256 artistId = uint160(artist);
            ArtistIdentity memory id =
                ArtistIdentity(artist, artist, _profileId(artist), _profileDoc(artist));
            uint64 deadline = uint64(block.timestamp + 1 days);
            bytes32 digest =
                artists.changeDigest(artistId, id, artists.changeNonce(artistId), deadline);
            artists.stageChange(
                artistId, id, deadline, abi.encodePacked(artist, _sign(artist, digest))
            );
            vm.prank(artist);
            artists.cancelChange(artistId);
            assertEq(uint8(artists.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        }
        ++operated;
    }

    function _operateStatementsAndSales(uint256 tokenId) internal returns (uint256 operated) {
        // StatementLog (permanent): a platform statement at once; the governance manifest,
        // delayed, now under the successor's subject.
        _immediate(
            platform,
            address(statements),
            abi.encodeCall(
                statements.appendPlatform,
                (_statement(StatementKinds.DISPUTE_OUTCOME, address(stream), tokenId, "ar://p"))
            )
        );
        (uint64 before,) = statements.chainOf(address(next), 0);
        (uint64 oldChain,) = statements.chainOf(address(manager), 0);
        _delayedAndCancelled(
            address(statements),
            abi.encodeCall(
                statements.appendGovernanceManifest,
                (_statement(StatementKinds.GOVERNANCE_MANIFEST, address(next), 0, "ar://epoch-1"))
            ),
            abi.encodeCall(statements.setArtistResolver, (address(0), address(0), bytes32(0)))
        );
        (uint64 count,) = statements.chainOf(address(next), 0);
        assertEq(count, before + 1, "the successor's governance chain");
        (uint64 oldAfter,) = statements.chainOf(address(manager), 0);
        assertEq(oldAfter, oldChain, "the old manager's chain is closed");
        ++operated;

        // English auction: a guardian's pause at once; the unpause, delayed.
        vm.prank(guardian1);
        auction.pause();
        _delayedAndCancelled(
            address(auction),
            abi.encodeCall(ISaleAdapter.unpause, ()),
            abi.encodeCall(ISaleAdapter.setTarget, (address(stream), true))
        );
        ++operated;

        // Edition auction: the same.
        _immediate(guardian1, address(editionAuction), abi.encodeCall(ISaleAdapter.pause, ()));
        _delayedAndCancelled(
            address(editionAuction),
            abi.encodeCall(ISaleAdapter.unpause, ()),
            abi.encodeCall(ISaleAdapter.setTarget, (address(editions), true))
        );
        ++operated;

        // Federated edition auction (ADR 0008): the same.
        address fea = address(deployment.federatedEditionAuction);
        _immediate(guardian1, fea, abi.encodeCall(ISaleAdapter.pause, ()));
        _delayedAndCancelled(
            fea,
            abi.encodeCall(ISaleAdapter.unpause, ()),
            abi.encodeWithSignature("setLimits(uint256,uint256)", uint256(0), uint256(0))
        );
        ++operated;

        // Federation registry: a guardian's suspension at once; the resumption, delayed; a
        // revocation, cancelled.
        FederationRegistry fed = deployment.federationRegistry;
        bytes32 template = DeployV1.templateCodeHash("FederatedStream");
        _immediate(guardian1, address(fed), abi.encodeCall(fed.suspendTemplate, (template)));
        _delayedAndCancelled(
            address(fed),
            abi.encodeCall(fed.resumeTemplate, (template)),
            abi.encodeCall(fed.revokeTemplate, (template))
        );
        assertEq(
            uint8(fed.templateOf(template).status),
            uint8(FederationRegistry.TemplateStatus.APPROVED),
            "resumed, not revoked"
        );
        ++operated;
    }

    function _operateMoney() internal returns (uint256 operated) {
        // EconomicsResolver: royalty defaults, delayed and at once.
        {
            (, uint64 streamRevision,) = economics.revisions(PRODUCT_STREAM);
            uint32 rate = economics.economics(PRODUCT_STREAM).royaltyRate;
            _delayedAndCancelled(
                address(economics),
                abi.encodeCall(
                    economics.setRoyaltyRate, (PRODUCT_STREAM, streamRevision, rate + 1)
                ),
                abi.encodeCall(economics.setMuseum, (1, makeAddr("elsewhere")))
            );
            assertEq(economics.economics(PRODUCT_STREAM).royaltyRate, rate + 1);
            (, uint64 editionRevision,) = economics.revisions(PRODUCT_EDITIONS);
            _immediate(
                hotAdmin,
                address(economics),
                abi.encodeCall(economics.setRoyaltyRate, (PRODUCT_EDITIONS, editionRevision, rate))
            );
        }
        ++operated;

        // AssetAllowlist: an admission, delayed; a guardian's deprecation, at once.
        {
            (,, uint64 revision) = allowlist.assetConfig(address(usd));
            _delayedAndCancelled(
                address(allowlist),
                abi.encodeCall(allowlist.admitAsset, (address(usd), revision, 1e6)),
                abi.encodeCall(allowlist.setIncrementFloor, (address(usd), revision + 1, 2e6))
            );
            _immediate(
                guardian1,
                address(allowlist),
                abi.encodeCall(allowlist.deprecateAsset, (address(usd)))
            );
        }
        ++operated;

        // RevenueEscrow (permanent): unowed balance swept, delayed and at once.
        vm.deal(address(escrow), address(escrow).balance + 1 ether);
        _delayedAndCancelled(
            address(escrow),
            abi.encodeCall(escrow.sweepExcess, (address(0), networkFeeSafe)),
            abi.encodeCall(escrow.recover, (address(1), address(2), address(0)))
        );
        vm.deal(address(escrow), address(escrow).balance + 1 ether);
        _immediate(
            hotAdmin, address(escrow), abi.encodeCall(escrow.sweepExcess, (address(0), museumSafe))
        );
        ++operated;

        // Both governed vaults (permanent): destinations, delayed and at once.
        address[2] memory vaults = [networkFee, museum];
        for (uint256 i; i < 2; ++i) {
            GovernedVault vault = GovernedVault(payable(vaults[i]));
            uint64 revision = vault.destinationRevision();
            _delayedAndCancelled(
                vaults[i],
                abi.encodeCall(vault.setDestination, (revision, makeAddr("delayed destination"))),
                abi.encodeCall(vault.setDestination, (revision + 1, makeAddr("cancelled")))
            );
            assertEq(vault.destination(), makeAddr("delayed destination"));
            _immediate(
                hotAdmin,
                vaults[i],
                abi.encodeCall(vault.setDestination, (revision + 1, makeAddr("fast destination")))
            );
            ++operated;
        }
    }

    function _operateContentAndEntropy() internal returns (uint256 operated) {
        // DependencyRegistry: a registration, delayed; a guardian's deprecation, at once.
        _delayedAndCancelled(
            address(dependencies),
            abi.encodeCall(dependencies.register, ("handover", "1.0.0", cc0TextFileId)),
            abi.encodeCall(dependencies.register, ("handover", "2.0.0", cc0TextFileId))
        );
        _immediate(
            guardian1,
            address(dependencies),
            abi.encodeCall(dependencies.deprecate, ("handover", "1.0.0"))
        );
        ++operated;

        // Entropy module: a configuration, delayed; lowering the callback gas, at once.
        {
            VrfEntropyModule.VrfConfig memory cfg = entropy.config();
            VrfEntropyModule.VrfConfig memory raised = VrfEntropyModule.VrfConfig(
                cfg.subscriptionId,
                cfg.keyHash,
                cfg.callbackGasLimit,
                cfg.confirmations + 1,
                cfg.nativePayment
            );
            _delayedAndCancelled(
                address(entropy),
                abi.encodeCall(entropy.setConfig, (cfg, raised)),
                abi.encodeCall(entropy.lowerCallbackGasLimit, (cfg.callbackGasLimit, 100_000))
            );
            assertEq(entropy.config().confirmations, cfg.confirmations + 1);
            _immediate(
                hotAdmin,
                address(entropy),
                abi.encodeCall(
                    entropy.lowerCallbackGasLimit, (cfg.callbackGasLimit, cfg.callbackGasLimit - 1)
                )
            );
        }
        ++operated;
    }

    /// @dev The non-stock paths: a relayed PLATFORM statement asks the successor's `canCall`
    ///      for the signer, and `WorkDelivery.addLocator` runs its own `_checkCanCall` for the
    ///      platform key.
    function test_RelayedStatementsAndTheLocatorCheckAskTheSuccessor() public {
        address artist = _actor("relay artist");
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        uint256 tokenId = _sell(root, works, 0, makeAddr("collector"), 1 ether);
        records.openRecord(tokenId, works[0].item, works[0].media);
        _handOver();

        // appendSigned: the platform signer is asked of the successor, which answers immediate.
        address relayed = _actor("relayed platform key");
        Statement memory st =
            _statement(StatementKinds.DISPUTE_OUTCOME, address(stream), tokenId, "ar://relayed");
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes32 digest = statements.authorizationDigest(Role.PLATFORM, st, relayed, 1, deadline);
        bytes memory sig = _sign(relayed, digest);
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.PLATFORM, relayed)
        );
        statements.appendSigned(Role.PLATFORM, st, relayed, 1, deadline, sig);
        vm.prank(executor);
        next.permit(relayed, address(statements), statements.appendPlatform.selector, 0);
        statements.appendSigned(Role.PLATFORM, st, relayed, 1, deadline, sig);
        // A delayed permission is not enough for a relayed statement.
        vm.prank(executor);
        next.permit(relayed, address(statements), statements.appendPlatform.selector, 1 hours);
        digest = statements.authorizationDigest(Role.PLATFORM, st, relayed, 2, deadline);
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.PLATFORM, relayed)
        );
        statements.appendSigned(Role.PLATFORM, st, relayed, 2, deadline, _sign(relayed, digest));

        // addLocator: the delivery contract's own check reaches the successor.
        bytes32 fileId = works[0].media[0].fileId;
        Locator memory locator =
            Locator(LocatorKind.ARWEAVE, "ar://H4ndover00000000000000000000000000000000000");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, curator)
        );
        vm.prank(curator);
        delivery.addLocator(tokenId, fileId, locator);
        vm.prank(executor);
        next.permit(platform, address(delivery), delivery.addLocator.selector, 0);
        vm.prank(platform);
        delivery.addLocator(tokenId, fileId, locator);
        (, uint256 byPlatform,) = delivery.locatorCounts(tokenId, fileId);
        assertEq(byPlatform, 1);
    }

    /// @dev The successor re-points every contract it governs a second time.
    function test_TheSuccessorMovesEveryContractOnAgain() public {
        _handOver();
        address[] memory governed = _governedBy(address(next));
        assertEq(governed.length, 19);
        address third = address(new AccessManager(makeAddr("third")));
        for (uint256 i; i < governed.length; ++i) {
            vm.prank(executor);
            next.execute(governed[i], abi.encodeCall(IAccessManaged.setAuthority, (third)));
        }
        assertEq(_governedBy(address(next)).length, 0, "nothing left behind");
        assertEq(_governedBy(third).length, 19, "all under the third authority");
    }

    // ------------------------------------------------------------------ a successor that cannot act

    /// @dev Review M-1 on the real stack: an authority that answers `canCall` but cannot
    ///      originate a call is proposed through the slow lane and never takes over; every
    ///      contract stays governed by the manager, which keeps all its power.
    function test_ASuccessorThatCannotCallNeverTakesOverTheStack() public {
        CanCallOnlyAuthorityMock dead = new CanCallOnlyAuthorityMock();
        _propose(address(dead));
        assertEq(manager.pendingSuccessor(), address(dead));
        vm.expectRevert(WorksAccessManager.NoSuccessor.selector);
        manager.migrate(0, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.NotPendingSuccessor.selector, address(this))
        );
        manager.acceptSuccession();
        assertEq(_governedBy(address(manager)).length, 19, "nothing moved");
        // The manager still governs: a guardian pause, and the admins replace the proposal.
        vm.prank(guardian2);
        auction.pause();
        _handOver();
        assertEq(_governedBy(address(next)).length, 19);
    }
}

/// @notice A governed module deployed after genesis.
contract LateModule is AccessManaged {
    constructor(address authority_) AccessManaged(authority_) { }
}

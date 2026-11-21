// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { Roles } from "src/governance/Roles.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { GovernedVault } from "src/economics/GovernedVault.sol";
import { DeployGuards } from "script/DeployGuards.sol";
import { ISafe, SafeForkBase } from "./SafeForkBase.sol";

/// @notice The network as a real 2-of-3 Safe v1.4.1 on a mainnet fork: genesis proposes it and
///         it accepts by a Safe transaction; it schedules and executes delayed actions through
///         the deployed `WorksAccessManager`, in `MultiSendCallOnly` batches; it acts at once in
///         the no-delay class (the curation signer kill, unpausing the auction); a brake Safe
///         delays one of its operations; and it hands the network over to a second Safe.
/// @dev Gated by `FORK_MAINNET_RPC` (see `SafeForkBase`). Every Safe transaction that is
///      expected to fail is also replayed as a prank of the Safe where the reason matters, so
///      the test names the exact revert the Safe hit.
contract SafeNetworkForkTest is SafeForkBase {
    address internal artist;

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        artist = _actor("safeForkArtist");
    }

    /// @dev GV-1, GV-2, GV-4, GV-11, GV-13: the genesis Safe transaction made the Safe the
    ///      network with every class delay, the configurator kept nothing, and readback of the
    ///      genesis configuration passes against the Safe.
    function test_SafeAcceptedTheNetworkAtGenesis() public onFork {
        assertEq(manager.network(), address(networkSafe));
        assertEq(manager.pendingNetwork(), address(0));
        assertEq(networkSafe.nonce(), 1, "one Safe transaction: acceptNetwork");
        _assertClass(Roles.NETWORK, 0);
        _assertClass(Roles.PARAMETER_SETTER, Roles.DELAY_24H);
        _assertClass(Roles.FUNDS_SETTER, Roles.DELAY_3D);
        _assertClass(Roles.SUCCESSOR_SETTER, Roles.DELAY_7D);
        _assertClass(Roles.ADMIN, Roles.DELAY_7D);
        (bool isAdmin,) = manager.hasRole(Roles.ADMIN, address(configurator));
        assertFalse(isAdmin, "the configurator renounced");
        configurator.verify(_genesisConfig());
        // The deploy script's holder guard accepts this Safe as the network.
        (address[] memory singletons, bytes32[] memory codehashes) =
            DeployGuards.canonicalSafeSingletons();
        DeployGuards.requireBareSafe("network", address(networkSafe), singletons, codehashes);
        DeployGuards.requireSafe("network", address(networkSafe));
        // The Safe's owners are not the network: only the Safe is.
        address[] memory owners = networkSafe.getOwners();
        for (uint256 i; i < owners.length; ++i) {
            (bool member,) = manager.hasRole(Roles.FUNDS_SETTER, owners[i]);
            assertFalse(member, "an owner key holds no network role");
        }
    }

    /// @dev GV-2, ECO-4, ECO-37, ECO-41: one Safe transaction schedules two 3-day setters (the
    ///      museum and the fee vault's destination); executing early is refused; after the
    ///      delay one Safe transaction executes both, compare-and-set on their revisions.
    function test_SafeSchedulesAndExecutesTwoFundsSettersInOneBatch() public onFork {
        GovernedVault feeVault = GovernedVault(payable(networkFee));
        ISafe nextMuseum = _newSafe("next museum");
        address nextFee = address(_newSafe("next network fee"));
        bytes memory museumCall =
            abi.encodeCall(economics.setMuseum, (economics.museumRevision(), address(nextMuseum)));
        bytes memory feeCall =
            abi.encodeCall(feeVault.setDestination, (feeVault.destinationRevision(), nextFee));

        SafeCall[] memory batch = new SafeCall[](2);
        batch[0] = _scheduleCall(address(economics), museumCall);
        batch[1] = _scheduleCall(address(feeVault), feeCall);
        assertTrue(_safeBatch(networkSafe, batch, THRESHOLD), "schedule both");
        uint48 ready = uint48(block.timestamp + Roles.DELAY_3D);
        assertEq(manager.getSchedule(_opId(networkSafe, address(economics), museumCall)), ready);
        assertEq(manager.getSchedule(_opId(networkSafe, address(feeVault), feeCall)), ready);

        batch[0] = _executeCall(address(economics), museumCall);
        batch[1] = _executeCall(address(feeVault), feeCall);
        vm.warp(ready - 1);
        uint256 nonceBefore = networkSafe.nonce();
        assertFalse(_safeBatch(networkSafe, batch, THRESHOLD), "not ready");
        assertEq(networkSafe.nonce(), nonceBefore, "a refused transaction spends no Safe nonce");

        vm.warp(ready);
        assertTrue(_safeBatch(networkSafe, batch, THRESHOLD), "execute both");
        assertEq(economics.museum(), address(nextMuseum));
        assertEq(economics.museumRevision(), 2);
        assertEq(feeVault.destination(), nextFee);
        assertEq(feeVault.destinationRevision(), 2);
    }

    /// @dev ECO-4, GV-17: a batch whose second call carries a stale revision reverts whole:
    ///      neither setter changes, both operations stay scheduled, and the Safe nonce stands.
    function test_StaleRevisionRevertsTheWholeBatch() public onFork {
        GovernedVault feeVault = GovernedVault(payable(networkFee));
        address nextFee = address(_newSafe("next network fee"));
        bytes memory feeCall =
            abi.encodeCall(feeVault.setDestination, (feeVault.destinationRevision(), nextFee));
        uint64 stale = economics.museumRevision() + 1;
        bytes memory museumCall = abi.encodeCall(economics.setMuseum, (stale, nextFee));

        SafeCall[] memory batch = new SafeCall[](2);
        batch[0] = _scheduleCall(address(feeVault), feeCall);
        batch[1] = _scheduleCall(address(economics), museumCall);
        assertTrue(_safeBatch(networkSafe, batch, THRESHOLD), "scheduling checks no arguments");
        vm.warp(block.timestamp + Roles.DELAY_3D);

        batch[0] = _executeCall(address(feeVault), feeCall);
        batch[1] = _executeCall(address(economics), museumCall);
        uint256 nonceBefore = networkSafe.nonce();
        assertFalse(_safeBatch(networkSafe, batch, THRESHOLD), "the stale call fails the batch");
        assertEq(networkSafe.nonce(), nonceBefore);
        assertEq(feeVault.destination(), address(feeSafe), "the good call rolled back too");
        assertEq(economics.museum(), museum);
        assertGt(manager.getSchedule(_opId(networkSafe, address(feeVault), feeCall)), 0);
        assertGt(manager.getSchedule(_opId(networkSafe, address(economics), museumCall)), 0);
        // The reason: the resolver's own compare-and-set.
        vm.prank(address(networkSafe));
        vm.expectRevert(
            abi.encodeWithSelector(IEconomicsResolver.RevisionMismatch.selector, stale, stale - 1)
        );
        manager.execute(address(economics), museumCall);
    }

    /// @dev GV-2: a delayed setter called by the Safe directly, not through the manager, is
    ///      refused by the target (OpenZeppelin `AccessManaged` asks the manager to consume a
    ///      scheduled operation, and there is none), so the delay cannot be skipped. A stranger
    ///      is refused outright.
    function test_DelayedSetterCalledDirectlyIsRefused() public onFork {
        uint64 revision = economics.museumRevision();
        bytes memory call = abi.encodeCall(economics.setMuseum, (revision, address(feeSafe)));
        assertFalse(_safeCall(networkSafe, address(economics), call));
        assertEq(economics.museum(), museum);
        bytes32 op = _opId(networkSafe, address(economics), call);
        vm.prank(address(networkSafe));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, op)
        );
        economics.setMuseum(revision, address(feeSafe));
        vm.prank(address(feeSafe));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManaged.AccessManagedUnauthorized.selector, address(feeSafe)
            )
        );
        economics.setMuseum(revision, address(feeSafe));
    }

    /// @dev A transaction signed by one owner of the 2-of-3 network Safe reaches nothing.
    function test_OneSignatureIsRefused() public onFork {
        bytes memory call =
            abi.encodeCall(economics.setMuseum, (economics.museumRevision(), address(feeSafe)));
        SafeCall[] memory batch = new SafeCall[](1);
        batch[0] = _scheduleCall(address(economics), call);
        assertFalse(_safeBatch(networkSafe, batch, 1));
        assertEq(manager.getSchedule(_opId(networkSafe, address(economics), call)), 0);
    }

    /// @dev CUR-17, CUR-23, CUR-24, GV-2: the signer kill as one no-delay MultiSend batch,
    ///      `disableSigner` and `killSignerApprovals`, called on the targets directly. A
    ///      package the signer registered before stops being live and its item cannot start.
    function test_SignerKillBatchActsAtOnce() public onFork {
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        bytes32 itemHash = WorksHashing.itemHash(works[0].item);
        assertTrue(registry.isApprovedItem(root, itemHash, _proofOf(works, 0)));
        bytes memory mintData = _mintData(root, works, 0);

        SafeCall[] memory batch = new SafeCall[](2);
        batch[0] = SafeCall(address(verifier), 0, abi.encodeCall(verifier.disableSigner, (signer1)));
        batch[1] =
            SafeCall(address(registry), 0, abi.encodeCall(registry.killSignerApprovals, (signer1)));
        uint256 start = block.timestamp;
        assertTrue(_safeBatch(networkSafe, batch, THRESHOLD), "the kill batch");
        assertEq(block.timestamp, start, "no delay");
        assertTrue(verifier.isDisabled(signer1));
        assertFalse(verifier.isSignerActive(signer1));
        assertFalse(registry.isApprovedItem(root, itemHash, _proofOf(works, 0)), "killed");
        vm.expectRevert();
        auction.start(address(stream), mintData);
        // The other signer still approves new packages.
        assertTrue(verifier.isSignerActive(signer2));
    }

    /// @dev GV-21, GV-3: a pauser key stops new auctions at once; the network Safe resumes
    ///      them at once (`unpause` is NETWORK, no delay), after which a start succeeds.
    function test_PauserStopsAndSafeResumesAtOnce() public onFork {
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        vm.prank(guardian1);
        auction.pause();
        bytes memory mintData = _mintData(root, works, 0);
        vm.expectRevert();
        auction.start(address(stream), mintData);

        assertTrue(_safeCall(networkSafe, address(auction), abi.encodeCall(auction.unpause, ())));
        auction.start(address(stream), mintData);
        assertEq(stream.ownerOf(_totalMinted()), address(auction), "started");
    }

    /// @dev GV-5, GV-6: the network Safe sets a brake Safe (7 days); the brake Safe delays one
    ///      scheduled network operation once; it runs only after the brake's extra 7 days.
    function test_BrakeSafeDelaysAScheduledSafeOperation() public onFork {
        ISafe brakeSafe = _newSafe("brake");
        _safeGovern(
            networkSafe, address(manager), abi.encodeCall(manager.setBrake, (address(brakeSafe)))
        );
        assertEq(manager.brake(), address(brakeSafe));

        bytes memory call =
            abi.encodeCall(economics.setMuseum, (economics.museumRevision(), address(feeSafe)));
        SafeCall[] memory batch = new SafeCall[](1);
        batch[0] = _scheduleCall(address(economics), call);
        assertTrue(_safeBatch(networkSafe, batch, THRESHOLD));
        bytes32 op = _opId(networkSafe, address(economics), call);
        uint48 ready = manager.getSchedule(op);
        assertTrue(_safeCall(brakeSafe, address(manager), abi.encodeCall(manager.brakeOnce, (op))));
        assertEq(manager.notBefore(op), ready + Roles.BRAKE_DELAY);

        bytes memory exec = abi.encodeCall(manager.execute, (address(economics), call));
        vm.warp(ready);
        assertFalse(_safeCall(networkSafe, address(manager), exec), "braked");
        vm.prank(address(networkSafe));
        vm.expectRevert(
            abi.encodeWithSelector(
                WorksAccessManager.BrakeNotElapsed.selector, op, ready + Roles.BRAKE_DELAY
            )
        );
        manager.execute(address(economics), call);
        assertFalse(
            _safeCall(brakeSafe, address(manager), abi.encodeCall(manager.brakeOnce, (op))),
            "once per operation"
        );

        vm.warp(ready + Roles.BRAKE_DELAY);
        assertTrue(_safeCall(networkSafe, address(manager), exec));
        assertEq(economics.museum(), address(feeSafe));
    }

    /// @dev GV-1, GV-4: the network Safe proposes a second Safe (7 days); one signature of the
    ///      successor cannot accept; two do. From then on the old Safe holds nothing and its
    ///      pending operation cannot run, while the new Safe governs.
    function test_HandoverToASecondSafe() public onFork {
        ISafe successor = _newSafe("successor network");
        bytes memory pending =
            abi.encodeCall(economics.setMuseum, (economics.museumRevision(), address(feeSafe)));
        SafeCall[] memory batch = new SafeCall[](1);
        batch[0] = _scheduleCall(address(economics), pending);
        assertTrue(_safeBatch(networkSafe, batch, THRESHOLD));
        _safeGovern(
            networkSafe,
            address(manager),
            abi.encodeCall(manager.transferNetwork, (address(successor)))
        );
        assertEq(manager.pendingNetwork(), address(successor));
        assertEq(manager.network(), address(networkSafe), "nothing changes before acceptance");

        bytes memory accept = abi.encodeCall(manager.acceptNetwork, ());
        assertFalse(_execSafe(successor, address(manager), 0, accept, CALL, 1), "one signature");
        assertTrue(_safeCall(successor, address(manager), accept));
        assertEq(manager.network(), address(successor));
        assertEq(manager.pendingNetwork(), address(0));
        (bool oldMember,) = manager.hasRole(Roles.FUNDS_SETTER, address(networkSafe));
        assertFalse(oldMember, "the old Safe holds nothing");

        // The old Safe's scheduled operation, now ready, cannot run.
        bytes memory exec = abi.encodeCall(manager.execute, (address(economics), pending));
        assertFalse(_safeCall(networkSafe, address(manager), exec));
        vm.prank(address(networkSafe));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector,
                address(networkSafe),
                address(economics),
                IEconomicsResolver.setMuseum.selector
            )
        );
        manager.execute(address(economics), pending);
        assertEq(economics.museum(), museum);

        // The new Safe governs at the same class delays.
        _safeGovern(successor, address(economics), pending);
        assertEq(economics.museum(), address(feeSafe));
    }

    // ------------------------------------------------------------------ helpers

    function _assertClass(uint64 role, uint32 delay) internal view {
        (bool member, uint32 d) = manager.hasRole(role, address(networkSafe));
        assertTrue(member, "the Safe holds the network role");
        assertEq(d, delay, "the class delay");
    }

    function _totalMinted() internal view returns (uint256) {
        return IStream(address(stream)).totalMinted();
    }
}

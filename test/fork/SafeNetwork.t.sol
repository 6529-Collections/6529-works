// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { DeployGuards } from "script/DeployGuards.sol";
import { IGovernedVault } from "src/economics/interfaces/IGovernedVault.sol";
import { Roles } from "src/governance/Roles.sol";
import { Outcome, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IDirectory } from "src/interfaces/core/IDirectory.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { IModuleSlots, IModules } from "src/interfaces/core/IModules.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { MockRenderer } from "../mocks/core/CoreMocks.sol";
import { ISafe, ISafe130ProxyFactory, ISafeProxyFactory, SafeForkBase } from "./SafeForkBase.sol";

/// @notice The network as a real 2-of-3 Safe v1.4.1 on a mainnet fork, governing the deployed
///         plain-core stack by Safe transactions: it proposes a module and anyone activates it
///         once `moduleDelay()` has passed; it removes a minter at once and rescues the unsold
///         work that minter held once `rescueDelay()` has passed; it changes three settings in
///         one `MultiSendCallOnly` batch (a failing call reverts the whole batch); it schedules
///         and executes a 3-day setter through the manager; and it hands the network to a
///         second Safe, which accepts by a Safe transaction. Planted faults: a transaction
///         signed by one owner reaches nothing, and an owner key calling the core directly is
///         refused.
/// @dev Gated by `FORK_MAINNET_RPC` (see `CoreForkBase`). A refused Safe transaction is also
///      repeated as a prank of the Safe where the reason matters, so the test names the exact
///      revert the Safe hit (the Safe itself reverts with "GS013").
contract SafeNetworkForkTest is SafeForkBase {
    address internal artist;
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        artist = _actor("safeForkArtist");
    }

    /// @notice The genesis made the Safe the network of the deployed stack; the deploy guards
    ///         accept it as a bare canonical Safe; its owner keys hold no role.
    function test_SafeNetwork_HoldsTheNetwork() public view {
        assertEq(manager.network(), address(networkSafe));
        assertEq(manager.pendingNetwork(), address(0));
        (bool member, uint32 delay) = manager.hasRole(Roles.NETWORK, address(networkSafe));
        assertTrue(member);
        assertEq(delay, 0, "core functions: no role delay");
        (address[] memory singletons, bytes32[] memory codehashes) =
            DeployGuards.canonicalSafeSingletons();
        // The proxy the canonical 1.4.1 factory just created has the pinned runtime code.
        assertEq(address(networkSafe).codehash, DeployGuards.SAFE_141_PROXY_CODEHASH, "1.4.1 proxy");
        DeployGuards.requireSafeProxy(
            "network", address(networkSafe), DeployGuards.canonicalSafeProxies()
        );
        DeployGuards.requireBareSafe("network", address(networkSafe), singletons, codehashes);
        DeployGuards.requireSafe("network", address(networkSafe));
        address[] memory owners = networkSafe.getOwners();
        assertEq(owners.length, 3);
        for (uint256 i; i < owners.length; ++i) {
            (bool ownerMember,) = manager.hasRole(Roles.NETWORK, owners[i]);
            assertFalse(ownerMember, "an owner key holds no network role");
        }
    }

    /// @notice The Safe proposes a renderer for Stream; activation is refused before the
    ///         module delay in force, then anyone activates it.
    function test_SafeNetwork_ProposesAModuleAndAnyoneActivatesItAfterTheDelay() public {
        address next = address(new MockRenderer());
        _safeCall(
            networkSafe,
            address(stream),
            abi.encodeCall(IModuleSlots.proposeModule, (Slots.RENDERER, next))
        );
        uint48 readyAt = stream.pendingModule(Slots.RENDERER).readyAt;
        assertEq(readyAt, block.timestamp + stream.moduleDelay(), "the delay in force");
        assertGt(stream.moduleDelay(), 0);

        vm.warp(readyAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, Slots.RENDERER)
        );
        vm.prank(stranger);
        stream.activateModule(Slots.RENDERER);

        vm.warp(readyAt);
        vm.prank(stranger);
        stream.activateModule(Slots.RENDERER);
        assertEq(stream.moduleOf(Slots.RENDERER), next);
    }

    /// @notice Planted fault: the same proposal signed by one of the three owners is refused
    ///         by the Safe ("GS020") and nothing is announced.
    function test_SafeNetwork_OneSignatureIsRefused() public {
        address next = address(new MockRenderer());
        bytes memory call = abi.encodeCall(IModuleSlots.proposeModule, (Slots.RENDERER, next));
        uint256 nonceBefore = networkSafe.nonce();
        vm.expectRevert(bytes("GS020"));
        this.execSafeExternal(networkSafe, address(stream), 0, call, CALL, 1);
        assertEq(networkSafe.nonce(), nonceBefore);
        assertEq(stream.pendingModule(Slots.RENDERER).readyAt, 0, "nothing announced");
    }

    /// @notice Planted fault: an owner key of the Safe calling the core directly is refused;
    ///         only the Safe is the network.
    function test_SafeNetwork_AnOwnerKeyCallingDirectlyIsRefused() public {
        address owner = _ownerOf(networkSafe, 0);
        address next = address(new MockRenderer());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner)
        );
        vm.prank(owner);
        stream.proposeModule(Slots.RENDERER, next);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner)
        );
        vm.prank(owner);
        stream.removeMinter(address(auction));
        assertTrue(stream.isMinter(address(auction)));
    }

    /// @notice The Safe removes the English auction as a minter at once: no new work starts.
    ///         The unsold work it held is not rescuable before `rescueDelay()` has passed since
    ///         the removal; then the Safe rescues it to the museum Safe.
    function test_SafeNetwork_RemovesAMinterAndRescuesAfterTheRescueDelay() public {
        Work[] memory works = new Work[](2);
        works[0] = _work(artist, collectionId);
        works[1] = _work(artist, collectionId);
        bytes32 root = _publish(works);
        (, uint256 tokenId) = _start(root, works, 0);
        assertEq(stream.ownerOf(tokenId), address(auction));

        _safeCall(
            networkSafe, address(stream), abi.encodeCall(IModules.removeMinter, (address(auction)))
        );
        uint256 removedAt = block.timestamp;
        assertFalse(stream.isMinter(address(auction)));
        bytes memory next = _mintData(root, works, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintPolicy.NotSaleContract.selector, address(stream), address(auction)
            )
        );
        auction.start(address(stream), next);

        bytes memory rescue = abi.encodeCall(IStream.rescue, (tokenId, address(museumDestination)));
        vm.warp(removedAt + stream.rescueDelay() - 1);
        _safeCallFails(
            networkSafe,
            address(stream),
            rescue,
            abi.encodeWithSelector(IStream.NotRescuable.selector, tokenId)
        );

        vm.warp(removedAt + stream.rescueDelay());
        _safeCall(networkSafe, address(stream), rescue);
        assertEq(stream.ownerOf(tokenId), address(museumDestination));
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.RESCUED));
    }

    /// @notice One MultiSend batch changes the rescue delay, the Editions module delay and the
    ///         unclaimed period at once; a batch with one failing call changes nothing.
    function test_SafeNetwork_ChangesSettingsInOneBatch() public {
        SafeCall[] memory batch = new SafeCall[](3);
        batch[0] =
            SafeCall(address(stream), 0, abi.encodeCall(IStream.setRescueDelay, (uint48(30 days))));
        batch[1] = SafeCall(
            address(editions), 0, abi.encodeCall(IModuleSlots.setModuleDelay, (uint48(10 days)))
        );
        batch[2] = SafeCall(
            address(directory), 0, abi.encodeCall(IDirectory.setUnclaimedPeriod, (uint48(1 days)))
        );
        _safeBatch(networkSafe, batch);
        assertEq(stream.rescueDelay(), 30 days);
        assertEq(editions.moduleDelay(), 10 days);
        assertEq(directory.unclaimedPeriod(), 1 days);

        // The third call announces a module without code: the whole batch reverts.
        batch[0] =
            SafeCall(address(stream), 0, abi.encodeCall(IStream.setRescueDelay, (uint48(1 days))));
        batch[1] = SafeCall(
            address(directory), 0, abi.encodeCall(IDirectory.setUnclaimedPeriod, (uint48(2 days)))
        );
        batch[2] = SafeCall(
            address(stream),
            0,
            abi.encodeCall(IModuleSlots.proposeModule, (Slots.RENDERER, stranger))
        );
        uint256 nonceBefore = networkSafe.nonce();
        vm.expectRevert(bytes("GS013"));
        this.execSafeExternal(
            networkSafe, MULTI_SEND_CALL_ONLY, 0, _multiSend(batch), DELEGATECALL, THRESHOLD
        );
        assertEq(networkSafe.nonce(), nonceBefore);
        assertEq(stream.rescueDelay(), 30 days, "the good calls rolled back too");
        assertEq(directory.unclaimedPeriod(), 1 days);
        assertEq(stream.pendingModule(Slots.RENDERER).readyAt, 0);
    }

    /// @notice A 3-day setter (the fee vault's destination): one batch schedules it through the
    ///         manager; executing early is refused, through the manager or by calling the vault
    ///         directly; after the delay it runs.
    function test_SafeNetwork_SchedulesAndExecutesADelayedSetter() public {
        ISafe nextFee = _newSafe("next network fee");
        bytes memory call = abi.encodeCall(
            IGovernedVault.setDestination, (feeVault.destinationRevision(), address(nextFee))
        );
        SafeCall[] memory batch = new SafeCall[](1);
        batch[0] = _scheduleCall(address(feeVault), call);
        _safeBatch(networkSafe, batch);
        bytes32 op = _opId(networkSafe, address(feeVault), call);
        uint48 ready = manager.getSchedule(op);
        (, uint32 delay) = manager.canCall(address(networkSafe), address(feeVault), bytes4(call));
        assertEq(ready, block.timestamp + delay);
        assertEq(delay, Roles.DELAY_3D);

        bytes memory exec = abi.encodeCall(manager.execute, (address(feeVault), call));
        vm.warp(ready - 1);
        _safeCallFails(
            networkSafe,
            address(manager),
            exec,
            abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, op)
        );
        // A direct call consumes the same scheduled operation, so it waits as long.
        _safeCallFails(
            networkSafe,
            address(feeVault),
            call,
            abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, op)
        );

        vm.warp(ready);
        _safeCall(networkSafe, address(manager), exec);
        assertEq(feeVault.destination(), address(nextFee));
        assertEq(manager.getSchedule(op), 0, "consumed");
    }

    /// @notice The Safe proposes a second Safe (the ADMIN class delay); one signature of the
    ///         successor cannot accept, a Safe transaction of two does. The old Safe then holds
    ///         nothing; the new one governs at once.
    function test_SafeNetwork_HandsOverToASecondSafe() public {
        ISafe successor = _newSafe("successor network");
        _safeGovern(
            networkSafe,
            address(manager),
            abi.encodeCall(manager.transferNetwork, (address(successor)))
        );
        assertEq(manager.pendingNetwork(), address(successor));
        assertEq(manager.network(), address(networkSafe), "nothing changes before acceptance");

        bytes memory accept = abi.encodeCall(manager.acceptNetwork, ());
        vm.expectRevert(bytes("GS020"));
        this.execSafeExternal(successor, address(manager), 0, accept, CALL, 1);
        _safeCall(successor, address(manager), accept);
        assertEq(manager.network(), address(successor));
        assertEq(manager.pendingNetwork(), address(0));
        (bool oldMember,) = manager.hasRole(Roles.NETWORK, address(networkSafe));
        assertFalse(oldMember, "the old Safe holds nothing");

        bytes memory setting = abi.encodeCall(IStream.setRescueDelay, (uint48(1 days)));
        _safeCallFails(
            networkSafe,
            address(stream),
            setting,
            abi.encodeWithSelector(
                IAccessManaged.AccessManagedUnauthorized.selector, address(networkSafe)
            )
        );
        _safeCall(successor, address(stream), setting);
        assertEq(stream.rescueDelay(), 1 days);
    }

    /// @notice Safe 1.3.0: both canonical proxy factories answer the pinned proxy runtime code,
    ///         and a 2-of-3 Safe the first one creates on the 1.3.0 singleton has that code and
    ///         passes the deploy guards.
    function test_SafeNetwork_ASafe130ProxyHasThePinnedCodeAndPassesTheGuards() public {
        address[2] memory factories = [
            0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2, 0xC22834581EbC8527d974F8a1c97E1bEA4EF910BC
        ];
        for (uint256 i; i < factories.length; ++i) {
            assertEq(
                keccak256(ISafe130ProxyFactory(factories[i]).proxyRuntimeCode()),
                DeployGuards.SAFE_130_PROXY_CODEHASH,
                "1.3.0 factory's proxy runtime code"
            );
        }
        address[] memory owners = new address[](3);
        for (uint256 i; i < 3; ++i) {
            owners[i] = makeAddr(string.concat("1.3.0 owner ", vm.toString(i)));
        }
        bytes memory init = abi.encodeCall(
            ISafe.setup,
            (owners, THRESHOLD, address(0), "", address(0), address(0), 0, payable(address(0)))
        );
        address safe = ISafeProxyFactory(factories[0])
            .createProxyWithNonce(DeployGuards.SAFE_130_L1, init, uint256(keccak256("1.3.0")));
        assertEq(safe.codehash, DeployGuards.SAFE_130_PROXY_CODEHASH, "1.3.0 proxy");
        (address[] memory singletons, bytes32[] memory codehashes) =
            DeployGuards.canonicalSafeSingletons();
        DeployGuards.requireSafeProxy("network", safe, DeployGuards.canonicalSafeProxies());
        DeployGuards.requireSafe("network", safe);
        DeployGuards.requireBareSafe("network", safe, singletons, codehashes);
        assertEq(DeployGuards.ownersOf("network", safe).length, 3);
    }

    /// @notice A Safe's transaction hash is the EIP-712 digest of its `SafeTx` under the domain
    ///         of the chain ID and the Safe's address, with the two type hashes
    ///         `script/sepolia/flows.ps1` computes it from before its owners sign.
    function test_SafeNetwork_TheTransactionHashIsTheEip712DigestComputedLocally() public view {
        bytes32 domainTypehash =
            keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");
        bytes32 safeTxTypehash = keccak256(
            "SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)"
        );
        assertEq(domainTypehash, 0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218);
        assertEq(safeTxTypehash, 0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8);
        bytes memory data = abi.encodeCall(manager.acceptNetwork, ());
        uint256 nonce = networkSafe.nonce();
        bytes32 domain = keccak256(abi.encode(domainTypehash, block.chainid, address(networkSafe)));
        assertEq(domain, networkSafe.domainSeparator());
        bytes32 structHash = keccak256(
            abi.encode(
                safeTxTypehash,
                address(manager),
                uint256(0),
                keccak256(data),
                CALL,
                uint256(0),
                uint256(0),
                uint256(0),
                address(0),
                address(0),
                nonce
            )
        );
        assertEq(
            keccak256(abi.encodePacked(bytes2(0x1901), domain, structHash)),
            networkSafe.getTransactionHash(
                address(manager), 0, data, CALL, 0, 0, 0, address(0), address(0), nonce
            )
        );
    }
}

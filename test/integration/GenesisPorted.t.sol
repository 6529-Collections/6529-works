// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { DeployCore } from "script/DeployCore.sol";
import { VerifyCore } from "script/VerifyCore.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Roles } from "src/governance/Roles.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { CURRENCY_DEFAULT, CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import {
    Erc165PeerPortedMock,
    WiringTargetPortedMock
} from "../governance/GenesisWiringPortedMocks.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice JSON helpers over the committed genesis policy, shared by the genesis suites.
abstract contract GenesisJsonPorted is IntegrationBase {
    function _at(string memory base, uint256 i) internal pure returns (string memory) {
        return string.concat(base, "[", vm.toString(i), "]");
    }

    function _count(string memory json, string memory base) internal view returns (uint256 n) {
        while (vm.keyExistsJson(json, _at(base, n))) ++n;
    }

    function _str(string memory json, string memory key) internal pure returns (string memory) {
        return vm.parseJsonString(json, key);
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _roleId(string memory name) internal pure returns (uint64) {
        if (_eq(name, "ADMIN")) return Roles.ADMIN;
        for (uint64 id = 1; id < Roles.COUNT; ++id) {
            if (Roles.isKnown(id) && _eq(name, Roles.label(id))) return id;
        }
        revert(string.concat("unknown role ", name));
    }
}

/// @notice Re-ported from the retired genesis suites (`integration/Genesis`,
///         `governance/GenesisConfig`, `deploy/GenesisFlows`, `deploy/VerifyGenesisState`) onto
///         the deployed plain-core stack, with the VRF entropy module, so every contract and
///         every wiring call of `config/genesis.core.example.json` is present.
contract GenesisPortedTest is GenesisJsonPorted {
    address internal outsider = makeAddr("genesisOutsider");

    /// @dev Raised by a `check_*` function when the readback accepts a wrong value.
    error ReadbackAccepted(string what);

    function _withVrf() internal pure override returns (bool) {
        return true;
    }

    // ------------------------------------------------------------------ the wiring

    /// @dev Every genesis wiring call took effect, the epoch-0 manifest is the manager's first
    ///      statement, the configurator keeps no record and the readback holds.
    function test_WiringIsInPlaceAndTheReadbackPasses() public view {
        assertEq(registry.stream(), address(stream), "PackageRegistry -> Stream");
        assertEq(registry.entropyModule(), address(entropy), "PackageRegistry -> entropy");
        IUniformEditionAuctionLens lens = IUniformEditionAuctionLens(address(editionAuction));
        assertTrue(lens.isTarget(address(editions)), "the edition auction sells editions");
        assertFalse(lens.isTarget(address(stream)), "and nothing else");
        assertEq(allowlist.openingBid(address(0)), OPENING_BID, "the ETH opening bid");
        assertGt(
            independentStream.saleContractOf(address(auction)).addedAt, 0, "EnglishAuction admitted"
        );
        assertGt(
            independentStream.saleContractOf(deployment.independentEditionAuction).addedAt,
            0,
            "IndependentEditionAuction admitted"
        );
        IIndependentStreamRegistry.Template memory s =
            independentStream.templateOf(deployment.independentStream721Deployer);
        assertEq(uint8(s.status), uint8(IIndependentStreamRegistry.TemplateStatus.APPROVED));
        assertEq(uint8(s.form), uint8(IIndependentStreamRegistry.Form.ERC721));
        assertEq(s.version, 1);
        IIndependentStreamRegistry.Template memory e =
            independentStream.templateOf(deployment.independentStreamEditionsDeployer);
        assertEq(uint8(e.status), uint8(IIndependentStreamRegistry.TemplateStatus.APPROVED));
        assertEq(uint8(e.form), uint8(IIndependentStreamRegistry.Form.ERC1155));
        assertEq(
            independentStream.entropyModule(), address(entropy), "Independent Stream -> entropy"
        );
        (uint64 count,) = statements.chainOf(address(manager), 0);
        assertEq(count, 1, "the epoch-0 manifest is the manager's first statement");

        for (uint64 role; role < Roles.COUNT; ++role) {
            assertFalse(GovernanceConfig.hasRecord(manager, role, address(configurator)));
        }
        configurator.verify(_genesisConfig());
    }

    /// @dev The `checkNothingDropped` equivalent: with the whole stack deployed, the
    ///      configuration and wiring `DeployCore` builds from the genesis file keep every
    ///      contract (with every governed function) and every wiring call; none is left out as
    ///      "not deployed".
    function test_NothingInThePolicyIsDroppedAtInstall() public view {
        GovernanceConfig.Config memory cfg = _genesisConfig();
        uint256 contracts = _count(genesisJson, ".contracts");
        assertEq(cfg.targets.length, contracts, "every contract is a target");
        for (uint256 i; i < contracts; ++i) {
            string memory c = _at(".contracts", i);
            string memory name = _str(genesisJson, string.concat(c, ".name"));
            address target_ = DeployCore.addressOf(deployment, name);
            assertTrue(target_ != address(0), name);
            assertEq(cfg.targets[i].target, target_, name);
            assertEq(
                cfg.targets[i].functions.length,
                _count(genesisJson, string.concat(c, ".functions")),
                name
            );
        }
        GovernanceConfig.Call[] memory calls = DeployCore.wiring(deployment, genesisJson, manifest);
        assertEq(calls.length, _count(genesisJson, ".wiring"), "every wiring call is kept");
        for (uint256 i; i < calls.length; ++i) {
            string memory w = _at(".wiring", i);
            assertEq(
                calls[i].target,
                DeployCore.addressOf(deployment, _str(genesisJson, string.concat(w, ".contract")))
            );
            assertEq(
                bytes4(calls[i].data),
                bytes4(keccak256(bytes(_str(genesisJson, string.concat(w, ".signature")))))
            );
        }
        assertEq(cfg.grants.length, _count(genesisJson, ".holders"), "every holder");
    }

    /// @dev The installed role map is the genesis file, for every function of every contract
    ///      (role, and the delay the network or the holder waits); each listed function exists
    ///      on its contract and is restricted: an outsider is refused by the manager.
    function test_EveryListedFunctionIsInstalledAndRestricted() public {
        uint256 contracts = _count(genesisJson, ".contracts");
        uint256 checked;
        uint256 via;
        uint256 refused;
        for (uint256 i; i < contracts; ++i) {
            string memory c = _at(".contracts", i);
            address target_ =
                DeployCore.addressOf(deployment, _str(genesisJson, string.concat(c, ".name")));
            uint256 n = _count(genesisJson, string.concat(c, ".functions"));
            for (uint256 j; j < n; ++j) {
                uint8 kind = _checkFunction(c, target_, j);
                ++checked;
                if (kind == 1) ++refused;
                if (kind == 2) ++via;
            }
        }
        assertGt(checked, 90);
        assertEq(via, 4, "rescue, setRescueDelay, rebind, setRebindDelay on the Directory");
        console2.log("listed functions refusing an outsider at once:", refused);
        assertEq(refused, checked - via - 3, "all but renounce, setFileStore and addLocator");
    }

    /// @dev Checks function `j` of contract entry `c` deployed at `target_`: its installed role and
    ///      the network's wait; then probes it as an outsider. Returns 1 when the manager refused
    ///      the outsider at once, 2 for a `via` row (asked on the Directory's behalf: the
    ///      Directory has no such function), 0 when the function checks its arguments first.
    function _checkFunction(string memory c, address target_, uint256 j) internal returns (uint8) {
        string memory f = _at(string.concat(c, ".functions"), j);
        bytes4 sel = bytes4(vm.parseJsonBytes(genesisJson, string.concat(f, ".selector")));
        string memory label = string.concat(
            _str(genesisJson, string.concat(c, ".name")),
            ".",
            _str(genesisJson, string.concat(f, ".signature"))
        );
        uint64 role = _roleId(_str(genesisJson, string.concat(f, ".role")));
        assertEq(manager.getTargetFunctionRole(target_, sel), role, label);
        assertEq(
            manager.getRoleAdmin(role),
            Roles.isNetworkRole(role) ? Roles.ADMIN : Roles.NETWORK,
            label
        );
        if (Roles.isNetworkRole(role)) {
            (bool immediate, uint32 delay) = manager.canCall(network, target_, sel);
            uint256 expected = vm.parseJsonUint(genesisJson, string.concat(f, ".delay"));
            assertEq(immediate, expected == 0, label);
            assertEq(delay, immediate ? 0 : expected, label);
        }
        (bool ok, bytes memory reason) = _probe(target_, abi.encodePacked(sel, new bytes(32 * 40)));
        assertFalse(ok, label);
        if (vm.keyExistsJson(genesisJson, string.concat(f, ".via"))) {
            assertEq(reason.length, 0, label);
            return 2;
        }
        // A missing function (no fallback) reverts with no data: every listed one answers.
        // Most refuse the outsider at once; a few check their own arguments first (the
        // consent-gated record changes), which a zero call cannot pass.
        assertGt(reason.length, 0, label);
        if (
            keccak256(reason)
                == keccak256(
                    abi.encodeWithSelector(
                        IAccessManaged.AccessManagedUnauthorized.selector, outsider
                    )
                )
        ) return 1;
        console2.log("checks its arguments first:", label);
        return 0;
    }

    function _probe(address target_, bytes memory data) internal returns (bool ok, bytes memory r) {
        vm.prank(outsider);
        (ok, r) = target_.call(data);
    }

    /// @dev Genesis-only and wiring selectors are the network's only through its delay after
    ///      install: the one-shot Stream bind waits the manager's 7-day ADMIN class and is then
    ///      refused as already bound; every wiring call's selector waits at least a day.
    function test_GenesisOnlySelectorsWaitAndRefuseARepeatAfterInstall() public {
        GovernanceConfig.Call[] memory calls = DeployCore.wiring(deployment, genesisJson, manifest);
        for (uint256 i; i < calls.length; ++i) {
            (bool immediate, uint32 delay) =
                manager.canCall(network, calls[i].target, bytes4(calls[i].data));
            assertFalse(immediate, "no wiring call repeats at once");
            assertGe(delay, 24 hours);
        }
        bytes memory again = abi.encodeCall(IPackageRegistry.bindStream, (address(stream)));
        (bool now_, uint32 wait) = manager.canCall(network, address(registry), bytes4(again));
        assertFalse(now_);
        assertEq(wait, 7 days, "unmapped: the ADMIN class");
        vm.prank(network);
        manager.schedule(address(registry), again, 0);
        vm.warp(block.timestamp + wait);
        vm.prank(network);
        (bool ok,) =
            address(manager).call(abi.encodeCall(manager.execute, (address(registry), again)));
        assertFalse(ok, "the one-shot bind is refused");
        assertEq(registry.stream(), address(stream));
    }

    // ------------------------------------------------------------------ the network

    /// @dev The platform key holds its zero-delay locator path; nobody else does.
    function test_PlatformHoldsItsZeroDelayPaths() public view {
        (bool immediate, uint32 delay) =
            manager.canCall(platform, address(delivery), delivery.addLocator.selector);
        assertTrue(immediate && delay == 0, "PLATFORM adds locators");
        (immediate,) = manager.canCall(outsider, address(delivery), delivery.addLocator.selector);
        assertFalse(immediate, "nobody else");
    }

    /// @dev The network cancels operations it scheduled; none can be executed afterwards.
    function test_TheNetworkCancelsItsScheduledOperations() public {
        bytes memory takeStream =
            abi.encodeCall(IAccessManager.updateAuthority, (address(stream), outsider));
        bytes4[] memory one = new bytes4[](1);
        one[0] = stream.createCollection.selector;
        bytes memory mapCollections = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (address(stream), one, Roles.PUBLIC)
        );
        bytes memory lowerShare =
            abi.encodeCall(independentStream.lowerFeeShare, (address(stream), uint32(0)));
        bytes[3] memory ops = [takeStream, mapCollections, lowerShare];
        address[3] memory targets = [address(manager), address(manager), address(independentStream)];
        for (uint256 i; i < 3; ++i) {
            vm.prank(network);
            manager.schedule(targets[i], ops[i], 0);
        }
        for (uint256 i; i < 3; ++i) {
            vm.prank(network);
            manager.cancel(network, targets[i], ops[i]);
        }
        vm.warp(block.timestamp + 8 days);
        for (uint256 i; i < 3; ++i) {
            bytes32 id = manager.hashOperation(network, targets[i], ops[i]);
            vm.prank(network);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, id)
            );
            manager.execute(targets[i], ops[i]);
        }
        assertEq(IAccessManaged(address(stream)).authority(), address(manager), "still governed");
        assertEq(
            manager.getTargetFunctionRole(address(stream), stream.createCollection.selector),
            Roles.PLATFORM
        );
    }

    /// @dev A brake the network installs (none at launch) delays a scheduled operation once by
    ///      7 days; it cannot brake it twice, and the operation then runs.
    function test_ABrakeDelaysAScheduledOperationOnce() public {
        assertEq(manager.brake(), address(0), "no brake at launch");
        address brake = makeAddr("brake");
        _govern(network, address(manager), abi.encodeCall(manager.setBrake, (brake)));
        assertEq(manager.brake(), brake);
        bytes memory release = abi.encodeCall(
            registry.releaseContent, (address(stream), uint256(1), bytes32(uint256(1)), uint256(1))
        );
        vm.prank(network);
        (bytes32 id,) = manager.schedule(address(registry), release, 0);
        uint48 ready = manager.getSchedule(id);
        vm.prank(brake);
        manager.brakeOnce(id);
        vm.prank(brake);
        vm.expectRevert(abi.encodeWithSelector(WorksAccessManager.AlreadyBraked.selector, id));
        manager.brakeOnce(id);
        vm.warp(ready);
        vm.prank(network);
        vm.expectRevert(
            abi.encodeWithSelector(
                WorksAccessManager.BrakeNotElapsed.selector, id, ready + uint48(7 days)
            )
        );
        manager.execute(address(registry), release);
        assertEq(manager.notBefore(id), ready + uint48(7 days));
    }

    /// @dev The network hands over to a new address: 7 days, then the new address accepts; the
    ///      old address then holds nothing and cannot act.
    function test_TheNetworkHandsOverAndTheOldAddressHoldsNothing() public {
        address next = makeAddr("nextNetwork");
        _govern(network, address(manager), abi.encodeCall(manager.transferNetwork, (next)));
        assertEq(manager.network(), network, "nothing changes before acceptance");
        vm.prank(next);
        manager.acceptNetwork();
        assertEq(manager.network(), next);
        uint64[5] memory roles = [
            Roles.ADMIN,
            Roles.NETWORK,
            Roles.PARAMETER_SETTER,
            Roles.FUNDS_SETTER,
            Roles.SUCCESSOR_SETTER
        ];
        for (uint256 i; i < roles.length; ++i) {
            (bool held,) = manager.hasRole(roles[i], network);
            assertFalse(held, "the old network holds nothing");
            (held,) = manager.hasRole(roles[i], next);
            assertTrue(held);
        }
        vm.prank(network);
        vm.expectRevert();
        manager.schedule(address(manager), abi.encodeCall(manager.setBrake, (outsider)), 0);
    }

    // ------------------------------------------------------------------ the genesis block

    /// @dev Formerly G-1: in the genesis block, with no time passing, a curated work priced in
    ///      `CURRENCY_DEFAULT` (ETH at launch) starts its auction, and its edition auction opens
    ///      beside it on the genesis wiring alone.
    function test_ACurrencyDefaultMasterAndItsEditionStartInTheGenesisBlock() public {
        uint256 genesisTime = block.timestamp;
        Work memory w = _asMaster(_work(_actor("genesisArtist"), collectionId), 100);
        w.item.sale.currency = CURRENCY_DEFAULT;
        Work[] memory works = _one(w);
        bytes32 root = _publish(works);
        (, uint256 tokenId) = _start(root, works, 0);
        assertEq(stream.ownerOf(tokenId), address(auction), "minted into the auction");

        IUniformEditionAuctionLens lens = IUniformEditionAuctionLens(address(editionAuction));
        uint256 saleId = lens.saleIdOf(address(editions), tokenId);
        vm.prank(makeAddr("anyone"));
        assertEq(
            editionAuction.open(
                address(editions), tokenId, abi.encode(w.item, root, new bytes32[](0))
            ),
            saleId
        );
        IUniformEditionAuction.Auction memory a =
            IUniformEditionAuction(address(editionAuction)).auction(saleId);
        assertEq(uint8(a.status), uint8(IUniformEditionAuction.AuctionStatus.OPEN));
        assertEq(a.maxCount, 100, "the creator's cap");
        assertEq(block.timestamp, genesisTime, "no time passed");
        assertEq(WorksHashing.itemHash(w.item), stream.itemHashOf(tokenId));
        assertEq(CURRENCY_ETH, address(0));
    }

    // ------------------------------------------------------------------ the readback

    function verifyExternal(DeployCore.Params memory q) external view {
        VerifyCore.verify(q, deployment, _genesisConfig(), true);
    }

    /// @dev The readback catches a changed setting (kept: `DeployCore.t.sol` covers the rest).
    function test_TheGenesisReadsBackAndAChangedSettingFails() public {
        this.verifyExternal(params);
        _asNetwork(address(stream), abi.encodeCall(stream.setRescueDelay, (1 days)));
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyCore.Mismatch.selector, "Stream6529.rescueDelay", address(0)
            )
        );
        this.verifyExternal(params);
    }

    /// @dev The genesis readback compares each governed vault's destination with the recipient
    ///      the deployment was given.
    function test_Readback_RefusesAWrongFeeVaultDestination() external view {
        DeployCore.Params memory q = params;
        q.feeRecipient = address(0xBAD);
        try this.verifyExternal(q) {
            revert ReadbackAccepted("fee vault destination");
        } catch { }
        assertEq(feeVault.destination(), feeSafe);
    }

    /// @dev The genesis readback checks the wiring's effects: here the edition auction's sale
    ///      target removed.
    function test_Readback_RefusesAMissingWiringEffect() external {
        vm.mockCall(
            address(editionAuction),
            abi.encodeCall(IUniformEditionAuctionLens.isTarget, (address(editions))),
            abi.encode(false)
        );
        try this.verifyExternal(params) {
            revert ReadbackAccepted("edition auction sale target");
        } catch { }
    }
}

/// @notice Without the VRF entropy module the policy loses exactly the entropy module's target
///         and the two wiring calls that name it; nothing else is dropped.
contract GenesisWithoutVrfPortedTest is GenesisJsonPorted {
    function test_OnlyTheEntropyModuleIsLeftOut() public view {
        GovernanceConfig.Config memory cfg = _genesisConfig();
        assertEq(deployment.entropyModule, address(0));
        assertEq(cfg.targets.length, _count(genesisJson, ".contracts") - 1);
        for (uint256 i; i < cfg.targets.length; ++i) {
            assertTrue(cfg.targets[i].target != address(0));
        }
        GovernanceConfig.Call[] memory calls = DeployCore.wiring(deployment, genesisJson, manifest);
        assertEq(calls.length, _count(genesisJson, ".wiring") - 2);
        for (uint256 i; i < calls.length; ++i) {
            assertTrue(
                bytes4(calls[i].data) != IPackageRegistry.setEntropyModule.selector
                    && bytes4(calls[i].data) != independentStream.setEntropyModule.selector
            );
        }
        assertEq(registry.entropyModule(), address(0));
        assertEq(independentStream.entropyModule(), address(0));
    }
}

/// @notice The genesis transaction itself: `configure` with the committed configuration and
///         wiring on a fresh deployment, and with the wiring bound filled to its maximum,
///         measured against the EIP-7825 transaction cap with 40% headroom.
contract GenesisTransactionPortedTest is GenesisJsonPorted {
    function _withVrf() internal pure override returns (bool) {
        return true;
    }

    function _fresh(bytes32 namespace) internal returns (DeployCore.Deployment memory all) {
        DeployCore.Params memory q = _params();
        q.namespace = namespace;
        all = DeployCore.deploy(q, address(this));
    }

    function _measure(
        DeployCore.Deployment memory all,
        GovernanceConfig.Config memory cfg,
        GovernanceConfig.Call[] memory calls
    ) internal returns (uint256 total, uint256 execution) {
        vm.cool(address(all.configurator));
        vm.cool(address(all.manager));
        for (uint256 i; i < cfg.targets.length; ++i) {
            vm.cool(cfg.targets[i].target);
        }
        uint256 calldataBytes =
            abi.encodeCall(all.configurator.configure, (cfg, manifest.digest, calls)).length;
        vm.prank(deployer);
        uint256 before = gasleft();
        all.configurator.configure(cfg, manifest.digest, calls);
        execution = before - gasleft();
        // Intrinsic 21,000 plus 40 gas per calldata byte bounds both the standard calldata
        // price and the EIP-7623 floor.
        total = 21_000 + 40 * calldataBytes + execution;
    }

    function test_GenesisConfigureFitsTheTransactionCap() public {
        DeployCore.Deployment memory all = _fresh(keccak256("genesis transaction"));
        GovernanceConfig.Config memory cfg = DeployCore.config(all, genesisJson);
        cfg.network = network;
        GovernanceConfig.Call[] memory calls = DeployCore.wiring(all, genesisJson, manifest);
        (uint256 total, uint256 execution) = _measure(all, cfg, calls);
        console2.log("genesis configure, execution", execution);
        console2.log("genesis configure, whole transaction", total);
        assertLt(total, TX_GAS_CAP * 60 / 100, "keep 40% headroom under the EIP-7825 cap");
        vm.prank(network);
        all.manager.acceptNetwork();
        all.configurator.verify(cfg);
    }

    /// @dev Sizes `MAX_WIRING_CALLS`: the genesis configuration plus one more target, with the
    ///      wiring filled to 64 calls (the genesis calls, then sale-target grants that each
    ///      ERC-165-check a fresh, cold peer and write a fresh slot).
    function test_MaximumWiringFitsTheTransactionCap() public {
        DeployCore.Deployment memory all = _fresh(keccak256("genesis max wiring"));
        GovernanceConfig.Config memory genesis = DeployCore.config(all, genesisJson);
        GovernanceConfig.Call[] memory genesisCalls = DeployCore.wiring(all, genesisJson, manifest);
        WiringTargetPortedMock wired = new WiringTargetPortedMock(address(all.manager));

        GovernanceConfig.Config memory cfg;
        cfg.network = network;
        cfg.grants = genesis.grants;
        cfg.targets = new GovernanceConfig.Target[](genesis.targets.length + 1);
        for (uint256 i; i < genesis.targets.length; ++i) {
            cfg.targets[i] = genesis.targets[i];
        }
        GovernanceConfig.FunctionRole[] memory fns = new GovernanceConfig.FunctionRole[](1);
        fns[0] = GovernanceConfig.FunctionRole(
            WiringTargetPortedMock.setTarget.selector, Roles.SUCCESSOR_SETTER
        );
        cfg.targets[genesis.targets.length] = GovernanceConfig.Target(address(wired), fns);

        uint256 max = GovernanceConfig.MAX_WIRING_CALLS;
        GovernanceConfig.Call[] memory calls = new GovernanceConfig.Call[](max);
        for (uint256 i; i < max; ++i) {
            if (i < genesisCalls.length) {
                calls[i] = genesisCalls[i];
                continue;
            }
            Erc165PeerPortedMock peer = new Erc165PeerPortedMock();
            vm.cool(address(peer));
            calls[i] = GovernanceConfig.Call(
                address(wired),
                abi.encodeCall(WiringTargetPortedMock.setTarget, (address(peer), true))
            );
        }
        (uint256 total, uint256 execution) = _measure(all, cfg, calls);
        console2.log("genesis + max wiring, execution", execution);
        console2.log("genesis + max wiring, whole transaction", total);
        assertLt(total, TX_GAS_CAP * 60 / 100, "keep 40% headroom under the EIP-7825 cap");
    }
}

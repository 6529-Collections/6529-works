// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { VerifyV1 } from "script/VerifyV1.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";

/// @notice The readback `Verify.s.sol` adds on top of `VerifyV1.check` (review D, I-5): the
///         recorded recipients against the chain, the manager's genesis state, the sales'
///         recorded configuration, and every deployed contract the manager governs being on its
///         managed list. Whether the recorded recipients are the intended ones is a human check.
contract VerifyGenesisStateTest is IntegrationBase {
    function setUp() public override {
        super.setUp();
        vm.warp(block.timestamp + manager.minSetback());
    }

    function checkRecipientsExternal(address feeRecipient, address owner) external view {
        VerifyV1.checkRecipients(deployment, feeRecipient, owner);
    }

    function checkGenesisStateExternal() external view {
        VerifyV1.checkGenesisState(deployment, _params());
    }

    function checkExternal(DeployV1.Deployment memory d) external view {
        VerifyV1.check(d, _genesisConfig(), _genesisWiring());
    }

    function test_ManagerDefaultsAreTheCompiledOnes() public {
        WorksAccessManager fresh = new WorksAccessManager(address(this));
        uint32[6] memory defaults = VerifyV1.managerDefaults();
        for (uint8 i; i < 6; ++i) {
            assertEq(fresh.parameter(WorksAccessManager.Parameter(i)), defaults[i]);
        }
    }

    function test_TheGenesisReadsBack() public view {
        this.checkRecipientsExternal(networkFeeSafe, marketOwner);
        this.checkGenesisStateExternal();
        this.checkExternal(deployment);
    }

    function test_ARecipientOtherThanTheRecordedOneFails() public {
        address wrong = makeAddr("not the recorded recipient");
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyV1.RecipientMismatch.selector, "fee vault destination", wrong, networkFeeSafe
            )
        );
        this.checkRecipientsExternal(wrong, marketOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyV1.RecipientMismatch.selector, "Stream owner", wrong, marketOwner
            )
        );
        this.checkRecipientsExternal(networkFeeSafe, wrong);
    }

    function test_AChangedParameterOrAPendingSuccessorFailsGenesisReadback() public {
        bytes memory raise = abi.encodeCall(
            WorksAccessManager.setParameter,
            (WorksAccessManager.Parameter.ESCALATED_DELAY, 120 days, 200 days)
        );
        vm.prank(hotAdmin);
        manager.schedule(address(manager), raise, 0);
        vm.warp(block.timestamp + 60 days);
        vm.prank(hotAdmin);
        manager.execute(address(manager), raise);
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyV1.ManagerParameterMismatch.selector, 1, 120 days, 200 days
            )
        );
        this.checkGenesisStateExternal();
    }

    function test_APendingSuccessorFailsGenesisReadback() public {
        address next = address(new WorksAccessManager(makeAddr("next admin")));
        bytes memory register = abi.encodeCall(WorksAccessManager.registerSuccessor, (next));
        vm.prank(hotAdmin);
        manager.schedule(address(manager), register, 0);
        vm.warp(block.timestamp + 60 days);
        vm.prank(hotAdmin);
        manager.registerSuccessor(next);
        vm.expectRevert(abi.encodeWithSelector(VerifyV1.SuccessionPending.selector, next));
        this.checkGenesisStateExternal();
    }

    /// @dev A deployed contract governed by the manager but never configured would stay behind
    ///      in a handover; the readback names it.
    function test_AGovernedButUnmanagedContractFails() public {
        DeployV1.Deployment memory d = deployment;
        address stray = address(new StrayModule(address(manager)));
        d.editionAuctionLens = stray;
        vm.expectRevert(abi.encodeWithSelector(VerifyV1.TargetNotManaged.selector, stray));
        this.checkExternal(d);
    }
}

/// @notice A contract governed by the manager that genesis never configured.
contract StrayModule is AccessManaged {
    constructor(address authority_) AccessManaged(authority_) { }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
}

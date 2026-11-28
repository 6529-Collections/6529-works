// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";
import { IndependentStreamFixture } from "./IndependentStreamFixture.sol";

/// @notice The events of the template setters of the Independent Stream module (GV-18): every
///         change of a version's status emits `TemplateSet` with the deployer (the key) and the
///         version's whole new state, and a refused change emits nothing.
contract IndependentStreamRegistryTemplateEventsTest is IndependentStreamFixture {
    function _expectTemplateSet(IIndependentStreamRegistry.TemplateStatus status) internal {
        IIndependentStreamRegistry.Template memory t = registry.templateOf(address(streamDeployer));
        vm.expectEmit(address(registry));
        emit IIndependentStreamRegistry.TemplateSet(
            address(streamDeployer), streamDeployer.creationHash(), t.version, t.form, status
        );
    }

    function _status() internal view returns (IIndependentStreamRegistry.TemplateStatus) {
        return registry.templateOf(address(streamDeployer)).status;
    }

    /// GV-18: `suspendTemplate`, `resumeTemplate`, `revokeTemplate` and `reinstateTemplate`
    /// each emit `TemplateSet` with the status they set.
    function test_Templates_EveryTransitionEmitsTemplateSetWithTheNewStatus() public {
        address d = address(streamDeployer);
        _expectTemplateSet(IIndependentStreamRegistry.TemplateStatus.SUSPENDED);
        registry.suspendTemplate(d);
        assertEq(uint8(_status()), uint8(IIndependentStreamRegistry.TemplateStatus.SUSPENDED));

        _expectTemplateSet(IIndependentStreamRegistry.TemplateStatus.APPROVED);
        registry.resumeTemplate(d);
        assertEq(uint8(_status()), uint8(IIndependentStreamRegistry.TemplateStatus.APPROVED));

        _expectTemplateSet(IIndependentStreamRegistry.TemplateStatus.REVOKED);
        registry.revokeTemplate(d);
        assertEq(uint8(_status()), uint8(IIndependentStreamRegistry.TemplateStatus.REVOKED));

        _expectTemplateSet(IIndependentStreamRegistry.TemplateStatus.APPROVED);
        registry.reinstateTemplate(d);
        assertEq(uint8(_status()), uint8(IIndependentStreamRegistry.TemplateStatus.APPROVED));
    }

    /// GV-18, the other side: a transition the status does not allow reverts with
    /// `TemplateStatusInvalid` and leaves the status as it was.
    function test_Templates_ARefusedTransitionChangesNothing() public {
        address d = address(streamDeployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IIndependentStreamRegistry.TemplateStatusInvalid.selector,
                d,
                IIndependentStreamRegistry.TemplateStatus.APPROVED
            )
        );
        registry.resumeTemplate(d);
        vm.expectRevert(
            abi.encodeWithSelector(
                IIndependentStreamRegistry.TemplateStatusInvalid.selector,
                d,
                IIndependentStreamRegistry.TemplateStatus.APPROVED
            )
        );
        registry.reinstateTemplate(d);
        assertEq(uint8(_status()), uint8(IIndependentStreamRegistry.TemplateStatus.APPROVED));
    }
}

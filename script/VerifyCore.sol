// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IModuleSlots } from "src/interfaces/core/IModules.sol";
import { DeployCore } from "./DeployCore.sol";

/// @title VerifyCore
/// @notice Reads a plain-core deployment back from the chain and reverts at the first
///         difference from what `DeployCore` was asked to build: code at every address, the
///         permanent contracts' immutable wiring, every genesis module slot and minter, no
///         module announced at genesis, the four waiting-period settings at their launch values,
///         and (once the network has accepted) the whole governance configuration.
/// @dev The settings are the network's to change at once; this check is for the state right
///      after genesis. A later readback of a live system compares against the network's
///      current values instead.
library VerifyCore {
    /// @notice A value read from the chain is not the expected one.
    error Mismatch(string what, address account);

    /// @notice Checks every part of `d` after `DeployCore.deploy` and `install`.
    /// @param p The deployment's parameters.
    /// @param d The deployment.
    /// @param cfg The governance configuration `install` was given.
    /// @param networkAccepted Whether the network has called `acceptNetwork` (the full
    ///        governance readback needs it).
    function verify(
        DeployCore.Params memory p,
        DeployCore.Deployment memory d,
        GovernanceConfig.Config memory cfg,
        bool networkAccepted
    ) internal view {
        string[] memory list = DeployCore.order(p);
        for (uint256 i; i < list.length; ++i) {
            address a = DeployCore.addressOf(d, list[i]);
            if (a.code.length == 0) revert Mismatch(list[i], a);
        }
        verifyPermanent(p, d);
        if (networkAccepted) d.configurator.verify(cfg);
    }

    /// @notice Checks the permanent contracts: immutable wiring, genesis modules and minters,
    ///         and the four settings at their launch values.
    function verifyPermanent(DeployCore.Params memory p, DeployCore.Deployment memory d)
        internal
        view
    {
        address m = address(d.manager);
        // WorkFacts and the money contracts.
        _eq(d.workFacts.contentStore(), address(d.contentStore), "WorkFacts.contentStore");
        if (d.workFacts.cc0TextFileId() != d.cc0TextFileId) {
            revert Mismatch("WorkFacts.cc0TextFileId", address(d.workFacts));
        }
        _eq(address(d.splitLedger.resolver()), address(d.directory), "SplitLedger.resolver");
        _eq(d.splitLedger.network(), address(d.feeRecipientVault), "SplitLedger.network");
        _eq(address(d.claimRouter.ledger()), address(d.splitLedger), "ClaimRouter.ledger");

        // Directory.
        _eq(IAccessManaged(address(d.directory)).authority(), m, "Directory.authority");
        _slot(address(d.directory), Slots.ACCOUNTS, d.accounts, "Directory.ACCOUNTS");
        _slot(address(d.directory), Slots.FEDERATION, d.federationRegistry, "Directory.FEDERATION");
        _slot(
            address(d.directory), Slots.FEDERATED_TERMS, d.streamTerms, "Directory.FEDERATED_TERMS"
        );
        _slot(
            address(d.directory),
            Slots.FEDERATED_RECORDS,
            d.workRules,
            "Directory.FEDERATED_RECORDS"
        );
        _setting(d.directory.moduleDelay(), DeployCore.LAUNCH_MODULE_DELAY, "Directory.moduleDelay");
        _setting(
            d.directory.unclaimedPeriod(),
            DeployCore.LAUNCH_UNCLAIMED_PERIOD,
            "Directory.unclaimedPeriod"
        );

        // Stream.
        _eq(IAccessManaged(address(d.stream)).authority(), m, "Stream.authority");
        _eq(d.stream.facts(), address(d.workFacts), "Stream.facts");
        _eq(d.stream.owner(), p.marketOwner, "Stream.owner");
        _slot(address(d.stream), Slots.RENDERER, d.renderer, "Stream.RENDERER");
        _slot(address(d.stream), Slots.TERMS, d.streamTerms, "Stream.TERMS");
        _slot(address(d.stream), Slots.RECORDS, d.workRules, "Stream.RECORDS");
        if (!d.stream.isMinter(d.englishAuction)) {
            revert Mismatch("Stream minter", d.englishAuction);
        }
        _setting(d.stream.moduleDelay(), DeployCore.LAUNCH_MODULE_DELAY, "Stream.moduleDelay");
        _setting(d.stream.rescueDelay(), DeployCore.LAUNCH_RESCUE_DELAY, "Stream.rescueDelay");

        // Editions.
        _eq(IAccessManaged(address(d.editions)).authority(), m, "Editions.authority");
        _eq(d.editions.stream(), address(d.stream), "Editions.stream");
        _eq(d.editions.owner(), p.marketOwner, "Editions.owner");
        _slot(address(d.editions), Slots.TERMS, d.streamTerms, "Editions.TERMS");
        if (!d.editions.isMinter(d.editionAuction)) {
            revert Mismatch("Editions minter", d.editionAuction);
        }
        _setting(d.editions.moduleDelay(), DeployCore.LAUNCH_MODULE_DELAY, "Editions.moduleDelay");
        _setting(d.editions.rebindDelay(), DeployCore.LAUNCH_REBIND_DELAY, "Editions.rebindDelay");
    }

    function _slot(address target, bytes32 slot, address expected, string memory what)
        private
        view
    {
        IModuleSlots t = IModuleSlots(target);
        if (t.moduleOf(slot) != expected || expected == address(0)) revert Mismatch(what, target);
        if (t.pendingModule(slot).readyAt != 0) {
            revert Mismatch(string.concat(what, " announced at genesis"), target);
        }
    }

    function _setting(uint48 actual, uint48 expected, string memory what) private pure {
        if (actual != expected) revert Mismatch(what, address(0));
    }

    function _eq(address actual, address expected, string memory what) private pure {
        if (actual != expected) revert Mismatch(what, actual);
    }
}

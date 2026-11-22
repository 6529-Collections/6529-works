// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Vm } from "forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Roles } from "src/governance/Roles.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IModuleSlots } from "src/interfaces/core/IModules.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import {
    PRODUCT_EDITIONS,
    PRODUCT_FEDERATED,
    PRODUCT_STREAM
} from "src/interfaces/types/EconomicsTypes.sol";
import { DeployCore } from "./DeployCore.sol";

/// @title VerifyCore
/// @notice Reads a plain-core deployment back and reverts at the first difference from what
///         `DeployCore` was asked to build:
///         - code at every address, and (`checkCode`) every runtime code hash equal to a
///           reference deployment of the same build with the same parameters;
///         - the permanent contracts' immutable wiring, every genesis module slot, the minter
///           lists (no other contract of the deployment mints) and the four settings at their
///           launch values;
///         - every module's manager and stored wiring, the vaults' destinations and the
///           economics' recipients;
///         - the effect of every genesis wiring call of the genesis file (a call this library
///           does not know how to read back fails the check);
///         - that the genesis configuration was installed: the network accepted and every role,
///           holder and selector reads back, or, before acceptance, the configurator gone and
///           the network pending.
/// @dev The settings are the network's to change at once; this check is for the state right
///      after genesis. A later readback of a live system compares against the network's
///      current values instead.
library VerifyCore {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice The committed genesis policy, whose wiring the four-argument `verify` reads.
    string internal constant CORE_GENESIS = "config/genesis.core.example.json";

    /// @notice A value read from the chain is not the expected one.
    error Mismatch(string what, address account);
    /// @notice The runtime code at `account` (contract `name`) is not the build's.
    error CodeMismatch(string name, address account);
    /// @notice The genesis file has a wiring call whose effect this library cannot read back.
    error UnverifiedWiring(bytes4 selector);
    /// @notice The genesis configuration was not installed (the configurator still holds it).
    error NotInstalled();

    /// @notice `verify` with the committed genesis policy's wiring.
    function verify(
        DeployCore.Params memory p,
        DeployCore.Deployment memory d,
        GovernanceConfig.Config memory cfg,
        bool networkAccepted
    ) internal view {
        verify(p, d, cfg, vm.readFile(CORE_GENESIS), networkAccepted);
    }

    /// @notice Checks every part of `d` after `DeployCore.deploy` and `install`.
    /// @param p The deployment's parameters.
    /// @param d The deployment.
    /// @param cfg The governance configuration `install` was given.
    /// @param json The genesis file `install` was built from (its wiring is read back).
    /// @param networkAccepted Whether the network has called `acceptNetwork` (the full
    ///        governance readback needs it; before, the network must be the pending one).
    function verify(
        DeployCore.Params memory p,
        DeployCore.Deployment memory d,
        GovernanceConfig.Config memory cfg,
        string memory json,
        bool networkAccepted
    ) internal view {
        if (d.coreFactory.code.length == 0) {
            revert Mismatch("CoreFactory", d.coreFactory);
        }
        string[] memory list = DeployCore.order(p);
        for (uint256 i; i < list.length; ++i) {
            address a = DeployCore.addressOf(d, list[i]);
            if (a.code.length == 0) revert Mismatch(list[i], a);
        }
        verifyPermanent(p, d);
        verifyModules(p, d, cfg);
        verifyWiring(d, json);
        verifyInstalled(d, cfg, networkAccepted);
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

    /// @notice Checks the replaceable modules: each governed contract's manager, the minter
    ///         lists (only the genesis minter of each token, nothing else of the deployment, now
    ///         or pending), every module's stored and constructor wiring, the vaults'
    ///         destinations and the economics' recipients.
    function verifyModules(
        DeployCore.Params memory p,
        DeployCore.Deployment memory d,
        GovernanceConfig.Config memory cfg
    ) internal view {
        address m = address(d.manager);
        for (uint256 i; i < cfg.targets.length; ++i) {
            address t = cfg.targets[i].target;
            if (IAccessManaged(t).authority() != m) revert Mismatch("authority", t);
        }
        string[] memory list = DeployCore.order(p);
        for (uint256 i; i < list.length; ++i) {
            address a = DeployCore.addressOf(d, list[i]);
            _minter(address(d.stream), a, a == d.englishAuction, "Stream minter");
            _minter(address(d.editions), a, a == d.editionAuction, "Editions minter");
        }

        // The English auction (ETH only; 6529 Stream's mint policy is the package registry).
        IAuctionWiring auction = IAuctionWiring(d.englishAuction);
        _eq(auction.streamPolicy(), d.packageRegistry, "EnglishAuction.streamPolicy");
        _eq(auction.stream(), address(d.stream), "EnglishAuction.stream");
        _eq(auction.directory(), address(d.directory), "EnglishAuction.directory");
        _eq(auction.economics(), d.economicsResolver, "EnglishAuction.economics");
        _eq(auction.escrow(), d.revenueEscrow, "EnglishAuction.escrow");
        _eq(auction.statementLog(), d.statementLog, "EnglishAuction.statementLog");
        _eq(
            IUniformWiring(d.editionAuction).lens(),
            d.editionAuctionLens,
            "UniformEditionAuction.lens"
        );
        _eq(
            IUniformWiring(d.federatedEditionAuction).lens(),
            d.federatedEditionAuctionLens,
            "FederatedEditionAuction.lens"
        );

        // Curation, accounts, records, terms and rendering.
        _eq(
            IPackageWiring(d.packageRegistry).verifier(),
            d.curationVerifier,
            "PackageRegistry.verifier"
        );
        _eq(
            IAccountsWiring(d.accounts).packageRegistry(),
            d.packageRegistry,
            "Accounts.packageRegistry"
        );
        _eq(
            IAccountsWiring(d.accounts).federationRegistry(),
            d.federationRegistry,
            "Accounts.federationRegistry"
        );
        _eq(IAccountsWiring(d.accounts).directory(), address(d.directory), "Accounts.directory");
        _eq(IRulesWiring(d.workRules).delivery(), d.workDelivery, "WorkRules.delivery");
        _eq(IRulesWiring(d.workRules).facts(), address(d.workFacts), "WorkRules.facts");
        _eq(IDeliveryWiring(d.workDelivery).records(), d.workRules, "WorkDelivery.records");
        _eq(
            ITermsWiring(d.streamTerms).editionsOf(address(d.stream)),
            address(d.editions),
            "StreamTerms.editionsOf(Stream)"
        );
        _eq(
            ITermsWiring(d.streamTerms).tokenOfEditions(address(d.editions)),
            address(d.stream),
            "StreamTerms.tokenOfEditions(Editions)"
        );
        _eq(
            IRendererWiring(d.renderer).contentStore(),
            address(d.contentStore),
            "Renderer.contentStore"
        );
        _eq(IRendererWiring(d.renderer).statementLog(), d.statementLog, "Renderer.statementLog");
        _template(d.federatedStreamDeployer, "FederatedStream.sol:FederatedStream");
        _template(d.federatedEditionsDeployer, "FederatedEditions.sol:FederatedEditions");

        // Money: the vaults' destinations and where the economics send fees and unsold works.
        _eq(d.feeRecipientVault.destination(), p.feeRecipient, "FeeRecipientVault.destination");
        _eq(d.museumVault.destination(), p.museum, "MuseumVault.destination");
        IEconomicsWiring economics = IEconomicsWiring(d.economicsResolver);
        _eq(economics.museum(), address(d.museumVault), "EconomicsResolver.museum");
        address fees = address(d.feeRecipientVault);
        _eq(economics.networkFeeRecipient(PRODUCT_STREAM), fees, "fee recipient (Stream)");
        _eq(economics.networkFeeRecipient(PRODUCT_EDITIONS), fees, "fee recipient (Editions)");
        _eq(economics.networkFeeRecipient(PRODUCT_FEDERATED), fees, "fee recipient (federated)");
    }

    /// @notice Checks the effect of every genesis wiring call of `json` that applies to `d`
    ///         (`DeployCore.wiring`). A call this library cannot read back reverts
    ///         `UnverifiedWiring`.
    function verifyWiring(DeployCore.Deployment memory d, string memory json) internal view {
        GovernanceConfig.Call[] memory calls =
            DeployCore.wiring(d, json, DeployCore.Manifest(bytes32(0), ""));
        for (uint256 i; i < calls.length; ++i) {
            _wired(d, calls[i]);
        }
    }

    /// @notice Checks that the governance configuration was installed: with the network
    ///         accepted, every role, holder and selector of `cfg` reads back
    ///         (`GovernanceConfigurator.verify`); before, the configurator holds nothing and
    ///         `cfg.network` is the pending network.
    function verifyInstalled(
        DeployCore.Deployment memory d,
        GovernanceConfig.Config memory cfg,
        bool networkAccepted
    ) internal view {
        if (networkAccepted) {
            d.configurator.verify(cfg);
            return;
        }
        if (GovernanceConfig.hasRecord(d.manager, Roles.ADMIN, address(d.configurator))) {
            revert NotInstalled();
        }
        _eq(d.manager.pendingNetwork(), cfg.network, "WorksAccessManager.pendingNetwork");
    }

    // ------------------------------------------------------------------ runtime code

    /// @notice The contracts whose runtime code `checkCode` compares: the deployer's factory,
    ///         the manager and every contract of `order(p)`.
    function codeNames(DeployCore.Params memory p) internal pure returns (string[] memory names) {
        string[] memory list = DeployCore.order(p);
        names = new string[](list.length + 2);
        names[0] = "CoreFactory";
        names[1] = "WorksAccessManager";
        for (uint256 i; i < list.length; ++i) {
            names[i + 2] = list[i];
        }
    }

    /// @notice The runtime code hash of every contract of `codeNames(p)` in `d`, as the chain
    ///         answers now.
    function codeHashes(DeployCore.Params memory p, DeployCore.Deployment memory d)
        internal
        view
        returns (bytes32[] memory hashes)
    {
        string[] memory names = codeNames(p);
        hashes = new bytes32[](names.length);
        for (uint256 i; i < names.length; ++i) {
            hashes[i] = DeployCore.addressOf(d, names[i]).codehash;
        }
    }

    /// @notice Reverts unless `d` and the reference deployment `ref` (the same build deployed
    ///         with the same parameters from the state before `d` existed) have the same address
    ///         and the same runtime code for every contract. Immutables and constructor
    ///         arguments are part of the runtime code, so this also checks every value a
    ///         constructor fixed, and that no address holds anyone else's code.
    /// @param p The deployment's parameters.
    /// @param d The deployment under check.
    /// @param actual `codeHashes(p, d)`, read from the chain under check.
    /// @param ref The reference deployment.
    /// @param expected `codeHashes(p, ref)`, read where the reference was deployed.
    function checkCode(
        DeployCore.Params memory p,
        DeployCore.Deployment memory d,
        bytes32[] memory actual,
        DeployCore.Deployment memory ref,
        bytes32[] memory expected
    ) internal pure {
        string[] memory names = codeNames(p);
        for (uint256 i; i < names.length; ++i) {
            address a = DeployCore.addressOf(d, names[i]);
            if (
                a != DeployCore.addressOf(ref, names[i]) || actual[i] != expected[i]
                    || actual[i] == bytes32(0) || actual[i] == keccak256("")
            ) revert CodeMismatch(names[i], a);
        }
    }

    // ------------------------------------------------------------------ helpers

    function _wired(DeployCore.Deployment memory d, GovernanceConfig.Call memory c) private view {
        bytes4 selector = bytes4(c.data);
        bytes memory args = _args(c.data);
        if (selector == IPackageWiring.bindStream.selector) {
            _eq(IPackageWiring(c.target).stream(), abi.decode(args, (address)), "bindStream");
        } else if (selector == IPackageWiring.setEntropyModule.selector) {
            (, address next) = abi.decode(args, (address, address));
            _eq(IPackageWiring(c.target).entropyModule(), next, "PackageRegistry.entropyModule");
        } else if (selector == IRegistryWiring.setEntropyModule.selector) {
            _eq(
                IRegistryWiring(c.target).entropyModule(),
                abi.decode(args, (address)),
                "FederationRegistry.entropyModule"
            );
        } else if (selector == IUniformWiring.setTarget.selector) {
            (address token, bool listed) = abi.decode(args, (address, bool));
            if (IUniformWiring(c.target).isTarget(token) != listed) {
                revert Mismatch("setTarget", token);
            }
        } else if (selector == IAllowlistWiring.setOpeningBid.selector) {
            (address asset,, uint256 bid) = abi.decode(args, (address, uint64, uint256));
            if (IAllowlistWiring(c.target).openingBid(asset) != bid) {
                revert Mismatch("setOpeningBid", asset);
            }
        } else if (selector == IRegistryWiring.setAdapter.selector) {
            (address adapter, bool admitted) = abi.decode(args, (address, bool));
            IFederationRegistry.SaleContract memory s =
                IRegistryWiring(c.target).saleContractOf(adapter);
            if ((s.addedAt != 0 && s.removedAt == 0) != admitted) {
                revert Mismatch("setAdapter", adapter);
            }
        } else if (selector == IRegistryWiring.approveTemplate.selector) {
            (address deployer, uint32 version, uint8 form) =
                abi.decode(args, (address, uint32, uint8));
            IFederationRegistry.Template memory t = IRegistryWiring(c.target).templateOf(deployer);
            if (
                t.version != version || uint8(t.form) != form
                    || t.status != IFederationRegistry.TemplateStatus.APPROVED
            ) revert Mismatch("approveTemplate", deployer);
        } else if (selector == IStatementLog.appendGovernanceManifest.selector) {
            (uint64 count,) = IStatementLog(c.target).chainOf(address(d.manager), 0);
            if (count == 0) revert Mismatch("governance manifest", c.target);
        } else {
            revert UnverifiedWiring(selector);
        }
    }

    function _args(bytes memory data) private pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[i + 4];
        }
    }

    function _minter(address token, address account, bool expected, string memory what)
        private
        view
    {
        IModuleSlotsMinters t = IModuleSlotsMinters(token);
        bool listed = t.minterOf(account).activeFrom != 0;
        if (t.isMinter(account) != expected || listed != expected) revert Mismatch(what, account);
    }

    function _template(address deployer, string memory artifact) private view {
        if (ITemplateWiring(deployer).creationHash() != keccak256(vm.getCode(artifact))) {
            revert Mismatch("FederatedDeployer.creationHash", deployer);
        }
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

/// @dev The views `VerifyCore` reads, by the names the modules expose them under.
interface IAuctionWiring {
    function streamPolicy() external view returns (address);
    function stream() external view returns (address);
    function directory() external view returns (address);
    function economics() external view returns (address);
    function escrow() external view returns (address);
    function statementLog() external view returns (address);
}

interface IUniformWiring {
    function lens() external view returns (address);
    function isTarget(address token) external view returns (bool);
    function setTarget(address token, bool listed) external;
}

interface IPackageWiring {
    function verifier() external view returns (address);
    function stream() external view returns (address);
    function entropyModule() external view returns (address);
    function bindStream(address target) external;
    function setEntropyModule(address expected, address next) external;
}

interface IRegistryWiring {
    function entropyModule() external view returns (address);
    function saleContractOf(address minter)
        external
        view
        returns (IFederationRegistry.SaleContract memory);
    function templateOf(address deployer)
        external
        view
        returns (IFederationRegistry.Template memory);
    function setEntropyModule(address next) external;
    function setAdapter(address adapter, bool admitted) external;
    function approveTemplate(address deployer, uint32 version, uint8 form) external;
}

interface IAllowlistWiring {
    function openingBid(address asset) external view returns (uint256);
    function setOpeningBid(address asset, uint64 expectedRevision, uint256 bid) external;
}

interface IAccountsWiring {
    function packageRegistry() external view returns (address);
    function federationRegistry() external view returns (address);
    function directory() external view returns (address);
}

interface IRulesWiring {
    function delivery() external view returns (address);
    function facts() external view returns (address);
}

interface IDeliveryWiring {
    function records() external view returns (address);
}

interface ITermsWiring {
    function editionsOf(address token) external view returns (address);
    function tokenOfEditions(address editions) external view returns (address);
}

interface IRendererWiring {
    function contentStore() external view returns (address);
    function statementLog() external view returns (address);
}

interface ITemplateWiring {
    function creationHash() external view returns (bytes32);
}

interface IEconomicsWiring {
    function museum() external view returns (address);
    function networkFeeRecipient(bytes32 product) external view returns (address);
}

interface IModuleSlotsMinters {
    function isMinter(address account) external view returns (bool);
    function minterOf(address minter) external view returns (MinterView memory);
}

/// @dev `Minter` of `src/interfaces/core/CoreTypes.sol`.
struct MinterView {
    uint48 activeFrom;
    uint48 removedAt;
}

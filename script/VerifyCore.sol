// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Vm } from "forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { Roles } from "src/governance/Roles.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { Minter, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IModules, IModuleSlots } from "src/interfaces/core/IModules.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";
import { IStatementLog, Statement } from "src/interfaces/IStatementLog.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import {
    PRODUCT_EDITIONS,
    PRODUCT_INDEPENDENT,
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
///         - the configuration the constructors stored (`verifyConfiguration`): the English
///           auction's four values, durations included, both edition auctions' six values and
///           payout gas, the ETH increment floor, and the entropy module's coordinator, request
///           parameters and retry delay, each against the deployment's parameters;
///         - (`verifyMinterLogs`) that the only minter each token ever logged is its genesis
///           minter, so a genesis minter outside the deployment is seen;
///         - the effect of every genesis wiring call of the genesis file (a call this library
///           does not know how to read back fails the check);
///         - that the genesis configuration was installed: the network accepted and every role,
///           holder and selector reads back, or, before acceptance, the configurator gone and
///           the network pending;
///         - (`verifyConfigured`) that the hashes the configurator logged at genesis
///           (`GovernanceConfigured`) are the ones the genesis file, the manifest and the wiring
///           produce, so genesis installed nothing the file does not name;
///         - (`governanceDifferences`) that the manager's logs since its deployment leave exactly
///           the configured holders and selector map: a key granted later, or a selector mapped
///           later, is named.
/// @dev The settings are the network's to change at once; this check is for the state right
///      after genesis. A later readback of a live system compares against the network's
///      current values instead.
library VerifyCore {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice The committed genesis policy, whose wiring the four-argument `verify` reads.
    string internal constant CORE_GENESIS = "config/genesis.core.example.json";

    /// @notice A value read from the chain is not the expected one.
    error Mismatch(string what, address account);
    /// @notice A stored number or word of `account` is not the one the deployment was told to
    ///         use.
    error ValueMismatch(string what, address account, uint256 expected, uint256 found);
    /// @notice `token` logged `minter` as added, and it is not the token's genesis minter.
    error UnexpectedMinter(string token, address minter);
    /// @notice The runtime code at `account` (contract `name`) is not the build's.
    error CodeMismatch(string name, address account);
    /// @notice The genesis file has a wiring call whose effect this library cannot read back.
    error UnverifiedWiring(bytes4 selector);
    /// @notice The genesis configuration was not installed (the configurator still holds it).
    error NotInstalled();
    /// @notice The manager's logs differ from the expected configuration in `count` ways; the
    ///         first is `what`, about `role`, `account` (a holder or a target) and `selector`.
    error GovernanceDiffers(
        string what, uint64 role, address account, bytes4 selector, uint256 count
    );

    /// @notice One log of one contract: its topics and its data.
    struct Entry {
        bytes32[] topics;
        bytes data;
    }

    /// @notice One way the manager's logs differ from the expected configuration
    ///         (`governanceDifferences`).
    /// @param what What differs.
    /// @param role The role held or mapped; zero when the difference is about a target alone.
    /// @param account The holder, or the target.
    /// @param selector The selector, or zero.
    struct Difference {
        string what;
        uint64 role;
        address account;
        bytes4 selector;
    }

    /// @notice A governance manifest entry as the statement log logged it
    ///         (`IStatementLog.StatementAppended`).
    /// @param head The governance chain's head after the entry.
    /// @param statement The statement in full.
    struct ManifestEntry {
        bytes32 head;
        Statement statement;
    }

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
        verifyConfiguration(p, d);
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
        _eq(d.workFacts.contentStore(), address(d.contentStore), "StreamWorkFacts6529.contentStore");
        if (d.workFacts.cc0TextFileId() != d.cc0TextFileId) {
            revert Mismatch("StreamWorkFacts6529.cc0TextFileId", address(d.workFacts));
        }
        _eq(address(d.splitLedger.resolver()), address(d.directory), "SplitLedger.resolver");
        _eq(d.splitLedger.network(), address(d.feeRecipientVault), "SplitLedger.network");
        _eq(address(d.claimRouter.ledger()), address(d.splitLedger), "ClaimRouter.ledger");

        // Directory.
        _eq(IAccessManaged(address(d.directory)).authority(), m, "StreamDirectory6529.authority");
        _slot(address(d.directory), Slots.ACCOUNTS, d.accounts, "StreamDirectory6529.ACCOUNTS");
        _slot(
            address(d.directory),
            Slots.INDEPENDENT_STREAM,
            d.independentStreamRegistry,
            "StreamDirectory6529.INDEPENDENT_STREAM"
        );
        _slot(
            address(d.directory),
            Slots.INDEPENDENT_TERMS,
            d.streamTerms,
            "StreamDirectory6529.INDEPENDENT_TERMS"
        );
        _slot(
            address(d.directory),
            Slots.INDEPENDENT_RECORDS,
            d.workRules,
            "StreamDirectory6529.INDEPENDENT_RECORDS"
        );
        _setting(
            d.directory.moduleDelay(),
            DeployCore.LAUNCH_MODULE_DELAY,
            "StreamDirectory6529.moduleDelay"
        );
        _setting(
            d.directory.unclaimedPeriod(),
            DeployCore.LAUNCH_UNCLAIMED_PERIOD,
            "StreamDirectory6529.unclaimedPeriod"
        );

        // Stream.
        _eq(IAccessManaged(address(d.stream)).authority(), m, "Stream6529.authority");
        _eq(d.stream.facts(), address(d.workFacts), "Stream6529.facts");
        _eq(d.stream.owner(), p.marketOwner, "Stream6529.owner");
        _slot(address(d.stream), Slots.RENDERER, d.renderer, "Stream6529.RENDERER");
        _slot(address(d.stream), Slots.TERMS, d.streamTerms, "Stream6529.TERMS");
        _slot(address(d.stream), Slots.RECORDS, d.workRules, "Stream6529.RECORDS");
        if (!d.stream.isMinter(d.englishAuction)) {
            revert Mismatch("Stream minter", d.englishAuction);
        }
        _setting(d.stream.moduleDelay(), DeployCore.LAUNCH_MODULE_DELAY, "Stream6529.moduleDelay");
        _setting(d.stream.rescueDelay(), DeployCore.LAUNCH_RESCUE_DELAY, "Stream6529.rescueDelay");

        // Editions.
        _eq(IAccessManaged(address(d.editions)).authority(), m, "StreamEditions6529.authority");
        _eq(d.editions.stream(), address(d.stream), "StreamEditions6529.stream");
        _eq(d.editions.owner(), p.marketOwner, "StreamEditions6529.owner");
        _slot(address(d.editions), Slots.TERMS, d.streamTerms, "StreamEditions6529.TERMS");
        if (!d.editions.isMinter(d.editionAuction)) {
            revert Mismatch("Editions minter", d.editionAuction);
        }
        _setting(
            d.editions.moduleDelay(),
            DeployCore.LAUNCH_MODULE_DELAY,
            "StreamEditions6529.moduleDelay"
        );
        _setting(
            d.editions.rebindDelay(),
            DeployCore.LAUNCH_REBIND_DELAY,
            "StreamEditions6529.rebindDelay"
        );
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
            IUniformWiring(d.independentEditionAuction).lens(),
            d.independentEditionAuctionLens,
            "IndependentEditionAuction.lens"
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
            IAccountsWiring(d.accounts).independentStreamRegistry(),
            d.independentStreamRegistry,
            "Accounts.independentStreamRegistry"
        );
        _eq(IAccountsWiring(d.accounts).directory(), address(d.directory), "Accounts.directory");
        _eq(IRulesWiring(d.workRules).delivery(), d.workDelivery, "WorkRules.delivery");
        _eq(IRulesWiring(d.workRules).facts(), address(d.workFacts), "WorkRules.facts");
        _eq(IDeliveryWiring(d.workDelivery).records(), d.workRules, "WorkDelivery.records");
        _eq(
            ITermsWiring(d.streamTerms).editionsOf(address(d.stream)),
            address(d.editions),
            "StreamTerms.editionsOf(Stream6529)"
        );
        _eq(
            ITermsWiring(d.streamTerms).tokenOfEditions(address(d.editions)),
            address(d.stream),
            "StreamTerms.tokenOfEditions(StreamEditions6529)"
        );
        _eq(
            IRendererWiring(d.renderer).contentStore(),
            address(d.contentStore),
            "Renderer.contentStore"
        );
        _eq(IRendererWiring(d.renderer).statementLog(), d.statementLog, "Renderer.statementLog");
        _template(d.independentStream721Deployer, "IndependentStream6529.sol:IndependentStream6529");
        _template(
            d.independentStreamEditionsDeployer,
            "IndependentStreamEditions6529.sol:IndependentStreamEditions6529"
        );

        // Money: the vaults' destinations and where the economics send fees and unsold works.
        _eq(d.feeRecipientVault.destination(), p.feeRecipient, "FeeRecipientVault.destination");
        _eq(d.museumVault.destination(), p.museum, "MuseumVault.destination");
        IEconomicsWiring economics = IEconomicsWiring(d.economicsResolver);
        _eq(economics.museum(), address(d.museumVault), "EconomicsResolver.museum");
        address fees = address(d.feeRecipientVault);
        _eq(economics.networkFeeRecipient(PRODUCT_STREAM), fees, "fee recipient (Stream)");
        _eq(economics.networkFeeRecipient(PRODUCT_EDITIONS), fees, "fee recipient (Editions)");
        _eq(
            economics.networkFeeRecipient(PRODUCT_INDEPENDENT),
            fees,
            "fee recipient (Independent Stream)"
        );
    }

    /// @notice Checks the configuration the modules' constructors stored against the
    ///         deployment's parameters `p`: the English auction's duration, extension window,
    ///         increment share and refusal gas; both edition auctions' configuration and payout
    ///         gas; the ETH increment floor; and, with a VRF coordinator, the entropy module's
    ///         coordinator, request parameters and retry delay, with no wrapper set. Runtime
    ///         code does not cover these: they are storage. The opening bid is a genesis wiring
    ///         call and is read back by `verifyWiring`.
    /// @dev `p` must be the parameters the deployment was told to use: a 1/1 auction shortened
    ///      with `AUCTION_DURATION` reads back only against the same shortened duration.
    function verifyConfiguration(DeployCore.Params memory p, DeployCore.Deployment memory d)
        internal
        view
    {
        address a = d.englishAuction;
        IEnglishAuction.AuctionConfig memory want =
            abi.decode(p.auctionConfig, (IEnglishAuction.AuctionConfig));
        IEnglishAuction.AuctionConfig memory got = IEnglishAuction(a).config();
        _value(got.duration, want.duration, "EnglishAuction.config.duration", a);
        _value(
            got.extensionWindow, want.extensionWindow, "EnglishAuction.config.extensionWindow", a
        );
        _value(got.incrementShare, want.incrementShare, "EnglishAuction.config.incrementShare", a);
        _value(got.refusalGas, want.refusalGas, "EnglishAuction.config.refusalGas", a);

        _editionConfiguration(p, d.editionAuction, "UniformEditionAuction");
        _editionConfiguration(p, d.independentEditionAuction, "IndependentEditionAuction");

        a = d.assetAllowlist;
        _value(
            IAllowlistWiring(a).incrementFloor(address(0)),
            p.ethIncrementFloor,
            "AssetAllowlist.incrementFloor(ETH)",
            a
        );

        if (p.vrfCoordinator != address(0)) _entropyConfiguration(p, d.entropyModule);
    }

    /// @notice Reverts unless the minters each token logged as added (`IModules.MinterAdded`,
    ///         from the last block before the deployment on) are exactly its one genesis minter:
    ///         the English auction for `Stream6529`, the edition auction for
    ///         `StreamEditions6529`. The tokens keep no list of their minters, so a genesis
    ///         minter that is not a contract of the deployment shows only in the logs.
    /// @param d The deployment.
    /// @param streamAdded Every minter `Stream6529` logged as added, in order.
    /// @param editionsAdded Every minter `StreamEditions6529` logged as added, in order.
    function verifyMinterLogs(
        DeployCore.Deployment memory d,
        address[] memory streamAdded,
        address[] memory editionsAdded
    ) internal pure {
        _onlyMinter(streamAdded, d.englishAuction, "Stream6529", address(d.stream));
        _onlyMinter(editionsAdded, d.editionAuction, "StreamEditions6529", address(d.editions));
    }

    /// @notice The minters `token` logged as added among `logs` (recorded with
    ///         `vm.recordLogs`), in order.
    function mintersAdded(Vm.Log[] memory logs, address token)
        internal
        pure
        returns (address[] memory added)
    {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (_isMinterAdded(logs[i], token)) ++n;
        }
        added = new address[](n);
        uint256 k;
        for (uint256 i; i < logs.length; ++i) {
            if (_isMinterAdded(logs[i], token)) {
                added[k++] = address(uint160(uint256(logs[i].topics[1])));
            }
        }
    }

    /// @notice Reverts unless the governance chain in the statement log (the subject
    ///         `(manager, 0)`) holds exactly one entry and that entry is the expected epoch-0
    ///         manifest (`DeployCore.manifestStatement`): the one logged entry carries the
    ///         chain's stored head, and its statement is the expected one, field for field. The
    ///         log stores only a count and a head, so the statement itself is read from its
    ///         event.
    /// @param d The deployment.
    /// @param manifest The manifest the deployment was given (its digest and URI).
    /// @param entries Every entry the statement log logged for the governance chain, in order.
    function verifyManifest(
        DeployCore.Deployment memory d,
        DeployCore.Manifest memory manifest,
        ManifestEntry[] memory entries
    ) internal view {
        (uint64 count, bytes32 head) = IStatementLog(d.statementLog).chainOf(address(d.manager), 0);
        _value(count, 1, "governance manifest entries", d.statementLog);
        _value(entries.length, 1, "governance manifest logs", d.statementLog);
        if (entries[0].head != head) revert Mismatch("governance manifest head", d.statementLog);
        if (
            keccak256(abi.encode(entries[0].statement))
                != keccak256(abi.encode(DeployCore.manifestStatement(d, manifest)))
        ) revert Mismatch("governance manifest", d.statementLog);
    }

    /// @notice The governance chain's entries among `logs` (recorded with `vm.recordLogs`), in
    ///         order.
    function manifestsAppended(Vm.Log[] memory logs, DeployCore.Deployment memory d)
        internal
        pure
        returns (ManifestEntry[] memory entries)
    {
        bytes32 key = keccak256(abi.encode(address(d.manager), uint256(0)));
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (_isManifest(logs[i], d.statementLog, key)) ++n;
        }
        entries = new ManifestEntry[](n);
        uint256 k;
        for (uint256 i; i < logs.length; ++i) {
            if (_isManifest(logs[i], d.statementLog, key)) {
                entries[k++] = manifestEntry(logs[i].data);
            }
        }
    }

    /// @notice The head and the statement in the data of a `StatementAppended` log.
    function manifestEntry(bytes memory data) internal pure returns (ManifestEntry memory e) {
        (,,,,, e.head, e.statement) =
            abi.decode(data, (uint8, address, uint64, uint64, bytes32, bytes32, Statement));
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

    // ------------------------------------------------------------------ governance logs

    /// @notice The logs of `emitter` among `logs` (recorded with `vm.recordLogs`), in order.
    function entries(Vm.Log[] memory logs, address emitter)
        internal
        pure
        returns (Entry[] memory out)
    {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter) ++n;
        }
        out = new Entry[](n);
        uint256 k;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter) out[k++] = Entry(logs[i].topics, logs[i].data);
        }
    }

    /// @notice Reverts unless the configurator logged exactly one `GovernanceConfigured`, for
    ///         this deployment's manager, whose three hashes are the ones the expected inputs
    ///         produce: `keccak256(abi.encode(cfg))`, the manifest's digest and
    ///         `keccak256(abi.encode(calls))`. The configurator is its manager's only installer
    ///         and configures once, so equal hashes mean genesis installed exactly the holders,
    ///         the selector map and the wiring calls of the genesis file, in its order, and
    ///         nothing else: an added holder or an added wiring call changes a hash.
    /// @param d The deployment.
    /// @param cfg The expected configuration (`DeployCore.config` of the genesis file).
    /// @param manifest The expected epoch-0 manifest.
    /// @param calls The expected wiring (`DeployCore.wiring` of the genesis file and `manifest`).
    /// @param logs Every log of the configurator, in order.
    function verifyConfigured(
        DeployCore.Deployment memory d,
        GovernanceConfig.Config memory cfg,
        DeployCore.Manifest memory manifest,
        GovernanceConfig.Call[] memory calls,
        Entry[] memory logs
    ) internal pure {
        address c = address(d.configurator);
        uint256 n;
        Entry memory found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].topics.length == 4
                    && logs[i].topics[0] == GovernanceConfigurator.GovernanceConfigured.selector
            ) {
                ++n;
                found = logs[i];
            }
        }
        _value(n, 1, "GovernanceConfigured logs", c);
        if (found.topics[1] != bytes32(uint256(uint160(address(d.manager))))) {
            revert Mismatch("GovernanceConfigured.manager", c);
        }
        if (found.topics[2] != keccak256(abi.encode(cfg))) {
            revert Mismatch("GovernanceConfigured.configHash", c);
        }
        if (found.topics[3] != manifest.digest) {
            revert Mismatch("GovernanceConfigured.manifestHash", c);
        }
        if (found.data.length != 32 || bytes32(found.data) != keccak256(abi.encode(calls))) {
            revert Mismatch("GovernanceConfigured.wiringHash", c);
        }
    }

    /// @notice Every (role, account) the manager's logs leave as a member: each `RoleGranted`
    ///         adds one and each `RoleRevoked` (a revocation or a renouncement) removes it. The
    ///         manager keeps no list of a role's members, so this is the only way to name them
    ///         all. The network roles are not in it: they answer for `network()` and are never
    ///         granted.
    /// @param logs Every log of the manager since its deployment, in order.
    /// @return held The members, in the order they were first granted.
    function holdersIn(Entry[] memory logs)
        internal
        pure
        returns (GovernanceConfig.Grant[] memory held)
    {
        GovernanceConfig.Grant[] memory all = new GovernanceConfig.Grant[](logs.length);
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            Entry memory e = logs[i];
            if (e.topics.length != 3) continue;
            bool granted = e.topics[0] == IAccessManager.RoleGranted.selector;
            if (!granted && e.topics[0] != IAccessManager.RoleRevoked.selector) continue;
            uint64 role = uint64(uint256(e.topics[1]));
            address account = address(uint160(uint256(e.topics[2])));
            uint256 at = n;
            for (uint256 k; k < n; ++k) {
                if (all[k].role == role && all[k].account == account) {
                    at = k;
                    break;
                }
            }
            if (granted && at == n) {
                all[n++] = GovernanceConfig.Grant(role, account);
            } else if (!granted && at != n) {
                for (uint256 k = at; k + 1 < n; ++k) {
                    all[k] = all[k + 1];
                }
                --n;
            }
        }
        held = new GovernanceConfig.Grant[](n);
        for (uint256 i; i < n; ++i) {
            held[i] = all[i];
        }
    }

    /// @notice The scheduled operations the manager's logs leave open: scheduled, and neither
    ///         executed nor cancelled since. One that expired is still listed; the manager's
    ///         `getSchedule` answers zero for it.
    /// @param logs Every log of the manager since its deployment, in order.
    function openOperations(Entry[] memory logs) internal pure returns (bytes32[] memory open) {
        bytes32[] memory all = new bytes32[](logs.length);
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            Entry memory e = logs[i];
            if (e.topics.length != 3) continue;
            if (e.topics[0] == IAccessManager.OperationScheduled.selector) {
                all[n++] = e.topics[1];
            } else if (
                e.topics[0] == IAccessManager.OperationExecuted.selector
                    || e.topics[0] == IAccessManager.OperationCanceled.selector
            ) {
                for (uint256 k; k < n; ++k) {
                    if (all[k] != e.topics[1]) continue;
                    for (uint256 j = k; j + 1 < n; ++j) {
                        all[j] = all[j + 1];
                    }
                    --n;
                    break;
                }
            }
        }
        open = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            open[i] = all[i];
        }
    }

    /// @notice Every way the manager's logs differ from `cfg`, the expected configuration:
    ///         - "holder not in the configuration": an account is a member of a role and `cfg`
    ///           does not grant it (a key added at genesis or later);
    ///         - "configured holder no longer a member": a grant of `cfg` was revoked or
    ///           renounced;
    ///         - "selector mapped outside the configuration": a selector `cfg` does not list is
    ///           mapped to a role other than `ADMIN` (the role of every unmapped selector);
    ///         - "configured selector mapped to another role";
    ///         - "target closed" and "target admin delay set", which genesis never does.
    ///         An empty answer means the holders and the selector map are exactly `cfg`'s at the
    ///         block the logs reach. It is as complete as the logs: an endpoint that leaves a
    ///         log out hides the change that log records.
    /// @param cfg The expected configuration.
    /// @param logs Every log of the manager since its deployment, in order.
    function governanceDifferences(GovernanceConfig.Config memory cfg, Entry[] memory logs)
        internal
        pure
        returns (Difference[] memory differences)
    {
        // Room for every difference: a log yields at most one (a holder the file does not
        // name, or the last state of a selector or target), and each grant of `cfg` at most
        // one more. Twice the logs is a margin, not a need.
        Difference[] memory all = new Difference[](2 * logs.length + cfg.grants.length);
        uint256 n;
        GovernanceConfig.Grant[] memory held = holdersIn(logs);
        for (uint256 i; i < held.length; ++i) {
            if (!_granted(cfg, held[i])) {
                all[n++] = Difference(
                    "holder not in the configuration", held[i].role, held[i].account, bytes4(0)
                );
            }
        }
        for (uint256 i; i < cfg.grants.length; ++i) {
            bool member;
            for (uint256 k; k < held.length && !member; ++k) {
                member =
                    held[k].role == cfg.grants[i].role && held[k].account == cfg.grants[i].account;
            }
            if (!member) {
                all[n++] = Difference(
                    "configured holder no longer a member",
                    cfg.grants[i].role,
                    cfg.grants[i].account,
                    bytes4(0)
                );
            }
        }
        n = _targetDifferences(cfg, logs, all, n);
        differences = new Difference[](n);
        for (uint256 i; i < n; ++i) {
            differences[i] = all[i];
        }
    }

    /// @notice Reverts with the first of `differences` and their number, unless there is none.
    function requireNoDifference(Difference[] memory differences) internal pure {
        if (differences.length == 0) return;
        Difference memory first = differences[0];
        revert GovernanceDiffers(
            first.what, first.role, first.account, first.selector, differences.length
        );
    }

    /// @dev Appends to `all` (from index `n`) the differences in the selector map, the closed
    ///      targets and the target admin delays; returns the new count.
    function _targetDifferences(
        GovernanceConfig.Config memory cfg,
        Entry[] memory logs,
        Difference[] memory all,
        uint256 n
    ) private pure returns (uint256) {
        // The last state each log leaves: a selector's role, a target closed, a target's delay.
        Difference[] memory last = new Difference[](logs.length);
        uint256 m;
        for (uint256 i; i < logs.length; ++i) {
            Entry memory e = logs[i];
            Difference memory now_;
            if (
                e.topics.length == 3
                    && e.topics[0] == IAccessManager.TargetFunctionRoleUpdated.selector
            ) {
                now_ = Difference(
                    "selector",
                    uint64(uint256(e.topics[2])),
                    address(uint160(uint256(e.topics[1]))),
                    bytes4(abi.decode(e.data, (bytes32)))
                );
            } else if (e.topics.length == 2 && e.topics[0] == IAccessManager.TargetClosed.selector)
            {
                now_ = Difference(
                    "target closed",
                    abi.decode(e.data, (bool)) ? 1 : 0,
                    address(uint160(uint256(e.topics[1]))),
                    bytes4(0)
                );
            } else if (
                e.topics.length == 2
                    && e.topics[0] == IAccessManager.TargetAdminDelayUpdated.selector
            ) {
                (uint32 delay,) = abi.decode(e.data, (uint32, uint48));
                now_ = Difference(
                    "target admin delay set",
                    delay,
                    address(uint160(uint256(e.topics[1]))),
                    bytes4(0)
                );
            } else {
                continue;
            }
            uint256 at = m;
            for (uint256 k; k < m; ++k) {
                if (
                    last[k].account == now_.account && last[k].selector == now_.selector
                        && keccak256(bytes(last[k].what)) == keccak256(bytes(now_.what))
                ) {
                    at = k;
                    break;
                }
            }
            last[at] = now_;
            if (at == m) ++m;
        }
        for (uint256 i; i < m; ++i) {
            Difference memory s = last[i];
            if (keccak256(bytes(s.what)) != keccak256("selector")) {
                // A target that is open again, or whose admin delay is back to zero, is as genesis
                // left it.
                if (s.role != 0) all[n++] = Difference(s.what, 0, s.account, bytes4(0));
                continue;
            }
            (bool listed, uint64 role) = _configuredRole(cfg, s.account, s.selector);
            if (listed && role != s.role) {
                s.what = "configured selector mapped to another role";
                all[n++] = s;
            } else if (!listed && s.role != Roles.ADMIN) {
                s.what = "selector mapped outside the configuration";
                all[n++] = s;
            }
        }
        return n;
    }

    function _granted(GovernanceConfig.Config memory cfg, GovernanceConfig.Grant memory g)
        private
        pure
        returns (bool)
    {
        for (uint256 i; i < cfg.grants.length; ++i) {
            if (cfg.grants[i].role == g.role && cfg.grants[i].account == g.account) return true;
        }
        return false;
    }

    function _configuredRole(GovernanceConfig.Config memory cfg, address target, bytes4 selector)
        private
        pure
        returns (bool listed, uint64 role)
    {
        for (uint256 i; i < cfg.targets.length; ++i) {
            if (cfg.targets[i].target != target) continue;
            GovernanceConfig.FunctionRole[] memory fns = cfg.targets[i].functions;
            for (uint256 j; j < fns.length; ++j) {
                if (fns[j].selector == selector) return (true, fns[j].role);
            }
        }
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
                "IndependentStreamRegistry.entropyModule"
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
            (address adapter, uint8 form, bool admitted) = abi.decode(args, (address, uint8, bool));
            IIndependentStreamRegistry.SaleContract memory s =
                IRegistryWiring(c.target).saleContractOf(adapter);
            if ((s.addedAt != 0 && s.removedAt == 0) != admitted || uint8(s.form) != form) {
                revert Mismatch("setAdapter", adapter);
            }
        } else if (selector == IRegistryWiring.approveTemplate.selector) {
            (address deployer, uint32 version, uint8 form) =
                abi.decode(args, (address, uint32, uint8));
            IIndependentStreamRegistry.Template memory t =
                IRegistryWiring(c.target).templateOf(deployer);
            if (
                t.version != version || uint8(t.form) != form
                    || t.status != IIndependentStreamRegistry.TemplateStatus.APPROVED
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

    function _editionConfiguration(DeployCore.Params memory p, address a, string memory name)
        private
        view
    {
        (
            IUniformEditionAuction.AuctionConfig memory want,
            IUniformEditionAuction.Limits memory l
        ) = abi.decode(
            p.editionAuctionConfig,
            (IUniformEditionAuction.AuctionConfig, IUniformEditionAuction.Limits)
        );
        IUniformEditionAuction.AuctionConfig memory got = IUniformEditionAuction(a).config();
        _value(got.basePrice, want.basePrice, string.concat(name, ".config.basePrice"), a);
        _value(
            got.stepsPerDecade,
            want.stepsPerDecade,
            string.concat(name, ".config.stepsPerDecade"),
            a
        );
        _value(got.stepCount, want.stepCount, string.concat(name, ".config.stepCount"), a);
        _value(got.marginShare, want.marginShare, string.concat(name, ".config.marginShare"), a);
        _value(got.softWindow, want.softWindow, string.concat(name, ".config.softWindow"), a);
        _value(got.maxExtension, want.maxExtension, string.concat(name, ".config.maxExtension"), a);
        _value(
            IUniformEditionAuction(a).limits().payoutGas,
            l.payoutGas,
            string.concat(name, ".limits.payoutGas"),
            a
        );
    }

    function _entropyConfiguration(DeployCore.Params memory p, address a) private view {
        VrfEntropyModule module = VrfEntropyModule(a);
        _eq(module.coordinator(), p.vrfCoordinator, "EntropyModule.coordinator");
        _eq(module.wrapper(), address(0), "EntropyModule.wrapper");
        VrfEntropyModule.VrfConfig memory got = module.config();
        _value(got.subscriptionId, p.vrf.subscriptionId, "EntropyModule.config.subscriptionId", a);
        _value(uint256(got.keyHash), uint256(p.vrf.keyHash), "EntropyModule.config.keyHash", a);
        _value(
            got.callbackGasLimit, p.vrf.callbackGasLimit, "EntropyModule.config.callbackGasLimit", a
        );
        _value(got.confirmations, p.vrf.confirmations, "EntropyModule.config.confirmations", a);
        _value(
            got.nativePayment ? 1 : 0,
            p.vrf.nativePayment ? 1 : 0,
            "EntropyModule.config.nativePayment",
            a
        );
        _value(module.retryDelay(), p.vrfRetryDelay, "EntropyModule.retryDelay", a);
    }

    function _onlyMinter(
        address[] memory added,
        address expected,
        string memory name,
        address token
    ) private pure {
        for (uint256 i; i < added.length; ++i) {
            if (added[i] != expected) revert UnexpectedMinter(name, added[i]);
        }
        if (added.length != 1) {
            revert ValueMismatch(string.concat(name, " MinterAdded logs"), token, 1, added.length);
        }
    }

    function _isManifest(Vm.Log memory log, address statementLog, bytes32 key)
        private
        pure
        returns (bool)
    {
        return log.emitter == statementLog && log.topics.length == 4
            && log.topics[0] == IStatementLog.StatementAppended.selector && log.topics[1] == key;
    }

    function _isMinterAdded(Vm.Log memory log, address token) private pure returns (bool) {
        return log.emitter == token && log.topics.length == 2
            && log.topics[0] == IModules.MinterAdded.selector;
    }

    function _minter(address token, address account, bool expected, string memory what)
        private
        view
    {
        Minter memory record = IModules(token).minterOf(account);
        bool listed = record.activeFrom != 0;
        if (IModules(token).isMinter(account) != expected || listed != expected) {
            revert Mismatch(what, account);
        }
    }

    function _template(address deployer, string memory artifact) private view {
        if (ITemplateWiring(deployer).creationHash() != keccak256(vm.getCode(artifact))) {
            revert Mismatch("IndependentStreamDeployer.creationHash", deployer);
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

    function _value(uint256 found, uint256 expected, string memory what, address account)
        private
        pure
    {
        if (found != expected) revert ValueMismatch(what, account, expected, found);
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
        returns (IIndependentStreamRegistry.SaleContract memory);
    function templateOf(address deployer)
        external
        view
        returns (IIndependentStreamRegistry.Template memory);
    function setEntropyModule(address next) external;
    function setAdapter(address adapter, uint8 form, bool admitted) external;
    function approveTemplate(address deployer, uint32 version, uint8 form) external;
}

interface IAllowlistWiring {
    function incrementFloor(address asset) external view returns (uint256);
    function openingBid(address asset) external view returns (uint256);
    function setOpeningBid(address asset, uint64 expectedRevision, uint256 bid) external;
}

interface IAccountsWiring {
    function packageRegistry() external view returns (address);
    function independentStreamRegistry() external view returns (address);
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

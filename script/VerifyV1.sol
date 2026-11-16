// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AuthorityUtils } from "@openzeppelin/contracts/access/manager/AuthorityUtils.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { FederationRegistry } from "src/federated/FederationRegistry.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Roles } from "src/governance/Roles.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import {
    PRODUCT_EDITIONS,
    PRODUCT_FEDERATED,
    PRODUCT_STREAM,
    ProductEconomics
} from "src/interfaces/types/EconomicsTypes.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { SSTORE2 } from "src/libraries/SSTORE2.sol";
import { EnglishAuctionLens } from "src/sales/EnglishAuctionLens.sol";
import { DeployV1 } from "./DeployV1.sol";

import { IWorkLocators } from "src/interfaces/IWorkDelivery.sol";

/// @title VerifyV1
/// @notice Reads a deployed system back against its genesis configuration and wiring. Static
///         checks only, so the integration tests can run them; `script/Verify.s.sol` adds the
///         event checks that need an RPC (hashes, pending delay reductions, role grants).
library VerifyV1 {
    error ConfiguratorHoldsRole(uint64 role);
    error WrongAuthority(address target, address authority);
    error WiringNotApplied(address target, bytes4 selector);
    error UnknownWiringSelector(bytes4 selector);
    /// @notice A wiring call's calldata is shorter than its selector's arguments.
    error MalformedWiringCall(bytes4 selector);
    /// @notice A bind's getter reverted or returned something other than one word.
    error GetterFailed(address target, string signature);
    error PlatformPathClosed(address target, bytes4 selector);
    error PlatformHolderMissing();
    /// @notice A recorded address is not where CREATE2 puts that contract given the recorded
    ///         parameters (or the manager is not the configurator's first CREATE).
    error AddressMismatch(string name, address predicted, address recorded);
    /// @notice The default license text is inconsistent: `what` names the failing check.
    error Cc0Mismatch(string what);
    /// @notice A guardian suspended this configured holder (`WorksAccessManager.suspend`).
    error HolderSuspended(uint64 role, address account);
    /// @notice The economics resolver's museum is not the recorded one.
    error MuseumMismatch(address recorded, address actual);
    /// @notice The manager has a registered successor: it is handed over (GV-43).
    error ManagerHandedOver(address successor);
    /// @notice A configured target, or any deployed contract governed by the manager, is not on
    ///         the manager's managed list, so a handover's `migrate` would not move it (GV-44).
    error TargetNotManaged(address target);
    /// @notice A recipient the deployment record names is not where the chain sends the money
    ///         or the marketplace role: `what` names the check.
    error RecipientMismatch(string what, address expected, address actual);
    /// @notice The manager has a pending successor proposal (GV-43).
    error SuccessionPending(address next);
    /// @notice Genesis readback: a manager parameter is not its compiled default.
    error ManagerParameterMismatch(uint8 which, uint32 expected, uint32 actual);
    /// @notice Genesis readback: the manager has a recovery address; genesis registers none.
    error UnexpectedRecoveryAddress(address recovery);
    /// @notice Genesis readback: the manager's governance chain does not hold exactly the
    ///         epoch-0 manifest.
    error ManifestChainMismatch(uint64 count);
    /// @notice Genesis readback: a sale's governed configuration is not the recorded one.
    error SaleConfigMismatch(address sale);
    /// @notice The English auction's `lens()` is not the recorded lens, or the lens has no code
    ///         or other dependencies than the recorded deployment's.
    error LensMismatch(address recorded, address actual);
    /// @notice The federation's genesis state is not the recorded deployment's: `what` names
    ///         the check (ADR 0008).
    error FederationMismatch(string what);

    /// @notice The network share every federated contract must lock to join at genesis
    ///         (`EconomicsResolver`'s `PRODUCT_FEDERATED` share, 10%).
    uint32 internal constant FEDERATED_SHARE = 10_000;

    /// @notice Every contract in `recorded` is at the address `predicted` computes
    ///         (`DeployV1.predict` from the recorded constructor parameters), and nothing is
    ///         recorded that was not predicted.
    function checkAddresses(
        DeployV1.Deployment memory predicted,
        DeployV1.Deployment memory recorded
    ) internal pure {
        string[] memory names = DeployV1.names();
        for (uint256 i; i < names.length; ++i) {
            address p = DeployV1.addressOf(predicted, names[i]);
            address r = DeployV1.addressOf(recorded, names[i]);
            if (p != r) revert AddressMismatch(names[i], p, r);
        }
    }

    /// @notice The default license (M-3): WorkRecords and every product's default license name
    ///         the same CC0 file, the recorded one, and it is complete in the content store with
    ///         SHA-256 `digest`.
    function checkCc0(DeployV1.Deployment memory d, bytes32 digest) internal view {
        bytes32 id = d.cc0TextFileId;
        if (id == bytes32(0)) revert Cc0Mismatch("no CC0 file recorded");
        if (d.workRecords.cc0TextFileId() != id) revert Cc0Mismatch("WorkRecords.cc0TextFileId");
        bytes32[3] memory products = [PRODUCT_STREAM, PRODUCT_EDITIONS, PRODUCT_FEDERATED];
        for (uint256 i; i < products.length; ++i) {
            if (d.economicsResolver.defaultLicense(products[i]).textFileId != id) {
                revert Cc0Mismatch("EconomicsResolver.defaultLicense");
            }
        }
        if (!d.contentStore.isComplete(id)) revert Cc0Mismatch("incomplete in the content store");
        if (d.contentStore.sha256Of(id) != digest) revert Cc0Mismatch("SHA-256");
    }

    /// @notice The economics resolver names the museum's governed vault as the account unbid
    ///         canonical works go to, and that vault forwards to `museum`, the recorded 6529
    ///         Network Museum (D140); the resolver's fee recipient is the fee recipient's vault.
    ///         Genesis readback: a later governed change (the resolver's museum, FUNDS_SETTER,
    ///         14 days; the vault's destination, SUCCESSOR_SETTER, 30 days) fails it by design.
    function checkMuseum(DeployV1.Deployment memory d, address museum) internal view {
        address actual = d.economicsResolver.museum();
        if (actual != address(d.museumVault)) {
            revert MuseumMismatch(address(d.museumVault), actual);
        }
        actual = d.museumVault.destination();
        if (actual != museum) revert MuseumMismatch(museum, actual);
    }

    /// @notice The money and marketplace recipients the deployment record names are the ones the
    ///         chain uses: every product's network fee recipient is the fee recipient's vault,
    ///         that vault forwards to `feeRecipient`, and 6529 Stream's and 6529 Stream Editions'
    ///         marketplace `owner()` is `marketOwner`. Genesis readback: a later governed change
    ///         fails it by design. No on-chain check can establish that the record's addresses
    ///         are the intended ones: a human compares them with the signed manifest.
    function checkRecipients(
        DeployV1.Deployment memory d,
        address feeRecipient,
        address marketOwner
    ) internal view {
        bytes32[3] memory products = [PRODUCT_STREAM, PRODUCT_EDITIONS, PRODUCT_FEDERATED];
        address vault = address(d.feeRecipientVault);
        for (uint256 i; i < products.length; ++i) {
            address actual = d.economicsResolver.networkFeeRecipient(products[i]);
            if (actual != vault) revert RecipientMismatch("networkFeeRecipient", vault, actual);
        }
        address dest = d.feeRecipientVault.destination();
        if (dest != feeRecipient) {
            revert RecipientMismatch("fee vault destination", feeRecipient, dest);
        }
        address owner = _getter(address(d.stream), "owner()");
        if (owner != marketOwner) revert RecipientMismatch("Stream owner", marketOwner, owner);
        if (address(d.editions) != address(0)) {
            owner = _getter(address(d.editions), "owner()");
            if (owner != marketOwner) {
                revert RecipientMismatch("Editions owner", marketOwner, owner);
            }
        }
    }

    /// @notice The manager's compiled defaults, in `WorksAccessManager.Parameter` order
    ///         (`VerifyGenesisState.t.sol` pins them against a freshly deployed manager).
    function managerDefaults() internal pure returns (uint32[6] memory) {
        return [uint32(60 days), 120 days, 365 days, 180 days, 5, 7];
    }

    /// @notice Genesis readback of the governance state `check` does not read: every manager
    ///         parameter is its compiled default, no recovery address is registered, no successor
    ///         is pending, the manager's governance chain holds exactly the epoch-0 manifest, and
    ///         both sales run the recorded configuration (`p.auction`, `p.editionAuction`). A
    ///         later slow-lane or 48-hour change fails it by design; `Verify.s.sol` skips it in
    ///         epoch mode.
    function checkGenesisState(DeployV1.Deployment memory d, DeployV1.Params memory p)
        internal
        view
    {
        uint32[6] memory defaults = managerDefaults();
        for (uint8 i; i < 6; ++i) {
            uint32 actual = d.manager.parameter(WorksAccessManager.Parameter(i));
            if (actual != defaults[i]) revert ManagerParameterMismatch(i, defaults[i], actual);
        }
        address recovery = d.manager.recoveryAddress();
        if (recovery != address(0)) revert UnexpectedRecoveryAddress(recovery);
        address pending = d.manager.pendingSuccessor();
        if (pending != address(0)) revert SuccessionPending(pending);
        (uint64 count,) = d.statementLog.chainOf(address(d.manager), 0);
        if (count != 1) revert ManifestChainMismatch(count);
        address english = address(d.englishAuction);
        if (
            keccak256(abi.encode(IEnglishAuction(english).config()))
                != keccak256(abi.encode(p.auction))
        ) revert SaleConfigMismatch(english);
        address edition = address(d.editionAuction);
        if (
            edition != address(0)
                && keccak256(abi.encode(IUniformEditionAuction(edition).config()))
                    != keccak256(abi.encode(p.editionAuction))
        ) revert SaleConfigMismatch(edition);
    }

    /// @notice The English auction answers its views through the lens it pinned (EIP-170
    ///         headroom; deployed on its own, F8): `lens()` is the recorded lens, with code, and
    ///         the lens's dependencies are the recorded deployment's escrow, statement log, asset
    ///         allowlist and economics resolver (its Permit2 is checked on mainnet by
    ///         `Verify.s.sol`). Its code hash is verified twice over: `checkAddresses` recomputes
    ///         the lens's CREATE2 address from its creation code and these arguments, and the
    ///         auction's from initcode that carries the lens's code hash read from the chain, the
    ///         one the auction's constructor checked; `Verify.s.sol` also compares it with the
    ///         record. Nothing can replace the lens: `lens` is immutable.
    function checkLens(DeployV1.Deployment memory d) internal view {
        address lens = d.englishAuction.lens();
        EnglishAuctionLens l = EnglishAuctionLens(lens);
        if (
            lens != address(d.englishAuctionLens) || lens.code.length == 0
                || l.escrow() != address(d.revenueEscrow)
                || l.statementLog() != address(d.statementLog)
                || address(l.allowlist()) != address(d.assetAllowlist)
                || address(l.economicsResolver()) != address(d.economicsResolver)
        ) revert LensMismatch(address(d.englishAuctionLens), lens);
    }

    /// @notice Reverts on the first difference between the deployment and `cfg` / `calls`.
    /// @dev Run at least `minSetback()` after genesis, when grant and target-admin delays are
    ///      effective (`GovernanceConfigurator.verify`).
    function check(
        DeployV1.Deployment memory d,
        GovernanceConfig.Config memory cfg,
        GovernanceConfig.Call[] memory calls
    ) internal view {
        // Every configured target answers to this manager. Checked first: the configurator's
        // `verify` also rejects a moved target, but only as `InvalidTarget(target)`.
        for (uint256 i; i < cfg.targets.length; ++i) {
            address authority = IAccessManaged(cfg.targets[i].target).authority();
            if (authority != address(d.manager)) {
                revert WrongAuthority(cfg.targets[i].target, authority);
            }
        }
        // The manager is not handed over, and a handover would move every configured target
        // and every other deployed contract the manager governs.
        address next = d.manager.successor();
        if (next != address(0)) revert ManagerHandedOver(next);
        address[] memory managed = d.manager.managedTargets();
        for (uint256 i; i < cfg.targets.length; ++i) {
            _requireManaged(managed, cfg.targets[i].target);
        }
        string[] memory names = DeployV1.names();
        for (uint256 i; i < names.length; ++i) {
            address a = DeployV1.addressOf(d, names[i]);
            if (a == address(d.manager) || a.code.length == 0) continue;
            (bool ok, bytes memory ret) = a.staticcall(abi.encodeCall(IAccessManaged.authority, ()));
            if (ok && ret.length == 32 && abi.decode(ret, (address)) == address(d.manager)) {
                _requireManaged(managed, a);
            }
        }
        // No configured holder is suspended (the readback below would only see a missing
        // member).
        for (uint256 i; i < cfg.grants.length; ++i) {
            GovernanceConfig.Grant memory g = cfg.grants[i];
            if (d.manager.isSuspended(g.role, g.account)) {
                revert HolderSuspended(g.role, g.account);
            }
        }
        checkLens(d);
        // Roles, delays, holders and selectors; the configurator renounced ADMIN.
        d.configurator.verify(cfg);
        // ...and holds no other role (`verify` checks only ADMIN for it).
        for (uint64 role; role < Roles.COUNT; ++role) {
            if (GovernanceConfig.hasRecord(d.manager, role, address(d.configurator))) {
                revert ConfiguratorHoldsRole(role);
            }
        }
        // Every wiring call left its mark.
        for (uint256 i; i < calls.length; ++i) {
            checkWired(d, calls[i]);
        }
        checkPlatformPath(d, cfg);
        checkEditionAuctionLens(d);
        checkFederation(d);
    }

    /// @notice The federation's genesis state (ADR 0008): the artist registry is bound to the
    ///         recorded federation registry (the one-shot genesis bind) and the English auction
    ///         names it with its code hash pinned; the registry admits exactly the English
    ///         auction and the federated edition auction (both read back), and approves the two
    ///         v1 template code hashes this build computes (`DeployV1.templateCodeHash`), version
    ///         1, as the ERC-721 and the ERC-1155; the federated edition auction pins the recorded
    ///         lens, whose English auction and escrow are the deployment's; and the economics
    ///         resolver's federated product pays 10% to the fee recipient's vault, the terms a
    ///         template must lock to join. Genesis readback: a later governed change (a
    ///         revocation, a new adapter, a new fee) fails it by design. Skipped where no
    ///         federation registry was deployed.
    function checkFederation(DeployV1.Deployment memory d) internal view {
        FederationRegistry registry = d.federationRegistry;
        if (address(registry) == address(0)) return;
        if (d.artistRegistry.federationRegistry() != address(registry)) {
            revert FederationMismatch("ArtistRegistry.federationRegistry");
        }
        address english = address(d.englishAuction);
        if (_getter(english, "federationRegistry()") != address(registry)) {
            revert FederationMismatch("EnglishAuction.federationRegistry");
        }
        (bool ok, bytes memory ret) =
            english.staticcall(abi.encodeWithSignature("federationRegistryCodeHash()"));
        if (!ok || ret.length != 32 || abi.decode(ret, (bytes32)) != address(registry).codehash) {
            revert FederationMismatch("EnglishAuction.federationRegistryCodeHash");
        }
        if (
            !registry.isAdmittedAdapter(english)
                || !registry.isAdmittedAdapter(address(d.federatedEditionAuction))
        ) revert FederationMismatch("admitted adapters");
        if (registry.contentStore() != address(d.contentStore)) {
            revert FederationMismatch("FederationRegistry.contentStore");
        }
        checkTemplate(
            registry,
            "FederatedStream",
            DeployV1.templateCodeHash("FederatedStream"),
            DeployV1.templateCodeHash("FederatedStream.creationCode"),
            IFederationRegistry.Form.ERC721
        );
        checkTemplate(
            registry,
            "FederatedEditions",
            DeployV1.templateCodeHash("FederatedEditions"),
            DeployV1.templateCodeHash("FederatedEditions.creationCode"),
            IFederationRegistry.Form.ERC1155
        );
        address lens = d.federatedEditionAuction.lens();
        IUniformEditionAuctionLens l = IUniformEditionAuctionLens(lens);
        if (
            lens != d.federatedEditionAuctionLens || lens.code.length == 0
                || l.englishAuction() != english || l.escrow() != address(d.revenueEscrow)
        ) revert FederationMismatch("FederatedEditionAuction.lens");
        ProductEconomics memory e = d.economicsResolver.economics(PRODUCT_FEDERATED);
        if (e.feeRecipient != address(d.feeRecipientVault) || e.feeShare != FEDERATED_SHARE) {
            revert FederationMismatch("PRODUCT_FEDERATED economics");
        }
    }

    /// @notice A template version is approved as built: version 1 of `form`, runtime code hash
    ///         `codeHash` bound to `creationHash`, and that creation code published in data
    ///         contracts whose bytes hash to it. A build whose sources or metadata differ from the
    ///         genesis build computes other hashes and fails (`FederationMismatch(name)`).
    /// @param registry The federation registry.
    /// @param name The template's name, for the error.
    /// @param codeHash The build's runtime code hash.
    /// @param creationHash The build's creation code hash.
    /// @param form Its form.
    function checkTemplate(
        FederationRegistry registry,
        string memory name,
        bytes32 codeHash,
        bytes32 creationHash,
        IFederationRegistry.Form form
    ) internal view {
        FederationRegistry.Template memory t = registry.templateOf(codeHash);
        address[] memory pointers = registry.codeOf(creationHash);
        bytes memory code;
        for (uint256 i; i < pointers.length; ++i) {
            code = bytes.concat(code, SSTORE2.read(pointers[i]));
        }
        if (
            t.status != FederationRegistry.TemplateStatus.APPROVED || t.version != 1
                || t.form != form || t.creationHash != creationHash || pointers.length == 0
                || keccak256(code) != creationHash
        ) revert FederationMismatch(name);
    }

    /// @notice The edition auction's lens is the one its constructor pinned and the record
    ///         names (deployed on its own before the auction, F8): `lens()` equals the recorded
    ///         address, with code, and the lens's Editions, Stream, English auction and escrow are
    ///         the deployment's. Its code hash is verified as the English auction's lens's is
    ///         (`checkLens`): `checkAddresses` recomputes the lens's CREATE2 address from its
    ///         creation code and arguments, and the auction's from initcode carrying the lens's
    ///         code hash read from the chain; `Verify.s.sol` also compares it with the record.
    function checkEditionAuctionLens(DeployV1.Deployment memory d) internal view {
        address auction = address(d.editionAuction);
        if (auction == address(0)) return;
        address lens = d.editionAuction.lens();
        IUniformEditionAuctionLens l = IUniformEditionAuctionLens(lens);
        if (
            lens != d.editionAuctionLens || lens.code.length == 0
                || l.editions() != address(d.editions) || l.stream() != address(d.stream)
                || l.englishAuction() != address(d.englishAuction)
                || l.escrow() != address(d.revenueEscrow)
        ) revert AddressMismatch("UniformEditionAuctionLens", d.editionAuctionLens, lens);
    }

    /// @notice Reverts unless the wired getter reflects `call`. This is genesis readback: a
    ///         default currency must still be at the revision its wiring produced, and an
    ///         asset's opening bid at its wired value, so a later governed change
    ///         makes it fail by design.
    function checkWired(DeployV1.Deployment memory d, GovernanceConfig.Call memory call)
        internal
        view
    {
        bytes memory data = call.data;
        // Casting to bytes4 is safe: it keeps the selector, the first four bytes.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes4 selector = bytes4(data);
        address target = call.target;
        bool ok;
        if (selector == IStatementLog.appendGovernanceManifest.selector) {
            (uint64 count,) = IStatementLog(target).chainOf(address(d.manager), 0);
            ok = count != 0;
        } else if (selector == IAssetAllowlist.setDefaultCurrency.selector) {
            bytes32 product = _word(data, 0);
            uint256 expected = uint256(_word(data, 1));
            address asset = address(uint160(uint256(_word(data, 2))));
            (bool configured, address current, uint64 revision) =
                IAssetAllowlist(target).defaultCurrencyConfig(product);
            ok = configured && current == asset && revision == expected + 1;
        } else if (selector == IAssetAllowlist.setOpeningBid.selector) {
            address currency = address(uint160(uint256(_word(data, 0))));
            ok = IAssetAllowlist(target).openingBid(currency) == uint256(_word(data, 2));
        } else {
            address arg = address(uint160(uint256(_word(data, 0))));
            if (selector == IStream.bindWorkRecords.selector) {
                ok = _getter(target, "workRecords()") == arg;
            } else if (selector == IStream.bindEditions.selector) {
                ok = _getter(target, "editions()") == arg;
            } else if (selector == IPackageRegistry.bindStream.selector) {
                ok = _getter(target, "stream()") == arg;
            } else if (selector == IArtistRegistry.bindPackageRegistry.selector) {
                ok = _getter(target, "packageRegistry()") == arg;
            } else if (selector == IArtistRegistry.bindSplitFactory.selector) {
                ok = _getter(target, "splitFactory()") == arg;
            } else if (selector == IArtistRegistry.bindFederationRegistry.selector) {
                ok = _getter(target, "federationRegistry()") == arg;
            } else if (selector == IArtistRegistry.bindStatementLog.selector) {
                ok = _getter(target, "statementLog()") == arg;
            } else if (selector == IMintTarget.setAdmittedMinter.selector) {
                ok = IMintTarget(target).isAdmittedMinter(arg) == (_word(data, 1) != 0);
            } else if (selector == ISaleAdapter.setTarget.selector) {
                ok = ISaleAdapter(target).isTarget(arg) == (_word(data, 1) != 0);
            } else if (selector == ISaleAdapter.setFederationRegistry.selector) {
                address next = address(uint160(uint256(_word(data, 1))));
                ok = _getter(target, "federationRegistry()") == next;
            } else if (selector == FederationRegistry.setAdapter.selector) {
                ok = FederationRegistry(target).isAdmittedAdapter(arg) == (_word(data, 1) != 0);
            } else if (selector == FederationRegistry.approveTemplate.selector) {
                FederationRegistry.Template memory t =
                    FederationRegistry(target).templateOf(_word(data, 0));
                ok = t.status == FederationRegistry.TemplateStatus.APPROVED
                    && t.creationHash == _word(data, 1) && t.version == uint256(_word(data, 2))
                    && uint256(t.form) == uint256(_word(data, 3));
            } else {
                revert UnknownWiringSelector(selector);
            }
        }
        if (!ok) revert WiringNotApplied(target, selector);
    }

    /// @notice PLATFORM reaches `addLocator` through the work-records satellite's own `canCall`
    ///         check (the artist path needs no role): the configured PLATFORM holder must get an
    ///         immediate answer, as the implementation asks it. No sale selector is on this path:
    ///         the edition auction opens permissionlessly (ADR 0005).
    function checkPlatformPath(DeployV1.Deployment memory d, GovernanceConfig.Config memory cfg)
        internal
        view
    {
        address platform;
        for (uint256 i; i < cfg.grants.length; ++i) {
            if (cfg.grants[i].role == Roles.PLATFORM) platform = cfg.grants[i].account;
        }
        if (platform == address(0)) revert PlatformHolderMissing();
        address records = address(d.workRecords);
        address delivery = records == address(0) ? address(0) : d.workRecords.delivery();
        _platformCan(d, platform, delivery, IWorkLocators.addLocator.selector);
    }

    function _platformCan(
        DeployV1.Deployment memory d,
        address platform,
        address target,
        bytes4 selector
    ) private view {
        if (target == address(0)) return; // pending lane
        (bool immediate,) =
            AuthorityUtils.canCallWithDelay(address(d.manager), platform, target, selector);
        if (!immediate) revert PlatformPathClosed(target, selector);
    }

    function _requireManaged(address[] memory managed, address target) private pure {
        for (uint256 j; j < managed.length; ++j) {
            if (managed[j] == target) return;
        }
        revert TargetNotManaged(target);
    }

    /// @dev Fails closed: a getter that reverts or returns anything but one word is an error,
    ///      never a zero address that could match a zero argument.
    function _getter(address target, string memory signature) private view returns (address) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(signature));
        if (!ok || ret.length != 32) revert GetterFailed(target, signature);
        return abi.decode(ret, (address));
    }

    /// @dev The `index`th 32-byte argument word of `data` (after the selector), bounds-checked.
    function _word(bytes memory data, uint256 index) private pure returns (bytes32 word) {
        uint256 end = 4 + 32 * (index + 1);
        // Casting to bytes4 is safe: it keeps the selector, the first four bytes.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (data.length < end) revert MalformedWiringCall(bytes4(data));
        assembly ("memory-safe") {
            word := mload(add(data, end))
        }
    }
}

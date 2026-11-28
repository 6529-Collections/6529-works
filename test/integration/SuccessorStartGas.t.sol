// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { DeployCore } from "script/DeployCore.sol";
import { PackageRegistry } from "src/curation/PackageRegistry.sol";
import { Accounts } from "src/identity/Accounts.sol";
import { IConsolidationSource } from "src/interfaces/IArtistRegistry.sol";
import { ICurationVerifier } from "src/interfaces/ICurationVerifier.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IModuleSlots } from "src/interfaces/core/IModules.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { GasBase } from "./GasBase.sol";

/// @notice What a steady-state start costs before and after a replacement, measured as
///         `GasReport.t.sol` measures a row (a whole transaction, every contract cold, Prague
///         gas), one start per test so that nothing an earlier start warmed is counted. Each
///         contract below prepares one situation in `setUp` and measures a start whose move
///         the root signed and one whose move a consolidated wallet signed:
///         - `FirstModulesStartGasTest`: the modules of a first deployment (the comparison);
///         - `UncopiedAccountStartGasTest`: a second accounts module, the artist not copied;
///         - `CopiedAccountStartGasTest`: the same after `copyAccounts`;
///         - `SecondMintPolicyStartGasTest`: a second mint policy.
///         The ceilings of the gas table (ADR 0004) are budgets of a first deployment. After
///         a replacement they hold for a copied account; an account not yet copied pays for
///         the reads of the replaced module, and a start under a second mint policy for one
///         read of the replaced policy. Each figure here is a regression ceiling a little
///         above the measurement.
abstract contract SuccessorStartGasBase is GasBase {
    address internal constant ALL_COLLECTIONS = 0x8888888888888888888888888888888888888888;
    /// @dev The steady-state start ceiling of the gas table (ADR 0004).
    uint256 internal constant START_CEILING = 370_000;

    address internal artist;
    address internal wallet;
    address internal caller = makeAddr("successorGasCaller");
    uint256 internal artistId;
    bytes32 internal root;
    /// @dev The next unused work of the package and the artist's next move nonce.
    uint256 internal nextWork;
    uint256 internal nextNonce;
    address internal secondAccounts;
    address internal secondPolicy;

    function setUp() public virtual override {
        super.setUp();
        artist = _actor("successorGasArtist");
        wallet = _actor("successorGasWallet");
        vm.prank(artist);
        delegation.registerDelegationAddress(
            ALL_COLLECTIONS, wallet, type(uint64).max, 999, true, 0
        );
        vm.prank(wallet);
        delegation.registerDelegationAddress(
            ALL_COLLECTIONS, artist, type(uint64).max, 999, true, 0
        );
        Work[] memory works = new Work[](8);
        for (uint256 i; i < works.length; ++i) {
            works[i] = _work(artist, collectionId);
        }
        root = _publish(works);
        _keep(root, works);
        artistId = accounts.artistIdOf(artist);
        // Steady state: the artist, the collection and the auction have started works before,
        // with a move of each signer.
        _warmUp(artist);
        _warmUp(wallet);
        _prepare();
    }

    /// @dev The situation the starts are measured in; runs at the end of `setUp`.
    function _prepare() internal virtual;

    /// @dev The ceilings of the two starts in this situation.
    function _ceilings() internal pure virtual returns (uint256 rootSigned, uint256 walletSigned);

    function _cooled() internal view override returns (address[] memory all) {
        address[] memory base = super._cooled();
        all = new address[](base.length + 2);
        uint256 n;
        for (; n < base.length; ++n) {
            all[n] = base[n];
        }
        if (secondAccounts != address(0)) all[n++] = secondAccounts;
        if (secondPolicy != address(0)) all[n++] = secondPolicy;
        assembly ("memory-safe") {
            mstore(all, n)
        }
    }

    function _mintDataBy(address signer) internal returns (bytes memory) {
        return _mintDataSignedBy(root, _package(root), nextWork++, signer, nextNonce++);
    }

    /// @dev An unmeasured start, in `setUp`.
    function _warmUp(address signer) internal {
        bytes memory mintData = _mintDataBy(signer);
        vm.prank(caller);
        auction.start(address(stream), mintData);
    }

    /// @dev A second `Accounts` naming the one in force, announced, waited out and activated.
    function _replaceAccounts() internal returns (Accounts next) {
        next = new Accounts(
            address(manager),
            IConsolidationSource(address(consolidation)),
            address(consolidation).codehash,
            Accounts.Wiring(
                address(directory),
                address(stream),
                address(editions),
                address(ledger),
                address(statements),
                address(registry),
                address(accounts)
            ),
            DeployCore.notPayouts(deployment)
        );
        _asNetwork(
            address(directory),
            abi.encodeCall(IModuleSlots.proposeModule, (Slots.ACCOUNTS, address(next)))
        );
        vm.warp(block.timestamp + directory.moduleDelay());
        directory.activateModule(Slots.ACCOUNTS);
        secondAccounts = address(next);
    }

    function _measureStart(address signer, uint256 ceiling, string memory label) internal {
        bytes memory data = abi.encodeCall(auction.start, (address(stream), _mintDataBy(signer)));
        (uint256 total,) = _measure(caller, address(auction), data, 0);
        emit log_named_uint(label, total);
        assertLt(total, ceiling, label);
        // A ceiling is kept close to its measurement, so a saving is seen too.
        assertGt(total, ceiling - ceiling / 50, "the ceiling is more than 2% above the cost");
    }

    function test_Gas_StartSignedByTheRoot() public {
        (uint256 ceiling,) = _ceilings();
        _measureStart(artist, ceiling, "start, steady state, move signed by the root");
    }

    function test_Gas_StartSignedByAConsolidatedWallet() public {
        (, uint256 ceiling) = _ceilings();
        _measureStart(wallet, ceiling, "start, steady state, move signed by a consolidated wallet");
    }
}

/// @notice The comparison: a first deployment's accounts module and mint policy.
contract FirstModulesStartGasTest is SuccessorStartGasBase {
    uint256 internal constant ROOT_FIRST = 320_000;
    uint256 internal constant WALLET_FIRST = 367_000;

    function _prepare() internal override { }

    function _ceilings() internal pure override returns (uint256, uint256) {
        return (ROOT_FIRST, WALLET_FIRST);
    }
}

/// @notice A second accounts module that has not copied the artist's account: each read of the
///         account goes on to the replaced module.
contract UncopiedAccountStartGasTest is SuccessorStartGasBase {
    uint256 internal constant ROOT_READ = 326_000;
    /// @dev Above the gas table's 370,000: the reason to copy an account before it sells.
    uint256 internal constant WALLET_READ = 380_000;

    function _prepare() internal override {
        _replaceAccounts();
    }

    function _ceilings() internal pure override returns (uint256, uint256) {
        return (ROOT_READ, WALLET_READ);
    }
}

/// @notice A second accounts module after `copyAccounts`: the start costs what it cost under
///         the first module, inside the gas table's ceiling.
contract CopiedAccountStartGasTest is SuccessorStartGasBase {
    uint256 internal constant ROOT_COPIED = 320_000;
    uint256 internal constant WALLET_COPIED = 367_000;

    function _prepare() internal override {
        Accounts next = _replaceAccounts();
        uint256[] memory ids = new uint256[](1);
        ids[0] = artistId;
        vm.prank(caller);
        next.copyAccounts(ids);
    }

    function _ceilings() internal pure override returns (uint256, uint256) {
        return (ROOT_COPIED, WALLET_COPIED);
    }

    function test_Gas_ACopiedAccountStartsInsideTheTableCeiling() public pure {
        assertLe(ROOT_COPIED, START_CEILING);
        assertLe(WALLET_COPIED, START_CEILING);
    }
}

/// @notice A second mint policy naming the first: every start reads the replaced policy once
///         for the root, which is how a revocation made there keeps reaching the new one.
contract SecondMintPolicyStartGasTest is SuccessorStartGasBase {
    uint256 internal constant ROOT_SECOND = 328_500;
    /// @dev Above the gas table's 370,000 (LIM-ID-21: the root signs the cheapest start).
    uint256 internal constant WALLET_SECOND = 375_500;

    function _prepare() internal override {
        PackageRegistry first = registry;
        PackageRegistry next = new PackageRegistry(
            address(manager),
            ICurationVerifier(address(verifier)),
            address(verifier).codehash,
            address(directory),
            IEconomicsResolver(address(economics)),
            address(0),
            cc0TextFileId,
            address(first)
        );
        _asNetwork(address(next), abi.encodeCall(PackageRegistry.bindStream, (address(stream))));
        _asNetwork(
            address(accounts),
            abi.encodeCall(Accounts.setPackageRegistry, (address(first), address(next)))
        );
        _asNetwork(
            address(auction),
            abi.encodeCall(EnglishAuction.setStreamPolicy, (address(first), address(next)))
        );
        bytes memory attestation = abi.encode(
            signer1,
            _sign(
                signer1,
                verifier.approvalDigest(root, _evidence(root), verifier.signerEpoch(signer1))
            )
        );
        next.registerPackage(root, _evidence(root), attestation);
        registry = next;
        secondPolicy = address(next);
        _accept(root, artist);
        // The artist's moves under the new policy count from zero; the first opens its nonce
        // word there.
        nextNonce = 0;
        _warmUp(artist);
        _warmUp(wallet);
    }

    function _ceilings() internal pure override returns (uint256, uint256) {
        return (ROOT_SECOND, WALLET_SECOND);
    }
}

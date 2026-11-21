// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Eip712CurationVerifier } from "src/curation/Eip712CurationVerifier.sol";
import { PackageRegistry } from "src/curation/PackageRegistry.sol";
import { Roles } from "src/governance/Roles.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { ICurationVerifier } from "src/interfaces/ICurationVerifier.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { HandlerReach } from "../helpers/HandlerReach.sol";
import { CurationArtistRegistryMock } from "../mocks/curation/CurationArtistRegistryMock.sol";
import { StreamContentMock } from "../mocks/curation/StreamContentMock.sol";
import { CurationHelpers } from "./CurationBase.sol";

/// @notice Drives the curation signers around live approvals: signers sign package approvals at
///         their current epoch (also while disabled or without the role), anyone submits them
///         (some tampered), and the network disables and re-enables signers, revokes and grants
///         the signer role (swapping one key for a spare), kills a signer's approvals and
///         revokes roots; a stranger tries the network's actions. Keeps an exact model of each
///         signer's activity and epoch and of every root; each action predicts its outcome.
contract CurationSignerHandler is CurationHelpers {
    uint256 internal constant SIGNERS = 3;
    uint256 internal constant ROOTS = 24;
    uint8 internal constant NONE = 0;
    uint8 internal constant APPROVED = 1;
    uint8 internal constant REVOKED = 2;
    bytes32 internal constant EVIDENCE = keccak256("curation signer campaign evidence");

    struct Attestation {
        uint256 signer;
        uint256 root;
        uint256 epochId;
        bytes data;
    }

    struct Root {
        uint8 status;
        uint256 signer;
        uint64 killEpoch;
    }

    WorksAccessManager internal immutable manager;
    Eip712CurationVerifier internal immutable verifier;
    PackageRegistry internal immutable registry;
    address internal immutable admin;
    address internal constant STRANGER = address(0xBAD);

    uint256[SIGNERS] internal _keys = [uint256(0xC1), 0xC2, 0xC3];
    address[SIGNERS] public signers;
    bytes32[ROOTS] public roots;

    mapping(uint256 signer => bool) public hasRole;
    mapping(uint256 signer => bool) public disabled;
    /// @dev Counts the epoch-ending changes of each signer (disable, enable, role revoked, role
    ///      granted to a non-member); an attestation counts only at the count it was signed at.
    mapping(uint256 signer => uint256) public epochId;
    /// @dev The verifier's epoch value read after the latest change, and every value seen.
    mapping(uint256 signer => uint256) public lastEpoch;
    mapping(uint256 signer => mapping(uint256 value => bool)) internal _seenEpoch;
    mapping(uint256 root => Root) internal _roots;
    uint64 public killEpoch;
    mapping(uint256 signer => uint64) public killedAt;
    Attestation[] internal _attestations;

    uint256 public violations;
    uint256 public registrations;
    uint256 public staleRefusals;
    uint256 public disables;
    uint256 public enables;
    uint256 public swaps;
    uint256 public kills;
    uint256 public killedRoots;

    constructor(
        WorksAccessManager manager_,
        Eip712CurationVerifier verifier_,
        PackageRegistry registry_,
        address admin_
    ) {
        (manager, verifier, registry, admin) = (manager_, verifier_, registry_, admin_);
        for (uint256 s; s < SIGNERS; ++s) {
            signers[s] = vm.addr(_keys[s]);
            lastEpoch[s] = verifier_.signerEpoch(signers[s]);
            _seenEpoch[s][lastEpoch[s]] = true;
        }
        hasRole[0] = true;
        hasRole[1] = true;
        for (uint256 r; r < ROOTS; ++r) {
            roots[r] = keccak256(abi.encode("curation signer campaign root", r));
        }
    }

    function attestationCount() external view returns (uint256) {
        return _attestations.length;
    }

    function root(uint256 r) external view returns (uint8 status, uint256 signer, uint64 epoch) {
        Root storage x = _roots[r];
        return (x.status, x.signer, x.killEpoch);
    }

    /// @notice Whether the model's root `r` is live: approved, its signer's approvals not killed
    ///         since it was registered.
    function live(uint256 r) public view returns (bool) {
        Root storage x = _roots[r];
        return
            x.status == APPROVED && (x.killEpoch == killEpoch || killedAt[x.signer] <= x.killEpoch);
    }

    function active(uint256 s) public view returns (bool) {
        return hasRole[s] && !disabled[s];
    }

    // ------------------------------------------------------------------------------- actions

    /// @dev A signer signs an approval of a root at its current epoch, whatever its state.
    function sign(uint256 signerSeed, uint256 rootSeed) external {
        uint256 s = signerSeed % SIGNERS;
        uint256 r = rootSeed % ROOTS;
        bytes32 digest =
            verifier.approvalDigest(roots[r], EVIDENCE, verifier.signerEpoch(signers[s]));
        _attestations.push(
            Attestation(s, r, epochId[s], abi.encode(signers[s], _sig(_keys[s], digest)))
        );
    }

    /// @dev Anyone submits a signed approval, one time in eight with other evidence. It
    ///      registers only an unused root, from a signer active now, at the epoch it signed at.
    function register(uint256 attestationSeed, uint8 tamper) external {
        if (_attestations.length == 0) return;
        Attestation storage a = _attestations[attestationSeed % _attestations.length];
        bool tampered = tamper % 8 == 0;
        bool current = a.epochId == epochId[a.signer];
        bool expected = _roots[a.root].status == NONE && active(a.signer) && current && !tampered;
        bytes32 evidence = tampered ? keccak256("other evidence") : EVIDENCE;
        vm.prank(STRANGER);
        try registry.registerPackage(roots[a.root], evidence, a.data) {
            if (!expected) ++violations;
            _roots[a.root] = Root(APPROVED, a.signer, killEpoch);
            ++registrations;
        } catch {
            if (expected) ++violations;
            if (!current && !tampered && _roots[a.root].status == NONE) ++staleRefusals;
        }
    }

    /// @dev The network (or a stranger, refused) disables a signer; a disabled one is refused.
    function disable(uint256 signerSeed, uint8 who) external {
        uint256 s = signerSeed % SIGNERS;
        address caller = who % 4 == 0 ? STRANGER : admin;
        bool expected = caller == admin && !disabled[s];
        vm.prank(caller);
        try verifier.disableSigner(signers[s]) {
            if (!expected) ++violations;
            disabled[s] = true;
            _newEpoch(s);
            ++disables;
        } catch {
            if (expected) ++violations;
        }
    }

    /// @dev The network (or a stranger, refused) re-enables a disabled signer.
    function enable(uint256 signerSeed, uint8 who) external {
        uint256 s = signerSeed % SIGNERS;
        address caller = who % 4 == 0 ? STRANGER : admin;
        bool expected = caller == admin && disabled[s];
        vm.prank(caller);
        try verifier.enableSigner(signers[s]) {
            if (!expected) ++violations;
            disabled[s] = false;
            _newEpoch(s);
            ++enables;
        } catch {
            if (expected) ++violations;
        }
    }

    /// @dev The network swaps a signer key: revokes the role from one signer and grants it to
    ///      another (the spare, or one revoked before), in the same block.
    function swap(uint256 fromSeed, uint256 toSeed) external {
        uint256 from = fromSeed % SIGNERS;
        uint256 to = toSeed % SIGNERS;
        vm.prank(admin);
        manager.revokeRole(Roles.CURATION_SIGNER, signers[from]);
        if (hasRole[from]) {
            hasRole[from] = false;
            _newEpoch(from);
        }
        vm.prank(admin);
        manager.grantRole(Roles.CURATION_SIGNER, signers[to], 0);
        if (!hasRole[to]) {
            hasRole[to] = true;
            _newEpoch(to);
        }
        ++swaps;
    }

    /// @dev The network kills every approval a signer made so far.
    function kill(uint256 signerSeed) external {
        uint256 s = signerSeed % SIGNERS;
        vm.prank(admin);
        registry.killSignerApprovals(signers[s]);
        killedAt[s] = ++killEpoch;
        for (uint256 r; r < ROOTS; ++r) {
            if (_roots[r].status == APPROVED && _roots[r].signer == s && !live(r)) ++killedRoots;
        }
        ++kills;
    }

    /// @dev The network revokes a root, registered or not; a revoked one is refused.
    function revokeRoot(uint256 rootSeed) external {
        uint256 r = rootSeed % ROOTS;
        bool expected = _roots[r].status != REVOKED;
        vm.prank(admin);
        try registry.revokePackage(roots[r], bytes32(0)) {
            if (!expected) ++violations;
            _roots[r].status = REVOKED;
        } catch {
            if (expected) ++violations;
        }
    }

    function warp(uint256 by) external {
        vm.warp(block.timestamp + by % 3 days);
    }

    /// @dev Reads the signer's new epoch value: it must differ from every value it had before.
    function _newEpoch(uint256 s) internal {
        ++epochId[s];
        uint256 value = verifier.signerEpoch(signers[s]);
        if (_seenEpoch[s][value]) ++violations;
        _seenEpoch[s][value] = true;
        lastEpoch[s] = value;
    }
}

/// @notice The curation signer lifecycle around live approvals (the gap the invariants page
///         named): disable, re-enable, role swaps and kills never let an approval signed at an
///         earlier epoch, or while disabled, register a root, and the registry's view of every
///         root follows the model. Uses the 6529 Works access manager, whose grant counter
///         keeps a revoke and re-grant in one block from reviving an epoch. Run with the
///         foundry.toml campaign (256 runs x depth 128, `fail_on_revert`).
contract CurationSignerInvariantTest is CurationHelpers {
    CurationSignerHandler internal handler;
    WorksAccessManager internal manager;
    Eip712CurationVerifier internal verifier;
    PackageRegistry internal registry;
    address internal admin = makeAddr("installer");

    function setUp() public {
        manager = new WorksAccessManager(admin);
        CurationArtistRegistryMock artists = new CurationArtistRegistryMock();
        verifier = new Eip712CurationVerifier(address(manager));
        registry = new PackageRegistry(
            address(manager),
            ICurationVerifier(address(verifier)),
            address(verifier).codehash,
            address(artists),
            address(artists).codehash
        );
        artists.bindPackageRegistry(address(registry));
        vm.startPrank(admin);
        _map(address(registry), PackageRegistry.revokePackage.selector, Roles.NETWORK);
        _map(address(registry), PackageRegistry.killSignerApprovals.selector, Roles.NETWORK);
        _map(address(verifier), Eip712CurationVerifier.disableSigner.selector, Roles.NETWORK);
        _map(
            address(verifier), Eip712CurationVerifier.enableSigner.selector, Roles.SUCCESSOR_SETTER
        );
        manager.grantRole(Roles.CURATION_SIGNER, vm.addr(0xC1), 0);
        manager.grantRole(Roles.CURATION_SIGNER, vm.addr(0xC2), 0);
        registry.bindStream(address(new StreamContentMock()));
        vm.stopPrank();
        handler = new CurationSignerHandler(manager, verifier, registry, admin);
        bytes4[] memory s = new bytes4[](10);
        s[0] = handler.sign.selector;
        s[1] = handler.sign.selector;
        s[2] = handler.register.selector;
        s[3] = handler.register.selector;
        s[4] = handler.disable.selector;
        s[5] = handler.enable.selector;
        s[6] = handler.swap.selector;
        s[7] = handler.kill.selector;
        s[8] = handler.revokeRoot.selector;
        s[9] = handler.warp.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: s }));
    }

    function _map(address target, bytes4 selector, uint64 role) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        manager.setTargetFunctionRole(target, selectors, role);
    }

    /// INV-CUR-7: a root registers only from an approval its signer made at its current epoch
    /// while active: none signed before a disable, a role revocation or a swap, or while the
    /// signer was disabled or held no role, ever registers, nor a tampered one, nor any for a
    /// root already registered or revoked; every allowed submission registers; each signer's
    /// epoch value is new at every disable, enable, revocation and grant.
    function invariant_RegistrationsFollowTheSignersEpoch() public view {
        assertEq(handler.violations(), 0);
    }

    /// INV-CUR-8: the registry's view of every root is the model's: unregistered, live (its
    /// signer recorded), or revoked, a root of a killed signer reading as revoked from the kill
    /// on.
    function invariant_RootsMatchTheModel() public view {
        for (uint256 r; r < 24; ++r) {
            (IPackageRegistry.PackageStatus status,, address signer) =
                registry.packageOf(handler.roots(r));
            (uint8 model, uint256 s,) = handler.root(r);
            uint8 want = model == 1 && !handler.live(r) ? 2 : model;
            assertEq(uint8(status), want, "status");
            if (model != 0 && signer != address(0)) assertEq(signer, handler.signers(s), "signer");
        }
    }

    /// INV-CUR-9: the verifier's view of each signer is the model's: disabled, active (the role
    /// with no delay and not disabled), and its epoch the value read after its latest change.
    function invariant_SignersMatchTheModel() public view {
        for (uint256 s; s < 3; ++s) {
            address signer = handler.signers(s);
            assertEq(verifier.isDisabled(signer), handler.disabled(s), "disabled");
            assertEq(verifier.isSignerActive(signer), handler.active(s), "active");
            assertEq(verifier.signerEpoch(signer), handler.lastEpoch(s), "epoch");
        }
    }

    /// @notice Handler self-test: approvals are signed, registered and refused as stale; signers
    ///         are disabled, re-enabled and swapped; approvals are killed and roots revoked.
    ///         Then every invariant holds.
    function test_HandlerPathsReachState() public {
        uint8 w = HandlerReach.WRITES;
        uint8 wr = HandlerReach.WRITES | HandlerReach.REFUSED;
        HandlerReach.Expect[] memory e = new HandlerReach.Expect[](8);
        e[0] = HandlerReach.Expect(handler.sign.selector, 0);
        e[1] = HandlerReach.Expect(handler.register.selector, wr);
        e[2] = HandlerReach.Expect(handler.disable.selector, wr);
        e[3] = HandlerReach.Expect(handler.enable.selector, wr);
        e[4] = HandlerReach.Expect(handler.swap.selector, w);
        e[5] = HandlerReach.Expect(handler.kill.selector, w);
        e[6] = HandlerReach.Expect(handler.revokeRoot.selector, wr);
        e[7] = HandlerReach.Expect(handler.warp.selector, HandlerReach.CLOCK);
        HandlerReach.covers(targetSelectors()[0].selectors, e);
        address[] memory sut = new address[](3);
        sut[0] = address(registry);
        sut[1] = address(verifier);
        sut[2] = address(manager);
        HandlerReach.Tally[] memory t = new HandlerReach.Tally[](e.length);
        uint256[4] memory n;
        for (uint256 run; run < 8; ++run) {
            uint256 snapshot = vm.snapshotState();
            HandlerReach.add(t, HandlerReach.drive(address(handler), e, sut, 16, run));
            n[0] += handler.registrations();
            n[1] += handler.staleRefusals();
            n[2] += handler.killedRoots();
            n[3] += handler.swaps();
            if (run < 7) vm.revertToState(snapshot);
        }
        HandlerReach.check(e, t);
        assertGt(n[0], 0, "registrations");
        assertGt(n[1], 0, "stale approvals refused");
        assertGt(n[2], 0, "roots killed");
        assertGt(n[3], 0, "swaps");
        invariant_RegistrationsFollowTheSignersEpoch();
        invariant_RootsMatchTheModel();
        invariant_SignersMatchTheModel();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { ArtistIdentity, ChangeKind } from "src/interfaces/types/IdentityTypes.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import {
    DisputeOutcomeLogMock,
    EditionsMastersMock,
    FederationRegistryStub,
    SplitFactoryWalletsMock
} from "../mocks/identity/IdentityWorksMocks.sol";
import { PreApprovedWallet } from "../mocks/identity/PermanenceMocks.sol";
import { StreamMock } from "../mocks/stream/StreamMock.sol";
import { SignatureReverts } from "test/helpers/SignatureReverts.sol";
import { IdentityFixture } from "./IdentityFixture.sol";

/// @notice The artist registry as the permanent federation directory (ADR 0001 section 16, as
///         amended for v1): the replaceable federation-registry pointer, identities created
///         with the account's own consent, per-token entries with no cap, statuses, exit by the
///         token itself, refusal of canonical contracts, and the federation registry's lack of
///         authority over identities.
contract FederationDirectoryTest is IdentityFixture {
    StreamMock internal stream;
    address internal editions;
    address internal federation;
    address internal token;
    address internal partner;
    address internal feeVault = makeAddr("networkFeeVault");
    uint64 internal constant DEADLINE = type(uint64).max;
    bytes32 internal constant LISTING = keccak256(
        "FederatedListing(uint256 artistId,address token,uint8 form,address partner,"
        "uint32 feeShare,address feeRecipient,uint64 deadline)"
    );

    function setUp() public override {
        super.setUp();
        stream = new StreamMock();
        editions = address(new EditionsMastersMock());
        stream.setEditions(editions);
        federation = address(new FederationRegistryStub());
        token = address(new FederationRegistryStub());
        partner = address(new EditionsMastersMock());
        vm.startPrank(admin);
        registry.bindStream(address(stream));
        registry.bindFederationRegistry(federation);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- the pointer

    function test_SetFederationRegistry_ReplacesThePointer() public {
        address next = address(new FederationRegistryStub());
        vm.expectEmit(address(registry));
        emit IArtistRegistry.FederationRegistrySet(federation, next);
        vm.prank(successorSetter);
        registry.setFederationRegistry(federation, next);
        assertEq(registry.federationRegistry(), next);

        // The predecessor lost its calls; the successor has them.
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnboundCaller.selector, federation));
        vm.prank(federation);
        registry.listFederatedContract(
            _l(artistId, token, 0, address(0), 10_000, feeVault),
            _ok(_l(artistId, token, 0, address(0), 10_000, feeVault))
        );
        vm.prank(next);
        registry.listFederatedContract(
            _l(artistId, token, 0, address(0), 10_000, feeVault),
            _ok(_l(artistId, token, 0, address(0), 10_000, feeVault))
        );
    }

    function test_SetFederationRegistry_Checks() public {
        address next = address(new FederationRegistryStub());
        vm.startPrank(successorSetter);
        vm.expectRevert(IArtistRegistry.ExpectedValueMismatch.selector);
        registry.setFederationRegistry(address(0), next);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(0)));
        registry.setFederationRegistry(federation, address(0));
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, stranger));
        registry.setFederationRegistry(federation, stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, packageRegistry)
        );
        registry.setFederationRegistry(federation, packageRegistry);
        vm.stopPrank();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, admin)
        );
        vm.prank(admin);
        registry.setFederationRegistry(federation, next);
    }

    // ----------------------------------------------------------------- identities

    function test_RegisterFederated_CreatesTheSameIdentityAsAPackageAcceptance() public {
        uint256 key = 0xFED;
        address account = vm.addr(key);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory consent = _consent(key, account, deadline);
        uint256 id = uint160(account);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ArtistRegistered(
            id, ArtistIdentity(account, account, PROFILE, PROFILE_DOC)
        );
        vm.prank(federation);
        assertEq(registry.registerFederated(account, PROFILE, PROFILE_DOC, deadline, consent), id);
        (ArtistIdentity memory identity, uint64 last) = registry.artist(id);
        assertEq(identity.authority, account);
        assertEq(identity.payout, account);
        assertEq(last, block.timestamp);
        assertEq(registry.artistIdOf(account), id);
        // A second use of the consent finds the account taken.
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, account));
        vm.prank(federation);
        registry.registerFederated(account, PROFILE, PROFILE_DOC, deadline, consent);
    }

    /// @dev No caller can create an identity for an account that did not sign for it: a consent
    ///      by another key, for other profile fields, expired, or relayed by anyone but the bound
    ///      federation registry is refused.
    function test_RegisterFederated_NeedsTheAccountsOwnConsent() public {
        uint256 key = 0xFED;
        address account = vm.addr(key);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory consent = _consent(key, account, deadline);
        bytes memory foreign = _consent(thiefKey, account, deadline);
        vm.startPrank(federation);
        vm.expectRevert(SignatureReverts.invalid(account));
        registry.registerFederated(account, PROFILE, PROFILE_DOC, deadline, foreign);
        vm.expectRevert(SignatureReverts.invalid(account));
        registry.registerFederated(account, PROFILE, keccak256("other"), deadline, consent);
        vm.expectRevert(SignatureReverts.invalid(account));
        registry.registerFederated(account, PROFILE, PROFILE_DOC, deadline, "");
        vm.warp(deadline + 1);
        vm.expectRevert(SignatureReverts.expired(deadline));
        registry.registerFederated(account, PROFILE, PROFILE_DOC, deadline, consent);
        vm.stopPrank();
        vm.warp(deadline);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnboundCaller.selector, stranger));
        vm.prank(stranger);
        registry.registerFederated(account, PROFILE, PROFILE_DOC, deadline, consent);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.UnboundCaller.selector, packageRegistry)
        );
        vm.prank(packageRegistry);
        registry.registerFederated(account, PROFILE, PROFILE_DOC, deadline, consent);
        assertEq(registry.artistIdOf(account), 0);
    }

    /// @dev The same guarantees as `register`: an account reserved by another artist's pending
    ///      change, or a payout that cannot pull, is refused; a contract account consents by
    ///      pre-approving the digest (ERC-1271).
    function test_RegisterFederated_SameGuaranteesAsRegister() public {
        _stage(artistKey, _identity(newAuthority, newAuthority), newKey);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory consent = _consent(newKey, newAuthority, deadline);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, newAuthority));
        vm.prank(federation);
        registry.registerFederated(newAuthority, PROFILE, PROFILE_DOC, deadline, consent);

        PreApprovedWallet wallet_ = new PreApprovedWallet(stranger);
        address account = address(wallet_);
        bytes32 digest = registry.registrationDigest(account, PROFILE, PROFILE_DOC, deadline);
        vm.prank(stranger);
        wallet_.approve(digest);
        vm.prank(federation);
        registry.registerFederated(account, PROFILE, PROFILE_DOC, deadline, "");
        assertEq(registry.authorityOf(uint160(account)), account);
    }

    function test_RegistrationDigest_IsStandardEip712() public view {
        bytes32 typehash = keccak256(
            "ArtistRegistration(address account,bytes32 profileId,bytes32 profileDocHash,uint64 deadline)"
        );
        // `cast keccak`, as off-chain tools compute it.
        assertEq(typehash, 0x251edc52a2bb08ba54c8c256d514ddd287d55597cda1692026fb5fcbf0f8a8d9);
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("6529 Works Artist Registry"),
                keccak256("1"),
                block.chainid,
                address(registry)
            )
        );
        bytes32 structHash =
            keccak256(abi.encode(typehash, stranger, PROFILE, PROFILE_DOC, uint64(9)));
        assertEq(
            registry.registrationDigest(stranger, PROFILE, PROFILE_DOC, 9),
            keccak256(abi.encodePacked(hex"1901", domain, structHash))
        );
    }

    // ----------------------------------------------------------------- listing

    /// @dev The entry's code hash is read by the artist registry; the caller supplies none.
    function test_List_RecordsTheEntryWithItsOwnCodeHash() public {
        vm.expectEmit(address(registry));
        emit IArtistRegistry.FederatedContractListed(
            artistId, token, token.codehash, 0, partner, 10_000, feeVault
        );
        vm.prank(federation);
        registry.listFederatedContract(
            _l(artistId, token, 0, partner, 10_000, feeVault),
            _ok(_l(artistId, token, 0, partner, 10_000, feeVault))
        );
        (uint256 listedArtist, IArtistRegistry.FederationStatus status) =
            registry.federatedListing(token);
        assertEq(listedArtist, artistId);
        assertEq(uint8(status), uint8(IArtistRegistry.FederationStatus.ACTIVE));
        assertTrue(token.codehash != bytes32(0) && token.codehash != keccak256(""));
    }

    /// @dev Review G (I3): the consent covers the entry's facts; a consent to the token with
    ///      other facts lists nothing.
    function test_List_TheConsentCoversTheFacts() public {
        bytes memory consent = _ok(_l(artistId, token, 0, address(0), 0, address(0)));
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, artist));
        vm.prank(federation);
        registry.listFederatedContract(_l(artistId, token, 0, partner, 10_000, feeVault), consent);
    }

    /// @dev The consent binds each of the seven signed facts on its own: a listing that differs
    ///      from the signed one in any single field lists nothing, and the signed one lists.
    function test_List_TheConsentBindsEachFieldAlone() public {
        IArtistRegistry.FederatedListing memory signed =
            _l(artistId, token, 0, partner, 10_000, feeVault);
        bytes memory consent = _ok(signed);
        address other = makeAddr("otherArtist");
        uint256 otherId = _register(other);
        for (uint256 field; field < 7; ++field) {
            IArtistRegistry.FederatedListing memory l = _l(artistId, token, 0, partner, 10_000, feeVault);
            address signer = artist;
            if (field == 0) (l.artistId, signer) = (otherId, other);
            else if (field == 1) l.token = address(new FederationRegistryStub());
            else if (field == 2) l.form = 1;
            else if (field == 3) l.partner = address(new EditionsMastersMock());
            else if (field == 4) l.feeShare = 10_001;
            else if (field == 5) l.feeRecipient = makeAddr("otherFeeVault");
            else l.deadline = DEADLINE - 1;
            vm.expectRevert(
                abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, signer)
            );
            vm.prank(federation);
            registry.listFederatedContract(l, consent);
        }
        vm.prank(federation);
        registry.listFederatedContract(signed, consent);
        (uint256 listedArtist,) = registry.federatedListing(token);
        assertEq(listedArtist, artistId);
    }

    /// Regression: the 64-entry append-only list (study H): an artist lists any number.
    function test_List_HasNoCap() public {
        vm.startPrank(federation);
        for (uint256 i; i < 100; ++i) {
            address t = address(new FederationRegistryStub());
            registry.listFederatedContract(
                _l(artistId, t, uint8(i % 2), address(0), 10_000, feeVault),
                _ok(_l(artistId, t, uint8(i % 2), address(0), 10_000, feeVault))
            );
        }
        vm.stopPrank();
    }

    function test_List_Refusals() public {
        vm.startPrank(federation);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, 5));
        registry.listFederatedContract(
            _l(5, token, 0, address(0), 10_000, feeVault),
            _ok(_l(5, token, 0, address(0), 10_000, feeVault))
        );
        // No code, or an EIP-7702 delegated account: its code hash would mean nothing.
        address delegated = makeAddr("delegated7702");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", token));
        _expectRefused(stranger);
        registry.listFederatedContract(
            _l(artistId, stranger, 0, address(0), 10_000, feeVault),
            _ok(_l(artistId, stranger, 0, address(0), 10_000, feeVault))
        );
        _expectRefused(delegated);
        registry.listFederatedContract(
            _l(artistId, delegated, 0, address(0), 10_000, feeVault),
            _ok(_l(artistId, delegated, 0, address(0), 10_000, feeVault))
        );
        // Listed once, in any status, never again.
        registry.listFederatedContract(
            _l(artistId, token, 0, address(0), 10_000, feeVault),
            _ok(_l(artistId, token, 0, address(0), 10_000, feeVault))
        );
        _expectRefused(token);
        registry.listFederatedContract(
            _l(artistId, token, 1, address(0), 5_000, feeVault),
            _ok(_l(artistId, token, 1, address(0), 5_000, feeVault))
        );
        registry.setFederatedStatus(token, IArtistRegistry.FederationStatus.DELISTED, "vote");
        _expectRefused(token);
        registry.listFederatedContract(
            _l(artistId, token, 0, address(0), 10_000, feeVault),
            _ok(_l(artistId, token, 0, address(0), 10_000, feeVault))
        );
        vm.stopPrank();
        vm.prank(token);
        registry.recordFederationExit();
        _expectRefused(token);
        vm.prank(federation);
        registry.listFederatedContract(
            _l(artistId, token, 0, address(0), 10_000, feeVault),
            _ok(_l(artistId, token, 0, address(0), 10_000, feeVault))
        );
    }

    /// @dev Entries, partners and fee recipients never name this registry, 6529 Stream, its
    ///      Editions or a bound contract.
    function test_List_RefusesCanonicalContracts() public {
        SplitFactoryWalletsMock factory = new SplitFactoryWalletsMock();
        DisputeOutcomeLogMock log = new DisputeOutcomeLogMock(address(registry));
        vm.startPrank(admin);
        registry.bindSplitFactory(address(factory));
        registry.bindStatementLog(address(log));
        vm.stopPrank();
        address[8] memory canonical = [
            address(registry),
            address(stream),
            editions,
            packageRegistry,
            federation,
            address(factory),
            address(log),
            address(adapter)
        ];
        vm.startPrank(federation);
        for (uint256 i; i < canonical.length; ++i) {
            _expectRefused(canonical[i]);
            registry.listFederatedContract(
                _l(artistId, canonical[i], 0, address(0), 10_000, feeVault),
                _ok(_l(artistId, canonical[i], 0, address(0), 10_000, feeVault))
            );
            _expectRefused(token);
            registry.listFederatedContract(
                _l(artistId, token, 0, canonical[i], 10_000, feeVault),
                _ok(_l(artistId, token, 0, canonical[i], 10_000, feeVault))
            );
            _expectRefused(token);
            registry.listFederatedContract(
                _l(artistId, token, 0, address(0), 10_000, canonical[i]),
                _ok(_l(artistId, token, 0, address(0), 10_000, canonical[i]))
            );
            (, IArtistRegistry.FederationStatus status) = registry.federatedListing(canonical[i]);
            assertEq(uint8(status), uint8(IArtistRegistry.FederationStatus.NONE));
        }
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- status and exit

    function test_Status_DelistAndRelist() public {
        _list();
        vm.startPrank(federation);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.FederatedContractStatus(
            token,
            artistId,
            IArtistRegistry.FederationStatus.ACTIVE,
            IArtistRegistry.FederationStatus.DELISTED,
            "vote 1"
        );
        registry.setFederatedStatus(token, IArtistRegistry.FederationStatus.DELISTED, "vote 1");
        vm.expectEmit(address(registry));
        emit IArtistRegistry.FederatedContractStatus(
            token,
            artistId,
            IArtistRegistry.FederationStatus.DELISTED,
            IArtistRegistry.FederationStatus.ACTIVE,
            "vote 2"
        );
        registry.setFederatedStatus(token, IArtistRegistry.FederationStatus.ACTIVE, "vote 2");
        vm.stopPrank();
        (, IArtistRegistry.FederationStatus status) = registry.federatedListing(token);
        assertEq(uint8(status), uint8(IArtistRegistry.FederationStatus.ACTIVE));
    }

    function test_Status_Refusals() public {
        vm.startPrank(federation);
        _expectStatusRefused(token, IArtistRegistry.FederationStatus.NONE);
        registry.setFederatedStatus(token, IArtistRegistry.FederationStatus.DELISTED, "");
        vm.stopPrank();
        _list();
        vm.startPrank(federation);
        _expectStatusRefused(token, IArtistRegistry.FederationStatus.ACTIVE);
        registry.setFederatedStatus(token, IArtistRegistry.FederationStatus.NONE, "");
        _expectStatusRefused(token, IArtistRegistry.FederationStatus.ACTIVE);
        registry.setFederatedStatus(token, IArtistRegistry.FederationStatus.LEFT, "");
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnboundCaller.selector, stranger));
        vm.prank(stranger);
        registry.setFederatedStatus(token, IArtistRegistry.FederationStatus.DELISTED, "");
    }

    /// @dev Exit is written by the token alone, is terminal, and survives a replacement of the
    ///      federation registry: no registry, old or new, can bring the entry back.
    function test_Exit_ByTheTokenIsTerminal() public {
        _list();
        vm.prank(federation);
        registry.setFederatedStatus(token, IArtistRegistry.FederationStatus.DELISTED, "vote");
        address next = address(new FederationRegistryStub());
        vm.prank(successorSetter);
        registry.setFederationRegistry(federation, next);

        // Left while delisted: LEFT_DELISTED, never more served than DELISTED.
        vm.expectEmit(address(registry));
        emit IArtistRegistry.FederatedContractStatus(
            token,
            artistId,
            IArtistRegistry.FederationStatus.DELISTED,
            IArtistRegistry.FederationStatus.LEFT_DELISTED,
            bytes32(0)
        );
        vm.prank(token);
        registry.recordFederationExit();
        // A repeat does nothing and emits nothing.
        vm.recordLogs();
        vm.prank(token);
        registry.recordFederationExit();
        assertEq(vm.getRecordedLogs().length, 0);

        vm.startPrank(next);
        _expectStatusRefused(token, IArtistRegistry.FederationStatus.LEFT_DELISTED);
        registry.setFederatedStatus(token, IArtistRegistry.FederationStatus.ACTIVE, "");
        _expectRefused(token);
        registry.listFederatedContract(
            _l(artistId, token, 0, address(0), 10_000, feeVault),
            _ok(_l(artistId, token, 0, address(0), 10_000, feeVault))
        );
        vm.stopPrank();
        (, IArtistRegistry.FederationStatus status) = registry.federatedListing(token);
        assertEq(uint8(status), uint8(IArtistRegistry.FederationStatus.LEFT_DELISTED));
    }

    /// @dev An exit from ACTIVE is LEFT, terminal too.
    function test_Exit_FromActiveIsLeft() public {
        _list();
        vm.expectEmit(address(registry));
        emit IArtistRegistry.FederatedContractStatus(
            token,
            artistId,
            IArtistRegistry.FederationStatus.ACTIVE,
            IArtistRegistry.FederationStatus.LEFT,
            bytes32(0)
        );
        vm.prank(token);
        registry.recordFederationExit();
        // A relisting never reverses an exit.
        vm.prank(federation);
        _expectStatusRefused(token, IArtistRegistry.FederationStatus.LEFT);
        registry.setFederatedStatus(token, IArtistRegistry.FederationStatus.ACTIVE, "");
    }

    /// @dev Review G (G1): a delisting decided before an exit still lands on the exited entry,
    ///      as LEFT_DELISTED (previous LEFT), which nothing reverses.
    function test_Status_ADelistingOfALeftEntryLandsAsLeftDelisted() public {
        _list();
        vm.prank(token);
        registry.recordFederationExit();
        vm.expectEmit(address(registry));
        emit IArtistRegistry.FederatedContractStatus(
            token,
            artistId,
            IArtistRegistry.FederationStatus.LEFT,
            IArtistRegistry.FederationStatus.LEFT_DELISTED,
            "vote"
        );
        vm.startPrank(federation);
        registry.setFederatedStatus(token, IArtistRegistry.FederationStatus.DELISTED, "vote");
        (, IArtistRegistry.FederationStatus status) = registry.federatedListing(token);
        assertEq(uint8(status), uint8(IArtistRegistry.FederationStatus.LEFT_DELISTED));
        _expectStatusRefused(token, IArtistRegistry.FederationStatus.LEFT_DELISTED);
        registry.setFederatedStatus(token, IArtistRegistry.FederationStatus.ACTIVE, "");
        _expectStatusRefused(token, IArtistRegistry.FederationStatus.LEFT_DELISTED);
        registry.setFederatedStatus(token, IArtistRegistry.FederationStatus.DELISTED, "");
        vm.stopPrank();
    }

    function test_Exit_RevertsForAnUnlistedCaller() public {
        _expectStatusRefused(stranger, IArtistRegistry.FederationStatus.NONE);
        vm.prank(stranger);
        registry.recordFederationExit();
        // Only the token: the federation registry cannot exit it.
        _list();
        _expectStatusRefused(federation, IArtistRegistry.FederationStatus.NONE);
        vm.prank(federation);
        registry.recordFederationExit();
    }

    // ----------------------------------------------------------------- no authority

    /// @dev A bound federation registry, however hostile, reaches no identity path: every
    ///      governed or artist call refuses it, and its own calls leave the artist untouched.
    function test_HostileFederationRegistry_HasNoAuthorityOverArtists() public {
        _stage(artistKey, _identity(artist, payout), 0);
        bytes32 before = _artistState();
        vm.startPrank(federation);
        _expectUnauthorized();
        registry.stageOverride(
            artistId, ChangeKind.CONTESTED, _identity(federation, federation), "e", 0, ""
        );
        _expectUnauthorized();
        registry.vetoChange(artistId);
        _expectUnauthorized();
        registry.setTimer(IArtistRegistry.Timer.CHANGE_DELAY, 30 days);
        _expectUnauthorized();
        registry.setConsolidationSource(adapter, adapter, address(adapter).codehash);
        _expectUnauthorized();
        registry.setFederationRegistry(federation, federation);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnboundCaller.selector, federation));
        registry.register(federation, PROFILE, PROFILE_DOC);
        vm.expectRevert(_notAuthorized(federation));
        registry.cancelChange(artistId);
        vm.expectRevert(_notAuthorized(federation));
        registry.heartbeat(artistId);
        vm.expectRevert(_notAuthorized(federation));
        registry.revokeNonce(artistId);
        // What it may do: write directory entries about other contracts.
        registry.listFederatedContract(
            _l(artistId, token, 0, address(0), 10_000, feeVault),
            _ok(_l(artistId, token, 0, address(0), 10_000, feeVault))
        );
        registry.setFederatedStatus(token, IArtistRegistry.FederationStatus.DELISTED, "");
        vm.stopPrank();
        assertEq(_artistState(), before, "the artist is untouched");
        vm.warp(block.timestamp + 7 days);
        registry.executeChange(artistId);
        assertEq(registry.payoutAddress(artistId), payout, "the artist's change still applies");
    }

    // ----------------------------------------------------------------- helpers

    /// @dev The artist's consent to `t` listed under `id`, by the artist's key, computed here
    ///      (no call, so a pending prank stays on the listing call).
    /// @dev A listing's facts with this test's deadline.
    function _l(
        uint256 id,
        address t,
        uint8 form,
        address partner_,
        uint32 share,
        address recipient
    ) internal pure returns (IArtistRegistry.FederatedListing memory) {
        return IArtistRegistry.FederatedListing(id, t, form, partner_, share, recipient, DEADLINE);
    }

    function _ok(IArtistRegistry.FederatedListing memory l) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("6529 Works Artist Registry"),
                keccak256("1"),
                block.chainid,
                address(registry)
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked(hex"1901", domain, keccak256(abi.encode(LISTING, l))));
        return _sign(artistKey, digest);
    }

    function _list() internal {
        vm.prank(federation);
        registry.listFederatedContract(
            _l(artistId, token, 0, partner, 10_000, feeVault),
            _ok(_l(artistId, token, 0, partner, 10_000, feeVault))
        );
    }

    function _consent(uint256 key, address account, uint64 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(key, registry.registrationDigest(account, PROFILE, PROFILE_DOC, deadline));
    }

    function _expectRefused(address t) internal {
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.FederatedContractRefused.selector, t)
        );
    }

    function _expectStatusRefused(address t, IArtistRegistry.FederationStatus current) internal {
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.FederatedStatusRefused.selector, t, current)
        );
    }

    function _expectUnauthorized() internal {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, federation)
        );
    }

    function _notAuthorized(address account) internal view returns (bytes memory) {
        return abi.encodeWithSelector(IArtistRegistry.NotAuthorized.selector, artistId, account);
    }

    function _artistState() internal view returns (bytes32) {
        (ArtistIdentity memory identity, uint64 last) = registry.artist(artistId);
        return keccak256(
            abi.encode(
                identity,
                last,
                registry.pendingChange(artistId),
                registry.standingOf(artistId),
                registry.changeNonce(artistId),
                registry.payoutAddress(artistId),
                registry.activeAuthorityOf(artistId)
            )
        );
    }
}

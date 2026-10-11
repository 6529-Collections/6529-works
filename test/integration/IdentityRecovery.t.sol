// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IClaimRouter } from "src/economics/interfaces/IClaimRouter.sol";
import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { CURRENCY_ETH, PRODUCT_STREAM } from "src/interfaces/types/EconomicsTypes.sol";
import {
    ArtistIdentity,
    ChangeKind,
    PendingChange,
    Standing
} from "src/interfaces/types/IdentityTypes.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Flow 4 (integration brief, lane B): artist identity and recovery on the real
///         contracts, with the 6529 delegation contract as the identity lane's faithful mock.
///         Registration through a package acceptance, consolidation standing, a STANDARD change
///         staged by a consolidated wallet, cancels, execution, the payout freeze while a change
///         or an override is pending, a sticky-standing scenario against a key thief, and the
///         split-wallet pull by the recovered identity.
contract IdentityRecoveryFlowTest is IntegrationBase {
    address internal constant ALL = 0x8888888888888888888888888888888888888888;
    uint256 internal constant CONSOLIDATION = 999;

    address internal artist;
    address internal wallet;
    address internal newKey;
    address internal thief;
    address internal collector = makeAddr("identityCollector");
    uint256 internal artistId;
    bytes32 internal root;
    address internal seller;

    function setUp() public override {
        super.setUp();
        artist = _actor("recoveringArtist");
        wallet = _actor("consolidatedWallet");
        newKey = _actor("newAuthority");
        thief = _actor("keyThief");
        artistId = uint160(artist);
        // A two-way 6529 consolidation (use case 999, all collections) before registration.
        _consolidate(artist, wallet);

        Work[] memory works = new Work[](3);
        for (uint256 i; i < 3; ++i) {
            works[i] = _work(artist, collectionId);
        }
        root = _publish(works);
        _keep(root, works);
        seller = economics.newWorkTerms(PRODUCT_STREAM, works[0].item.payees).seller;
        // One sale accrues 0.75 ETH in the artist's (artist-resolved) seller wallet.
        _sell(root, works, 0, collector, 1 ether);
        splitFactory.createWallet(works[0].item.payees, bytes32(0));
        assertEq(seller.balance, 0.75 ether);
    }

    function _consolidate(address a, address b) internal {
        vm.prank(a);
        delegation.registerDelegationAddress(ALL, b, type(uint64).max, CONSOLIDATION, true, 0);
        vm.prank(b);
        delegation.registerDelegationAddress(ALL, a, type(uint64).max, CONSOLIDATION, true, 0);
    }

    function _identity(address authority) internal view returns (ArtistIdentity memory) {
        return ArtistIdentity(authority, authority, _profileId(artist), _profileDoc(artist));
    }

    /// @dev `signer` (the authority or an established wallet) stages a STANDARD change to
    ///      `next`, which `next`'s authority countersigns.
    function _stage(address signer, address next) internal {
        ArtistIdentity memory id = _identity(next);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = artists.changeDigest(artistId, id, artists.changeNonce(artistId), deadline);
        artists.stageChange(
            artistId, id, signer, deadline, _sign(signer, digest), _sign(next, digest)
        );
    }

    function test_RegistrationRecordsYoungConsolidationAsPending() public {
        (ArtistIdentity memory id,) = artists.artist(artistId);
        assertEq(id.authority, artist, "created by the first package acceptance");
        assertEq(id.payout, artist);
        Standing[] memory standing = artists.standingOf(artistId);
        assertEq(standing.length, 1);
        assertEq(standing[0].wallet, wallet);
        assertGt(standing[0].effectiveAt, block.timestamp, "pending until 30 days old");
        assertFalse(consolidation.isEstablished(artist, wallet));
        vm.warp(block.timestamp + 30 days);
        assertTrue(consolidation.isEstablished(artist, wallet));
    }

    function test_RecoveryByConsolidatedWalletThenSplitWalletPull() public {
        vm.warp(block.timestamp + 31 days);
        _stage(wallet, newKey);
        PendingChange memory p = artists.pendingChange(artistId);
        assertEq(uint8(p.kind), uint8(ChangeKind.STANDARD));
        assertEq(p.cancellers.length, 1, "the established wallet is captured at staging");
        assertEq(p.cancellers[0], wallet);

        // Payout freeze: the pending change moves the payout, so nothing resolves.
        assertEq(artists.payoutAddress(artistId), address(0));
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayoutUnresolved.selector, artistId));
        ISplitWallet(seller).release(CURRENCY_ETH, 0);

        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.ChangeNotDue.selector, artistId, p.executableAt)
        );
        artists.executeChange(artistId);
        vm.warp(p.executableAt);
        artists.executeChange(artistId);
        assertEq(artists.authorityOf(artistId), newKey);
        assertEq(artists.payoutAddress(artistId), newKey);

        // The accrued balance follows the new payout; the old key cannot pull it.
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, artist, newKey)
        );
        ISplitWallet(seller).release(CURRENCY_ETH, 0);
        vm.prank(newKey);
        ISplitWallet(seller).release(CURRENCY_ETH, 0);
        assertEq(newKey.balance, 0.75 ether, "recovered identity pulls the accrued balance");

        // The new authority signs moves; a move signed by the old key no longer verifies.
        Work[] memory works = _package(root);
        uint256 nonce = nextMoveNonce[artistId]++;
        bytes memory stale = _mintDataSignedBy(root, works, 1, artist, nonce);
        vm.expectRevert(IPackageRegistry.InvalidSignature.selector);
        auction.start(address(stream), stale);
        auction.start(address(stream), _mintDataSignedBy(root, works, 1, newKey, nonce));
        assertEq(stream.ownerOf(stream.totalMinted()), address(auction));
    }

    function test_OldKeyAndCapturedWalletCancel() public {
        vm.warp(block.timestamp + 31 days);
        _stage(wallet, newKey);
        vm.prank(artist);
        artists.cancelChange(artistId);
        assertEq(uint8(artists.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        assertEq(artists.payoutAddress(artistId), artist, "the freeze lifts");

        _stage(artist, newKey);
        vm.prank(wallet);
        artists.cancelChange(artistId);
        assertEq(uint8(artists.pendingChange(artistId).kind), uint8(ChangeKind.NONE));

        _stage(artist, newKey);
        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.NotAuthorized.selector, artistId, collector)
        );
        artists.cancelChange(artistId);
        vm.prank(guardian2);
        artists.vetoChange(artistId);
        assertEq(
            uint8(artists.pendingChange(artistId).kind), uint8(ChangeKind.NONE), "guardian veto"
        );
    }

    /// @dev A thief holding the artist's key revokes the consolidation, then stages a change to
    ///      itself. The wallet keeps its standing for 30 days after it goes missing, is captured
    ///      at staging, and cancels.
    function test_StickyStandingDefeatsAKeyThief() public {
        vm.warp(block.timestamp + 31 days);
        artists.refreshStanding(artistId);
        vm.prank(artist); // the thief, with the stolen key
        delegation.revokeDelegationAddress(ALL, wallet, CONSOLIDATION);
        artists.refreshStanding(artistId);
        Standing[] memory standing = artists.standingOf(artistId);
        assertEq(standing.length, 1);
        assertGt(standing[0].missingSince, 0, "missing, but standing within the grace");

        vm.warp(block.timestamp + 10 days);
        _stage(artist, thief);
        assertEq(artists.pendingChange(artistId).cancellers[0], wallet, "captured at staging");
        vm.prank(wallet);
        artists.cancelChange(artistId);
        assertEq(artists.authorityOf(artistId), artist, "the thief's change never executes");

        // After the grace a refresh removes the wallet.
        vm.warp(block.timestamp + 30 days);
        artists.refreshStanding(artistId);
        assertEq(artists.standingOf(artistId).length, 0);
    }

    /// @dev A lost key with no usable consolidation: after a year without the artist's own
    ///      activity, PARAMETER_SETTER stages a 180-day LOST_KEY override (48-hour class) that the
    ///      new authority accepted; the payout is frozen for the whole notice, then follows.
    function test_LostKeyOverrideFreezesThePayoutThenRecovers() public {
        vm.prank(artist);
        delegation.revokeDelegationAddress(ALL, wallet, CONSOLIDATION);
        vm.warp(block.timestamp + 366 days);
        ArtistIdentity memory next = _identity(newKey);
        bytes32 evidence = keccak256("estate and lost-key evidence, public notice");
        uint64 deadline = uint64(block.timestamp + 7 days);
        bytes memory acceptance = _sign(
            newKey, artists.overrideDigest(artistId, ChangeKind.LOST_KEY, next, evidence, deadline)
        );
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(
                artists.stageOverride,
                (artistId, ChangeKind.LOST_KEY, next, evidence, deadline, acceptance)
            )
        );
        PendingChange memory p = artists.pendingChange(artistId);
        assertEq(uint8(p.kind), uint8(ChangeKind.LOST_KEY));
        assertEq(p.executableAt, p.stagedAt + 180 days);
        assertEq(artists.payoutAddress(artistId), address(0), "frozen during the notice");
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.NotAuthorized.selector, artistId, artist)
        );
        artists.cancelChange(artistId); // the old key cannot cancel an override

        vm.warp(p.executableAt);
        artists.executeChange(artistId);
        vm.prank(newKey);
        ISplitWallet(seller).release(CURRENCY_ETH, 0);
        assertEq(newKey.balance, 0.75 ether);
    }

    function _authorization(address account, address recipient, uint256 amount, uint256 nonce)
        internal
        view
        returns (IClaimRouter.SignedClaim[] memory claims)
    {
        IReleaseVerifier.Authorization memory a = IReleaseVerifier.Authorization(
            seller, CURRENCY_ETH, 0, account, recipient, amount, nonce, block.timestamp + 30 days
        );
        claims = new IClaimRouter.SignedClaim[](1);
        claims[0] = IClaimRouter.SignedClaim(a, _sign(account, releaseVerifier.releaseDigest(a)));
    }

    /// @dev The artist's signed release authorization, relayed through the claim router, pays
    ///      only while its signer is the current payout address: recovery voids the old key's.
    function test_SignedReleaseIsVoidedByRecovery() public {
        address vault = makeAddr("artistVault");
        vm.prank(makeAddr("relayer"));
        claimRouter.claimSigned(_authorization(artist, vault, 0.25 ether, 1), false);
        assertEq(vault.balance, 0.25 ether, "relayed signed release");
        IClaimRouter.SignedClaim[] memory stale = _authorization(artist, thief, 0.5 ether, 2);

        vm.warp(block.timestamp + 31 days);
        _stage(wallet, newKey);
        vm.warp(block.timestamp + 7 days);
        artists.executeChange(artistId);
        bytes memory reason =
            abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, artist, newKey);
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimRouter.ClaimCallFailed.selector, 0, seller, reason.length, reason
            )
        );
        claimRouter.claimSigned(stale, false);
        claimRouter.claimSigned(_authorization(newKey, newKey, 0.5 ether, 1), false);
        assertEq(newKey.balance, 0.5 ether);
        assertEq(thief.balance, 0);
    }
}

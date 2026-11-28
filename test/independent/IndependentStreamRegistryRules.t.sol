// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { IndependentStreamEditions6529 } from "src/independent/IndependentStreamEditions6529.sol";
import { IndependentStream6529 } from "src/independent/IndependentStream6529.sol";
import { IIndependentStreamMembership } from "src/interfaces/IIndependentStreamMembership.sol";
import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { MockRenderer } from "../mocks/core/CoreMocks.sol";
import { IndependentStreamFixture } from "./IndependentStreamFixture.sol";

/// @notice Rules of `docs/spec/independent-stream.md` on the real Independent Stream module, the
///         real accounts module and the real token pair: a copy runs the approved code (IND-1),
///         an artist power needs a wallet of the account now and none acts while it is frozen
///         (IND-3), an artist-resolved payee needs a payout address now (IND-60), and an account
///         delisting leaves identity, payout and 6529 Stream alone (IND-51, ID-13).
contract IndependentStreamRegistryRulesTest is IndependentStreamFixture {
    uint256 internal otherId;

    function setUp() public override {
        super.setUp();
        otherId = uint256(uint160(other));
    }

    function _notArtist(address caller) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IIndependentStreamMembership.NotArtist.selector, caller);
    }

    /// @dev What the accounts module and the directory answer about an account.
    function _identity(uint256 id, address root) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                accountsModule.artistIdOf(root),
                accountsModule.authorityOf(id),
                accountsModule.activeAuthorityOf(id),
                accountsModule.payoutAddress(id),
                indDirectory.payoutAddress(id),
                accountsModule.isWallet(id, root)
            )
        );
    }

    // ------------------------------------------------------------------ the approved code

    /// A copy the approved deployer creates has exactly the runtime code of the template built
    /// with the same arguments, the deployer commits to the template's creation code, and the
    /// module reports the copy's code hash (IND-1).
    function test_Deploy_ACopyRunsTheApprovedCode() public {
        assertEq(streamDeployer.creationHash(), keccak256(type(IndependentStream6529).creationCode));
        assertEq(
            editionsDeployer.creationHash(),
            keccak256(type(IndependentStreamEditions6529).creationCode)
        );
        IndependentStream6529 built = new IndependentStream6529(
            "Artist Works",
            "ART",
            address(facts),
            address(indDirectory),
            fArtistId,
            marketOwner,
            address(renderer)
        );
        assertEq(address(fStream).codehash, address(built).codehash, "the 1/1 template");
        IndependentStreamEditions6529 builtEditions = new IndependentStreamEditions6529(
            "Artist Editions",
            "ARTED",
            address(fStream),
            address(indDirectory),
            fArtistId,
            marketOwner
        );
        assertEq(
            address(fEditions).codehash, address(builtEditions).codehash, "the editions template"
        );
        assertTrue(streamDeployer.deployed(address(fStream)));
        assertEq(registry.entry(address(fStream)).codeHash, address(fStream).codehash);
        assertEq(registry.entry(address(fEditions)).codeHash, address(fEditions).codehash);

        // The same code built outside the deployer is not a copy: the deployer did not record it.
        assertFalse(streamDeployer.deployed(address(built)));
        IIndependentStreamRegistry.Join memory j =
            _joinData(address(built), artistKey, artistKey, address(streamDeployer));
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamRegistry.NotListable.selector, address(built))
        );
        registry.register(address(built), j);
    }

    // ------------------------------------------------------------------ artist powers

    /// Every artist function of the 1/1 token and of the editions token is open to any wallet of
    /// the artist's account and refused (`NotArtist`) for all of them while the account is frozen;
    /// the power returns when the freeze ends (IND-3).
    function test_ArtistPowers_AnyWalletOfTheAccountAndNoneWhileFrozen() public {
        MockRenderer next = new MockRenderer();
        vm.prank(wallet);
        fStream.setContractURI("ipfs://before");
        vm.prank(artist);
        fEditions.setContractURI("ipfs://editions");
        vm.prank(wallet);
        fStream.proposeModule(Slots.RENDERER, address(next));

        accountsModule.freeze(fArtistId);
        address[2] memory callers = [artist, wallet];
        for (uint256 i; i < callers.length; ++i) {
            address caller = callers[i];
            vm.startPrank(caller);
            vm.expectRevert(_notArtist(caller));
            fStream.setOwner(caller);
            vm.expectRevert(_notArtist(caller));
            fStream.setContractURI("ipfs://frozen");
            vm.expectRevert(_notArtist(caller));
            fStream.proposeModule(Slots.RENDERER, address(next));
            vm.expectRevert(_notArtist(caller));
            fStream.cancelModule(Slots.RENDERER);
            vm.expectRevert(_notArtist(caller));
            fStream.removeModule(Slots.RENDERER);
            vm.expectRevert(_notArtist(caller));
            fEditions.setOwner(caller);
            vm.expectRevert(_notArtist(caller));
            fEditions.setContractURI("ipfs://frozen");
            vm.stopPrank();
        }
        assertEq(fStream.contractURI(), "ipfs://before");
        assertEq(fStream.owner(), marketOwner);
        assertEq(fStream.moduleOf(Slots.RENDERER), address(renderer));
        assertEq(fStream.pendingModule(Slots.RENDERER).module, address(next), "still announced");

        accountsModule.unfreeze(fArtistId);
        vm.prank(wallet);
        fStream.cancelModule(Slots.RENDERER);
        assertEq(fStream.pendingModule(Slots.RENDERER).readyAt, 0);
        vm.prank(artist);
        fEditions.setOwner(artist);
        assertEq(fEditions.owner(), artist);
    }

    /// The question is asked at every call: a wallet that stops being consolidated with the
    /// artist's account loses the artist's functions at once, and the root keeps them (IND-3).
    function test_ArtistPowers_AWalletNoLongerOfTheAccountIsRefusedAtOnce() public {
        vm.prank(wallet);
        fStream.setContractURI("ipfs://consolidated");
        vm.prank(artist);
        delegation.revokeDelegationAddress(ALL, wallet, CONSOLIDATION);
        assertFalse(accountsModule.isWallet(fArtistId, wallet));
        vm.prank(wallet);
        vm.expectRevert(_notArtist(wallet));
        fStream.setContractURI("ipfs://gone");
        vm.prank(wallet);
        vm.expectRevert(_notArtist(wallet));
        fEditions.setContractURI("ipfs://gone");
        vm.prank(artist);
        fStream.setContractURI("ipfs://root");
        assertEq(fStream.contractURI(), "ipfs://root");
    }

    // ------------------------------------------------------------------ payees

    /// A payee paid through its account must have a payout address when the work is minted: a
    /// collaborator with no identity has none, so the mint is refused (`InvalidMintRequest`); once
    /// the collaborator has an identity the same item mints (IND-60).
    function test_Authorize_AnArtistResolvedPayeeNeedsAPayoutAddressNow() public {
        address[] memory collaborators = new address[](1);
        collaborators[0] = collab;
        (PackageItem memory item, MediaFile[] memory media) = _itemOf(1, 0, collaborators);
        uint256 collabId = uint256(uint160(collab));
        item.payees[0] = ISplitWallet.Payee(collabId, address(0), 100_000);
        _approve(address(fStream), item, RATE);
        bytes[] memory consents = new bytes[](1);
        consents[0] = _consent(collabKey, address(fStream), item, RATE);
        bytes memory request = _request(item, media, consents);

        assertEq(accountsModule.payoutAddress(collabId), address(0), "no payout address yet");
        vm.expectRevert(IIndependentStreamRegistry.InvalidMintRequest.selector);
        indSale.start(address(registry), address(fStream), request);
        assertEq(fStream.totalMinted(), 0);

        vm.prank(packageRegistry);
        accountsModule.register(collab, PROFILE, PROFILE_DOC);
        assertEq(accountsModule.payoutAddress(collabId), collab);
        (uint256 id,,) = indSale.start(address(registry), address(fStream), request);
        assertEq(fStream.ownerOf(id), address(indSale));
        assertEq(fStream.workOf(id).artistId, fArtistId, "the work names the contract's artist");
    }

    // ------------------------------------------------------------------ account delisting

    /// An artist with a 6529 Stream identity lists an Independent Stream contract and is then
    /// delisted by account: every contract of the account reads DELISTED and no new one is listed,
    /// while the account's identity and payout, and 6529 Stream's minters and works, are exactly
    /// as before (IND-51, ID-13).
    function test_SetAccountDelisted_LeavesIdentityPayoutAndStreamAlone() public {
        vm.prank(packageRegistry);
        accountsModule.register(other, PROFILE, PROFILE_DOC);
        bytes32 identity = _identity(otherId, other);
        uint256 streamWork = _sell(1, collector);
        bytes32 streamFacts = keccak256(abi.encode(stream.workOf(streamWork)));

        IndependentStream6529 first = _deployStream(otherId, keccak256("first"));
        IIndependentStreamRegistry.Join memory j =
            _joinData(address(first), otherKey, otherKey, address(streamDeployer));
        assertEq(j.registration.length, 0, "the identity exists: listing creates none");
        registry.register(address(first), j);
        IndependentStreamEditions6529 firstEditions =
            _deployEditions(address(first), otherId, keccak256("first editions"));
        _join(address(firstEditions), otherKey, otherKey, address(editionsDeployer));
        assertEq(_identity(otherId, other), identity, "listing changed the identity");

        registry.setAccountDelisted(otherId, true, "decision");
        assertEq(
            uint8(registry.entry(address(first)).status),
            uint8(IIndependentStreamRegistry.Status.DELISTED)
        );
        assertEq(
            uint8(registry.entry(address(firstEditions)).status),
            uint8(IIndependentStreamRegistry.Status.DELISTED)
        );
        assertFalse(first.isMinter(address(indSale)));
        assertFalse(firstEditions.isMinter(address(indEdSale)));
        IndependentStream6529 second = _deployStream(otherId, keccak256("second"));
        IIndependentStreamRegistry.Join memory j2 =
            _joinData(address(second), otherKey, otherKey, address(streamDeployer));
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamRegistry.NotListable.selector, address(second))
        );
        registry.register(address(second), j2);

        // Identity and payout are untouched; another account's contracts are still listed.
        assertEq(_identity(otherId, other), identity, "delisting changed the identity");
        assertEq(indDirectory.payoutAddress(otherId), other);
        assertTrue(fStream.isMinter(address(indSale)), "another account is not delisted");
        // 6529 Stream is untouched: its minter still mints and its works are as they were.
        assertTrue(stream.isMinter(address(sale)));
        assertEq(keccak256(abi.encode(stream.workOf(streamWork))), streamFacts);
        assertEq(stream.ownerOf(streamWork), collector);
        assertEq(stream.ownerOf(_mint(2)), address(sale));
    }
}

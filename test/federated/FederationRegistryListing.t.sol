// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FederatedDeployer } from "src/federated/FederatedDeployer.sol";
import { FederatedEditions } from "src/federated/FederatedEditions.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { FederationRegistry } from "src/federated/FederationRegistry.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { FederationFixture } from "./FederationFixture.sol";

/// @notice Listing federated contracts, and a replacement module inheriting the listings.
contract FederationRegistryListingTest is FederationFixture {
    uint256 internal otherId;
    uint256 internal other2Key = 0xE5;

    function setUp() public override {
        super.setUp();
        otherId = uint256(uint160(other));
    }

    function _notListable(address token) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IFederationRegistry.NotListable.selector, token);
    }

    function _tokens(address a) internal pure returns (address[] memory t) {
        t = new address[](1);
        t[0] = a;
    }

    /// @dev Deploys and lists `other`'s stream, creating `other`'s identity.
    function _otherStream() internal returns (FederatedStream t) {
        t = _deployStream(otherId, keccak256("other"));
        _join(address(t), otherKey, otherKey, address(streamDeployer));
    }

    // ------------------------------------------------------------------ happy paths

    function test_Register_StreamOfANewArtistCreatesItsIdentity() public {
        FederatedStream t = _deployStream(otherId, keccak256("other"));
        IFederationRegistry.Join memory j =
            _joinData(address(t), otherKey, otherKey, address(streamDeployer));
        assertGt(j.registration.length, 0);
        vm.expectEmit(address(registry));
        emit IFederationRegistry.Registered(
            address(t),
            otherId,
            address(streamDeployer),
            IFederationRegistry.Form.ERC721,
            address(0),
            SHARE
        );
        vm.prank(stranger); // anyone relays
        registry.register(address(t), j);
        assertEq(accountsModule.artistIdOf(other), otherId, "identity created");
        IFederationRegistry.Listing memory l = registry.listingOf(address(t));
        assertEq(uint256(l.artistId), otherId);
        assertEq(uint8(l.status), uint8(IFederationRegistry.Status.ACTIVE));
        assertEq(l.feeShare, SHARE);
        assertEq(l.deployer, address(streamDeployer));
        assertEq(l.partner, address(0));
    }

    function test_Register_ARegisteredArtistNeedsNoRegistration() public {
        FederatedStream t = _deployStream(fArtistId, keccak256("second"));
        IFederationRegistry.Join memory j =
            _joinData(address(t), artistKey, artistKey, address(streamDeployer));
        assertEq(j.registration.length, 0);
        registry.register(address(t), j);
        assertTrue(registry.isActive(address(t)));
    }

    function test_Register_EditionsRecordThePartnerBothWays() public view {
        assertEq(registry.listingOf(address(fEditions)).partner, address(fStream));
        assertEq(registry.listingOf(address(fStream)).partner, address(fEditions));
        assertEq(
            uint8(registry.listingOf(address(fEditions)).form),
            uint8(IFederationRegistry.Form.ERC1155)
        );
    }

    function test_Register_ShareIsTheEconomicsShareAtListing() public {
        econ.setFeeShare(7_000);
        FederatedStream t = _otherStream();
        assertEq(registry.feeShareOf(address(t)), 7_000);
        assertEq(registry.feeShareOf(address(fStream)), SHARE, "earlier listings unchanged");
    }

    function test_Register_AConsolidatedWalletOfANewArtistMayConsent() public {
        address other2 = vm.addr(other2Key);
        _consolidate(other, other2);
        FederatedStream t = _deployStream(otherId, keccak256("other"));
        _join(address(t), other2Key, otherKey, address(streamDeployer));
        assertTrue(registry.isActive(address(t)));
    }

    // ------------------------------------------------------------------ refusals

    function test_Register_RefusesAListedContract() public {
        IFederationRegistry.Join memory j =
            _joinData(address(fStream), artistKey, artistKey, address(streamDeployer));
        vm.expectRevert(_notListable(address(fStream)));
        registry.register(address(fStream), j);
    }

    function test_Register_RefusesAnUnapprovedDeployer() public {
        FederatedDeployer d = new FederatedDeployer(type(FederatedStream).creationCode);
        bytes memory config = abi.encode(
            "x", "X", address(facts), address(fedDirectory), otherId, marketOwner, address(renderer)
        );
        address t = d.deploy(0, config);
        // the join is built against the approved form; only the deployer differs
        IFederationRegistry.Join memory j =
            _joinData(t, otherKey, otherKey, address(streamDeployer));
        j.deployer = address(d);
        vm.expectRevert(_notListable(t));
        registry.register(t, j);
    }

    function test_Register_RefusesASuspendedOrRevokedDeployer() public {
        FederatedStream t = _deployStream(otherId, keccak256("other"));
        IFederationRegistry.Join memory j =
            _joinData(address(t), otherKey, otherKey, address(streamDeployer));
        registry.suspendTemplate(address(streamDeployer));
        vm.expectRevert(_notListable(address(t)));
        registry.register(address(t), j);
        registry.revokeTemplate(address(streamDeployer));
        vm.expectRevert(_notListable(address(t)));
        registry.register(address(t), j);
        registry.reinstateTemplate(address(streamDeployer));
        registry.register(address(t), j);
    }

    function test_Register_RefusesATokenTheDeployerDidNotRecord() public {
        FederatedStream t = new FederatedStream(
            "x", "X", address(facts), address(fedDirectory), otherId, marketOwner, address(renderer)
        );
        IFederationRegistry.Join memory j =
            _joinData(address(t), otherKey, otherKey, address(streamDeployer));
        vm.expectRevert(_notListable(address(t)));
        registry.register(address(t), j);
    }

    function test_Register_RefusesTheWrongEditionsDeployer() public {
        FederatedStream t = _otherStream();
        FederatedEditions e = _deployEditions(address(t), otherId, keccak256("e"));
        IFederationRegistry.Join memory j =
            _joinData(address(e), otherKey, otherKey, address(editionsDeployer));
        j.deployer = address(streamDeployer); // approved, but it did not record the editions
        vm.expectRevert(_notListable(address(e)));
        registry.register(address(e), j);
    }

    function test_Register_RefusesAnotherDirectory() public {
        bytes memory config = abi.encode(
            "x", "X", address(facts), address(directory), otherId, marketOwner, address(renderer)
        );
        address t = streamDeployer.deploy(keccak256("dir"), config);
        IFederationRegistry.Join memory j =
            _joinData(t, otherKey, otherKey, address(streamDeployer));
        vm.expectRevert(_notListable(t));
        registry.register(t, j);
    }

    function test_Register_RefusesAnotherRecordContract() public {
        bytes memory config = abi.encode(
            "x",
            "X",
            address(0xFAC7),
            address(fedDirectory),
            otherId,
            marketOwner,
            address(renderer)
        );
        address t = streamDeployer.deploy(keccak256("facts"), config);
        IFederationRegistry.Join memory j =
            _joinData(t, otherKey, otherKey, address(streamDeployer));
        vm.expectRevert(_notListable(t));
        registry.register(t, j);
    }

    function test_Register_RefusesADelistedAccount() public {
        registry.setAccountDelisted(otherId, true, 0);
        FederatedStream t = _deployStream(otherId, keccak256("other"));
        IFederationRegistry.Join memory j =
            _joinData(address(t), otherKey, otherKey, address(streamDeployer));
        vm.expectRevert(_notListable(address(t)));
        registry.register(address(t), j);
        registry.setAccountDelisted(otherId, false, 0);
        registry.register(address(t), j);
    }

    function test_Register_RefusesEditionsBeforeTheirStream() public {
        FederatedStream t = _deployStream(otherId, keccak256("other"));
        FederatedEditions e = _deployEditions(address(t), otherId, keccak256("e"));
        IFederationRegistry.Join memory j =
            _joinData(address(e), otherKey, otherKey, address(editionsDeployer));
        vm.expectRevert(_notListable(address(e)));
        registry.register(address(e), j);
    }

    function test_Register_RefusesEditionsOfAnotherArtistsStream() public {
        _otherStream(); // other has an identity
        FederatedStream unpaired = _deployStream(fArtistId, keccak256("unpaired"));
        _join(address(unpaired), artistKey, artistKey, address(streamDeployer));
        FederatedEditions e = _deployEditions(address(unpaired), otherId, keccak256("e"));
        IFederationRegistry.Join memory j =
            _joinData(address(e), otherKey, otherKey, address(editionsDeployer));
        vm.expectRevert(_notListable(address(e)));
        registry.register(address(e), j);
    }

    function test_Register_RefusesEditionsOfADelistedStream() public {
        FederatedStream t = _otherStream();
        registry.setStatus(_tokens(address(t)), IFederationRegistry.Status.DELISTED, 0);
        FederatedEditions e = _deployEditions(address(t), otherId, keccak256("e"));
        IFederationRegistry.Join memory j =
            _joinData(address(e), otherKey, otherKey, address(editionsDeployer));
        vm.expectRevert(_notListable(address(e)));
        registry.register(address(e), j);
    }

    function test_Register_RefusesASecondEditionsForAStream() public {
        FederatedEditions e = _deployEditions(address(fStream), fArtistId, keccak256("e2"));
        IFederationRegistry.Join memory j =
            _joinData(address(e), artistKey, artistKey, address(editionsDeployer));
        vm.expectRevert(_notListable(address(e)));
        registry.register(address(e), j);
    }

    function test_Register_RefusesAnExpiredConsent() public {
        FederatedStream t = _deployStream(fArtistId, keccak256("second"));
        IFederationRegistry.Join memory j =
            _joinData(address(t), artistKey, artistKey, address(streamDeployer));
        vm.warp(j.deadline + 1);
        vm.expectRevert(
            abi.encodeWithSelector(SignatureVerifier.SignatureExpired.selector, j.deadline)
        );
        registry.register(address(t), j);
    }

    function test_Register_RefusesAConsentByANonWallet() public {
        FederatedStream t = _deployStream(fArtistId, keccak256("second"));
        IFederationRegistry.Join memory j =
            _joinData(address(t), collabKey, artistKey, address(streamDeployer));
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, collab));
        registry.register(address(t), j);
    }

    function test_Register_RefusesAConsentToAnotherShare() public {
        FederatedStream t = _deployStream(fArtistId, keccak256("second"));
        IFederationRegistry.Join memory j =
            _joinData(address(t), artistKey, artistKey, address(streamDeployer));
        econ.setFeeShare(SHARE + 1); // the share listed is not the one consented to
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, artist));
        registry.register(address(t), j);
    }

    function test_Register_RefusesAConsentToAnotherPartner() public {
        FederatedStream t = _otherStream();
        FederatedEditions e = _deployEditions(address(t), otherId, keccak256("e"));
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 subject = registry.listingSubject(
            address(e), IFederationRegistry.Form.ERC1155, address(0), SHARE, deadline
        );
        IFederationRegistry.Join memory j = IFederationRegistry.Join(
            address(editionsDeployer),
            PROFILE,
            PROFILE_DOC,
            deadline,
            "",
            _proof(otherKey, accountsModule.consentDigest(address(registry), subject))
        );
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, other));
        registry.register(address(e), j);
    }

    function test_Register_RefusesABadRegistrationSignature() public {
        FederatedStream t = _deployStream(otherId, keccak256("other"));
        IFederationRegistry.Join memory j =
            _joinData(address(t), otherKey, otherKey, address(streamDeployer));
        j.registration = _sign(collabKey, keccak256("nothing"));
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, other));
        registry.register(address(t), j);
    }

    function test_Register_ConsentIsForThisModuleOnly() public {
        FederatedStream t = _deployStream(fArtistId, keccak256("second"));
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 subject = registry.listingSubject(
            address(t), IFederationRegistry.Form.ERC721, address(0), SHARE, deadline
        );
        IFederationRegistry.Join memory j = IFederationRegistry.Join(
            address(streamDeployer),
            PROFILE,
            PROFILE_DOC,
            deadline,
            "",
            _proof(artistKey, accountsModule.consentDigest(address(0xDEAD), subject))
        );
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, artist));
        registry.register(address(t), j);
    }

    function test_ListingSubject_CommitsToEveryField() public view {
        bytes32 s =
            registry.listingSubject(address(1), IFederationRegistry.Form.ERC721, address(2), 3, 4);
        assertTrue(
            s
                != registry.listingSubject(
                    address(9), IFederationRegistry.Form.ERC721, address(2), 3, 4
                )
        );
        assertTrue(
            s
                != registry.listingSubject(
                    address(1), IFederationRegistry.Form.ERC1155, address(2), 3, 4
                )
        );
        assertTrue(
            s
                != registry.listingSubject(
                    address(1), IFederationRegistry.Form.ERC721, address(9), 3, 4
                )
        );
        assertTrue(
            s
                != registry.listingSubject(
                    address(1), IFederationRegistry.Form.ERC721, address(2), 9, 4
                )
        );
        assertTrue(
            s
                != registry.listingSubject(
                    address(1), IFederationRegistry.Form.ERC721, address(2), 3, 9
                )
        );
    }

    function test_NoExit_ADelistedContractStaysListed() public {
        registry.setStatus(_tokens(address(fStream)), IFederationRegistry.Status.DELISTED, 0);
        assertEq(
            uint8(registry.listingOf(address(fStream)).status),
            uint8(IFederationRegistry.Status.DELISTED)
        );
        IFederationRegistry.Join memory j =
            _joinData(address(fStream), artistKey, artistKey, address(streamDeployer));
        vm.expectRevert(_notListable(address(fStream)));
        registry.register(address(fStream), j);
    }

    function test_RegisterFederated_OnlyTheDirectorysFederationModule() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnboundCaller.selector, stranger));
        accountsModule.registerFederated(other, PROFILE, PROFILE_DOC, uint64(block.timestamp), "");
    }

    // ------------------------------------------------------------------ replacement

    function _successor() internal returns (FederationRegistry next) {
        next = new FederationRegistry(
            address(manager),
            address(fedDirectory),
            address(facts),
            address(econ),
            address(store),
            address(registry)
        );
        fedDirectory.proposeModule(Slots.FEDERATION, address(next));
        vm.warp(block.timestamp + fedDirectory.moduleDelay());
        fedDirectory.activateModule(Slots.FEDERATION);
    }

    function test_Replacement_InheritsListingsTemplatesAdaptersWithoutSignatures() public {
        registry.setAccountDelisted(otherId, true, "old");
        FederationRegistry next = _successor();
        assertEq(accountsModule.federationRegistry(), address(next));
        assertEq(
            abi.encode(next.listingOf(address(fStream))),
            abi.encode(registry.listingOf(address(fStream)))
        );
        assertEq(
            abi.encode(next.entry(address(fEditions))),
            abi.encode(registry.entry(address(fEditions)))
        );
        assertEq(
            abi.encode(next.templateOf(address(streamDeployer))),
            abi.encode(registry.templateOf(address(streamDeployer)))
        );
        assertTrue(next.canMint(address(fStream), address(fedSale)));
        assertTrue(next.canMint(address(fEditions), address(fedSale)));
        assertTrue(next.isActive(address(fStream)));
        assertTrue(next.saleContractOf(address(fedSale)).addedAt != 0);
        assertTrue(next.isAccountDelisted(otherId));
        assertEq(next.feeShareOf(address(fStream)), SHARE);
        assertTrue(fStream.isMinter(address(fedSale)), "tokens ask the new module");
    }

    function test_Replacement_ItsOwnWritesOverrideAndLeaveThePredecessorAlone() public {
        registry.setAccountDelisted(otherId, true, "old");
        FederationRegistry next = _successor();
        next.lowerFeeShare(address(fStream), 1_000);
        assertEq(next.feeShareOf(address(fStream)), 1_000);
        assertEq(registry.feeShareOf(address(fStream)), SHARE);
        assertEq(next.listingOf(address(fStream)).partner, address(fEditions), "copied whole");

        next.setStatus(_tokens(address(fEditions)), IFederationRegistry.Status.DELISTED, 0);
        assertFalse(next.isActive(address(fEditions)));
        assertTrue(registry.isActive(address(fEditions)));

        next.setAccountDelisted(otherId, false, "new");
        assertFalse(next.isAccountDelisted(otherId));
        assertTrue(registry.isAccountDelisted(otherId));

        next.setAdapter(address(fedSale), IFederationRegistry.Form.ERC721, false);
        assertFalse(next.canMint(address(fStream), address(fedSale)));
        assertTrue(registry.canMint(address(fStream), address(fedSale)));
        assertFalse(fStream.isMinter(address(fedSale)), "the token follows the directory");

        next.suspendTemplate(address(streamDeployer));
        assertEq(
            uint8(next.templateOf(address(streamDeployer)).status),
            uint8(IFederationRegistry.TemplateStatus.SUSPENDED)
        );
        assertEq(
            uint8(registry.templateOf(address(streamDeployer)).status),
            uint8(IFederationRegistry.TemplateStatus.APPROVED)
        );
        assertEq(next.templateOf(address(streamDeployer)).version, 1, "copied whole");
    }

    function test_Replacement_DoesNotInheritItemApprovals() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        _approve(address(fStream), item, RATE);
        FederationRegistry next = _successor();
        bytes32 h = WorksHashing.itemHash(item);
        assertFalse(next.itemOf(address(fStream), h).approved);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederationRegistry.ItemNotApproved.selector, address(fStream), h
            )
        );
        fedSale.start(address(next), address(fStream), _request(item, media, new bytes[](0)));
        // the old module is no longer the gate, so its approval mints nothing either
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintPolicy.NotSaleContract.selector, address(fStream), address(fedSale)
            )
        );
        fedSale.start(address(registry), address(fStream), _request(item, media, new bytes[](0)));
        vm.prank(wallet);
        next.approveItem(address(fStream), h, RATE);
        fedSale.start(address(next), address(fStream), _request(item, media, new bytes[](0)));
    }

    function test_Replacement_ListsNewContractsAndCreatesIdentities() public {
        FederationRegistry next = _successor();
        FederatedStream t = _deployStream(otherId, keccak256("other"));
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 subject = next.listingSubject(
            address(t), IFederationRegistry.Form.ERC721, address(0), SHARE, deadline
        );
        IFederationRegistry.Join memory j = IFederationRegistry.Join(
            address(streamDeployer),
            PROFILE,
            PROFILE_DOC,
            deadline,
            _sign(
                otherKey, accountsModule.registrationDigest(other, PROFILE, PROFILE_DOC, deadline)
            ),
            _proof(otherKey, accountsModule.consentDigest(address(next), subject))
        );
        next.register(address(t), j);
        assertTrue(next.isActive(address(t)));
        assertEq(accountsModule.artistIdOf(other), otherId);
        // listing again through the old module is refused: it is no longer the federation module
        FederatedStream t2 = _deployStream(fArtistId, keccak256("t2"));
        IFederationRegistry.Join memory j2 =
            _joinData(address(t2), artistKey, artistKey, address(streamDeployer));
        registry.register(address(t2), j2); // registered artist: no identity call, so it lists there
        assertEq(
            uint8(next.listingOf(address(t2)).status),
            uint8(IFederationRegistry.Status.ACTIVE),
            "and is inherited"
        );
    }

    function test_Replacement_ChainOfTwoReadsThrough() public {
        FederationRegistry next = _successor();
        FederationRegistry third = new FederationRegistry(
            address(manager),
            address(fedDirectory),
            address(facts),
            address(econ),
            address(store),
            address(next)
        );
        next.lowerFeeShare(address(fStream), 500);
        assertEq(third.feeShareOf(address(fStream)), 500);
        assertEq(third.listingOf(address(fEditions)).partner, address(fStream));
    }

    function test_Identity_FrozenArtistCannotConsentToAListing() public {
        FederatedStream t = _deployStream(fArtistId, keccak256("second"));
        IFederationRegistry.Join memory j =
            _joinData(address(t), artistKey, artistKey, address(streamDeployer));
        accountsModule.freeze(fArtistId);
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, artist));
        registry.register(address(t), j);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { IndependentStream6529 } from "src/independent/IndependentStream6529.sol";
import { IndependentStreamRegistry } from "src/independent/IndependentStreamRegistry.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";
import { Core, MintFacts, MintTerms } from "src/interfaces/core/CoreTypes.sol";
import { IIndependentStreamGate } from "src/interfaces/core/IIndependentStreamGate.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";
import { License, PackageItem, Party } from "src/interfaces/types/PackageTypes.sol";
import { StreamHashing } from "src/interfaces/types/StreamHashing.sol";
import { IndependentStreamFixture } from "./IndependentStreamFixture.sol";

/// @notice Behaviour of the Independent Stream module that the mutation campaign found unpinned:
///         exact bounds, template events, the listing subject, releases of unlisted contracts,
///         and the party, consent and payee rules with several parties.
contract IndependentStreamRegistryMutationTest is IndependentStreamFixture {
    IIndependentStreamRegistry.Form internal constant ERC721 =
    IIndependentStreamRegistry.Form.ERC721;

    function _templateSet(address d, IIndependentStreamRegistry.TemplateStatus status) internal {
        vm.expectEmit(address(registry));
        emit IIndependentStreamRegistry.TemplateSet(
            d, streamDeployer.creationHash(), 1, ERC721, status
        );
    }

    /// @dev The network replaces the root of the fixture's artist with the wallet of `newKey`,
    ///      keeping the payout address, and the notice passes.
    function _replaceRoot(uint256 newKey) internal {
        ArtistIdentity memory next = ArtistIdentity(vm.addr(newKey), artist, PROFILE, PROFILE_DOC);
        bytes32 evidence = keccak256("evidence");
        uint64 deadline = uint64(block.timestamp + 3 days);
        bytes memory acceptance =
            _sign(newKey, accountsModule.replacementDigest(fArtistId, next, evidence, deadline));
        accountsModule.stageReplacement(fArtistId, next, evidence, deadline, acceptance);
        vm.warp(block.timestamp + accountsModule.REPLACEMENT_NOTICE());
        accountsModule.executeChange(fArtistId);
    }

    /// @dev Approves `item` and mints it into the fixture's stream.
    function _mint(PackageItem memory item, MediaFile[] memory media, bytes[] memory consents)
        internal
        returns (uint256 id)
    {
        _approve(address(fStream), item, RATE);
        (id,,) = indSale.start(address(registry), address(fStream), _request(item, media, consents));
        assertEq(fStream.ownerOf(id), address(indSale));
    }

    /// @dev Approves `item` and expects its mint to revert with `InvalidMintRequest`.
    function _refuse(PackageItem memory item, MediaFile[] memory media, bytes[] memory consents)
        internal
    {
        _approve(address(fStream), item, RATE);
        bytes memory req = _request(item, media, consents);
        vm.expectRevert(IIndependentStreamRegistry.InvalidMintRequest.selector);
        indSale.start(address(registry), address(fStream), req);
    }

    // ------------------------------------------------------------------ governance

    /// @notice One `setStatus` call takes 256 contracts and refuses 257.
    function test_SetStatus_TakesExactly256Contracts() public {
        assertEq(registry.MAX_BATCH(), 256);
        registry.setStatus(new address[](256), IIndependentStreamRegistry.Status.DELISTED, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamRegistry.BatchTooLarge.selector, 257)
        );
        registry.setStatus(new address[](257), IIndependentStreamRegistry.Status.DELISTED, 0);
    }

    /// @notice A revocation logs the template with its new status.
    function test_RevokeTemplate_Logs() public {
        _templateSet(address(streamDeployer), IIndependentStreamRegistry.TemplateStatus.REVOKED);
        registry.revokeTemplate(address(streamDeployer));
    }

    /// @notice A suspension, its lifting and a reinstatement each log the template's new status.
    function test_Templates_SuspendResumeReinstateLog() public {
        address d = address(streamDeployer);
        _templateSet(d, IIndependentStreamRegistry.TemplateStatus.SUSPENDED);
        registry.suspendTemplate(d);
        _templateSet(d, IIndependentStreamRegistry.TemplateStatus.APPROVED);
        registry.resumeTemplate(d);
        registry.revokeTemplate(d);
        _templateSet(d, IIndependentStreamRegistry.TemplateStatus.APPROVED);
        registry.reinstateTemplate(d);
    }

    /// @notice A module that does not list a contract releases none of its content, even for a
    ///         burned token and the zero beneficiary an unlisted contract's empty listing names.
    function test_ReleaseContent_RefusesAnUnlistedContract() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        _approve(address(fStream), item, RATE);
        (uint256 burned,,) = indSale.start(
            address(registry), address(fStream), _request(item, media, new bytes[](0))
        );
        indSale.burn(address(fStream), burned);
        IndependentStreamRegistry solo = new IndependentStreamRegistry(
            address(manager),
            address(indDirectory),
            address(facts),
            address(econ),
            address(store),
            address(0)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IIndependentStreamRegistry.ReleaseRefused.selector, address(fStream), burned
            )
        );
        solo.releaseContent(address(fStream), burned, item.contentHash, 0);
    }

    /// @notice Once a released content is minted again, the earlier burned token of it is
    ///         released no more.
    function test_ReleaseContent_RefusesAnEarlierBurnedTokenOfTheContent() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        uint256 first = _mint(item, media, new bytes[](0));
        indSale.burn(address(fStream), first);
        registry.releaseContent(address(fStream), first, item.contentHash, fArtistId);
        item.recordFileId = _file("another record", "application/json");
        uint256 second = _mint(item, media, new bytes[](0));
        assertEq(fStream.tokenOfContent(item.contentHash), second);
        vm.expectRevert(
            abi.encodeWithSelector(
                IIndependentStreamRegistry.ReleaseRefused.selector, address(fStream), first
            )
        );
        registry.releaseContent(address(fStream), first, item.contentHash, fArtistId);
    }

    /// @notice A release names the contract's artist exactly: the IDs next above and below it
    ///         are refused.
    function test_ReleaseContent_RefusesABeneficiaryNextToTheArtist() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        uint256 burned = _mint(item, media, new bytes[](0));
        indSale.burn(address(fStream), burned);
        bytes memory refused = abi.encodeWithSelector(
            IIndependentStreamRegistry.ReleaseRefused.selector, address(fStream), burned
        );
        vm.expectRevert(refused);
        registry.releaseContent(address(fStream), burned, item.contentHash, fArtistId + 1);
        vm.expectRevert(refused);
        registry.releaseContent(address(fStream), burned, item.contentHash, fArtistId - 1);
    }

    // ------------------------------------------------------------------ listing

    /// @notice Editions of another artist's stream are refused whichever artist ID is the
    ///         higher.
    function test_Register_RefusesEditionsOfAnotherArtistsStreamEitherWay() public {
        IndependentStream6529 mine = _deployStream(fArtistId, keccak256("unpaired"));
        _join(address(mine), artistKey, artistKey, address(streamDeployer));
        IndependentStream6529 theirs = _deployStream(uint160(other), keccak256("other"));
        _join(address(theirs), otherKey, otherKey, address(streamDeployer));
        address e = address(_deployEditions(address(mine), uint160(other), keccak256("a")));
        IIndependentStreamRegistry.Join memory j =
            _joinData(e, otherKey, otherKey, address(editionsDeployer));
        vm.expectRevert(abi.encodeWithSelector(IIndependentStreamRegistry.NotListable.selector, e));
        registry.register(e, j);
        e = address(_deployEditions(address(theirs), fArtistId, keccak256("b")));
        j = _joinData(e, artistKey, artistKey, address(editionsDeployer));
        vm.expectRevert(abi.encodeWithSelector(IIndependentStreamRegistry.NotListable.selector, e));
        registry.register(e, j);
    }

    /// @notice Listing a 1/1 contract, which has no partner, writes nothing at the zero address.
    function test_Register_AStreamWritesNoListingAtTheZeroAddress() public view {
        IIndependentStreamRegistry.Listing memory none;
        assertEq(abi.encode(registry.listingOf(address(0))), abi.encode(none));
    }

    /// @notice The collaborator's consent subject, pinned: the domain, the item hash and the
    ///         rate, each in a whole word. The values were computed independently with
    ///         `cast keccak` and `cast abi-encode "f(bytes32,bytes32,uint24)"` for the item hash
    ///         `keccak256("item")` and the rate 6,529.
    function test_IndependentConsent_Golden() public pure {
        assertEq(
            Core.INDEPENDENT_CONSENT_DOMAIN,
            0x22fa010d48b30efa0ad886886afa983972547c8d73a243ed9c0bb0fe4c451283
        );
        assertEq(Core.INDEPENDENT_CONSENT_DOMAIN, keccak256("6529STREAM_INDEPENDENT_CONSENT_V1"));
        assertEq(
            Core.independentConsent(keccak256("item"), 6529),
            0x3fd493609a08f7c5ee290c4f97480bcf6b1bc7d69a9fe013205ecf6b35e6f142
        );
    }

    /// @notice The listing subject is the hash of the ABI-encoded domain and fields, each in a
    ///         whole word.
    function test_ListingSubject_IsTheAbiEncodedDomainAndFields() public view {
        IIndependentStreamRegistry.Form form = IIndependentStreamRegistry.Form.ERC1155;
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("6529STREAM_INDEPENDENT_LISTING_V1"),
                address(0x1111),
                form,
                address(0x2222),
                uint32(3_333),
                uint64(4_444)
            )
        );
        assertEq(
            registry.listingSubject(address(0x1111), form, address(0x2222), 3_333, 4_444), expected
        );
    }

    /// @notice A contract whose artist ID is the address of another account's root is not
    ///         listed: that address cannot become an account of its own.
    function test_Register_RefusesATokenNamingAnotherAccountsRoot() public {
        // A new root for the fixture's artist whose address is below the artist's ID.
        uint256 newKey = 0xE500;
        while (uint160(vm.addr(newKey)) >= fArtistId) {
            ++newKey;
        }
        address newRoot = vm.addr(newKey);
        _replaceRoot(newKey);
        assertEq(accountsModule.artistIdOf(newRoot), fArtistId, "the new root's account");

        IndependentStream6529 t = _deployStream(uint160(newRoot), keccak256("new root"));
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 subject = registry.listingSubject(address(t), ERC721, address(0), SHARE, deadline);
        IIndependentStreamRegistry.Join memory j = IIndependentStreamRegistry.Join(
            address(streamDeployer),
            PROFILE,
            PROFILE_DOC,
            deadline,
            _sign(
                newKey, accountsModule.registrationDigest(newRoot, PROFILE, PROFILE_DOC, deadline)
            ),
            _proof(newKey, accountsModule.consentDigest(address(registry), subject))
        );
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, newRoot));
        registry.register(address(t), j);
        assertEq(uint8(registry.listingOf(address(t)).status), 0, "not listed");
    }

    // ------------------------------------------------------------------ mint policy

    /// @notice The sale's parameters are answered as the item states them, by `authorize` and by
    ///         `preview`.
    function test_Authorize_AnswersTheItemsSaleParams() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        item.sale.params = abi.encode(uint256(1 ether), uint64(7 days));
        _approve(address(fStream), item, RATE);
        bytes memory req = _request(item, media, new bytes[](0));
        (, MintTerms memory pt) = registry.preview(address(fStream), req);
        assertEq(pt.params, item.sale.params, "previewed");
        (,, MintTerms memory t) = indSale.start(address(registry), address(fStream), req);
        assertEq(t.params, item.sale.params, "authorized");
    }

    /// @notice At a zero network share `preview` names the seller vault as the royalty receiver,
    ///         as `authorize` does.
    function test_Preview_AtZeroShareTheRoyaltyReceiverIsTheSeller() public {
        registry.lowerFeeShare(address(fStream), 0);
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        _approve(address(fStream), item, RATE);
        (MintFacts memory f, MintTerms memory t) =
            registry.preview(address(fStream), _request(item, media, new bytes[](0)));
        assertEq(t.feeShare, 0);
        assertEq(f.seller, ledger.walletFor(item.payees, 0));
        assertEq(f.royaltyReceiver, f.seller);
    }

    /// @notice With two collaborators each one's consent is checked against its own entry.
    function test_Authorize_EachCollaboratorsOwnConsentIsChecked() public {
        address[] memory c = new address[](2);
        (c[0], c[1]) = (collab, other);
        (PackageItem memory item, MediaFile[] memory media) = _itemOf(1, 0, c);
        _approve(address(fStream), item, RATE);
        bytes[] memory consents = new bytes[](2);
        consents[0] = _consent(collabKey, address(fStream), item, RATE);
        consents[1] = _consent(otherKey, address(fStream), item, RATE);
        (uint256 id,,) =
            indSale.start(address(registry), address(fStream), _request(item, media, consents));
        assertEq(fStream.ownerOf(id), address(indSale));
    }

    /// @notice An artist-resolved payee that is none of several parties is refused, even when it
    ///         is an account with a payout address and parties stand below and above its ID.
    function test_Authorize_APayeeOutsideSeveralPartiesIsRefused() public {
        vm.prank(packageRegistry);
        accountsModule.register(other, PROFILE, PROFILE_DOC);
        assertEq(accountsModule.payoutAddress(uint160(other)), other, "the payee has a payout");
        uint256 lowKey = 0x4000;
        while (vm.addr(lowKey) >= other) {
            ++lowKey;
        }
        uint256 highKey = 0x5000;
        while (vm.addr(highKey) <= other) {
            ++highKey;
        }
        address[] memory c = new address[](2);
        (c[0], c[1]) = (vm.addr(lowKey), vm.addr(highKey));
        (PackageItem memory item, MediaFile[] memory media) = _itemOf(1, 0, c);
        item.payees[0] = ISplitWallet.Payee(uint160(other), address(0), 100_000);
        bytes[] memory consents = new bytes[](2);
        consents[0] = _consent(lowKey, address(fStream), item, RATE);
        consents[1] = _consent(highKey, address(fStream), item, RATE);
        _refuse(item, media, consents);
    }

    /// @notice Exactly sixteen parties mint, each collaborator consenting.
    function test_Authorize_SixteenPartiesMint() public {
        address[] memory c = new address[](15);
        for (uint256 i; i < 15; ++i) {
            c[i] = vm.addr(0x3000 + i);
        }
        (PackageItem memory item, MediaFile[] memory media) = _itemOf(1, 0, c);
        bytes[] memory consents = new bytes[](15);
        for (uint256 i; i < 15; ++i) {
            consents[i] = _consent(0x3000 + i, address(fStream), item, RATE);
        }
        _mint(item, media, consents);
    }

    /// @notice Exactly sixty-four payees mint.
    function test_Authorize_SixtyFourPayeesMint() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        item.payees = new ISplitWallet.Payee[](64);
        for (uint256 i; i < 64; ++i) {
            item.payees[i] =
                ISplitWallet.Payee(0, address(uint160(0x100 + i)), i == 63 ? 99_937 : 1);
        }
        _mint(item, media, new bytes[](0));
    }

    /// @notice A first party next above or below the artist's ID is refused.
    function test_Authorize_RefusesAFirstPartyNextToTheArtist() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        item.payees[0] = ISplitWallet.Payee(0, collab, 100_000); // only the party rule bites
        item.parties[0] = Party(address(uint160(artist) + 1), 0);
        _refuse(item, media, new bytes[](0));
        item.parties[0] = Party(address(uint160(artist) - 1), 0);
        _refuse(item, media, new bytes[](0));
    }

    /// @notice An original needs no editions contract: it mints while the editions are delisted.
    function test_Authorize_AnOriginalMintsWithoutActiveEditions() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(fEditions);
        registry.setStatus(tokens, IIndependentStreamRegistry.Status.DELISTED, 0);
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        _mint(item, media, new bytes[](0));
    }

    /// @notice A stated digest below the one the content store holds is refused, also when the
    ///         item commits to the stated one.
    function test_Authorize_RefusesAStatedDigestBelowTheStoredOne() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        media[0].sha256Hash = bytes32(uint256(media[0].sha256Hash) - 1);
        item.contentHash = media[0].sha256Hash;
        item.mediaHash = StreamHashing.mediaHash(media);
        _refuse(item, media, new bytes[](0));
    }

    /// @notice CC0 is refused with a text whose file ID is above the deployment's CC0 text, and
    ///         with one below it.
    function test_Authorize_Cc0RefusesATextAboveOrBelowTheDeploymentsText() public {
        uint256 cc0 = uint256(facts.cc0TextFileId());
        bytes32 above = licenseText;
        for (uint256 k; uint256(above) <= cc0; ++k) {
            above = _file(abi.encodePacked("text above ", k), "text/plain");
        }
        bytes32 below = licenseText;
        for (uint256 k; uint256(below) >= cc0; ++k) {
            below = _file(abi.encodePacked("text below ", k), "text/plain");
        }
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        item.license = License("CC0-1.0", above);
        _refuse(item, media, new bytes[](0));
        item.license = License("CC0-1.0", below);
        _refuse(item, media, new bytes[](0));
    }

    /// @notice Only CC0 must name the deployment's CC0 text: other licenses mint with their own.
    function test_Authorize_OtherLicensesMintWithTheirOwnText() public {
        string[6] memory ids =
            ["MIT", "Apache-2.0", "CC-BY-SA-4.0", "CC-BY-NC-4.0", "GPL-3.0-only", "ARR"];
        for (uint256 i; i < 6; ++i) {
            (PackageItem memory item, MediaFile[] memory media) = _item(10 + i);
            item.license = License(ids[i], licenseText);
            _mint(item, media, new bytes[](0));
        }
    }

    /// @notice A content hash above the primary file's digest is refused like one below it.
    function test_Authorize_RefusesAContentHashAboveThePrimaryDigest() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        item.contentHash = bytes32(uint256(item.contentHash) + 1);
        _approve(address(fStream), item, RATE);
        bytes memory req = _request(item, media, new bytes[](0));
        vm.expectRevert(IIndependentStreamRegistry.InvalidMintRequest.selector);
        indSale.start(address(registry), address(fStream), req);
    }

    /// @notice A media hash above the hash of the media files is refused like one below it.
    function test_Authorize_RefusesAMediaHashAboveTheFilesHash() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        item.mediaHash = bytes32(uint256(item.mediaHash) + 1);
        _approve(address(fStream), item, RATE);
        bytes memory req = _request(item, media, new bytes[](0));
        vm.expectRevert(IIndependentStreamRegistry.InvalidMintRequest.selector);
        indSale.start(address(registry), address(fStream), req);
    }

    // ------------------------------------------------------------------ views

    /// @notice Only the four interface IDs are supported: not zero, nor an ID next to one.
    function test_SupportsInterface_OnlyTheExactIds() public view {
        bytes4[4] memory ids = [
            type(IIndependentStreamRegistry).interfaceId,
            type(IIndependentStreamGate).interfaceId,
            type(IMintPolicy).interfaceId,
            type(IERC165).interfaceId
        ];
        assertFalse(registry.supportsInterface(0x00000000));
        for (uint256 i; i < 4; ++i) {
            assertTrue(registry.supportsInterface(ids[i]));
            assertFalse(registry.supportsInterface(bytes4(uint32(ids[i]) - 1)));
            assertFalse(registry.supportsInterface(bytes4(uint32(ids[i]) + 1)));
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { MintFacts, MintTerms } from "src/interfaces/core/CoreTypes.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License, PackageItem, Party } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { FederationFixture, FedSale } from "./FederationFixture.sol";

/// @notice An entropy module whose federated seeds the test delivers.
contract FedEntropyStub {
    mapping(address => mapping(bytes32 => bytes32)) public seeds;

    function deliver(address token, bytes32 contentHash, bytes32 seed) external {
        seeds[token][contentHash] = seed;
    }

    function federatedSeedOf(address token, bytes32 contentHash)
        external
        view
        returns (bool, bytes32)
    {
        bytes32 s = seeds[token][contentHash];
        return (s != 0, s);
    }
}

/// @notice The federated mint policy: `authorize`, `preview` and the content release rules.
contract FederationRegistryPolicyTest is FederationFixture {
    uint256 internal collab2Key = 0xC4;

    // ------------------------------------------------------------------ helpers

    function _start(PackageItem memory item, MediaFile[] memory media, bytes[] memory consents)
        internal
        returns (uint256 id, MintFacts memory f, MintTerms memory t)
    {
        return fedSale.start(address(registry), address(fStream), _request(item, media, consents));
    }

    /// @dev Approves `item` and expects its start to revert with `InvalidMintRequest`.
    function _refused(PackageItem memory item, MediaFile[] memory media) internal {
        _approve(address(fStream), item, RATE);
        bytes memory req = _request(item, media, new bytes[](item.parties.length - 1));
        vm.expectRevert(IFederationRegistry.InvalidMintRequest.selector);
        fedSale.start(address(registry), address(fStream), req);
    }

    function _notApproved(bytes32 h) internal view returns (bytes memory) {
        return
            abi.encodeWithSelector(
                IFederationRegistry.ItemNotApproved.selector, address(fStream), h
            );
    }

    function _withCollab() internal returns (PackageItem memory item, MediaFile[] memory media) {
        address[] memory c = new address[](1);
        c[0] = collab;
        (item, media) = _itemOf(1, 0, c);
    }

    // ------------------------------------------------------------------ the caller

    function test_Authorize_CallerMustBeAnActiveSaleContract() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        _approve(address(fStream), item, RATE);
        FedSale outsider = new FedSale();
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintPolicy.NotSaleContract.selector, address(fStream), address(outsider)
            )
        );
        outsider.start(address(registry), address(fStream), _request(item, media, new bytes[](0)));
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.NotSaleContract.selector, address(fStream), stranger)
        );
        registry.authorize(address(fStream), _request(item, media, new bytes[](0)));
        registry.setAdapter(address(fedSale), IFederationRegistry.Form.ERC721, false);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintPolicy.NotSaleContract.selector, address(fStream), address(fedSale)
            )
        );
        _start(item, media, new bytes[](0));
    }

    function test_Authorize_RefusesADelistedContract() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        _approve(address(fStream), item, RATE);
        registry.setAccountDelisted(fArtistId, true, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintPolicy.NotSaleContract.selector, address(fStream), address(fedSale)
            )
        );
        _start(item, media, new bytes[](0));
    }

    // ------------------------------------------------------------------ approval

    function test_ApproveItem_ByAnyWalletLoggedAndBounded() public {
        (PackageItem memory item,) = _item(1);
        bytes32 h = WorksHashing.itemHash(item);
        vm.expectEmit(address(registry));
        emit IFederationRegistry.ItemApproval(address(fStream), h, 4_000, true);
        vm.prank(wallet);
        registry.approveItem(address(fStream), h, 4_000);
        IFederationRegistry.Item memory it = registry.itemOf(address(fStream), h);
        assertTrue(it.approved);
        assertEq(it.royaltyRate, 4_000);
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IFederationRegistry.InvalidRoyaltyRate.selector, 100_001)
        );
        registry.approveItem(address(fStream), h, 100_001);
        vm.prank(artist);
        registry.approveItem(address(fStream), h, 100_000);
    }

    function test_ApproveItem_RefusesStrangersEditionsAndUnlisted() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederationRegistry.NotArtist.selector, address(fStream), stranger
            )
        );
        registry.approveItem(address(fStream), bytes32(uint256(1)), 0);
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederationRegistry.NotArtist.selector, address(fEditions), artist
            )
        );
        registry.approveItem(address(fEditions), bytes32(uint256(1)), 0);
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IFederationRegistry.NotArtist.selector, stranger, artist)
        );
        registry.approveItem(stranger, bytes32(uint256(1)), 0);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederationRegistry.NotArtist.selector, address(fStream), stranger
            )
        );
        registry.revokeItem(address(fStream), bytes32(uint256(1)));
    }

    function test_ApproveItem_AFrozenArtistCannotApprove() public {
        accountsModule.freeze(fArtistId);
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IFederationRegistry.NotArtist.selector, address(fStream), artist)
        );
        registry.approveItem(address(fStream), bytes32(uint256(1)), 0);
    }

    function test_Authorize_NeedsAnApproval() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        vm.expectRevert(_notApproved(WorksHashing.itemHash(item)));
        _start(item, media, new bytes[](0));
    }

    function test_Authorize_AnItemMintsOnce() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        _approve(address(fStream), item, RATE);
        _start(item, media, new bytes[](0));
        bytes32 h = WorksHashing.itemHash(item);
        assertTrue(registry.itemOf(address(fStream), h).used);
        vm.expectRevert(_notApproved(h));
        _start(item, media, new bytes[](0));
        vm.prank(artist);
        vm.expectRevert(_notApproved(h));
        registry.approveItem(address(fStream), h, RATE);
        vm.prank(artist);
        vm.expectRevert(_notApproved(h));
        registry.revokeItem(address(fStream), h);
    }

    function test_RevokeItem_BeforeMintStopsIt() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        _approve(address(fStream), item, RATE);
        bytes32 h = WorksHashing.itemHash(item);
        vm.expectEmit(address(registry));
        emit IFederationRegistry.ItemApproval(address(fStream), h, 0, false);
        vm.prank(wallet);
        registry.revokeItem(address(fStream), h);
        assertFalse(registry.itemOf(address(fStream), h).approved);
        vm.expectRevert(_notApproved(h));
        _start(item, media, new bytes[](0));
    }

    // ------------------------------------------------------------------ the item

    function test_Authorize_EthOnly() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        item.sale.currency = address(0xE20);
        _refused(item, media);
    }

    function test_Authorize_MediaCountBounds() public {
        (PackageItem memory item,) = _item(1);
        MediaFile[] memory none = new MediaFile[](0);
        item.mediaHash = WorksHashing.mediaHash(none);
        _refused(item, none);

        (PackageItem memory big, MediaFile[] memory one) = _item(2);
        MediaFile[] memory many = new MediaFile[](33);
        for (uint256 i; i < 33; ++i) {
            many[i] = MediaFile(one[0].fileId, one[0].sha256Hash, i == 0 ? 0 : 1);
        }
        big.mediaHash = WorksHashing.mediaHash(many);
        _refused(big, many);
    }

    function test_Authorize_ThirtyTwoFilesMint() public {
        (PackageItem memory item, MediaFile[] memory one) = _item(1);
        MediaFile[] memory many = new MediaFile[](32);
        for (uint256 i; i < 32; ++i) {
            many[i] = MediaFile(one[0].fileId, one[0].sha256Hash, i == 0 ? 0 : 1);
        }
        item.mediaHash = WorksHashing.mediaHash(many);
        _approve(address(fStream), item, RATE);
        _start(item, many, new bytes[](0));
    }

    function test_Authorize_PrimaryHashMustBeTheContent() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        item.contentHash = keccak256("other");
        _refused(item, media);
        (PackageItem memory zero, MediaFile[] memory m2) = _item(2);
        zero.contentHash = 0;
        m2[0].sha256Hash = 0;
        zero.mediaHash = WorksHashing.mediaHash(m2);
        _refused(zero, m2);
    }

    function test_Authorize_MediaHashMustCommit() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        item.mediaHash = keccak256("other");
        _refused(item, media);
    }

    function test_Authorize_FilesMustBeInTheStoreWithTheirDigest() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        media[0].fileId = keccak256("unknown file");
        item.mediaHash = WorksHashing.mediaHash(media);
        _approve(address(fStream), item, RATE);
        vm.expectRevert();
        _start(item, media, new bytes[](0));

        (PackageItem memory two, MediaFile[] memory m2) = _item(2);
        MediaFile[] memory pair = new MediaFile[](2);
        pair[0] = m2[0];
        pair[1] = MediaFile(m2[0].fileId, keccak256("not its digest"), 1);
        two.mediaHash = WorksHashing.mediaHash(pair);
        _refused(two, pair);
    }

    function test_Authorize_RoleRule() public {
        (PackageItem memory item, MediaFile[] memory m) = _item(1);
        MediaFile[] memory pair = new MediaFile[](2);
        pair[0] = m[0];
        pair[1] = MediaFile(m[0].fileId, m[0].sha256Hash, 0); // a second primary
        item.mediaHash = WorksHashing.mediaHash(pair);
        _refused(item, pair);
        (PackageItem memory two, MediaFile[] memory m2) = _item(2);
        m2[0].role = 1; // the first is not primary
        two.mediaHash = WorksHashing.mediaHash(m2);
        _refused(two, m2);
    }

    function test_Authorize_KindAndSeedPolicyBounds() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        item.kind = 2;
        _refused(item, media);
        (PackageItem memory two, MediaFile[] memory m2) = _item(2);
        two.seedPolicy = 3;
        _refused(two, m2);
    }

    function test_Authorize_AnEditionMasterNeedsListedEditions() public {
        (PackageItem memory item, MediaFile[] memory media) = _itemOf(1, 1, new address[](0));
        _approve(address(fStream), item, RATE);
        (uint256 id,,) = _start(item, media, new bytes[](0));
        assertEq(fStream.workOf(id).kind, 1);

        address[] memory t = new address[](1);
        t[0] = address(fEditions);
        registry.setStatus(t, IFederationRegistry.Status.DELISTED, 0);
        (PackageItem memory two, MediaFile[] memory m2) = _itemOf(2, 1, new address[](0));
        _refused(two, m2);
    }

    function test_Authorize_AnEditionMasterOfAStreamWithoutEditions() public {
        FederatedStream solo = _deployStream(fArtistId, keccak256("solo"));
        _join(address(solo), artistKey, artistKey, address(streamDeployer));
        (PackageItem memory item, MediaFile[] memory media) = _itemOf(1, 1, new address[](0));
        _approve(address(solo), item, RATE);
        vm.expectRevert(IFederationRegistry.InvalidMintRequest.selector);
        fedSale.start(address(registry), address(solo), _request(item, media, new bytes[](0)));
    }

    function test_Authorize_ArtistSeedIsStored() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        item.seedPolicy = 1;
        item.seed = keccak256("artist seed");
        _approve(address(fStream), item, RATE);
        (uint256 id, MintFacts memory f,) = _start(item, media, new bytes[](0));
        assertEq(f.seed, item.seed);
        assertEq(fStream.workOf(id).seed, item.seed);
        assertEq(fStream.workOf(id).seedPolicy, 1);
    }

    function test_Authorize_NoSeedIgnoresTheItemsSeedField() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        item.seed = keccak256("ignored");
        _approve(address(fStream), item, RATE);
        (, MintFacts memory f,) = _start(item, media, new bytes[](0));
        assertEq(f.seed, 0);
    }

    function test_Authorize_VrfNeedsADeliveredSeed() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        item.seedPolicy = 2;
        _approve(address(fStream), item, RATE);
        bytes memory req = _request(item, media, new bytes[](0));
        bytes memory notDelivered = abi.encodeWithSelector(
            IFederationRegistry.SeedNotDelivered.selector, address(fStream), item.contentHash
        );
        vm.expectRevert(notDelivered);
        fedSale.start(address(registry), address(fStream), req);
        FedEntropyStub vrf = new FedEntropyStub();
        registry.setEntropyModule(address(vrf));
        vm.expectRevert(notDelivered);
        fedSale.start(address(registry), address(fStream), req);
        vrf.deliver(address(fStream), item.contentHash, keccak256("vrf"));
        (uint256 id,,) = fedSale.start(address(registry), address(fStream), req);
        assertEq(fStream.workOf(id).seed, keccak256("vrf"));
    }

    function test_Authorize_LicenseIdMustBeShowable() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        item.license.spdxId = "";
        _refused(item, media);
        (PackageItem memory two, MediaFile[] memory m2) = _item(2);
        two.license.spdxId = "bad id!";
        _refused(two, m2);
    }

    function test_Authorize_LicenseTextOfAtMostSixteenChunks() public {
        bytes32[] memory chunks = new bytes32[](17);
        for (uint256 i; i < 17; ++i) {
            chunks[i] = keccak256(abi.encode(i));
        }
        bytes32 long = store.registerManifest(chunks, 17 * 24_575, 0, "text/plain", keccak256("t"));
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        item.license.textFileId = long;
        _refused(item, media);

        bytes32[] memory sixteen = new bytes32[](16);
        for (uint256 i; i < 16; ++i) {
            sixteen[i] = keccak256(abi.encode(i));
        }
        bytes32 ok = store.registerManifest(sixteen, 16 * 24_575, 0, "text/plain", keccak256("u"));
        (PackageItem memory two, MediaFile[] memory m2) = _item(2);
        two.license.textFileId = ok;
        _approve(address(fStream), two, RATE);
        _start(two, m2, new bytes[](0));
    }

    function test_Authorize_LicenseTextMustBeSha256() public {
        bytes memory text = "license text with another digest";
        (bytes32 textHash,) = store.writeChunk(text);
        (bytes32 listHash,) = store.writeChunk(abi.encodePacked(textHash));
        bytes32[] memory lists = new bytes32[](1);
        lists[0] = listHash;
        bytes32 fileId =
            store.registerManifestList(lists, 1, text.length, 0, "text/plain", keccak256(text), 1);
        assertEq(store.fileInfo(fileId).digestKind, 1);
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        item.license.textFileId = fileId;
        _refused(item, media);
    }

    function test_Authorize_Cc0MustNameTheDeploymentsText() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        item.license = License("CC0-1.0", licenseText);
        _refused(item, media);
    }

    // ------------------------------------------------------------------ parties and payees

    function test_Authorize_FirstPartyIsTheArtist() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        item.parties[0] = Party(collab, 0);
        item.payees[0] = ISplitWallet.Payee(0, collab, 100_000); // only the party rule bites
        _refused(item, media);
        (PackageItem memory two, MediaFile[] memory m2) = _item(2);
        two.parties = new Party[](0);
        _approve(address(fStream), two, RATE);
        vm.expectRevert(IFederationRegistry.InvalidMintRequest.selector);
        _start(two, m2, new bytes[](0));
    }

    function test_Authorize_AtMostSixteenParties() public {
        address[] memory c = new address[](16);
        for (uint256 i; i < 16; ++i) {
            c[i] = address(uint160(0x1000 + i));
        }
        (PackageItem memory item, MediaFile[] memory media) = _itemOf(1, 0, c);
        _refused(item, media);
    }

    function test_Authorize_OneConsentPerCollaborator() public {
        (PackageItem memory item, MediaFile[] memory media) = _withCollab();
        _approve(address(fStream), item, RATE);
        vm.expectRevert(IFederationRegistry.InvalidMintRequest.selector);
        _start(item, media, new bytes[](0));
        vm.expectRevert(IFederationRegistry.InvalidMintRequest.selector);
        _start(item, media, new bytes[](2));
    }

    function test_Authorize_ACollaboratorConsentsToTheItemAndTheRate() public {
        (PackageItem memory item, MediaFile[] memory media) = _withCollab();
        _approve(address(fStream), item, RATE);
        bytes[] memory c = new bytes[](1);
        c[0] = _consent(collabKey, address(fStream), item, RATE);
        (uint256 id,,) = _start(item, media, c);
        assertEq(fStream.workOf(id).royaltyRate, RATE);
    }

    function test_Authorize_AConsentToAnotherRateFails() public {
        (PackageItem memory item, MediaFile[] memory media) = _withCollab();
        _approve(address(fStream), item, RATE);
        bytes[] memory c = new bytes[](1);
        c[0] = _consent(collabKey, address(fStream), item, RATE - 1);
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, collab));
        _start(item, media, c);
    }

    function test_Authorize_AnApprovalAtAnotherRateThanSignedFails() public {
        (PackageItem memory item, MediaFile[] memory media) = _withCollab();
        bytes[] memory c = new bytes[](1);
        c[0] = _consent(collabKey, address(fStream), item, RATE);
        _approve(address(fStream), item, RATE + 1); // the artist raised the rate after signing
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, collab));
        _start(item, media, c);
    }

    function test_Authorize_AConsentForAnotherTokenOrItemFails() public {
        (PackageItem memory item, MediaFile[] memory media) = _withCollab();
        _approve(address(fStream), item, RATE);
        bytes[] memory c = new bytes[](1);
        c[0] = _consent(collabKey, address(fEditions), item, RATE);
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, collab));
        _start(item, media, c);
        (PackageItem memory otherItem,) = _item(9);
        c[0] = _consent(collabKey, address(fStream), otherItem, RATE);
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, collab));
        _start(item, media, c);
    }

    function test_Authorize_AConsentByANonWalletOfTheCollaboratorFails() public {
        (PackageItem memory item, MediaFile[] memory media) = _withCollab();
        _approve(address(fStream), item, RATE);
        bytes[] memory c = new bytes[](1);
        c[0] = _consent(otherKey, address(fStream), item, RATE);
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, other));
        _start(item, media, c);
    }

    function test_Authorize_AnyWalletOfTheCollaboratorsAccountMayConsent() public {
        address collab2 = vm.addr(collab2Key);
        vm.prank(packageRegistry);
        accountsModule.register(collab, PROFILE, PROFILE_DOC);
        _consolidate(collab, collab2);
        (PackageItem memory item, MediaFile[] memory media) = _withCollab();
        _approve(address(fStream), item, RATE);
        bytes[] memory c = new bytes[](1);
        c[0] = _consent(collab2Key, address(fStream), item, RATE);
        _start(item, media, c);
    }

    function test_Authorize_ArtistResolvedPayeeMustBeAPartyWithAPayout() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        item.payees[0] = ISplitWallet.Payee(uint160(collab), address(0), 100_000);
        _refused(item, media); // not a party

        (PackageItem memory two, MediaFile[] memory m2) = _item(2);
        _approve(address(fStream), two, RATE);
        accountsModule.freeze(fArtistId); // a frozen account cannot act
        vm.expectRevert(
            abi.encodeWithSelector(IFederationRegistry.AccountCannotAct.selector, fArtistId)
        );
        _start(two, m2, new bytes[](0));
        accountsModule.unfreeze(fArtistId);
        _start(two, m2, new bytes[](0));
    }

    function test_Authorize_AFixedPayeeNeedsNoPayout() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        item.payees[0] = ISplitWallet.Payee(0, address(0xF1), 100_000);
        _approve(address(fStream), item, RATE);
        _start(item, media, new bytes[](0));
    }

    function test_Authorize_AtMostSixtyFourPayees() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        item.payees = new ISplitWallet.Payee[](65);
        for (uint256 i; i < 65; ++i) {
            item.payees[i] = ISplitWallet.Payee(0, address(uint160(0x100 + i)), 1);
        }
        _refused(item, media);
    }

    // ------------------------------------------------------------------ the answer

    function test_Authorize_DeploysTheVaultsAndAnswersExactly() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        _approve(address(fStream), item, RATE);
        address seller = ledger.walletFor(item.payees, 0);
        address royalty = ledger.walletFor(Splits.royaltyPayees(seller, feeVault, SHARE), 0);
        assertEq(seller.code.length, 0);
        assertEq(royalty.code.length, 0);
        bytes32 h = WorksHashing.itemHash(item);
        vm.expectEmit(address(registry));
        emit IFederationRegistry.ItemMinted(address(fStream), h, address(fedSale), seller, royalty);
        (uint256 id, MintFacts memory f, MintTerms memory t) = _start(item, media, new bytes[](0));
        assertGt(seller.code.length, 0, "seller vault deployed");
        assertGt(royalty.code.length, 0, "royalty vault deployed");
        assertEq(f.itemHash, h);
        assertEq(f.contentHash, item.contentHash);
        assertEq(f.artistId, fArtistId);
        assertEq(f.collectionId, 1);
        assertEq(f.kind, 0);
        assertEq(f.seedPolicy, 0);
        assertEq(f.seed, 0);
        assertEq(f.royaltyReceiver, royalty);
        assertEq(f.royaltyRate, RATE);
        assertEq(f.packageRoot, 0);
        assertEq(f.mediaHash, item.mediaHash);
        assertEq(f.recordFileId, item.recordFileId);
        assertEq(f.seller, seller);
        assertEq(t.saleKind, SaleKind.ENGLISH_AUCTION);
        assertEq(t.params, item.sale.params);
        assertEq(t.seller, seller);
        assertEq(t.feeRecipient, feeVault);
        assertEq(t.feeShare, registry.feeShareOf(address(fStream)));
        assertEq(t.creator, address(fStream));
        (address r,) = fStream.royaltyInfo(id, 1 ether);
        assertEq(r, royalty);
        assertEq(fStream.workOf(id).artistId, fArtistId);
    }

    function test_Authorize_AtZeroShareTheRoyaltyReceiverIsTheSeller() public {
        registry.lowerFeeShare(address(fStream), 0);
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        _approve(address(fStream), item, RATE);
        (, MintFacts memory f, MintTerms memory t) = _start(item, media, new bytes[](0));
        assertEq(f.royaltyReceiver, f.seller);
        assertEq(t.feeShare, 0);
    }

    function test_Authorize_UsesTheLoweredShare() public {
        registry.lowerFeeShare(address(fStream), 2_500);
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        _approve(address(fStream), item, RATE);
        (, MintFacts memory f, MintTerms memory t) = _start(item, media, new bytes[](0));
        assertEq(t.feeShare, 2_500);
        assertEq(
            f.royaltyReceiver, ledger.walletFor(Splits.royaltyPayees(f.seller, feeVault, 2_500), 0)
        );
    }

    function test_Preview_EqualsAuthorizeWithoutConsumingOrDeploying() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        _approve(address(fStream), item, RATE);
        bytes memory req = _request(item, media, new bytes[](0));
        vm.prank(stranger); // anyone may preview
        (MintFacts memory pf, MintTerms memory pt) = registry.preview(address(fStream), req);
        assertEq(pf.seller.code.length, 0, "nothing deployed");
        assertFalse(registry.itemOf(address(fStream), WorksHashing.itemHash(item)).used);
        (, MintFacts memory f, MintTerms memory t) =
            fedSale.start(address(registry), address(fStream), req);
        assertEq(abi.encode(pf), abi.encode(f));
        assertEq(abi.encode(pt), abi.encode(t));
    }

    function test_Preview_RefusesAnUnapprovedItem() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        vm.expectRevert(_notApproved(WorksHashing.itemHash(item)));
        registry.preview(address(fStream), _request(item, media, new bytes[](0)));
    }

    // ------------------------------------------------------------------ content release

    /// @dev Mints item 1, burns it in sale custody, and returns a second item of the same
    ///      content (another record).
    function _burnedContent()
        internal
        returns (
            uint256 burned,
            PackageItem memory again,
            MediaFile[] memory media,
            bytes32 burnedHash
        )
    {
        PackageItem memory item;
        (item, media) = _item(1);
        _approve(address(fStream), item, RATE);
        (burned,,) = _start(item, media, new bytes[](0));
        fedSale.burn(address(fStream), burned);
        burnedHash = WorksHashing.itemHash(item);
        again = item;
        again.recordFileId = _file("another record", "application/json");
    }

    function test_Content_ALiveTokenHoldsItsContent() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        _approve(address(fStream), item, RATE);
        (uint256 id,,) = _start(item, media, new bytes[](0));
        PackageItem memory again = item;
        again.recordFileId = _file("another record", "application/json");
        _approve(address(fStream), again, RATE);
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, item.contentHash, id)
        );
        _start(again, media, new bytes[](0));
    }

    function test_Content_ABurnedContentMintsOnlyAfterARelease() public {
        (uint256 burned, PackageItem memory again, MediaFile[] memory media, bytes32 burnedHash) =
            _burnedContent();
        _approve(address(fStream), again, RATE);
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, again.contentHash, burned)
        );
        _start(again, media, new bytes[](0));

        vm.expectEmit(address(registry));
        emit IMintPolicy.ContentReleased(address(fStream), burned, again.contentHash, fArtistId);
        vm.expectEmit(address(registry));
        emit IFederationRegistry.ItemBarred(burnedHash);
        registry.releaseContent(address(fStream), burned, again.contentHash, fArtistId);
        assertEq(registry.releasedTo(address(fStream), again.contentHash), fArtistId);
        assertTrue(registry.isBarred(burnedHash));

        (uint256 id,,) = _start(again, media, new bytes[](0));
        assertEq(fStream.tokenOfContent(again.contentHash), id);
        assertEq(registry.releasedTo(address(fStream), again.contentHash), 0, "spent");
    }

    function test_Content_TheBurnedItemIsBarred() public {
        (uint256 burned, PackageItem memory again,, bytes32 burnedHash) = _burnedContent();
        registry.releaseContent(address(fStream), burned, again.contentHash, fArtistId);
        vm.prank(artist);
        vm.expectRevert(_notApproved(burnedHash));
        registry.approveItem(address(fStream), burnedHash, RATE);
    }

    /// @dev The bar is by item hash, for every contract: another contract of the same artist
    ///      can neither approve the burned item nor mint it if it approved it before the release.
    function test_Content_TheBurnedItemIsBarredInEveryContract() public {
        FederatedStream second = _deployStream(fArtistId, keccak256("second"));
        _join(address(second), artistKey, artistKey, address(streamDeployer));
        (uint256 burned, PackageItem memory again,, bytes32 burnedHash) = _burnedContent();
        vm.prank(artist);
        registry.approveItem(address(second), burnedHash, RATE); // before the release
        registry.releaseContent(address(fStream), burned, again.contentHash, fArtistId);
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederationRegistry.ItemNotApproved.selector, address(second), burnedHash
            )
        );
        registry.approveItem(address(second), burnedHash, RATE);
        assertTrue(registry.itemOf(address(second), burnedHash).approved);
    }

    function test_Content_ABarredItemApprovedBeforeTheReleaseCannotMint() public {
        FederatedStream second = _deployStream(fArtistId, keccak256("second"));
        _join(address(second), artistKey, artistKey, address(streamDeployer));
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        _approve(address(fStream), item, RATE);
        _approve(address(second), item, RATE);
        (uint256 burned,,) = _start(item, media, new bytes[](0));
        fedSale.burn(address(fStream), burned);
        registry.releaseContent(address(fStream), burned, item.contentHash, fArtistId);
        bytes32 h = WorksHashing.itemHash(item);
        vm.expectRevert(
            abi.encodeWithSelector(IFederationRegistry.ItemNotApproved.selector, address(second), h)
        );
        fedSale.start(address(registry), address(second), _request(item, media, new bytes[](0)));
    }

    function test_Content_ATwinApprovedBeforeTheReleaseMintsAfterIt() public {
        (uint256 burned, PackageItem memory again, MediaFile[] memory media,) = _burnedContent();
        _approve(address(fStream), again, RATE);
        registry.releaseContent(address(fStream), burned, again.contentHash, fArtistId);
        bytes32 h = WorksHashing.itemHash(again);
        assertFalse(registry.isBarred(h));
        _start(again, media, new bytes[](0));
    }

    function test_Content_AReleaseIsForTheBurnedTokenOnly() public {
        (uint256 burned, PackageItem memory again, MediaFile[] memory media,) = _burnedContent();
        registry.releaseContent(address(fStream), burned, again.contentHash, fArtistId);
        (uint256 second,,) = _startApproved(again, media);
        fedSale.burn(address(fStream), second);
        PackageItem memory third = again;
        third.recordFileId = _file("third record", "application/json");
        _approve(address(fStream), third, RATE);
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, again.contentHash, second)
        );
        _start(third, media, new bytes[](0));
    }

    function _startApproved(PackageItem memory item, MediaFile[] memory media)
        internal
        returns (uint256 id, MintFacts memory f, MintTerms memory t)
    {
        _approve(address(fStream), item, RATE);
        return _start(item, media, new bytes[](0));
    }

    function test_ReleaseContent_Refusals() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        _approve(address(fStream), item, RATE);
        (uint256 live,,) = _start(item, media, new bytes[](0));
        bytes32 c = item.contentHash;
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederationRegistry.ReleaseRefused.selector, address(fStream), live
            )
        );
        registry.releaseContent(address(fStream), live, c, fArtistId); // live
        fedSale.burn(address(fStream), live);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederationRegistry.ReleaseRefused.selector, address(fStream), live + 1
            )
        );
        registry.releaseContent(address(fStream), live + 1, c, fArtistId); // wrong token
        vm.expectRevert(
            abi.encodeWithSelector(IFederationRegistry.ReleaseRefused.selector, address(fStream), 0)
        );
        registry.releaseContent(address(fStream), 0, keccak256("never"), fArtistId);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederationRegistry.ReleaseRefused.selector, address(fStream), live
            )
        );
        registry.releaseContent(address(fStream), live, c, uint160(other)); // another artist
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederationRegistry.ReleaseRefused.selector, address(fEditions), live
            )
        );
        registry.releaseContent(address(fEditions), live, c, fArtistId); // not a 1/1 contract
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        registry.releaseContent(address(fStream), live, c, fArtistId);
        registry.releaseContent(address(fStream), live, c, fArtistId);
    }

    function test_ReleasedTo_ZeroWithoutARelease() public view {
        assertEq(registry.releasedTo(address(fStream), keccak256("none")), 0);
        assertFalse(registry.isBarred(keccak256("none")));
    }
}

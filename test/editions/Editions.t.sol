// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { IERC1155Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {
    IERC1155MetadataURI
} from "@openzeppelin/contracts/token/ERC1155/extensions/IERC1155MetadataURI.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { EditionRules } from "src/editions/EditionRules.sol";
import { Editions } from "src/editions/Editions.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import {
    CURRENCY_ETH,
    PRODUCT_EDITIONS,
    ProductEconomics,
    WorkTerms
} from "src/interfaces/types/EconomicsTypes.sol";
import {
    EditionTerms,
    ItemKind,
    License,
    PackageItem,
    Party,
    PartyRole,
    SeedPolicy
} from "src/interfaces/types/PackageTypes.sol";
import { PrimaryOutcome, PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { EditionsBase } from "./EditionsBase.sol";
import { StateGrowth } from "../helpers/StateGrowth.sol";
import {
    EditionsAdapterMock,
    EditionsPackages,
    EditionsRendererMock,
    EditionsStreamMock,
    EditionsWorkRecordsMock,
    GasBurnerReceiver1155,
    NoHookReceiver1155,
    ReentrantReceiver1155,
    RevertingReceiver1155,
    WrongSelectorReceiver1155
} from "../mocks/editions/EditionsMocks.sol";
import { Dependency } from "src/libraries/Dependency.sol";

/// @dev An ERC-721 by ERC-165 that is not `IStream`.
contract ERC721OnlyStream {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC721).interfaceId;
    }
}

/// @dev An ERC-721 by ERC-165 that reports no economics resolver.
contract UnwiredStream {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId != 0xffffffff;
    }

    function packageRegistry() external pure returns (address) {
        return address(1);
    }

    function economics() external pure returns (address) {
        return address(0);
    }

    function artistRegistry() external pure returns (address) {
        return address(3);
    }
}

contract EditionsTest is EditionsBase {
    /// @dev EIP-7825 (Fusaka): no transaction may use more gas than this.
    uint256 internal constant TX_GAS_CAP = 16_777_216;
    /// @dev rc.1's fixed-price label: a sale method an adapter added later may claim again.
    bytes32 internal constant FIXED_PRICE = keccak256("FIXED_PRICE");

    event ContentClaimed(bytes32 indexed contentHash, bytes32 indexed itemHash);
    event EditionLinked(uint256 indexed tokenId, address indexed editions, uint256 editionId);

    // ------------------------------------------------------------------ deployment

    function test_Constructor_WiresFromStream() public view {
        assertEq(editions.stream(), address(stream));
        assertEq(address(editions.packageRegistry()), address(registry));
        assertEq(address(editions.economics()), address(economics));
        assertEq(address(editions.artistRegistry()), address(artists));
        assertEq(editions.workRecords(), address(workRecordsMock));
        assertEq(editions.owner(), marketOwner);
        assertEq(editions.authority(), address(manager));
        assertEq(editions.contractURI(), "");
    }

    function test_Constructor_EmitsOwnership() public {
        vm.expectEmit(true, true, false, false);
        emit IEditions.OwnershipTransferred(address(0), marketOwner);
        _freshEditions();
    }

    function test_Constructor_RejectsMissingWiring() public {
        address unwired = address(new UnwiredStream());
        vm.expectRevert(IEditions.ZeroAddress.selector);
        new Editions(address(manager), unwired, unwired.codehash, marketOwner);
    }

    /// @dev ADR 0001 section 13.6 install checks: code, no EIP-7702 delegation, ERC-165 for
    ///      ERC-721, and the reviewed code hash.
    function test_Constructor_ChecksStreamInstall() public {
        _expectInvalidStream(address(0));
        _expectInvalidStream(outsider); // an EOA
        address delegated = makeAddr("delegated");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(stream)));
        _expectInvalidStream(delegated);
        _expectInvalidStream(address(renderer)); // code, but no ERC-165
        _expectInvalidStream(address(new ERC721OnlyStream())); // an ERC-721, but not IStream
        bytes32 wrong = keccak256("not the reviewed stream");
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(stream))
        );
        new Editions(address(manager), address(stream), wrong, marketOwner);
        // A wrong pin is refused whichever way it sorts against the code's hash.
        bytes32[2] memory extremes = [bytes32(0), bytes32(type(uint256).max)];
        for (uint256 i; i < extremes.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(stream))
            );
            new Editions(address(manager), address(stream), extremes[i], marketOwner);
        }
    }

    function _expectInvalidStream(address s) internal {
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, s));
        new Editions(address(manager), s, s.codehash, marketOwner);
    }

    function _freshEditions() internal returns (Editions) {
        return
            new Editions(address(manager), address(stream), address(stream).codehash, marketOwner);
    }

    // ------------------------------------------------------------------ createEdition

    function test_CreateEdition_LinksBothWaysAndLocksTerms() public {
        PackageItem memory item = _item(50);
        uint256 id = _master(item);
        bytes32 itemHash = WorksHashing.itemHash(item);
        WorkTerms memory w = economics.newWorkTerms(PRODUCT_EDITIONS, item.payees);

        vm.expectEmit(true, true, false, true, address(editions));
        emit IEditions.EditionCreated(id, item.contentHash, item.edition);
        vm.expectEmit(false, false, false, true, address(editions));
        emit IEditions.MetadataUpdate(id);
        vm.expectEmit(true, true, false, true, address(registry));
        emit ContentClaimed(item.contentHash, itemHash);
        vm.expectEmit(true, true, false, true, address(stream));
        emit EditionLinked(id, address(editions), id);
        vm.prank(outsider); // permissionless
        assertEq(_createEdition(id, item), id, "edition ID is the master's token ID");

        // Editions -> Stream: (stream, workId, contentHash).
        (address s, uint256 workId, bytes32 contentHash) = editions.masterOf(id);
        assertEq(s, address(stream));
        assertEq(workId, id);
        assertEq(contentHash, item.contentHash);
        assertEq(editions.contentHashOf(id), item.contentHash);
        assertTrue(editions.exists(id));
        // Stream -> Editions.
        (address e, uint256 editionId) = stream.editionOf(id);
        assertEq(e, address(editions));
        assertEq(editionId, id);

        IEditions.Edition memory ed = editions.edition(id);
        assertEq(ed.contentHash, item.contentHash);
        assertEq(keccak256(abi.encode(ed.terms)), keccak256(abi.encode(item.edition)));
        assertEq(ed.minted, 0);
        assertEq(ed.minter, address(0), "bound by the first mint");
        assertEq(ed.seller, w.seller);
        assertEq(ed.feeRecipient, feeRecipient);
        assertEq(ed.feeShare, 25_000);
        assertEq(ed.royaltyReceiver, w.royaltyReceiver);
        assertEq(ed.royaltyRate, 6_529);
        // Uniqueness: Stream consumed the hash for the master, Editions claimed it for the edition.
        assertEq(registry.consumedItemOf(item.contentHash), itemHash);
        assertEq(registry.editionClaimOf(item.contentHash), itemHash);
    }

    function test_CreateEdition_RefusesOriginalItem() public {
        PackageItem memory item = _item(10);
        item.kind = ItemKind.ORIGINAL;
        uint256 id = _master(item);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotEditionMaster.selector, id));
        _createEdition(id, item);
        // Relabelling the item as a master changes its hash, so it matches nothing.
        item.kind = ItemKind.EDITION_MASTER;
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotEditionMaster.selector, id));
        _createEdition(id, item);
    }

    function test_CreateEdition_RefusesMismatchedItem() public {
        PackageItem memory item = _item(10);
        uint256 id = _master(item);
        PackageItem memory other = _item(10); // another master's item
        uint256 otherId = _master(other);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotEditionMaster.selector, id));
        _createEdition(id, other);
        // And the other way round, so one of the two item hashes sorts below its master's
        // (mutation testing).
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotEditionMaster.selector, otherId));
        _createEdition(otherId, item);
    }

    /// @dev Any change to the approved item (here: cap, params, content hash, payees, license)
    ///      breaks the item hash Stream stored for the master.
    function testFuzz_CreateEdition_RefusesTamperedItem(uint8 field, uint256 value) public {
        PackageItem memory item = _item(10);
        uint256 id = _master(item);
        field = uint8(bound(field, 0, 4));
        value = bound(value, 1, type(uint64).max);
        if (field == 0) item.edition.maxCount += uint32(value % 1000) + 1;
        if (field == 1) item.edition.params = abi.encode(value);
        if (field == 2) item.contentHash = bytes32(uint256(item.contentHash) ^ value);
        if (field == 3) item.payees[0].share -= 1;
        if (field == 4) item.license.spdxId = "LicenseRef-AllRightsReserved";
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotEditionMaster.selector, id));
        _createEdition(id, item);
    }

    /// @dev The registry accepts a claim only for the item Stream consumed for that content hash.
    function test_CreateEdition_RefusesHashConsumedByAnotherItem() public {
        PackageItem memory item = _item(10);
        uint256 id = _master(item);
        registry.setConsumedItem(item.contentHash, keccak256("another item"));
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ClaimNotAllowed.selector, PRODUCT_EDITIONS, item.contentHash
            )
        );
        _createEdition(id, item);
    }

    /// @dev L-1: no edition before the work-records satellite is bound, since an edition's
    ///      license and record updates go through it.
    function test_CreateEdition_RequiresBoundWorkRecords() public {
        // Stream and the registry already bind this Editions; only its own bind is missing.
        Editions fresh = _freshEditions();
        stream.bind(address(workRecordsMock), address(fresh));
        registry.bindCallers(address(stream), address(fresh));
        PackageItem memory item = _item(10);
        uint256 id = _master(item);
        (bytes32 root, bytes32[] memory proof) = EditionsPackages.packageOf(item, 0);
        vm.expectRevert(IEditions.WorkRecordsUnbound.selector);
        fresh.createEdition(id, item, root, proof);
        assertEq(fresh.workRecords(), address(0));
        vm.prank(admin);
        fresh.bindWorkRecords(address(workRecordsMock));
        fresh.createEdition(id, item, root, proof);
        assertTrue(fresh.exists(id));
    }

    /// @dev A zero content hash is refused even where the registry would let it through (the
    ///      mock does; the real one refuses it at `consume`): `exists` keys on the hash.
    function test_CreateEdition_RefusesZeroContentHash() public {
        PackageItem memory item = _item(10);
        item.contentHash = bytes32(0);
        uint256 id = _master(item);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotEditionMaster.selector, id));
        _createEdition(id, item);
    }

    function test_CreateEdition_RefusesUnknownMaster() public {
        PackageItem memory item = _item(10);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, 1));
        _createEdition(1, item);
    }

    /// @dev D14: a master still in auction custody, live or paused for a dispute, gets no
    ///      edition; an upheld dispute burns it, so it never does.
    function test_CreateEdition_RequiresSettledMaster() public {
        PackageItem memory item = _item(10);
        uint256 id = _masterInAuction(item);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotEditionMaster.selector, id));
        _createEdition(id, item);
        stream.burnMaster(id); // dispute upheld
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, id));
        _createEdition(id, item);

        PackageItem memory sold = _item(10);
        uint256 soldId = _masterInAuction(sold);
        stream.settle(soldId, COLLECTOR);
        _createEdition(soldId, sold);
        assertTrue(editions.exists(soldId));
    }

    /// Regression: SIGS-4 (docs/security/internal-review-2026-10.md)
    /// @dev The caller proves the item in a package root the registry registered. SIGS-4: a
    ///      revocation after the master sold no longer blocks its edition (it stops unconsumed
    ///      items only); a root never registered, or revoked before registration, proves nothing.
    function test_CreateEdition_RequiresARegisteredPackageProof() public {
        PackageItem memory item = _item(10);
        uint256 id = _master(item);
        (bytes32 root, bytes32[] memory proof) = EditionsPackages.packageOf(item, 0);
        bytes memory notMaster = abi.encodeWithSelector(IEditions.NotEditionMaster.selector, id);

        vm.expectRevert(notMaster);
        editions.createEdition(id, item, root, new bytes32[](0)); // no proof
        bytes32[] memory deep = new bytes32[](Limits.MAX_PROOF_DEPTH + 1);
        vm.expectRevert(notMaster);
        editions.createEdition(id, item, root, deep); // deeper than any package
        (bytes32 unknownRoot, bytes32[] memory unknownProof) = EditionsPackages.packageOf(item, 7);
        vm.expectRevert(notMaster);
        editions.createEdition(id, item, unknownRoot, unknownProof); // never approved
        registry.revoke(unknownRoot);
        vm.expectRevert(notMaster);
        editions.createEdition(id, item, unknownRoot, unknownProof); // revoked unregistered

        registry.revoke(root);
        editions.createEdition(id, item, root, proof);
        assertTrue(editions.exists(id), "revoked after the master sold: still its edition");
    }

    /// @dev A chain-shaped package puts the item `depth` levels deep, so its proof has `depth`
    ///      nodes. At `Limits.MAX_PROOF_DEPTH` it is accepted; one level deeper it is refused even
    ///      though the proof verifies against an approved root.
    function test_CreateEdition_ProofDepthBounded() public {
        uint256 max = Limits.MAX_PROOF_DEPTH;
        PackageItem memory item = _item(5);
        uint256 id = _master(item);
        (bytes32 deepRoot, bytes32[] memory deepProof) = _chain(item, max + 1);
        registry.approve(deepRoot);
        assertTrue(
            MerkleProof.verify(deepProof, deepRoot, WorksHashing.leaf(WorksHashing.itemHash(item))),
            "the over-deep proof itself verifies"
        );
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotEditionMaster.selector, id));
        editions.createEdition(id, item, deepRoot, deepProof);

        (bytes32 root, bytes32[] memory proof) = _chain(item, max);
        registry.approve(root);
        editions.createEdition(id, item, root, proof);
        assertTrue(editions.exists(id));
    }

    function _chain(PackageItem memory item, uint256 depth)
        internal
        pure
        returns (bytes32 node, bytes32[] memory proof)
    {
        node = WorksHashing.leaf(WorksHashing.itemHash(item));
        proof = new bytes32[](depth);
        for (uint256 i; i < depth; ++i) {
            bytes32 sibling = keccak256(abi.encode("chain", i));
            proof[i] = sibling;
            node = node < sibling
                ? keccak256(abi.encode(node, sibling))
                : keccak256(abi.encode(sibling, node));
        }
    }

    /// @dev An item listed in two packages passes through either registered root.
    function test_CreateEdition_SecondApprovedPackageAdmits() public {
        PackageItem memory item = _item(10);
        uint256 id = _master(item);
        (bytes32 rootA,) = EditionsPackages.packageOf(item, 0);
        registry.revoke(rootA);
        (bytes32 rootB, bytes32[] memory proofB) = EditionsPackages.packageOf(item, 1);
        registry.approve(rootB);
        editions.createEdition(id, item, rootB, proofB);
        assertTrue(editions.exists(id));
    }

    function test_CreateEdition_RefusesSecondCreate() public {
        PackageItem memory item = _item(10);
        uint256 id = _create(item);
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionExists.selector, id));
        _createEdition(id, item);
    }

    function test_CreateEdition_ReentryThroughStreamHitsEditionExists() public {
        PackageItem memory item = _item(10);
        uint256 id = _master(item);
        stream.setReentryItem(item);
        stream.setLinkMode(EditionsStreamMock.LinkMode.REENTER);
        _createEdition(id, item);
        assertEq(
            stream.reentryError(), abi.encodeWithSelector(IEditions.EditionExists.selector, id)
        );
        (address e, uint256 editionId) = stream.editionOf(id);
        assertEq(e, address(editions));
        assertEq(editionId, id);
    }

    /// @dev A VRF master's seed is delivered before its auction starts (D4), so a settled VRF
    ///      master links like any other.
    function test_CreateEdition_SettledVrfMaster() public {
        PackageItem memory item = _item(10);
        item.seedPolicy = SeedPolicy.VRF;
        uint256 id = _create(item);
        assertTrue(editions.exists(id));
    }

    /// @dev `EditionRules` (ADR 0005, owner decision 14): a nonzero sale kind and bounded
    ///      params; the currency and params are the sale method's, checked by its adapter.
    function test_CreateEdition_RefusesMalformedTerms() public {
        PackageItem memory item = _item(5);
        item.edition.saleKind = 0;
        _expectBadTerms(item);
        item = _item(0);
        item.edition.saleKind = FIXED_PRICE;
        item.edition.params = new bytes(EditionRules.MAX_PARAMS_BYTES + 1);
        _expectBadTerms(item);
        // Opaque to the token: any currency and params within the bound.
        item = _item(0);
        item.edition.currency = address(type(uint160).max);
        item.edition.params = new bytes(EditionRules.MAX_PARAMS_BYTES);
        assertTrue(editions.exists(_create(item)));
    }

    /// @dev A master whose edition another sale method sells: a fixed price in an ERC-20,
    ///      carried in its params.
    function _fixedPriceItem(uint32 maxCount) internal returns (PackageItem memory item) {
        item = _item(maxCount);
        item.edition.saleKind = FIXED_PRICE;
        item.edition.currency = makeAddr("usd");
        item.edition.params = abi.encode(uint256(25e6));
    }

    function _expectBadTerms(PackageItem memory item) internal {
        uint256 id = _master(item);
        vm.expectRevert(abi.encodeWithSelector(IEditions.InvalidEditionTerms.selector, id));
        _createEdition(id, item);
    }

    /// @dev Edition auctions are ETH-only with no reserve: the terms report ETH, no price and no
    ///      params, before and after the first mint, capped or not.
    function test_PrimaryTerms_EthWithoutPrice() public {
        uint256 capped = _create(_item(10));
        uint256 open = _create(_item(0));
        uint256[2] memory ids = [capped, open];
        for (uint256 i; i < ids.length; ++i) {
            PrimaryTerms memory t = editions.primaryTerms(ids[i], "");
            assertEq(t.saleKind, SaleKind.UNIFORM_AUCTION);
            assertEq(t.currency, CURRENCY_ETH);
            assertEq(t.price, 0);
            assertEq(t.params, "");
            adapter.buy(editions, ids[i], buyer, 1);
            assertEq(
                keccak256(abi.encode(editions.primaryTerms(ids[i], ""))),
                keccak256(abi.encode(t)),
                "a mint changes no terms"
            );
        }
        assertEq(editions.edition(capped).terms.maxCount, 10);
        assertEq(editions.edition(open).terms.maxCount, 0);
    }

    /// @dev The one permitted reuse: the edition carries its master's hash, which Stream consumed
    ///      under PRODUCT_STREAM. A hash an edition already claimed is refused, here for a twin
    ///      master the mock let through Stream's own check.
    function test_CreateEdition_ContentHashUniqueAmongEditions() public {
        PackageItem memory first = _item(10);
        _create(first);

        registry.setSkipStreamUniqueness(true);
        PackageItem memory twin = _item(10);
        twin.contentHash = first.contentHash;
        uint256 twinId = _master(twin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ContentUsed.selector,
                PRODUCT_EDITIONS,
                first.contentHash,
                WorksHashing.itemHash(first)
            )
        );
        _createEdition(twinId, twin);
    }

    function test_CreateEdition_RefusesHashClaimedInEditions() public {
        PackageItem memory item = _item(10);
        uint256 id = _master(item);
        bytes32 claimedBy = keccak256("earlier claim");
        registry.preclaim(item.contentHash, claimedBy);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ContentUsed.selector, PRODUCT_EDITIONS, item.contentHash, claimedBy
            )
        );
        _createEdition(id, item);
    }

    function test_CreateEdition_FailsClosedWhenStreamDoesNotLink() public {
        PackageItem memory item = _item(10);
        uint256 id = _master(item);
        stream.setLinkMode(EditionsStreamMock.LinkMode.IGNORE);
        vm.expectRevert(abi.encodeWithSelector(IEditions.LinkFailed.selector, id));
        _createEdition(id, item);
        stream.setLinkMode(EditionsStreamMock.LinkMode.WRONG_ID);
        vm.expectRevert(abi.encodeWithSelector(IEditions.LinkFailed.selector, id));
        _createEdition(id, item);
        assertFalse(editions.exists(id), "nothing persists");
    }

    function test_CreateEdition_RequiresStreamToBindThisContract() public {
        PackageItem memory item = _item(10);
        uint256 id = _master(item);
        stream.bind(address(workRecordsMock), outsider);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnboundCaller.selector, address(editions)));
        _createEdition(id, item);
    }

    function test_CreateEdition_LinkIsPermanent() public {
        PackageItem memory item = _item(3);
        uint256 id = _create(item);
        adapter.buy(editions, id, buyer, 3);
        workRecordsMock.setLicense(id, License("CC-BY-4.0", keccak256("by")));
        stream.pinRenderer(id, address(new EditionsRendererMock("pinned")));
        economics.setEconomics(ProductEconomics(outsider, 1, 1));
        (address s, uint256 workId, bytes32 contentHash) = editions.masterOf(id);
        assertEq(s, address(stream));
        assertEq(workId, id);
        assertEq(contentHash, item.contentHash);
        (address e, uint256 editionId) = stream.editionOf(id);
        assertEq(e, address(editions));
        assertEq(editionId, id);
    }

    /// @dev EIP-7825: `createEdition` for an item at `Limits.MAX_PARTIES` parties and payees, of
    ///      another sale kind storing the most params `EditionRules` allows, fits the transaction
    ///      cap with wide margin (Editions' own work; the real registry and resolver add their
    ///      share).
    function test_Gas_CreateEditionWorstCaseFitsTxCap() public {
        PackageItem memory item = _fixedPriceItem(type(uint32).max);
        item.edition.params = new bytes(EditionRules.MAX_PARAMS_BYTES);
        for (uint256 i; i < item.edition.params.length; ++i) {
            item.edition.params[i] = 0xff;
        }
        uint256 n = Limits.MAX_PARTIES;
        item.parties = new Party[](n);
        item.payees = new ISplitWallet.Payee[](n);
        for (uint256 i; i < n; ++i) {
            address account = address(uint160(0x1000 + i));
            item.parties[i] = Party(account, i == 0 ? PartyRole.ARTIST : PartyRole.COLLABORATOR);
            item.payees[i] = ISplitWallet.Payee(0, account, uint32(100_000 / n));
        }
        item.payees[n - 1].share += uint32(100_000 % n);
        item.license.spdxId = "LicenseRef-6529-Works-Custom-License-With-A-Long-Identifier";
        uint256 id = _master(item);
        (bytes32 root, bytes32[] memory proof) = EditionsPackages.packageOf(item, 0);
        // Calldata cost: a nonzero selector stand-in plus the ABI-encoded arguments.
        bytes memory callData = bytes.concat(bytes4(0xffffffff), abi.encode(id, item, root, proof));
        uint256 g = gasleft();
        editions.createEdition(id, item, root, proof);
        uint256 execution = g - gasleft();
        uint256 txGas = 21_000 + _calldataGas(callData) + execution;
        console2.log("createEdition worst case: execution", execution);
        console2.log("createEdition worst case: transaction", txGas);
        assertLe(txGas, TX_GAS_CAP / 8, "an eighth of the EIP-7825 cap");
    }

    /// @dev One claim's token-side cost: the first copies to a new holder, binding the edition
    ///      to its adapter, are the most expensive mint.
    function test_Gas_MintFirstCopy() public {
        uint256 id = _create(_item(100));
        vm.prank(address(adapter));
        uint256 g = gasleft();
        editions.mint(buyer, id, 1, "");
        uint256 used = g - gasleft();
        console2.log("mint, first copies of an edition: execution", used);
        assertLt(used, 150_000);
    }

    // ------------------------------------------------------------------ minting

    function test_Mint_ToBuyer() public {
        PackageItem memory item = _item(10);
        uint256 id = _create(item);
        vm.expectEmit(true, true, true, true, address(editions));
        emit IERC1155.TransferSingle(address(adapter), address(0), buyer, id, 3);
        (uint256 tokenId, PrimaryTerms memory minted) = adapter.buy(editions, id, buyer, 3);
        assertEq(tokenId, id);
        assertEq(editions.balanceOf(buyer, id), 3);
        assertEq(editions.edition(id).minted, 3);
        // `mint` returns only the sale kind (QUALITY-2); the adapter applies the terms it locked
        // from `primaryTerms` when the sale opened.
        PrimaryTerms memory kindOnly;
        kindOnly.saleKind = SaleKind.UNIFORM_AUCTION;
        assertEq(keccak256(abi.encode(minted)), keccak256(abi.encode(kindOnly)));
        PrimaryTerms memory terms = editions.primaryTerms(id, "");
        WorkTerms memory w = economics.newWorkTerms(PRODUCT_EDITIONS, item.payees);
        assertEq(terms.saleKind, SaleKind.UNIFORM_AUCTION);
        assertEq(terms.currency, CURRENCY_ETH);
        assertEq(terms.price, 0);
        assertEq(terms.params, "");
        assertEq(terms.seller, w.seller);
        assertEq(terms.feeRecipient, feeRecipient);
        assertEq(terms.feeShare, 25_000);
        assertEq(terms.creator, artist);
    }

    function test_Mint_OnlyAdmittedMinter() public {
        uint256 id = _create(_item(10));
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, outsider));
        editions.mint(outsider, id, 1, "");
        // An adapter that was removed can no longer mint.
        vm.prank(governor);
        editions.setAdmittedMinter(address(adapter), false);
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(adapter))
        );
        adapter.buy(editions, id, buyer, 1);
    }

    /// @dev E4: admission is a governed setter (the 30-day class in deployment); an admitted
    ///      adapter must support `ISaleAdapter` by ERC-165 and not be an EIP-7702 account.
    function test_SetAdmittedMinter_GovernedAndChecked() public {
        address fresh = address(new EditionsAdapterMock(SaleKind.UNIFORM_AUCTION));
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        editions.setAdmittedMinter(fresh, true);

        vm.startPrank(governor);
        _expectNotAdmissible(outsider); // an EOA
        _expectNotAdmissible(address(renderer)); // code, but not an ISaleAdapter
        address delegated = makeAddr("delegatedAdapter");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", fresh));
        _expectNotAdmissible(delegated);

        vm.expectEmit(true, false, false, true, address(editions));
        emit IMintTarget.AdmittedMinterSet(fresh, true);
        editions.setAdmittedMinter(fresh, true);
        assertTrue(editions.isAdmittedMinter(fresh));
        vm.expectEmit(true, false, false, true, address(editions));
        emit IMintTarget.AdmittedMinterSet(fresh, false);
        editions.setAdmittedMinter(fresh, false);
        assertFalse(editions.isAdmittedMinter(fresh));

        // Emits only on a change: removing a never-admitted or already-removed address, or
        // admitting an admitted adapter, is a silent no-op.
        vm.recordLogs();
        editions.setAdmittedMinter(outsider, false); // never admitted (and not admissible)
        editions.setAdmittedMinter(fresh, false); // already removed
        editions.setAdmittedMinter(address(adapter), true); // already admitted
        assertEq(vm.getRecordedLogs().length, 0);
        assertFalse(editions.isAdmittedMinter(outsider));
        assertTrue(editions.isAdmittedMinter(address(adapter)));
        vm.stopPrank();
        // The never-admitted address gained no burn right from the no-op removal.
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, outsider));
        editions.burn(1, 1);
    }

    function _expectNotAdmissible(address candidate) internal {
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, candidate));
        editions.setAdmittedMinter(candidate, true);
    }

    /// @dev Only an adapter reporting the edition's own sale kind mints, even when admitted.
    function test_Mint_RequiresTheEditionsSaleKind() public {
        uint256 id = _create(_item(10));
        bytes32[3] memory kinds = [SaleKind.ENGLISH_AUCTION, FIXED_PRICE, keccak256("DUTCH")];
        for (uint256 i; i < kinds.length; ++i) {
            EditionsAdapterMock other = new EditionsAdapterMock(kinds[i]);
            vm.prank(governor);
            editions.setAdmittedMinter(address(other), true);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IMintTarget.SaleKindMismatch.selector, SaleKind.UNIFORM_AUCTION, kinds[i]
                )
            );
            other.buy(editions, id, buyer, 1);
        }
        assertEq(editions.edition(id).minter, address(0), "a refused mint binds nothing");
        adapter.buy(editions, id, buyer, 1);

        // An edition of another kind refuses the auction.
        uint256 fixedId = _create(_fixedPriceItem(10));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintTarget.SaleKindMismatch.selector, FIXED_PRICE, SaleKind.UNIFORM_AUCTION
            )
        );
        adapter.buy(editions, fixedId, buyer, 1);
    }

    /// @dev Owner decision 14: a sale method added later is a new adapter that governance
    ///      admits; it mints the editions whose terms name its kind, in their own currency and
    ///      params, with no redeployment of Editions (here, a fixed-price adapter such as
    ///      rc.1's `FixedPriceSale` restored).
    function test_Mint_ANewSaleMethodAdmittedLaterMints() public {
        PackageItem memory item = _fixedPriceItem(25);
        uint256 id = _create(item);
        EditionsAdapterMock fixedPrice = new EditionsAdapterMock(FIXED_PRICE);
        assertFalse(editions.isAdmittedMinter(address(fixedPrice)));
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(fixedPrice))
        );
        fixedPrice.buy(editions, id, buyer, 1);

        vm.prank(governor); // SUCCESSOR_SETTER: the 30-day class in deployment
        editions.setAdmittedMinter(address(fixedPrice), true);
        (uint256 tokenId, PrimaryTerms memory minted) = fixedPrice.buy(editions, id, buyer, 25);
        assertEq(tokenId, id);
        assertEq(minted.saleKind, FIXED_PRICE);
        assertEq(editions.balanceOf(buyer, id), 25);
        assertEq(editions.edition(id).minter, address(fixedPrice));
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id));
        fixedPrice.buy(editions, id, buyer, 1);

        // The adapter reads its currency and params back as approved.
        PrimaryTerms memory t = editions.primaryTerms(id, "");
        assertEq(t.saleKind, FIXED_PRICE);
        assertEq(t.currency, item.edition.currency);
        assertEq(t.price, 0);
        assertEq(keccak256(t.params), keccak256(item.edition.params));
        assertEq(
            keccak256(abi.encode(editions.edition(id).terms)), keccak256(abi.encode(item.edition))
        );
    }

    /// @dev The first admitted adapter to mint an edition binds it: no other adapter, admitted
    ///      before or after, can add copies, so the count the auction cleared is final.
    function test_Mint_BindsTheEditionToItsFirstMinter() public {
        uint256 id = _create(_item(0));
        uint256 other = _create(_item(0));
        vm.expectEmit(true, true, false, true, address(editions));
        emit IEditions.EditionMinterBound(id, address(adapter));
        adapter.buy(editions, id, buyer, 2);
        assertEq(editions.edition(id).minter, address(adapter));
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.MinterMismatch.selector, id, address(adapter))
        );
        secondAdapter.buy(editions, id, buyer, 1);

        // A later admission is bound out too.
        EditionsAdapterMock late = new EditionsAdapterMock(SaleKind.UNIFORM_AUCTION);
        vm.prank(governor);
        editions.setAdmittedMinter(address(late), true);
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.MinterMismatch.selector, id, address(adapter))
        );
        late.buy(editions, id, buyer, 1);

        // The binding emits once; the bound adapter keeps minting.
        vm.recordLogs();
        adapter.buy(editions, id, buyer, 1);
        assertEq(vm.getRecordedLogs().length, 1, "TransferSingle only");
        assertEq(editions.edition(id).minted, 3);

        // Each edition binds on its own: another adapter may take another edition.
        secondAdapter.buy(editions, other, buyer, 1);
        assertEq(editions.edition(other).minter, address(secondAdapter));
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.MinterMismatch.selector, other, address(secondAdapter))
        );
        adapter.buy(editions, other, buyer, 1);
    }

    /// @dev A bound adapter that governance removes keeps minting its own edition, within the
    ///      creator's cap: its sale has paid the seller, so its winners must still claim (ADR
    ///      0005, amended 31 October 2026). It binds no new edition and mints no unbound one, no
    ///      other adapter takes its edition, and a re-admission keeps its binding ID.
    function test_Mint_RemovedBoundAdapterFinishesItsEditionWithinTheCap() public {
        PackageItem memory item = _item(3);
        uint256 id = _create(item);
        uint256 other = _create(_item(0));
        adapter.buy(editions, id, buyer, 1);
        vm.prank(governor);
        editions.setAdmittedMinter(address(adapter), false);

        // Its winners claim: the bound edition mints, up to the cap and no further.
        adapter.buy(editions, id, buyer, 2);
        assertEq(editions.edition(id).minted, 3);
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id));
        adapter.buy(editions, id, buyer, 1);
        // No new sale: it neither binds nor mints an unbound edition.
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(adapter))
        );
        adapter.buy(editions, other, buyer, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(adapter))
        );
        adapter.bind(editions, other, item);
        // Not even a no-op re-binding of its own edition: removal ends its sales.
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(adapter))
        );
        adapter.bind(editions, id, item);
        // Another adapter cannot take the edition over.
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.MinterMismatch.selector, id, address(adapter))
        );
        secondAdapter.buy(editions, id, buyer, 1);
        vm.prank(governor);
        editions.setAdmittedMinter(address(adapter), true);
        assertEq(editions.edition(id).minter, address(adapter));
        adapter.buy(editions, other, buyer, 1);
        assertEq(editions.edition(other).minter, address(adapter));
    }

    /// @dev `bindMinter` before the edition exists: the edition auction opens with the master's
    ///      1/1, so it binds an edition `createEdition` writes only after the 1/1 settles. The
    ///      item must be the master's stored EDITION_MASTER item, and the caller's kind its
    ///      terms' kind. The binding emits once, is a no-op for the bound adapter, refuses any
    ///      other, and survives `createEdition`.
    function test_BindMinter_BeforeTheEditionExists() public {
        PackageItem memory item = _item(10);
        uint256 id = _masterInAuction(item);
        assertFalse(editions.exists(id));

        // Another item (same kind and terms) is not the master's.
        PackageItem memory forged = _item(10);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotEditionMaster.selector, id));
        adapter.bind(editions, id, forged);
        // The adapter's kind must be the one the item's terms name.
        EditionsAdapterMock fixedKind = new EditionsAdapterMock(FIXED_PRICE);
        vm.prank(governor);
        editions.setAdmittedMinter(address(fixedKind), true);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintTarget.SaleKindMismatch.selector, SaleKind.UNIFORM_AUCTION, FIXED_PRICE
            )
        );
        fixedKind.bind(editions, id, item);
        // Only admitted adapters bind.
        EditionsAdapterMock stranger = new EditionsAdapterMock(SaleKind.UNIFORM_AUCTION);
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(stranger))
        );
        stranger.bind(editions, id, item);

        vm.expectEmit(true, true, false, true, address(editions));
        emit IEditions.EditionMinterBound(id, address(adapter));
        adapter.bind(editions, id, item);
        assertFalse(editions.exists(id), "binding creates no edition");
        vm.recordLogs();
        adapter.bind(editions, id, item);
        assertEq(vm.getRecordedLogs().length, 0, "a no-op for the bound adapter");
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.MinterMismatch.selector, id, address(adapter))
        );
        secondAdapter.bind(editions, id, item);

        stream.settle(id, COLLECTOR);
        vm.recordLogs();
        _createEdition(id, item);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != IEditions.EditionMinterBound.selector, "bound once, earlier"
            );
        }
        assertEq(editions.edition(id).minter, address(adapter), "the binding survives creation");
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.MinterMismatch.selector, id, address(adapter))
        );
        secondAdapter.buy(editions, id, buyer, 1);
        adapter.buy(editions, id, buyer, 10);
        assertEq(editions.edition(id).minted, 10);
    }

    /// @dev The item matters only before the edition exists: a master of another kind is
    ///      refused, and after creation the stored kind is checked (any item is ignored).
    function test_BindMinter_ChecksTheMasterAndTheStoredKind() public {
        // A work that is not an edition master: its stored item kind is not EDITION_MASTER.
        PackageItem memory plain = _item(0);
        plain.kind = ItemKind.ORIGINAL;
        uint256 work = _masterInAuction(plain);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotEditionMaster.selector, work));
        adapter.bind(editions, work, plain);
        // A token Stream never minted: Stream refuses it.
        PackageItem memory never = _item(0);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, 999_999));
        adapter.bind(editions, 999_999, never);

        // After creation: the stored kind, whatever item is passed.
        PackageItem memory item = _item(0);
        item.edition = EditionTerms(0, CURRENCY_ETH, FIXED_PRICE, "");
        uint256 id = _create(item);
        PackageItem memory unrelated = _item(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintTarget.SaleKindMismatch.selector, FIXED_PRICE, SaleKind.UNIFORM_AUCTION
            )
        );
        adapter.bind(editions, id, unrelated);
        EditionsAdapterMock fixedKind = new EditionsAdapterMock(FIXED_PRICE);
        vm.prank(governor);
        editions.setAdmittedMinter(address(fixedKind), true);
        PackageItem memory empty;
        fixedKind.bind(editions, id, empty);
        assertEq(editions.edition(id).minter, address(fixedKind));
        // Binding an existing edition locks nothing new: its economics are the creation's.
        assertEq(editions.edition(id).feeShare, 25_000);
    }

    /// @dev The fee snapshot: an edition bound before it exists keeps the economics locked at
    ///      the binding, the ones its sale locked and pays, through a `PRODUCT_EDITIONS` fee
    ///      change before `createEdition`; an edition nobody bound locks them at creation.
    function test_BindMinter_LocksTheEconomicsTheSalePays() public {
        PackageItem memory item = _item(0);
        uint256 id = _masterInAuction(item);
        WorkTerms memory atOpen = economics.newWorkTerms(PRODUCT_EDITIONS, item.payees);
        adapter.bind(editions, id, item);
        PackageItem memory unboundItem = _item(0);
        uint256 unbound = _master(unboundItem);

        address newRecipient = makeAddr("newFeeRecipient");
        economics.setEconomics(ProductEconomics(newRecipient, 10_000, 6_529));
        WorkTerms memory later = economics.newWorkTerms(PRODUCT_EDITIONS, item.payees);
        assertTrue(later.royaltyReceiver != atOpen.royaltyReceiver, "the royalty split moves");

        stream.settle(id, COLLECTOR);
        _createEdition(id, item);
        IEditions.Edition memory e = editions.edition(id);
        assertEq(e.seller, atOpen.seller);
        assertEq(e.feeRecipient, feeRecipient);
        assertEq(e.feeShare, 25_000);
        assertEq(e.royaltyReceiver, atOpen.royaltyReceiver);
        (address receiver,) = editions.royaltyInfo(id, 1 ether);
        assertEq(receiver, atOpen.royaltyReceiver);
        PrimaryTerms memory p = editions.primaryTerms(id, "");
        assertEq(p.feeRecipient, feeRecipient);
        assertEq(p.feeShare, 25_000);

        _createEdition(unbound, unboundItem);
        IEditions.Edition memory u = editions.edition(unbound);
        assertEq(u.feeRecipient, newRecipient, "unbound: locked at creation");
        assertEq(u.feeShare, 10_000);
    }

    function test_Mint_RejectsUnknownEditionZeroAmountAndData() public {
        vm.expectRevert(abi.encodeWithSelector(IEditions.UnknownEdition.selector, 7));
        adapter.buy(editions, 7, buyer, 1);
        uint256 id = _create(_item(10));
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        adapter.buy(editions, id, buyer, 0);
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        adapter.buyWithData(editions, id, buyer, hex"00");
        vm.expectRevert(abi.encodeWithSelector(IEditions.UnknownEdition.selector, 7));
        editions.primaryTerms(7, "");
        // `primaryTerms` ignores `data` for a minted token (IMintTarget).
        assertEq(
            keccak256(abi.encode(editions.primaryTerms(id, hex"00"))),
            keccak256(abi.encode(editions.primaryTerms(id, "")))
        );
    }

    /// @dev The creator's cap (`maxCount`) bounds every mint; the auction decides the count below
    ///      it.
    function test_Mint_StopsAtTheCreatorCap() public {
        uint256 id = _create(_item(5));
        adapter.buy(editions, id, buyer, 4);
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id));
        adapter.buy(editions, id, buyer, 2);
        adapter.buy(editions, id, outsider, 1);
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id));
        adapter.buy(editions, id, buyer, 1);
        assertEq(editions.edition(id).minted, 5);
    }

    function testFuzz_Mint_NeverExceedsTheCap(uint32 size, uint256 a, uint256 b) public {
        size = uint32(bound(size, 1, 1_000_000));
        uint256 id = _create(_item(size));
        a = bound(a, 1, type(uint256).max);
        b = bound(b, 1, type(uint256).max);
        _tryBuy(id, a, a <= size);
        uint256 minted = a <= size ? a : 0;
        _tryBuy(id, b, b <= size - minted);
        assertLe(editions.edition(id).minted, size);
    }

    function _tryBuy(uint256 id, uint256 amount, bool expectOk) internal {
        if (!expectOk) {
            vm.expectRevert(abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id));
        }
        adapter.buy(editions, id, buyer, amount);
    }

    /// @dev Without a cap the auction's clearing alone bounds the count; the record stops at
    ///      2^48 - 1, far past any auction's.
    function test_Mint_UncappedStopsAtUint48() public {
        uint256 id = _create(_item(0));
        adapter.buy(editions, id, buyer, type(uint48).max - 1);
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id));
        adapter.buy(editions, id, buyer, 2);
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id));
        adapter.buy(editions, id, buyer, type(uint256).max);
        adapter.buy(editions, id, buyer, 1);
        assertEq(editions.edition(id).minted, type(uint48).max);
    }

    /// @dev The largest cap is a bound like any other.
    function test_Mint_MaximumCap() public {
        uint256 id = _create(_item(type(uint32).max));
        adapter.buy(editions, id, buyer, type(uint32).max);
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id));
        adapter.buy(editions, id, buyer, 1);
        assertEq(editions.edition(id).minted, type(uint32).max);
    }

    /// @dev A master with an edition has settled, and Stream never burns a settled token
    ///      (`SaleAlreadySettled`, mirrored by the mock), so minting needs no read from Stream.
    function test_Mint_MasterWithEditionIsNeverBurned() public {
        uint256 id = _create(_item(10));
        adapter.buy(editions, id, buyer, 1);
        vm.expectRevert(abi.encodeWithSelector(IStream.SaleAlreadySettled.selector, id));
        stream.burnMaster(id);
        adapter.buy(editions, id, buyer, 1);
        assertEq(editions.edition(id).minted, 2);
    }

    function test_Mint_CreatorFollowsArtistRecovery() public {
        uint256 id = _create(_item(10));
        assertEq(editions.primaryTerms(id, "").creator, artist);
        address recovered = makeAddr("recovered");
        artists.recover(uint256(uint160(artist)), recovered);
        assertEq(editions.primaryTerms(id, "").creator, recovered);
        adapter.buy(editions, id, buyer, 1);
        assertEq(editions.primaryTerms(id, "").creator, recovered);
    }

    /// @dev QUALITY-5: the packed record rebuilds the approved terms exactly at the field bounds
    ///      (the largest cap), and a mint counts and binds in place, beside the seller.
    function test_Edition_PackedRecordRoundTripsAtTheBounds() public {
        PackageItem memory item = _item(type(uint32).max);
        uint256 id = _create(item);
        WorkTerms memory w = economics.newWorkTerms(PRODUCT_EDITIONS, item.payees);
        IEditions.Edition memory ed = editions.edition(id);
        assertEq(keccak256(abi.encode(ed.terms)), keccak256(abi.encode(item.edition)));

        adapter.buy(editions, id, buyer, 3);
        ed = editions.edition(id);
        assertEq(ed.minted, 3);
        assertEq(ed.minter, address(adapter));
        assertEq(ed.seller, w.seller, "the seller shares the counted word");
        assertEq(keccak256(abi.encode(ed.terms)), keccak256(abi.encode(item.edition)));
        assertEq(ed.royaltyRate, 6_529);
        assertEq(ed.feeShare, 25_000);
    }

    /// @dev The first mint writes no new record slot: the count and the binding share the
    ///      seller's word, which `createEdition` wrote. The one new slot is the new holder's
    ///      ERC-1155 balance.
    function test_Mint_FirstMintWritesNoNewRecordSlot() public {
        uint256 id = _create(_item(10));
        uint256 preCall = vm.snapshotState();
        vm.startStateDiffRecording();
        adapter.buy(editions, id, buyer, 1);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        StateGrowth.Growth memory g =
            StateGrowth.count(accesses, preCall, address(this), address(adapter));
        uint256 onEditions;
        for (uint256 i; i < g.newSlots.length; ++i) {
            if (g.newSlots[i].account == address(editions)) ++onEditions;
        }
        assertEq(onEditions, 1, "the holder's balance only");
        assertEq(editions.balanceOf(buyer, id), 1);
    }

    // ------------------------------------------------------------------ burn

    function test_Burn_AdapterBurnsItsOwnCopies() public {
        uint256 id = _create(_item(5));
        adapter.buy(editions, id, address(adapter), 2);
        vm.expectEmit(true, true, true, true, address(editions));
        emit IERC1155.TransferSingle(address(adapter), address(adapter), address(0), id, 2);
        adapter.burnHeld(editions, id, 2);
        assertEq(editions.balanceOf(address(adapter), id), 0);
        assertEq(editions.edition(id).minted, 2, "burned copies still count toward the cap");
        adapter.buy(editions, id, buyer, 3);
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id));
        adapter.buy(editions, id, buyer, 1);
    }

    function test_Burn_OnlyMinterOnlyOwnBalance() public {
        uint256 id = _create(_item(5));
        adapter.buy(editions, id, buyer, 2);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, buyer));
        editions.burn(id, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC1155Errors.ERC1155InsufficientBalance.selector, address(adapter), 0, 1, id
            )
        );
        adapter.burnHeld(editions, id, 1);
        vm.expectRevert(abi.encodeWithSelector(IEditions.UnknownEdition.selector, 9));
        adapter.burnHeld(editions, 9, 1);
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        adapter.burnHeld(editions, id, 0);
        assertEq(editions.balanceOf(buyer, id), 2);
    }

    /// @dev IMintTarget: an adapter removed after minting can still burn the copies it holds;
    ///      a never-admitted account cannot.
    function test_Burn_RemovedAdapterCanStillBurn() public {
        uint256 id = _create(_item(5));
        adapter.buy(editions, id, address(adapter), 2);
        vm.prank(governor);
        editions.setAdmittedMinter(address(adapter), false);
        assertFalse(editions.isAdmittedMinter(address(adapter)));
        adapter.burnHeld(editions, id, 2);
        assertEq(editions.balanceOf(address(adapter), id), 0);

        EditionsAdapterMock stranger = new EditionsAdapterMock(SaleKind.UNIFORM_AUCTION);
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(stranger))
        );
        stranger.burnHeld(editions, id, 1);
    }

    /// @dev Copies are sold at mint, so `settlePrimary` is a no-op returning nothing for every
    ///      adapter ever admitted (also after removal) and refused for anyone else.
    function test_SettlePrimary_NoOpForAdapters() public {
        uint256 id = _create(_item(5));
        adapter.buy(editions, id, buyer, 1);
        IEditions.Edition memory before = editions.edition(id);
        vm.recordLogs();
        adapter.markSettled(editions, id);
        assertEq(vm.getRecordedLogs().length, 0, "no event");
        assertEq(keccak256(abi.encode(editions.edition(id))), keccak256(abi.encode(before)));

        vm.prank(governor);
        editions.setAdmittedMinter(address(adapter), false);
        adapter.markSettled(editions, id); // the minting adapter, since removed

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, outsider));
        editions.settlePrimary(id, PrimaryOutcome.SOLD, outsider, address(0), 1);
    }

    // ------------------------------------------------------------------ royalties

    function test_RoyaltyInfo_LockedTermsOutOf100k() public {
        PackageItem memory item = _item(5);
        uint256 id = _create(item);
        (address receiver, uint256 amount) = editions.royaltyInfo(id, 1 ether);
        assertEq(receiver, economics.newWorkTerms(PRODUCT_EDITIONS, item.payees).royaltyReceiver);
        assertEq(amount, 0.06529 ether, "6.529% is exact");
        (, amount) = editions.royaltyInfo(id, 100_000);
        assertEq(amount, 6_529);
    }

    function testFuzz_RoyaltyInfo_NoOverflow(uint256 salePrice) public {
        uint256 id = _create(_item(5));
        (, uint256 amount) = editions.royaltyInfo(id, salePrice);
        assertLe(amount, salePrice);
        assertEq(amount, salePrice / 100_000 * 6_529 + salePrice % 100_000 * 6_529 / 100_000);
    }

    function test_RoyaltyInfo_UnaffectedByNewDefaults() public {
        PackageItem memory item = _item(5);
        uint256 id = _create(item);
        (address receiver, uint256 amount) = editions.royaltyInfo(id, 1 ether);
        IEditions.Edition memory before = editions.edition(id);

        economics.setEconomics(ProductEconomics(outsider, 50_000, 10_000));
        (address r2, uint256 a2) = editions.royaltyInfo(id, 1 ether);
        assertEq(r2, receiver);
        assertEq(a2, amount);
        IEditions.Edition memory afterChange = editions.edition(id);
        assertEq(afterChange.feeRecipient, before.feeRecipient);
        assertEq(afterChange.feeShare, before.feeShare);
        assertEq(afterChange.seller, before.seller);

        // New editions lock the new fee terms, but their rate is their master's (6.529%), never
        // the product default.
        uint256 next = _create(_item(5));
        (, uint256 a3) = editions.royaltyInfo(next, 1 ether);
        assertEq(a3, 0.06529 ether);
        assertEq(editions.edition(next).feeRecipient, outsider);
        assertEq(editions.edition(next).feeShare, 50_000);
    }

    /// @dev The edition starts at its master's current rate, not the `PRODUCT_EDITIONS` default,
    ///      so a consented re-rate of the master before the edition exists carries over.
    function test_CreateEdition_InheritsMasterRoyaltyRate() public {
        economics.setEconomics(ProductEconomics(feeRecipient, 25_000, 12_345)); // ignored
        PackageItem memory item = _item(5);
        uint256 id = _master(item);
        stream.setMasterRoyaltyRate(id, 9_000); // agreed by every party before the edition
        _createEdition(id, item);
        assertEq(editions.edition(id).royaltyRate, 9_000);
        (address receiver, uint256 amount) = editions.royaltyInfo(id, 1 ether);
        assertEq(amount, 0.09 ether);
        assertEq(
            receiver,
            economics.newWorkTerms(PRODUCT_EDITIONS, item.payees).royaltyReceiver,
            "the receiver is still the edition's split"
        );
        // A later re-rate reaches the edition through the work-records hook.
        workRecordsMock.setRate(editions, id, 7_000);
        (, amount) = editions.royaltyInfo(id, 1 ether);
        assertEq(amount, 0.07 ether);
    }

    /// @dev D19: the rate changes only through the bound work-records satellite (which verifies
    ///      every party's consent and the governed action); the receiver never changes.
    function test_SetRoyaltyRate_OnlyThroughWorkRecords() public {
        uint256 id = _create(_item(5));
        (address receiver,) = editions.royaltyInfo(id, 1 ether);

        vm.expectEmit(true, false, false, true, address(editions));
        emit IEditions.RoyaltyRateChanged(id, 6_529, 10_000);
        vm.expectEmit(false, false, false, true, address(editions));
        emit IEditions.MetadataUpdate(id);
        workRecordsMock.setRate(editions, id, 10_000);
        (address r2, uint256 amount) = editions.royaltyInfo(id, 1 ether);
        assertEq(r2, receiver, "payees never change");
        assertEq(amount, 0.1 ether);
        assertEq(editions.edition(id).royaltyRate, 10_000);

        vm.expectRevert(abi.encodeWithSelector(IEditions.InvalidRoyaltyRate.selector, 100_001));
        workRecordsMock.setRate(editions, id, 100_001);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IEditions.UnboundCaller.selector, outsider));
        editions.setRoyaltyRate(id, 0);
        vm.prank(address(stream));
        vm.expectRevert(abi.encodeWithSelector(IEditions.UnboundCaller.selector, address(stream)));
        editions.setRoyaltyRate(id, 0);

        // An unchanged rate is a silent no-op.
        vm.recordLogs();
        workRecordsMock.setRate(editions, id, 10_000);
        assertEq(vm.getRecordedLogs().length, 0, "unchanged rate");

        // A master without an edition is a silent no-op, whatever the rate.
        uint256 bare = _master(_item(5));
        vm.recordLogs();
        workRecordsMock.setRate(editions, bare, 0);
        workRecordsMock.setRate(editions, bare, 10_000);
        assertEq(vm.getRecordedLogs().length, 0);

        // The bound is inclusive: a rate of exactly 100% is accepted.
        workRecordsMock.setRate(editions, id, 100_000);
        assertEq(editions.edition(id).royaltyRate, 100_000);
    }

    function test_RoyaltyInfo_UnknownEdition() public {
        vm.expectRevert(abi.encodeWithSelector(IEditions.UnknownEdition.selector, 3));
        editions.royaltyInfo(3, 1 ether);
    }

    // ------------------------------------------------------------------ license and uri

    function test_LicenseOf_InheritsMaster() public {
        PackageItem memory item = _item(5);
        uint256 id = _create(item);
        // E9: the master's record must be opened first; Editions inherits the satellite's error.
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.RecordNotOpen.selector, id));
        editions.licenseOf(id);
        workRecordsMock.openRecord(id);
        License memory l = editions.licenseOf(id);
        assertEq(l.spdxId, "CC0-1.0");
        assertEq(l.textFileId, item.license.textFileId);
        // A permitted relicense of the master carries over to its edition.
        workRecordsMock.setLicense(id, License("CC-BY-4.0", keccak256("by")));
        assertEq(editions.licenseOf(id).spdxId, "CC-BY-4.0");
        assertEq(WorksHashing.licenseKey(editions.licenseOf(id).spdxId), keccak256("cc-by-4.0"));
        vm.expectRevert(abi.encodeWithSelector(IEditions.UnknownEdition.selector, 99));
        editions.licenseOf(99);
    }

    function test_Uri_RoutesThroughMasterRenderer() public {
        uint256 id = _create(_item(5));
        string memory suffix =
            string.concat(":", Strings.toHexString(address(editions)), ":", Strings.toString(id));
        assertEq(editions.uri(id), string.concat("default", suffix));
        // Finalizing the master pins its renderer; the edition follows the pin.
        stream.pinRenderer(id, address(new EditionsRendererMock("pinned")));
        assertEq(editions.uri(id), string.concat("pinned", suffix));
        vm.expectRevert(abi.encodeWithSelector(IEditions.UnknownEdition.selector, 42));
        editions.uri(42);
    }

    // ------------------------------------------------------------------ hostile receivers

    function test_Receiver_RevertingHookRevertsMint() public {
        uint256 id = _create(_item(5));
        address r = address(new RevertingReceiver1155());
        vm.expectRevert(RevertingReceiver1155.Refused.selector);
        adapter.buy(editions, id, r, 1);
        assertEq(editions.edition(id).minted, 0, "nothing persists");
    }

    function test_Receiver_WrongMagicOrNoHookIsInvalid() public {
        uint256 id = _create(_item(5));
        address wrong = address(new WrongSelectorReceiver1155());
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, wrong)
        );
        adapter.buy(editions, id, wrong, 1);
        address none = address(new NoHookReceiver1155());
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, none)
        );
        adapter.buy(editions, id, none, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, address(0))
        );
        adapter.buy(editions, id, address(0), 1);
    }

    function test_Receiver_GasBurnerCannotMint() public {
        uint256 id = _create(_item(5));
        address burner = address(new GasBurnerReceiver1155());
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, burner)
        );
        adapter.buy{ gas: 2_000_000 }(editions, id, burner, 1);
        assertEq(editions.edition(id).minted, 0);
    }

    function test_Receiver_ReentryThroughAdapterSeesUpdatedSupply() public {
        uint256 id = _create(_item(1));
        ReentrantReceiver1155 r = new ReentrantReceiver1155(adapter, editions);
        adapter.buy(editions, id, address(r), 1);
        assertFalse(r.reentrySucceeded());
        assertEq(
            r.reentryError(), abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id)
        );
        assertEq(editions.balanceOf(address(r), id), 1);
        assertEq(editions.edition(id).minted, 1);
    }

    function test_Receiver_ReentryWithinSizeIsCounted() public {
        uint256 id = _create(_item(2));
        ReentrantReceiver1155 r = new ReentrantReceiver1155(adapter, editions);
        adapter.buy(editions, id, address(r), 1);
        assertTrue(r.reentrySucceeded());
        assertEq(editions.balanceOf(address(r), id), 2);
        assertEq(editions.edition(id).minted, 2);
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id));
        adapter.buy(editions, id, buyer, 1);
    }

    function test_Receiver_DirectReentryIsUnauthorized() public {
        uint256 id = _create(_item(5));
        ReentrantReceiver1155 r = new ReentrantReceiver1155(adapter, editions);
        r.setMode(ReentrantReceiver1155.Mode.DIRECT);
        adapter.buy(editions, id, address(r), 1);
        assertEq(
            r.reentryError(),
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(r))
        );
        assertEq(editions.edition(id).minted, 1);
    }

    function test_Receiver_CreateReentryHitsEditionExists() public {
        PackageItem memory item = _item(5);
        uint256 id = _create(item);
        ReentrantReceiver1155 r = new ReentrantReceiver1155(adapter, editions);
        r.setMode(ReentrantReceiver1155.Mode.CREATE);
        r.setItem(item);
        adapter.buy(editions, id, address(r), 1);
        assertEq(r.reentryError(), abi.encodeWithSelector(IEditions.EditionExists.selector, id));
    }

    // ------------------------------------------------------------------ metadata propagation

    /// @dev ADMIN (unmapped selector), once, and only the satellite Stream bound, with code and
    ///      no EIP-7702 delegation.
    function test_BindWorkRecords_OnceAdminAndChecked() public {
        Editions fresh = _freshEditions();
        address records = address(workRecordsMock);
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        fresh.bindWorkRecords(records);

        vm.startPrank(admin);
        _expectInvalidDependency(fresh, address(0));
        _expectInvalidDependency(fresh, address(renderer)); // no IWorkRecords ERC-165
        address other = address(new EditionsWorkRecordsMock()); // a valid IWorkRecords...
        _expectInvalidBinding(fresh, other); // ...that Stream did not bind
        stream.bind(address(renderer), address(editions)); // bound, but no IWorkRecords ERC-165
        _expectInvalidDependency(fresh, address(renderer));
        stream.bind(outsider, address(editions)); // Stream bound an EOA
        _expectInvalidDependency(fresh, outsider);
        address delegated = makeAddr("delegatedRecords");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", records));
        stream.bind(delegated, address(editions));
        _expectInvalidDependency(fresh, delegated);

        stream.bind(records, address(editions));
        vm.expectEmit(false, false, false, true, address(fresh));
        emit IEditions.Bound("WORK_RECORDS", records);
        fresh.bindWorkRecords(records);
        assertEq(fresh.workRecords(), records);
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.AlreadyBound.selector, bytes32("WORK_RECORDS"))
        );
        fresh.bindWorkRecords(records);
        vm.stopPrank();
    }

    function _expectInvalidBinding(Editions target, address records) internal {
        vm.expectRevert(abi.encodeWithSelector(IEditions.InvalidBinding.selector, records));
        target.bindWorkRecords(records);
    }

    function _expectInvalidDependency(Editions target, address records) internal {
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, records));
        target.bindWorkRecords(records);
    }

    function test_NotifyMasterUpdated_EmitsForEditionsOnly() public {
        // Before the binding nobody may report, not even the future satellite.
        Editions fresh = _freshEditions();
        vm.prank(address(workRecordsMock));
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.UnboundCaller.selector, address(workRecordsMock))
        );
        fresh.notifyMasterUpdated(1);

        uint256 id = _create(_item(5));
        vm.expectEmit(false, false, false, true, address(editions));
        emit IEditions.MetadataUpdate(id);
        workRecordsMock.notify(editions, id);

        // A master without an edition (or an ORIGINAL) is a silent no-op, never a revert.
        uint256 bare = _master(_item(5));
        vm.recordLogs();
        workRecordsMock.notify(editions, bare);
        assertEq(vm.getRecordedLogs().length, 0);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IEditions.UnboundCaller.selector, outsider));
        editions.notifyMasterUpdated(id);
        vm.prank(address(stream));
        vm.expectRevert(abi.encodeWithSelector(IEditions.UnboundCaller.selector, address(stream)));
        editions.notifyMasterUpdated(id);
    }

    /// @dev E11: Stream (default renderer) and the bound work-records satellite (global or
    ///      collection preferred location) may each signal a batch refresh; nobody else.
    function test_NotifyAllUpdated_StreamOrWorkRecords() public {
        vm.expectEmit(false, false, false, true, address(editions));
        emit IEditions.BatchMetadataUpdate(0, type(uint256).max);
        vm.prank(address(stream));
        editions.notifyAllUpdated();

        vm.expectEmit(false, false, false, true, address(editions));
        emit IEditions.BatchMetadataUpdate(0, type(uint256).max);
        workRecordsMock.notifyAll(editions);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IEditions.UnboundCaller.selector, outsider));
        editions.notifyAllUpdated();
        // An unbound Editions accepts only Stream.
        Editions fresh = _freshEditions();
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.UnboundCaller.selector, address(workRecordsMock))
        );
        workRecordsMock.notifyAll(fresh);
    }

    // ------------------------------------------------------------------ governed setters

    function test_SetContractURI_Governed() public {
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        editions.setContractURI("ipfs://x");
        vm.expectEmit(false, false, false, true, address(editions));
        emit IEditions.ContractURISet("", "ipfs://contract");
        vm.expectEmit(false, false, false, false, address(editions));
        emit IEditions.ContractURIUpdated();
        vm.prank(governor);
        editions.setContractURI("ipfs://contract");
        assertEq(editions.contractURI(), "ipfs://contract");
        vm.expectEmit(false, false, false, true, address(editions));
        emit IEditions.ContractURISet("ipfs://contract", "ipfs://v2");
        vm.prank(governor);
        editions.setContractURI("ipfs://v2");
    }

    function test_SetOwner_CompareAndSet() public {
        address next = makeAddr("nextOwner");
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        editions.setOwner(marketOwner, next);
        vm.prank(governor);
        vm.expectRevert(IEditions.ExpectedValueMismatch.selector);
        editions.setOwner(outsider, next);
        vm.expectEmit(true, true, false, false, address(editions));
        emit IEditions.OwnershipTransferred(marketOwner, next);
        vm.prank(governor);
        editions.setOwner(marketOwner, next);
        assertEq(editions.owner(), next);
    }

    // ------------------------------------------------------------------ introspection

    /// @dev D139 and ADR 0005 owner decision 13: the collection is 6529 Stream Editions.
    function test_NameAndSymbol() public view {
        assertEq(editions.name(), "6529 Stream Editions");
        assertEq(editions.symbol(), "STREAMEDITIONS");
        assertEq(IEditions(address(editions)).name.selector, bytes4(keccak256("name()")));
        assertEq(IEditions(address(editions)).symbol.selector, bytes4(keccak256("symbol()")));
    }

    function test_SupportsInterface() public view {
        assertTrue(editions.supportsInterface(type(IERC165).interfaceId));
        assertTrue(editions.supportsInterface(type(IERC1155).interfaceId));
        assertTrue(editions.supportsInterface(type(IERC1155MetadataURI).interfaceId));
        assertTrue(editions.supportsInterface(type(IERC2981).interfaceId));
        assertTrue(editions.supportsInterface(type(IMintTarget).interfaceId));
        assertTrue(editions.supportsInterface(type(IEditions).interfaceId));
        assertTrue(editions.supportsInterface(0x49064906), "ERC-4906");
        assertFalse(editions.supportsInterface(0xffffffff));
        // IDs just below each of the contract's own.
        bytes4[4] memory own = [
            type(IERC2981).interfaceId,
            type(IMintTarget).interfaceId,
            type(IEditions).interfaceId,
            bytes4(0x49064906)
        ];
        for (uint256 i; i < own.length; ++i) {
            assertFalse(editions.supportsInterface(bytes4(uint32(own[i]) - 1)));
        }
    }

    function test_Exists_FalseForUnknown() public {
        assertFalse(editions.exists(1));
        vm.expectRevert(abi.encodeWithSelector(IEditions.UnknownEdition.selector, 1));
        editions.edition(1);
        vm.expectRevert(abi.encodeWithSelector(IEditions.UnknownEdition.selector, 1));
        editions.masterOf(1);
        vm.expectRevert(abi.encodeWithSelector(IEditions.UnknownEdition.selector, 1));
        editions.contentHashOf(1);
    }
}

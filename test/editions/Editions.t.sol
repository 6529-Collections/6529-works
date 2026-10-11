// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { IERC1155Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {
    IERC1155MetadataURI
} from "@openzeppelin/contracts/token/ERC1155/extensions/IERC1155MetadataURI.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Editions } from "src/editions/Editions.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import {
    CURRENCY_DEFAULT,
    CURRENCY_ETH,
    PRODUCT_EDITIONS,
    PRODUCT_STREAM,
    Payee,
    ProductEconomics,
    WorkTerms
} from "src/interfaces/types/EconomicsTypes.sol";
import {
    EditionFormat,
    ItemKind,
    License,
    PackageItem,
    Party,
    PartyRole,
    SeedPolicy
} from "src/interfaces/types/PackageTypes.sol";
import { DutchParams, PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { EditionsBase } from "./EditionsBase.sol";
import {
    EditionsAdapterMock,
    EditionsRendererMock,
    EditionsStreamMock,
    GasBurnerReceiver1155,
    NoHookReceiver1155,
    ReentrantReceiver1155,
    RevertingReceiver1155,
    WrongSelectorReceiver1155
} from "../mocks/editions/EditionsMocks.sol";

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

    event ContentClaimed(bytes32 indexed product, bytes32 indexed contentHash, bytes32 contentId);
    event EditionLinked(uint256 indexed tokenId, address indexed editions, uint256 editionId);

    // ------------------------------------------------------------------ deployment

    function test_Constructor_WiresFromStream() public view {
        assertEq(editions.stream(), address(stream));
        assertEq(address(editions.packageRegistry()), address(registry));
        assertEq(address(editions.economics()), address(economics));
        assertEq(address(editions.artistRegistry()), address(artists));
        assertEq(editions.owner(), marketOwner);
        assertEq(editions.authority(), address(manager));
        assertEq(editions.contractURI(), "");
    }

    function test_Constructor_EmitsOwnership() public {
        vm.expectEmit(true, true, false, false);
        emit IEditions.OwnershipTransferred(address(0), marketOwner);
        new Editions(address(manager), address(stream), address(stream).codehash, marketOwner);
    }

    function test_Constructor_RejectsMissingWiring() public {
        address unwired = address(new UnwiredStream());
        vm.expectRevert(Editions.ZeroAddress.selector);
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
        bytes32 wrong = keccak256("not the reviewed stream");
        vm.expectRevert(
            abi.encodeWithSelector(
                Editions.CodeHashMismatch.selector, wrong, address(stream).codehash
            )
        );
        new Editions(address(manager), address(stream), wrong, marketOwner);
    }

    function _expectInvalidStream(address s) internal {
        vm.expectRevert(abi.encodeWithSelector(Editions.InvalidDependency.selector, s));
        new Editions(address(manager), s, s.codehash, marketOwner);
    }

    // ------------------------------------------------------------------ createEdition

    function test_CreateEdition_LinksBothWaysAndLocksTerms() public {
        PackageItem memory item = _fixedItem(50);
        uint256 id = _master(item);
        bytes32 sha = registry.sha256Of(item.contentId);
        WorkTerms memory w = economics.newWorkTerms(PRODUCT_EDITIONS, item.payees);

        vm.expectEmit(true, true, false, true, address(editions));
        emit IEditions.EditionCreated(id, item.contentId, item.edition);
        vm.expectEmit(false, false, false, true, address(editions));
        emit Editions.MetadataUpdate(id);
        vm.expectEmit(true, true, false, true, address(registry));
        emit ContentClaimed(PRODUCT_EDITIONS, sha, item.contentId);
        vm.expectEmit(true, true, false, true, address(stream));
        emit EditionLinked(id, address(editions), id);
        vm.prank(outsider); // permissionless
        assertEq(editions.createEdition(id, item), id, "edition ID is the master's token ID");

        // Editions -> Stream.
        (address s, uint256 workId, bytes32 contentId) = editions.masterOf(id);
        assertEq(s, address(stream));
        assertEq(workId, id);
        assertEq(contentId, item.contentId);
        assertEq(editions.contentHashOf(id), sha, "records the master's content hash");
        assertTrue(editions.exists(id));
        // Stream -> Editions.
        (address e, uint256 editionId) = stream.editionOf(id);
        assertEq(e, address(editions));
        assertEq(editionId, id);

        IEditions.Edition memory ed = editions.edition(id);
        assertEq(ed.contentId, item.contentId);
        assertEq(keccak256(abi.encode(ed.terms)), keccak256(abi.encode(item.edition)));
        assertEq(ed.minted, 0);
        assertEq(ed.windowStart, 0);
        assertEq(ed.seller, w.seller);
        assertEq(ed.feeRecipient, feeRecipient);
        assertEq(ed.feeShare, 25_000);
        assertEq(ed.royaltyReceiver, w.royaltyReceiver);
        assertEq(ed.royaltyRate, 6_529);
        // Uniqueness: Stream claimed the hash for the master, Editions for the edition.
        assertTrue(registry.isContentUsed(PRODUCT_STREAM, sha));
        assertTrue(registry.isContentUsed(PRODUCT_EDITIONS, sha));
    }

    function test_CreateEdition_RefusesOriginalItem() public {
        PackageItem memory item = _fixedItem(10);
        item.kind = ItemKind.ORIGINAL;
        uint256 id = _master(item);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotEditionMaster.selector, id));
        editions.createEdition(id, item);
        // Relabelling the item as a master changes its hash, so it matches nothing.
        item.kind = ItemKind.EDITION_MASTER;
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotEditionMaster.selector, id));
        editions.createEdition(id, item);
    }

    function test_CreateEdition_RefusesMismatchedItem() public {
        PackageItem memory item = _fixedItem(10);
        uint256 id = _master(item);
        PackageItem memory other = _fixedItem(10); // another master's item
        _master(other);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotEditionMaster.selector, id));
        editions.createEdition(id, other);
    }

    /// @dev Any change to the approved item (here: price, size, content, payees, license) breaks
    ///      the item hash Stream recorded for the master.
    function testFuzz_CreateEdition_RefusesTamperedItem(uint8 field, uint256 value) public {
        PackageItem memory item = _fixedItem(10);
        uint256 id = _master(item);
        field = uint8(bound(field, 0, 4));
        value = bound(value, 1, type(uint64).max);
        if (field == 0) item.edition.price += value;
        if (field == 1) item.edition.size += uint64(value % 1000) + 1;
        if (field == 2) item.contentId = bytes32(uint256(item.contentId) ^ value);
        if (field == 3) item.payees[0].share -= 1;
        if (field == 4) item.license.spdxId = "LicenseRef-AllRightsReserved";
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotEditionMaster.selector, id));
        editions.createEdition(id, item);
    }

    function test_CreateEdition_RefusesMismatchedContentHash() public {
        PackageItem memory item = _fixedItem(10);
        uint256 id = _master(item);
        // A faulty Stream reports other content for the master than the item it consumed.
        stream.corruptContentId(id, keccak256("other media"));
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotEditionMaster.selector, id));
        editions.createEdition(id, item);
    }

    function test_CreateEdition_RefusesUnknownMaster() public {
        PackageItem memory item = _fixedItem(10);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, 1));
        editions.createEdition(1, item);
    }

    /// @dev D14: a master still in auction custody, live or paused for a dispute, gets no
    ///      edition; an upheld dispute burns it, so it never does.
    function test_CreateEdition_RequiresSettledMaster() public {
        PackageItem memory item = _fixedItem(10);
        uint256 id = _masterInAuction(item);
        vm.expectRevert(abi.encodeWithSelector(Editions.MasterNotSettled.selector, id));
        editions.createEdition(id, item);
        stream.burnMaster(id); // dispute upheld
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, id));
        editions.createEdition(id, item);

        PackageItem memory sold = _fixedItem(10);
        uint256 soldId = _masterInAuction(sold);
        stream.settle(soldId, COLLECTOR);
        editions.createEdition(soldId, sold);
        assertTrue(editions.exists(soldId));
    }

    function test_CreateEdition_RefusesSecondCreate() public {
        PackageItem memory item = _fixedItem(10);
        uint256 id = _create(item);
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionExists.selector, id));
        editions.createEdition(id, item);
    }

    function test_CreateEdition_ReentryThroughStreamHitsEditionExists() public {
        PackageItem memory item = _fixedItem(10);
        uint256 id = _master(item);
        stream.setReentryItem(item);
        stream.setLinkMode(EditionsStreamMock.LinkMode.REENTER);
        editions.createEdition(id, item);
        assertEq(
            stream.reentryError(), abi.encodeWithSelector(IEditions.EditionExists.selector, id)
        );
        (address e, uint256 editionId) = stream.editionOf(id);
        assertEq(e, address(editions));
        assertEq(editionId, id);
    }

    function test_CreateEdition_RefusesRevokedPackage() public {
        PackageItem memory item = _fixedItem(10);
        uint256 id = _master(item);
        registry.revoke(_root(item));
        vm.expectRevert(abi.encodeWithSelector(Editions.MasterNotApproved.selector, id));
        editions.createEdition(id, item);
    }

    function test_CreateEdition_RefusesUnconsumedItem() public {
        PackageItem memory item = _fixedItem(10);
        uint256 id = _master(item);
        registry.setConsumed(WorksHashing.itemHash(item), false);
        vm.expectRevert(abi.encodeWithSelector(Editions.MasterNotApproved.selector, id));
        editions.createEdition(id, item);
    }

    /// @dev A VRF master's seed is delivered before its auction starts (D4), so a settled VRF
    ///      master links like any other.
    function test_CreateEdition_SettledVrfMaster() public {
        PackageItem memory item = _fixedItem(10);
        item.seedPolicy = SeedPolicy.VRF;
        uint256 id = _create(item);
        assertFalse(editions.primaryTerms(id, "").revealPending);
    }

    function test_CreateEdition_RefusesMalformedTerms() public {
        _expectBadTerms(_item(EditionFormat.FIXED, 0, 0, SaleKind.FIXED_PRICE)); // no size
        _expectBadTerms(_item(EditionFormat.FIXED, 5, 1 days, SaleKind.FIXED_PRICE)); // window
        _expectBadTerms(_item(EditionFormat.OPEN, 0, 0, SaleKind.FIXED_PRICE)); // no window
        _expectBadTerms(_item(EditionFormat.FIXED, 5, 0, SaleKind.ENGLISH_AUCTION));
        _expectBadTerms(_item(EditionFormat.FIXED, 5, 0, keccak256("RAFFLE")));
        PackageItem memory item = _fixedItem(5);
        item.edition.params = hex"01"; // fixed price takes no params
        _expectBadTerms(item);
        item = _openItem(1 days, 0);
        item.edition.params = abi.encode(DutchParams(1, 1 days, 0), uint256(1)); // too long
        _expectBadTerms(item);
        item = _openItem(1 days, 0);
        item.edition.params = abi.encode(DutchParams(PRICE + 1, 1 days, 0)); // rests above start
        _expectBadTerms(item);
    }

    function _expectBadTerms(PackageItem memory item) internal {
        uint256 id = _master(item);
        vm.expectRevert(abi.encodeWithSelector(Editions.InvalidEditionTerms.selector, id));
        editions.createEdition(id, item);
    }

    /// @dev ADR 0001 section 5: each sale locks its currency when it starts. The edition keeps
    ///      the package's `CURRENCY_DEFAULT`; the terms resolve it when read, so a sale opened
    ///      after a default change locks the new default.
    function test_PrimaryTerms_ResolveDefaultCurrencyWhenRead() public {
        address usdc = makeAddr("usdc");
        economics.setAllowed(usdc, true);
        economics.setDefaultCurrency(usdc);
        PackageItem memory item = _fixedItem(10);
        item.edition.currency = CURRENCY_DEFAULT;
        uint256 id = _create(item);
        assertEq(editions.edition(id).terms.currency, CURRENCY_DEFAULT, "stored as approved");
        assertEq(editions.primaryTerms(id, "").currency, usdc);
        (, PrimaryTerms memory terms) = fixedAdapter.buy(editions, id, buyer, 1);
        assertEq(terms.currency, usdc);
        economics.setDefaultCurrency(CURRENCY_ETH);
        assertEq(editions.primaryTerms(id, "").currency, CURRENCY_ETH);
    }

    /// @dev A currency that is not active cannot open a sale (or mint), but does not block
    ///      creating the edition: it can be admitted later.
    function test_PrimaryTerms_RefuseInactiveCurrency() public {
        address token = makeAddr("unlisted");
        PackageItem memory item = _fixedItem(10);
        item.edition.currency = token;
        uint256 id = _create(item);
        bytes memory notAllowed =
            abi.encodeWithSelector(IEconomicsResolver.CurrencyNotAllowed.selector, token);
        vm.expectRevert(notAllowed);
        editions.primaryTerms(id, "");
        vm.expectRevert(notAllowed);
        fixedAdapter.buy(editions, id, buyer, 1);
        economics.setAllowed(token, true);
        assertEq(editions.primaryTerms(id, "").currency, token);
        (, PrimaryTerms memory terms) = fixedAdapter.buy(editions, id, buyer, 1);
        assertEq(terms.currency, token);
    }

    /// @dev The one permitted reuse: the edition carries its master's hash, which Stream claimed
    ///      under PRODUCT_STREAM. A hash already used by an edition is refused, even under a
    ///      different content ID (the same media re-encoded).
    function test_CreateEdition_ContentHashUniqueAmongEditions() public {
        PackageItem memory first = _fixedItem(10);
        _create(first);
        bytes32 sha = registry.sha256Of(first.contentId);

        // A second master whose media decodes to the same bytes (Stream's own check disabled
        // in the mock, to reach the Editions check).
        registry.setSkipStreamUniqueness(true);
        PackageItem memory twin = _fixedItem(10);
        registry.setContent(twin.contentId, sha);
        uint256 twinId = _master(twin);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.ContentUsed.selector, PRODUCT_EDITIONS, sha)
        );
        editions.createEdition(twinId, twin);
    }

    function test_CreateEdition_RefusesHashClaimedInEditions() public {
        PackageItem memory item = _fixedItem(10);
        uint256 id = _master(item);
        bytes32 sha = registry.sha256Of(item.contentId);
        registry.preclaim(PRODUCT_EDITIONS, sha);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.ContentUsed.selector, PRODUCT_EDITIONS, sha)
        );
        editions.createEdition(id, item);
    }

    function test_CreateEdition_FailsClosedWhenStreamDoesNotLink() public {
        PackageItem memory item = _fixedItem(10);
        uint256 id = _master(item);
        stream.setLinkMode(EditionsStreamMock.LinkMode.IGNORE);
        vm.expectRevert(abi.encodeWithSelector(Editions.LinkFailed.selector, id));
        editions.createEdition(id, item);
        stream.setLinkMode(EditionsStreamMock.LinkMode.WRONG_ID);
        vm.expectRevert(abi.encodeWithSelector(Editions.LinkFailed.selector, id));
        editions.createEdition(id, item);
        assertFalse(editions.exists(id), "nothing persists");
    }

    function test_CreateEdition_RequiresStreamToNameThisContract() public {
        PackageItem memory item = _fixedItem(10);
        uint256 id = _master(item);
        stream.setEditions(outsider);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotEditions.selector, address(editions)));
        editions.createEdition(id, item);
    }

    function test_CreateEdition_LinkIsPermanent() public {
        PackageItem memory item = _fixedItem(3);
        uint256 id = _create(item);
        fixedAdapter.buy(editions, id, buyer, 3);
        stream.setLicense(id, License("CC-BY-4.0", keccak256("by")));
        stream.pinRenderer(id, address(new EditionsRendererMock("pinned")));
        economics.setEconomics(ProductEconomics(outsider, 1, 1));
        (address s, uint256 workId, bytes32 contentId) = editions.masterOf(id);
        assertEq(s, address(stream));
        assertEq(workId, id);
        assertEq(contentId, item.contentId);
        (address e, uint256 editionId) = stream.editionOf(id);
        assertEq(e, address(editions));
        assertEq(editionId, id);
    }

    /// @dev EIP-7825: `createEdition` for an item at `Limits.MAX_PARTIES` parties and payees with
    ///      Dutch params fits the transaction cap with wide margin (Editions' own work; the real
    ///      registry and resolver add their share).
    function test_Gas_CreateEditionWorstCaseFitsTxCap() public {
        PackageItem memory item = _openItem(30 days, type(uint64).max);
        uint256 n = Limits.MAX_PARTIES;
        item.parties = new Party[](n);
        item.payees = new Payee[](n);
        for (uint256 i; i < n; ++i) {
            address account = address(uint160(0x1000 + i));
            item.parties[i] = Party(account, i == 0 ? PartyRole.ARTIST : PartyRole.COLLABORATOR);
            item.payees[i] = Payee(0, account, uint32(100_000 / n));
        }
        item.payees[n - 1].share += uint32(100_000 % n);
        item.license.spdxId = "LicenseRef-6529-Works-Custom-License-With-A-Long-Identifier";
        uint256 id = _master(item);
        bytes memory callData = abi.encodeCall(IEditions.createEdition, (id, item));
        uint256 g = gasleft();
        editions.createEdition(id, item);
        uint256 execution = g - gasleft();
        uint256 txGas = 21_000 + _calldataGas(callData) + execution;
        console2.log("createEdition worst case: execution", execution);
        console2.log("createEdition worst case: transaction", txGas);
        assertLe(txGas, TX_GAS_CAP / 8, "an eighth of the EIP-7825 cap");
    }

    /// @dev One purchase's token-side cost: the first copy to a new holder of an OPEN edition
    ///      (window start written) is the most expensive mint.
    function test_Gas_MintFirstCopy() public {
        uint256 id = _create(_item(EditionFormat.OPEN, 100, 1 days, SaleKind.FIXED_PRICE));
        vm.prank(address(fixedAdapter));
        uint256 g = gasleft();
        editions.mint(buyer, id, 1, "");
        uint256 used = g - gasleft();
        console2.log("mint, first copy of an OPEN edition: execution", used);
        assertLt(used, 150_000);
    }

    // ------------------------------------------------------------------ minting

    function test_Mint_FixedEditionToBuyer() public {
        PackageItem memory item = _fixedItem(10);
        uint256 id = _create(item);
        vm.expectEmit(true, true, true, true, address(editions));
        emit IERC1155.TransferSingle(address(fixedAdapter), address(0), buyer, id, 3);
        (uint256 tokenId, PrimaryTerms memory terms) = fixedAdapter.buy(editions, id, buyer, 3);
        assertEq(tokenId, id);
        assertEq(editions.balanceOf(buyer, id), 3);
        assertEq(editions.edition(id).minted, 3);
        WorkTerms memory w = economics.newWorkTerms(PRODUCT_EDITIONS, item.payees);
        assertEq(terms.saleKind, SaleKind.FIXED_PRICE);
        assertEq(terms.currency, CURRENCY_ETH);
        assertEq(terms.price, PRICE);
        assertEq(terms.params, "");
        assertEq(terms.seller, w.seller);
        assertEq(terms.feeRecipient, feeRecipient);
        assertEq(terms.feeShare, 25_000);
        assertEq(terms.creator, artist);
        assertFalse(terms.revealPending);
        assertEq(keccak256(abi.encode(editions.primaryTerms(id, ""))), keccak256(abi.encode(terms)));
    }

    function test_Mint_OnlyMinter() public {
        uint256 id = _create(_fixedItem(10));
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        editions.mint(outsider, id, 1, "");
        // An adapter that lost its role can no longer mint.
        vm.prank(admin);
        manager.revokeRole(MINTER, address(fixedAdapter));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManaged.AccessManagedUnauthorized.selector, address(fixedAdapter)
            )
        );
        fixedAdapter.buy(editions, id, buyer, 1);
    }

    function test_Mint_RequiresMatchingSaleKind() public {
        uint256 fixedId = _create(_fixedItem(10));
        uint256 dutchId = _create(_openItem(1 days, 0));
        vm.expectRevert(
            abi.encodeWithSelector(
                Editions.SaleKindMismatch.selector, SaleKind.FIXED_PRICE, SaleKind.DUTCH
            )
        );
        dutchAdapter.buy(editions, fixedId, buyer, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                Editions.SaleKindMismatch.selector, SaleKind.DUTCH, SaleKind.FIXED_PRICE
            )
        );
        fixedAdapter.buy(editions, dutchId, buyer, 1);
        dutchAdapter.buy(editions, dutchId, buyer, 1);
    }

    function test_Mint_RejectsUnknownEditionZeroAmountAndData() public {
        vm.expectRevert(abi.encodeWithSelector(IEditions.UnknownEdition.selector, 7));
        fixedAdapter.buy(editions, 7, buyer, 1);
        uint256 id = _create(_fixedItem(10));
        vm.expectRevert(Editions.InvalidMintRequest.selector);
        fixedAdapter.buy(editions, id, buyer, 0);
        vm.expectRevert(Editions.InvalidMintRequest.selector);
        fixedAdapter.buyWithData(editions, id, buyer, hex"00");
        vm.expectRevert(Editions.InvalidMintRequest.selector);
        editions.primaryTerms(id, hex"00");
        vm.expectRevert(abi.encodeWithSelector(IEditions.UnknownEdition.selector, 7));
        editions.primaryTerms(7, "");
    }

    function test_Mint_StopsAtSize() public {
        uint256 id = _create(_fixedItem(5));
        fixedAdapter.buy(editions, id, buyer, 4);
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id));
        fixedAdapter.buy(editions, id, buyer, 2);
        fixedAdapter.buy(editions, id, outsider, 1);
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id));
        fixedAdapter.buy(editions, id, buyer, 1);
        assertEq(editions.edition(id).minted, 5);
    }

    function testFuzz_Mint_NeverExceedsSize(uint64 size, uint256 a, uint256 b) public {
        size = uint64(bound(size, 1, 1_000_000));
        uint256 id = _create(_fixedItem(size));
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
        fixedAdapter.buy(editions, id, buyer, amount);
    }

    function test_Mint_OpenWindowStartsAtFirstMint() public {
        uint64 window = 2 days;
        uint256 id = _create(_openItem(window, 0));
        vm.warp(block.timestamp + 10 days); // creation does not start the clock
        uint64 start = uint64(block.timestamp);
        vm.expectEmit(true, false, false, true, address(editions));
        emit Editions.EditionWindowOpened(id, start, uint256(start) + window);
        dutchAdapter.buy(editions, id, buyer, 1_000_000);
        assertEq(editions.edition(id).windowStart, start);

        vm.warp(uint256(start) + window - 1);
        dutchAdapter.buy(editions, id, buyer, 1);
        vm.warp(uint256(start) + window);
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id));
        dutchAdapter.buy(editions, id, buyer, 1);
        assertEq(editions.edition(id).windowStart, start, "the window never restarts");
        assertEq(editions.edition(id).minted, 1_000_001);
    }

    function test_Mint_OpenWindowWithSizeCap() public {
        uint256 id = _create(_openItem(1 days, 3));
        dutchAdapter.buy(editions, id, buyer, 3);
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id));
        dutchAdapter.buy(editions, id, buyer, 1);
    }

    function test_Mint_OpenWithoutCapStopsAtUint64() public {
        uint256 id = _create(_openItem(1 days, 0));
        dutchAdapter.buy(editions, id, buyer, type(uint64).max - 1);
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id));
        dutchAdapter.buy(editions, id, buyer, 2);
        dutchAdapter.buy(editions, id, buyer, 1);
        assertEq(editions.edition(id).minted, type(uint64).max);
    }

    function test_Mint_CreatorFollowsArtistRecovery() public {
        uint256 id = _create(_fixedItem(10));
        assertEq(editions.primaryTerms(id, "").creator, artist);
        address recovered = makeAddr("recovered");
        artists.recover(uint256(uint160(artist)), recovered);
        assertEq(editions.primaryTerms(id, "").creator, recovered);
        (, PrimaryTerms memory terms) = fixedAdapter.buy(editions, id, buyer, 1);
        assertEq(terms.creator, recovered);
    }

    function test_Mint_DutchTermsCarryParams() public {
        PackageItem memory item = _openItem(1 days, 0);
        uint256 id = _create(item);
        PrimaryTerms memory terms = editions.primaryTerms(id, "");
        assertEq(terms.saleKind, SaleKind.DUTCH);
        assertEq(terms.price, PRICE);
        DutchParams memory p = abi.decode(terms.params, (DutchParams));
        assertEq(p.restingPrice, PRICE / 10);
        assertEq(p.duration, 1 days);
    }

    // ------------------------------------------------------------------ burn

    function test_Burn_AdapterBurnsItsOwnCopies() public {
        uint256 id = _create(_fixedItem(5));
        fixedAdapter.buy(editions, id, address(fixedAdapter), 2);
        vm.expectEmit(true, true, true, true, address(editions));
        emit IERC1155.TransferSingle(
            address(fixedAdapter), address(fixedAdapter), address(0), id, 2
        );
        fixedAdapter.burnHeld(editions, id, 2);
        assertEq(editions.balanceOf(address(fixedAdapter), id), 0);
        assertEq(editions.edition(id).minted, 2, "burned copies still count toward the size");
        fixedAdapter.buy(editions, id, buyer, 3);
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id));
        fixedAdapter.buy(editions, id, buyer, 1);
    }

    function test_Burn_OnlyMinterOnlyOwnBalance() public {
        uint256 id = _create(_fixedItem(5));
        fixedAdapter.buy(editions, id, buyer, 2);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, buyer)
        );
        editions.burn(id, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC1155Errors.ERC1155InsufficientBalance.selector, address(fixedAdapter), 0, 1, id
            )
        );
        fixedAdapter.burnHeld(editions, id, 1);
        vm.expectRevert(abi.encodeWithSelector(IEditions.UnknownEdition.selector, 9));
        fixedAdapter.burnHeld(editions, 9, 1);
        vm.expectRevert(Editions.InvalidMintRequest.selector);
        fixedAdapter.burnHeld(editions, id, 0);
        assertEq(editions.balanceOf(buyer, id), 2);
    }

    // ------------------------------------------------------------------ royalties

    function test_RoyaltyInfo_LockedTermsOutOf100k() public {
        PackageItem memory item = _fixedItem(5);
        uint256 id = _create(item);
        (address receiver, uint256 amount) = editions.royaltyInfo(id, 1 ether);
        assertEq(receiver, economics.newWorkTerms(PRODUCT_EDITIONS, item.payees).royaltyReceiver);
        assertEq(amount, 0.06529 ether, "6.529% is exact");
        (, amount) = editions.royaltyInfo(id, 100_000);
        assertEq(amount, 6_529);
    }

    function testFuzz_RoyaltyInfo_NoOverflow(uint256 salePrice) public {
        uint256 id = _create(_fixedItem(5));
        (, uint256 amount) = editions.royaltyInfo(id, salePrice);
        assertLe(amount, salePrice);
        assertEq(amount, salePrice / 100_000 * 6_529 + salePrice % 100_000 * 6_529 / 100_000);
    }

    function test_RoyaltyInfo_ImmutableAfterGovernanceChange() public {
        PackageItem memory item = _fixedItem(5);
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

        // New editions lock the new defaults.
        uint256 next = _create(_fixedItem(5));
        (, uint256 a3) = editions.royaltyInfo(next, 1 ether);
        assertEq(a3, 0.1 ether);
        assertEq(editions.edition(next).feeRecipient, outsider);
    }

    function test_RoyaltyInfo_UnknownEdition() public {
        vm.expectRevert(abi.encodeWithSelector(IEditions.UnknownEdition.selector, 3));
        editions.royaltyInfo(3, 1 ether);
    }

    // ------------------------------------------------------------------ license and uri

    function test_LicenseOf_InheritsMaster() public {
        PackageItem memory item = _fixedItem(5);
        uint256 id = _create(item);
        License memory l = editions.licenseOf(id);
        assertEq(l.spdxId, "CC0-1.0");
        assertEq(l.textFileId, item.license.textFileId);
        // A permitted relicense of the master carries over to its edition.
        stream.setLicense(id, License("CC-BY-4.0", keccak256("by")));
        assertEq(editions.licenseOf(id).spdxId, "CC-BY-4.0");
        vm.expectRevert(abi.encodeWithSelector(IEditions.UnknownEdition.selector, 99));
        editions.licenseOf(99);
    }

    function test_Uri_RoutesThroughMasterRenderer() public {
        uint256 id = _create(_fixedItem(5));
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
        uint256 id = _create(_fixedItem(5));
        address r = address(new RevertingReceiver1155());
        vm.expectRevert(RevertingReceiver1155.Refused.selector);
        fixedAdapter.buy(editions, id, r, 1);
        assertEq(editions.edition(id).minted, 0, "nothing persists");
    }

    function test_Receiver_WrongMagicOrNoHookIsInvalid() public {
        uint256 id = _create(_fixedItem(5));
        address wrong = address(new WrongSelectorReceiver1155());
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, wrong)
        );
        fixedAdapter.buy(editions, id, wrong, 1);
        address none = address(new NoHookReceiver1155());
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, none)
        );
        fixedAdapter.buy(editions, id, none, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, address(0))
        );
        fixedAdapter.buy(editions, id, address(0), 1);
    }

    function test_Receiver_GasBurnerCannotMint() public {
        uint256 id = _create(_fixedItem(5));
        address burner = address(new GasBurnerReceiver1155());
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, burner)
        );
        fixedAdapter.buy{ gas: 2_000_000 }(editions, id, burner, 1);
        assertEq(editions.edition(id).minted, 0);
    }

    function test_Receiver_ReentryThroughAdapterSeesUpdatedSupply() public {
        uint256 id = _create(_fixedItem(1));
        ReentrantReceiver1155 r = new ReentrantReceiver1155(fixedAdapter, editions);
        fixedAdapter.buy(editions, id, address(r), 1);
        assertFalse(r.reentrySucceeded());
        assertEq(
            r.reentryError(), abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id)
        );
        assertEq(editions.balanceOf(address(r), id), 1);
        assertEq(editions.edition(id).minted, 1);
    }

    function test_Receiver_ReentryWithinSizeIsCounted() public {
        uint256 id = _create(_fixedItem(2));
        ReentrantReceiver1155 r = new ReentrantReceiver1155(fixedAdapter, editions);
        fixedAdapter.buy(editions, id, address(r), 1);
        assertTrue(r.reentrySucceeded());
        assertEq(editions.balanceOf(address(r), id), 2);
        assertEq(editions.edition(id).minted, 2);
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id));
        fixedAdapter.buy(editions, id, buyer, 1);
    }

    function test_Receiver_DirectReentryIsUnauthorized() public {
        uint256 id = _create(_fixedItem(5));
        ReentrantReceiver1155 r = new ReentrantReceiver1155(fixedAdapter, editions);
        r.setMode(ReentrantReceiver1155.Mode.DIRECT);
        fixedAdapter.buy(editions, id, address(r), 1);
        assertEq(
            r.reentryError(),
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(r))
        );
        assertEq(editions.edition(id).minted, 1);
    }

    function test_Receiver_CreateReentryHitsEditionExists() public {
        PackageItem memory item = _fixedItem(5);
        uint256 id = _create(item);
        ReentrantReceiver1155 r = new ReentrantReceiver1155(fixedAdapter, editions);
        r.setMode(ReentrantReceiver1155.Mode.CREATE);
        r.setItem(item);
        fixedAdapter.buy(editions, id, address(r), 1);
        assertEq(r.reentryError(), abi.encodeWithSelector(IEditions.EditionExists.selector, id));
    }

    // ------------------------------------------------------------------ metadata propagation

    function test_BindWorkRecords_OnceGovernedAndChecked() public {
        address records = address(workRecordsMock);
        bytes32 codeHash = records.codehash;
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        editions.bindWorkRecords(records, codeHash);

        vm.startPrank(governor);
        vm.expectRevert(abi.encodeWithSelector(Editions.InvalidDependency.selector, outsider));
        editions.bindWorkRecords(outsider, outsider.codehash); // an EOA
        address delegated = makeAddr("delegatedRecords");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", records));
        vm.expectRevert(abi.encodeWithSelector(Editions.InvalidDependency.selector, delegated));
        editions.bindWorkRecords(delegated, delegated.codehash);
        vm.expectRevert(
            abi.encodeWithSelector(
                Editions.CodeHashMismatch.selector, bytes32(uint256(1)), codeHash
            )
        );
        editions.bindWorkRecords(records, bytes32(uint256(1)));

        vm.expectEmit(true, false, false, true, address(editions));
        emit Editions.WorkRecordsBound(records, codeHash);
        editions.bindWorkRecords(records, codeHash);
        assertEq(editions.workRecords(), records);
        vm.expectRevert(Editions.AlreadyBound.selector);
        editions.bindWorkRecords(address(renderer), address(renderer).codehash);
        vm.stopPrank();
        assertEq(editions.workRecords(), records, "the binding is permanent");
    }

    function test_NotifyMasterUpdated_EmitsForEditionsOnly() public {
        uint256 id = _create(_fixedItem(5));
        // Before the binding nobody may report, not even the future satellite.
        vm.expectRevert(
            abi.encodeWithSelector(Editions.NotWorkRecords.selector, address(workRecordsMock))
        );
        workRecordsMock.notify(editions, id);

        _bindWorkRecords();
        vm.expectEmit(false, false, false, true, address(editions));
        emit Editions.MetadataUpdate(id);
        workRecordsMock.notify(editions, id);

        // A master without an edition (or an ORIGINAL) is a silent no-op, never a revert.
        uint256 bare = _master(_fixedItem(5));
        vm.recordLogs();
        workRecordsMock.notify(editions, bare);
        assertEq(vm.getRecordedLogs().length, 0);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Editions.NotWorkRecords.selector, outsider));
        editions.notifyMasterUpdated(id);
        vm.prank(address(stream));
        vm.expectRevert(abi.encodeWithSelector(Editions.NotWorkRecords.selector, address(stream)));
        editions.notifyMasterUpdated(id);
    }

    // ------------------------------------------------------------------ governed setters

    function test_SetContractURI_Governed() public {
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        editions.setContractURI("ipfs://x");
        vm.expectEmit(false, false, false, true, address(editions));
        emit Editions.ContractURISet("", "ipfs://contract");
        vm.expectEmit(false, false, false, false, address(editions));
        emit IEditions.ContractURIUpdated();
        vm.prank(governor);
        editions.setContractURI("ipfs://contract");
        assertEq(editions.contractURI(), "ipfs://contract");
        vm.expectEmit(false, false, false, true, address(editions));
        emit Editions.ContractURISet("ipfs://contract", "ipfs://v2");
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

    function test_SupportsInterface() public view {
        assertTrue(editions.supportsInterface(type(IERC165).interfaceId));
        assertTrue(editions.supportsInterface(type(IERC1155).interfaceId));
        assertTrue(editions.supportsInterface(type(IERC1155MetadataURI).interfaceId));
        assertTrue(editions.supportsInterface(type(IERC2981).interfaceId));
        assertTrue(editions.supportsInterface(type(IMintTarget).interfaceId));
        assertTrue(editions.supportsInterface(type(IEditions).interfaceId));
        assertFalse(editions.supportsInterface(0xffffffff));
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

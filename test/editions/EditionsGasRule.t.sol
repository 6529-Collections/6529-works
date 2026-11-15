// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC1155Holder } from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import { Editions } from "src/editions/Editions.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { Burner, GasRuleAssertions } from "../helpers/GasRule.sol";
import { EditionsBase } from "./EditionsBase.sol";
import {
    EditionsPackages,
    EditionsRegistryMock,
    EditionsStreamMock
} from "../mocks/editions/EditionsMocks.sol";

/// @dev A plain ERC-1155 recipient.
contract Holder1155 is ERC1155Holder { }

/// @notice The gas rule for every call out of 6529 Stream Editions (ED-28): each dependency is
///         wrapped in a `Burner` that costs 1x to 100x its base, and every operation reaching it
///         gives the same answer at every multiple, and, short of gas, either that answer, the
///         shortfall error naming the dependency, or the caller's own out-of-gas, never another
///         answer. Sites: the renderer (`uri`), the work-records satellite (`licenseOf`), the
///         artist registry (`primaryTerms`), the economics resolver (`createEdition`,
///         `bindMinter`) and a recipient's ERC-1155 hook (`mint`).
contract EditionsGasRuleTest is EditionsBase, GasRuleAssertions {
    uint256 internal constant BASE = 10_000;

    Burner internal rendererBurner;
    Burner internal recordsBurner;
    Burner internal artistsBurner;
    Burner internal economicsBurner;

    function setUp() public override {
        super.setUp();
        // A second wiring whose Stream reports burner-wrapped dependencies.
        rendererBurner = new Burner(address(renderer), BASE);
        recordsBurner = new Burner(address(workRecordsMock), BASE);
        artistsBurner = new Burner(address(artists), BASE);
        economicsBurner = new Burner(address(economics), BASE);
        registry = new EditionsRegistryMock();
        stream = new EditionsStreamMock(
            address(registry),
            address(economicsBurner),
            address(artistsBurner),
            address(rendererBurner)
        );
        editions =
            new Editions(address(manager), address(stream), address(stream).codehash, marketOwner);
        stream.bind(address(recordsBurner), address(editions));
        registry.bindCallers(address(stream), address(editions));
        vm.startPrank(admin);
        manager.setTargetFunctionRole(
            address(editions), _one(Editions.setAdmittedMinter.selector), SUCCESSOR_SETTER
        );
        editions.bindWorkRecords(address(recordsBurner));
        vm.stopPrank();
        vm.prank(governor);
        editions.setAdmittedMinter(address(adapter), true);
    }

    function test_GasRule_UriThroughTheRenderer() public {
        uint256 id = _create(_item(5));
        bytes memory data = abi.encodeCall(editions.uri, (id));
        Outcome memory o =
            _assertSameAtEveryMultiple(rendererBurner, outsider, address(editions), data);
        assertTrue(o.ok, "uri answers");
        _assertShortfallNeverAnswers(rendererBurner, outsider, address(editions), data);
        rendererBurner.burnerSetMultiple(10);
        _assertShortfallNeverAnswers(rendererBurner, outsider, address(editions), data);
    }

    function test_GasRule_LicenseThroughWorkRecords() public {
        uint256 id = _create(_item(5));
        bytes memory data = abi.encodeCall(editions.licenseOf, (id));
        // Unopened: the satellite's refusal passes through unchanged at every multiple.
        Outcome memory o =
            _assertSameAtEveryMultiple(recordsBurner, outsider, address(editions), data);
        assertFalse(o.ok, "RecordNotOpen");
        workRecordsMock.openRecord(id);
        o = _assertSameAtEveryMultiple(recordsBurner, outsider, address(editions), data);
        assertTrue(o.ok, "licenseOf answers");
        _assertShortfallNeverAnswers(recordsBurner, outsider, address(editions), data);
    }

    function test_GasRule_CreatorThroughTheArtistRegistry() public {
        uint256 id = _create(_item(5));
        bytes memory data = abi.encodeCall(editions.primaryTerms, (id, ""));
        Outcome memory o =
            _assertSameAtEveryMultiple(artistsBurner, outsider, address(editions), data);
        assertTrue(o.ok, "primaryTerms answers");
        _assertShortfallNeverAnswers(artistsBurner, outsider, address(editions), data);
    }

    function test_GasRule_CreateEditionThroughTheEconomicsResolver() public {
        PackageItem memory item = _item(5);
        uint256 id = _master(item);
        (bytes32 root, bytes32[] memory proof) = EditionsPackages.packageOf(item, 0);
        bytes memory data = abi.encodeCall(editions.createEdition, (id, item, root, proof));
        Outcome memory o =
            _assertSameAtEveryMultiple(economicsBurner, outsider, address(editions), data);
        assertTrue(o.ok, "createEdition succeeds");
        // `createEdition` calls several dependencies after the resolver, so running short there
        // names whichever one ran short: any shortfall, never another answer or refusal.
        uint256 named;
        for (uint256 g = 30_000; g < 400_000; g += 2_500) {
            Outcome memory r = _try(outsider, address(editions), data, g);
            if (r.ok || r.data.length == 0) continue;
            assertEq(r.data.length, 36, "a shortfall");
            assertEq(bytes4(r.data), BoundedCall.BoundedCallShortfall.selector, "a shortfall");
            if (keccak256(r.data) == keccak256(_shortfall(address(economicsBurner)))) ++named;
        }
        assertGt(named, 0, "the resolver's shortfall is reached");
    }

    function test_GasRule_BindMinterThroughTheEconomicsResolver() public {
        PackageItem memory item = _item(5);
        uint256 id = _master(item);
        bytes memory data = abi.encodeCall(editions.bindMinter, (id, item));
        Outcome memory o =
            _assertSameAtEveryMultiple(economicsBurner, address(adapter), address(editions), data);
        assertTrue(o.ok, "bindMinter succeeds");
        _assertShortfallNeverAnswers(economicsBurner, address(adapter), address(editions), data);
    }

    function test_GasRule_MintThroughTheRecipientsHook() public {
        uint256 id = _create(_item(0));
        Burner holder = new Burner(address(new Holder1155()), BASE);
        bytes memory data = abi.encodeCall(
            IMintTarget.mint, (address(holder), id, 1, abi.encode(CURRENCY_ETH, uint256(1)))
        );
        Outcome memory o =
            _assertSameAtEveryMultiple(holder, address(adapter), address(editions), data);
        assertTrue(o.ok, "the recipient accepts");
        // At 1x the 1/64 a hook leaves behind is too little to revert with a reason (the
        // caller's own out-of-gas, which the harness accepts); from 10x it names the hook.
        holder.burnerSetMultiple(10);
        _assertShortfallNeverAnswers(holder, address(adapter), address(editions), data);
        holder.burnerSetMultiple(100);
        _assertShortfallNeverAnswers(holder, address(adapter), address(editions), data);
        assertEq(editions.edition(id).minted, 0, "each attempt was rolled back");
    }

    /// @dev The renderer and the satellite are read only through these calls: an edition's
    ///      metadata never comes from another renderer when the pinned one runs short.
    function test_GasRule_UriNeverFallsBack() public {
        uint256 id = _create(_item(5));
        rendererBurner.burnerSetMultiple(100);
        vm.expectRevert(_shortfall(address(rendererBurner)));
        editions.uri{ gas: 900_000 }(id);
        editions.uri(id);
    }
}

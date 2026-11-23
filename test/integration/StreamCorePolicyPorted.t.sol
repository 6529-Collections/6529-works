// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { Splits } from "src/economics/Splits.sol";
import { Collection, MintFacts, Slots, Work as CoreWork } from "src/interfaces/core/CoreTypes.sol";
import { IModuleSlots } from "src/interfaces/core/IModules.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { PRODUCT_STREAM } from "src/interfaces/types/EconomicsTypes.sol";
import { ItemKind } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice The permanent Stream core on the deployed stack (re-ported from the retired
///         `StreamCorePolicy` suite): the mint record a real sale writes, the native views, the
///         royalty setter only the deployed TERMS module reaches, `rendererOf`'s fail-closed
///         read of WorkFacts, and burning only by the minter holding the work.
contract StreamCorePolicyPortedTest is IntegrationBase {
    bytes32 internal root;
    address internal lead;

    function setUp() public override {
        super.setUp();
        lead = _actor("coreArtist");
        Work[] memory w = new Work[](2);
        for (uint256 i; i < 2; ++i) {
            w[i] = _work(lead, collectionId);
        }
        root = _publish(w);
        _keep(root, w);
    }

    function _first() internal returns (uint256 tokenId) {
        (, tokenId) = _start(root, _package(root), 0);
    }

    /// @dev A real start logs `WorkMinted` once, with the account's ID as the artist topic and
    ///      the facts the package and the economics derive: the item, the seller vault of the
    ///      payees, the royalty vault at the genesis share and rate, the package root. The token
    ///      stores the same.
    function test_Mint_LogsTheFactsThePackageAndTheEconomicsDerive() public {
        Work memory w = _package(root)[0];
        vm.recordLogs();
        uint256 tokenId = _first();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        MintFacts memory f;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(stream)) continue;
            if (logs[i].topics[0] != IStream.WorkMinted.selector) continue;
            ++count;
            assertEq(uint256(logs[i].topics[1]), tokenId, "tokenId topic");
            assertEq(uint256(logs[i].topics[2]), collectionId, "collection topic");
            assertEq(uint256(logs[i].topics[3]), accounts.artistIdOf(lead), "artistId topic");
            address minter;
            uint32 serial;
            (minter, serial, f) = abi.decode(logs[i].data, (address, uint32, MintFacts));
            assertEq(minter, address(auction), "the minter");
            assertEq(serial, 1);
        }
        assertEq(count, 1, "WorkMinted once");
        assertEq(f.itemHash, WorksHashing.itemHash(w.item));
        assertEq(f.contentHash, w.item.contentHash);
        assertEq(f.packageRoot, root);
        assertEq(f.mediaHash, w.item.mediaHash);
        assertEq(f.recordFileId, w.item.recordFileId);
        address seller = ledger.walletFor(w.item.payees, bytes32(0));
        assertEq(f.seller, seller, "the payees' vault");
        uint32 share = economics.economics(PRODUCT_STREAM).feeShare;
        assertEq(
            f.royaltyReceiver,
            ledger.walletFor(Splits.royaltyPayees(seller, networkFee, share), bytes32(0)),
            "the royalty vault at the genesis share"
        );
        assertEq(f.royaltyRate, economics.economics(PRODUCT_STREAM).royaltyRate);

        CoreWork memory stored = stream.workOf(tokenId);
        assertEq(stored.itemHash, f.itemHash);
        assertEq(stored.artistId, f.artistId);
        assertEq(stored.collectionId, collectionId);
        assertEq(stored.serial, 1);
        assertEq(stored.kind, uint8(ItemKind.ORIGINAL));
        assertEq(stored.seedPolicy, w.item.seedPolicy);
        assertEq(stored.royaltyReceiver, f.royaltyReceiver);
        assertEq(stored.royaltyRate, f.royaltyRate);
        assertEq(stream.itemHashOf(tokenId), f.itemHash);
        assertEq(stream.tokenOfContent(f.contentHash), tokenId);
    }

    /// @dev The native views after two starts: counts, the collection record and its unknown
    ///      neighbour, the royalty pair.
    function test_Views_AfterTwoStarts() public {
        uint256 first = _first();
        (, uint256 second) = _start(root, _package(root), 1);
        assertEq(second, first + 1);
        assertEq(stream.totalMinted(), second);
        assertEq(stream.totalSupply(), second);
        assertEq(stream.collectionCount(), collectionId);
        Collection memory c = stream.collectionOf(collectionId);
        assertTrue(c.exists);
        assertEq(c.minted, 2);
        assertEq(c.name, "Genesis");
        assertEq(stream.workOf(second).serial, 2);
        assertFalse(stream.collectionOf(collectionId + 1).exists);
        (address receiver, uint256 royalty) = stream.royaltyInfo(first, 1 ether);
        assertEq(receiver, stream.workOf(first).royaltyReceiver);
        assertEq(royalty, 1 ether * uint256(stream.workOf(first).royaltyRate) / 100_000);
    }

    /// @dev A long collection name is stored and read back whole.
    function test_CreateCollection_LongNameRoundTrips() public {
        string memory name = "A collection whose name is longer than thirty-one bytes, stored long";
        vm.prank(platform);
        uint256 id = stream.createCollection(name, keccak256("m"));
        assertEq(stream.collectionOf(id).name, name);
    }

    function test_SupportsTheDeclaredInterfaces() public view {
        assertTrue(stream.supportsInterface(type(IStream).interfaceId), "IStream");
        assertTrue(stream.supportsInterface(type(IERC721).interfaceId), "IERC721");
        assertTrue(stream.supportsInterface(type(IERC2981).interfaceId), "IERC2981");
        assertFalse(stream.supportsInterface(0xffffffff));
    }

    /// @dev Stream has no fallback: an unknown selector and ETH are refused.
    function test_UnknownSelectorAndEthAreRefused() public {
        (bool ok,) = address(stream).call(abi.encodeWithSignature("nothingHere()"));
        assertFalse(ok);
        (ok,) = address(stream).call{ value: 1 }("");
        assertFalse(ok, "no receive");
        (ok,) = address(stream).call{ value: 1 }(abi.encodeWithSignature("totalMinted()"));
        assertFalse(ok, "views are not payable");
    }

    // ------------------------------------------------------------------ royalties

    /// @dev Only the deployed TERMS module sets a royalty, never past 100%, and it may move a
    ///      rate either way.
    function test_SetRoyalty_OnlyTheTermsModuleUpToTheCeiling() public {
        uint256 tokenId = _first();
        CoreWork memory w = stream.workOf(tokenId);
        assertEq(stream.moduleOf(Slots.TERMS), address(terms));
        vm.prank(address(rules));
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.NotModule.selector, Slots.TERMS, address(rules))
        );
        stream.setRoyalty(tokenId, w.royaltyReceiver, w.royaltyRate + 1);
        vm.startPrank(address(terms));
        vm.expectRevert(IStream.InvalidRoyalty.selector);
        stream.setRoyalty(tokenId, w.royaltyReceiver, 100_001);
        stream.setRoyalty(tokenId, w.royaltyReceiver, w.royaltyRate + 1);
        assertEq(stream.workOf(tokenId).royaltyRate, w.royaltyRate + 1);
        stream.setRoyalty(tokenId, w.royaltyReceiver, w.royaltyRate - 1);
        assertEq(stream.workOf(tokenId).royaltyRate, w.royaltyRate - 1);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ the renderer

    /// @dev Before finalize WorkFacts pins nothing, so the token serves its RENDERER module.
    function test_RendererOf_UnfinalizedServesTheModule() public {
        uint256 tokenId = _first();
        assertEq(facts.rendererOf(address(stream), tokenId), address(0));
        assertEq(stream.rendererOf(tokenId), stream.moduleOf(Slots.RENDERER));
        assertEq(stream.rendererOf(tokenId), address(renderer));
    }

    /// @dev A failing WorkFacts read is passed on, never answered with a renderer.
    function test_RendererOf_AFailingReadFailsClosed() public {
        uint256 tokenId = _first();
        vm.mockCallRevert(
            address(facts),
            abi.encodeCall(IWorkFacts.rendererOf, (address(stream), tokenId)),
            abi.encodeWithSelector(IWorkFacts.RendererCodeChanged.selector, address(renderer))
        );
        vm.expectRevert(
            abi.encodeWithSelector(IWorkFacts.RendererCodeChanged.selector, address(renderer))
        );
        stream.rendererOf(tokenId);
    }

    /// @dev A malformed answer (not an address) reverts instead of being used.
    function test_RendererOf_AMalformedAnswerFailsClosed() public {
        uint256 tokenId = _first();
        vm.mockCall(
            address(facts),
            abi.encodeCall(IWorkFacts.rendererOf, (address(stream), tokenId)),
            abi.encode(type(uint256).max)
        );
        vm.expectRevert();
        stream.rendererOf(tokenId);
    }

    /// @dev A short-gas read never serves a wrong renderer: at every gas limit from 2,000 to
    ///      40,000 the call either fails or answers the RENDERER module.
    function test_RendererOf_ShortGasNeverServesAnotherRenderer() public {
        uint256 tokenId = _first();
        uint256 failures;
        for (uint256 g = 2_000; g <= 40_000; g += 500) {
            (bool ok, bytes memory answer) =
                address(stream).call{ gas: g }(abi.encodeCall(stream.rendererOf, (tokenId)));
            if (!ok) {
                ++failures;
                continue;
            }
            assertEq(abi.decode(answer, (address)), address(renderer), vm.toString(g));
        }
        assertGt(failures, 0, "the lowest limits fail");
    }

    // ------------------------------------------------------------------ burn

    /// @dev Only the minter holding the work in its sale burns it: not a stranger, not the
    ///      network.
    function test_Burn_OnlyTheMinterHoldingTheWork() public {
        uint256 tokenId = _first();
        address[2] memory callers = [address(this), network];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(IStream.NotInPrimarySale.selector, tokenId));
            stream.burn(tokenId);
        }
        assertEq(stream.ownerOf(tokenId), address(auction));
    }
}

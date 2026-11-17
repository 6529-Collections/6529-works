// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { FederatedEditions } from "src/federated/FederatedEditions.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { PrimaryOutcome, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { HandlerReach } from "../helpers/HandlerReach.sol";
import { FederationBase } from "./FederationBase.sol";
import { FedAdapterMock, FederatedStateHandler } from "./FederatedStateHandler.sol";

/// @notice Stateful invariants of the federated templates' own state on the real federation
///         registry (FED-5, FED-7, FED-16, FED-17, FED-24, FED-33, FED-51): settlement once by
///         the minting adapter, unsold works in the template's custody, royalty rates that only
///         fall, no mint before joining or while delisted, sealed edition supply, and 6529
///         Stream untouched. Run with the foundry.toml campaign (256 runs x depth 128,
///         `fail_on_revert`).
contract FederatedStateInvariantTest is FederationBase {
    uint256 internal constant ITEMS = 12;

    FederatedStateHandler internal handler;
    FederatedStream internal pairStream;
    FederatedEditions internal pairEditions;
    FederatedStream internal neverJoined;
    uint256 internal streamMinted;
    bytes32 internal identity;
    mapping(uint256 workId => uint256) internal _lastRate;
    mapping(uint256 editionId => uint256) internal _sealedAt;

    function setUp() public override {
        super.setUp();
        (pairStream, pairEditions) = _pair(fedArtist);
        neverJoined = _deployStream(fedArtist);
        FedAdapterMock english = new FedAdapterMock(SaleKind.ENGLISH_AUCTION);
        FedAdapterMock uniform = new FedAdapterMock(SaleKind.UNIFORM_AUCTION);
        FedAdapterMock outsider = new FedAdapterMock(SaleKind.UNIFORM_AUCTION);
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(fedRegistry.setAdapter, (address(english), true))
        );
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(fedRegistry.setAdapter, (address(uniform), true))
        );
        handler = new FederatedStateHandler(
            pairStream,
            pairEditions,
            neverJoined,
            fedRegistry,
            manager,
            hotAdmin,
            fedArtist,
            english,
            uniform,
            outsider
        );
        for (uint256 i; i < ITEMS; ++i) {
            Work memory w =
                i % 3 == 2 ? _fedMaster(fedArtist, i % 2 == 0 ? 0 : 20) : _fedWork(fedArtist);
            uint32 rate = uint32(5_000 + 1_000 * i);
            vm.prank(fedArtist);
            pairStream.approveItem(_itemHash(w), rate);
            vm.prank(fedArtist);
            neverJoined.approveItem(_itemHash(w), rate);
            handler.addItem(w.item, _mintData(w), rate);
        }
        streamMinted = stream.totalMinted();
        identity = keccak256(abi.encode(artists.authorityOf(uint160(fedArtist))));
        bytes4[] memory s = new bytes4[](14);
        s[0] = handler.mint.selector;
        s[1] = handler.mint.selector;
        s[2] = handler.settle.selector;
        s[3] = handler.settle.selector;
        s[4] = handler.setRoyaltyRate.selector;
        s[5] = handler.approve.selector;
        s[6] = handler.bind.selector;
        s[7] = handler.create.selector;
        s[8] = handler.mintCopies.selector;
        s[9] = handler.mintCopies.selector;
        s[10] = handler.seal.selector;
        s[11] = handler.toggleListing.selector;
        s[12] = handler.toggleAdapter.selector;
        s[13] = handler.approve.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: s }));
    }

    /// INV-FED-1 (FED-16): every token's recorded minting adapter is the one that minted it,
    /// and its primary outcome and `primarySaleSettled` are the model's: set once, by its
    /// minting adapter, never by another adapter, never twice, SOLD only with a buyer.
    function invariant_SettledOnceByTheMintingAdapter() public view {
        for (uint256 id = 1; id <= handler.tokenCount(); ++id) {
            (, address adapter, uint8 state) = pairStream.tokenInfo(id);
            assertEq(adapter, handler.adapterOf(id), "minting adapter");
            assertEq(state, handler.stateOf(id), "state");
            (PrimaryOutcome outcome,,) = pairStream.primarySale(id);
            uint8 s = handler.stateOf(id);
            PrimaryOutcome want = s == 2
                ? PrimaryOutcome.SOLD
                : s == 3
                    ? PrimaryOutcome.UNBID
                    : s == 4 ? PrimaryOutcome.FROZEN_OUT : PrimaryOutcome(0);
            assertEq(uint8(outcome), uint8(want), "outcome");
            assertEq(pairStream.primarySaleSettled(id), s >= 2, "settled");
        }
    }

    /// INV-FED-2 (FED-17): an unbid or frozen-out token not restarted is held by the template
    /// itself, never by a person; a sold one by its buyer; one in sale by its minting adapter;
    /// a restarted (burned) one by no one.
    function invariant_UnsoldWorksStayInTheTemplatesCustody() public {
        for (uint256 id = 1; id <= handler.tokenCount(); ++id) {
            if (handler.burned(id)) {
                vm.expectRevert(
                    abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id)
                );
                pairStream.ownerOf(id);
                continue;
            }
            address holder = pairStream.ownerOf(id);
            assertEq(holder, handler.ownerOf(id), "holder");
            uint8 s = handler.stateOf(id);
            if (s == 3 || s == 4) assertEq(holder, address(pairStream), "template custody");
        }
    }

    /// INV-FED-3 (FED-24): each work's royalty rate is the model's and never rises: no change
    /// that did not lower it ever succeeded, and the rate is at most the one last checked.
    function invariant_RoyaltyRateOnlyFalls() public {
        assertEq(handler.rateRises(), 0, "a royalty change that did not lower the rate");
        for (uint256 workId = 1; workId <= handler.workCount(); ++workId) {
            uint256 live = pairStream.liveTokenOf(workId);
            if (live == 0) continue;
            (,,,,, uint32 rate) = pairStream.coreOf(live);
            assertEq(rate, handler.rateOf(workId), "rate");
            if (_lastRate[workId] != 0) assertLe(rate + 1, _lastRate[workId], "rate rose");
            _lastRate[workId] = uint256(rate) + 1;
        }
    }

    /// INV-FED-4 (FED-5, FED-7): the copy that never joined holds no token and admits no
    /// adapter; no mint, restart or binding succeeded while the contract (or its partner) was
    /// delisted or the adapter not admitted (each predicted refusal is checked by the handler).
    function invariant_NoMintBeforeJoiningOrWhileDelisted() public view {
        (, address adapter,) = neverJoined.tokenInfo(1);
        assertEq(adapter, address(0), "a token on the copy that never joined");
        assertEq(neverJoined.balanceOf(address(handler.english())), 0);
        assertEq(neverJoined.balanceOf(address(handler.uniform())), 0);
        assertFalse(neverJoined.isAdmittedMinter(address(handler.english())));
        assertFalse(neverJoined.isAdmittedMinter(address(handler.outsider())));
        assertFalse(pairStream.isAdmittedMinter(address(handler.outsider())));
        assertEq(handler.violations(), 0);
    }

    /// INV-FED-5 (FED-33): every edition's minted count is the model's and within its maximum;
    /// a sealed edition's maximum is its sealed count and never moves; the copies the buyers
    /// hold add up to the copies minted.
    function invariant_SealedEditionSupply() public {
        uint256 held;
        for (uint256 k; k < handler.masterCount(); ++k) {
            uint256 id = handler.masterTokens(k);
            (address minter, bool created, uint40 limit, uint40 minted, bool sealed_) =
                handler.edition(id);
            assertEq(pairEditions.isBound(id), minter != address(0) || created, "bound");
            for (uint256 b; b < 3; ++b) {
                held += pairEditions.balanceOf(handler.buyers(b), id);
            }
            if (!created) continue;
            assertEq(pairEditions.edition(id).minter, minter, "minter");
            assertEq(pairEditions.edition(id).minted, minted, "minted");
            assertEq(pairEditions.edition(id).maxSupply, limit, "maximum");
            assertEq(pairEditions.edition(id).supplySealed, sealed_, "sealed");
            assertLe(minted, limit, "within the maximum");
            if (sealed_) {
                if (_sealedAt[id] == 0) _sealedAt[id] = uint256(limit) + 1;
                assertEq(uint256(limit) + 1, _sealedAt[id], "a sealed maximum moved");
            }
        }
        assertEq(held, handler.copiesMinted(), "copies held");
    }

    /// INV-FED-6 (FED-51): nothing the federated contracts do changes 6529 Stream's supply or
    /// the artist's identity in the artist registry.
    function invariant_FederationNeverTouchesStreamOrIdentity() public view {
        assertEq(stream.totalMinted(), streamMinted, "6529 Stream minted");
        assertEq(keccak256(abi.encode(artists.authorityOf(uint160(fedArtist)))), identity);
    }

    /// @notice Handler self-test: every action changes the templates, the registry or the
    ///         artist registry, or is refused by a template; mints, restarts, settlements,
    ///         refusals, rate cuts, copies and seals all happen. Then every invariant holds.
    function test_HandlerPathsReachState() public {
        uint8 w = HandlerReach.WRITES;
        uint8 wr = HandlerReach.WRITES | HandlerReach.REFUSED;
        HandlerReach.Expect[] memory e = new HandlerReach.Expect[](11);
        e[0] = HandlerReach.Expect(handler.mint.selector, wr);
        e[1] = HandlerReach.Expect(handler.settle.selector, wr);
        e[2] = HandlerReach.Expect(handler.setRoyaltyRate.selector, wr);
        e[3] = HandlerReach.Expect(handler.approve.selector, w);
        e[4] = HandlerReach.Expect(handler.bind.selector, wr);
        e[5] = HandlerReach.Expect(handler.create.selector, wr);
        e[6] = HandlerReach.Expect(handler.mintCopies.selector, wr);
        e[7] = HandlerReach.Expect(handler.seal.selector, wr);
        e[8] = HandlerReach.Expect(handler.toggleListing.selector, w);
        e[9] = HandlerReach.Expect(handler.toggleAdapter.selector, w);
        e[10] = HandlerReach.Expect(handler.mint.selector, wr);
        HandlerReach.covers(targetSelectors()[0].selectors, e);
        address[] memory sut = new address[](5);
        sut[0] = address(pairStream);
        sut[1] = address(pairEditions);
        sut[2] = address(neverJoined);
        sut[3] = address(fedRegistry);
        sut[4] = address(artists);
        HandlerReach.Tally[] memory t = new HandlerReach.Tally[](e.length);
        uint256[6] memory n;
        for (uint256 run; run < 8; ++run) {
            uint256 snapshot = vm.snapshotState();
            HandlerReach.add(t, HandlerReach.drive(address(handler), e, sut, 12, run));
            n[0] += handler.restarts();
            n[1] += handler.refusedSettlements();
            n[2] += handler.rateCuts();
            n[3] += handler.copiesMinted();
            n[4] += handler.seals();
            n[5] += handler.delistedRefusals();
            if (run < 7) vm.revertToState(snapshot);
        }
        HandlerReach.check(e, t);
        assertGt(n[0], 0, "restarts");
        assertGt(n[1], 0, "refused settlements");
        assertGt(n[2], 0, "rate cuts");
        assertGt(n[3], 0, "copies");
        assertGt(n[4], 0, "seals");
        assertGt(n[5], 0, "refusals while delisted");
        invariant_SettledOnceByTheMintingAdapter();
        invariant_UnsoldWorksStayInTheTemplatesCustody();
        invariant_RoyaltyRateOnlyFalls();
        invariant_NoMintBeforeJoiningOrWhileDelisted();
        invariant_SealedEditionSupply();
        invariant_FederationNeverTouchesStreamOrIdentity();
    }
}

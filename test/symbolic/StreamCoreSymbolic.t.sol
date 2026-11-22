// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Stream } from "src/core/Stream.sol";
import { Core, MintFacts, Outcome, Work } from "src/interfaces/core/CoreTypes.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { MockRenderer, MockSale, MockTerms } from "../mocks/core/CoreMocks.sol";
import { MockPinnedFacts } from "../mocks/core/StreamCoreMocks.sol";

/// @notice Halmos proofs on the permanent ERC-721 (`src/core/Stream.sol`): what `mint` accepts,
///         the royalty rules, and the rescue predicate. Run with
///         `FOUNDRY_PROFILE=symbolic halmos --contract StreamCoreSymbolic`.
contract StreamCoreSymbolic is Test {
    AccessManager internal manager;
    Stream internal stream;
    MockSale internal sale;
    MockTerms internal terms;
    MockPinnedFacts internal facts;
    bytes32 internal constant CONTENT = keccak256("content of token 1");
    address internal constant TO = address(0x7070);

    function setUp() public {
        vm.warp(1_800_000_000);
        manager = new AccessManager(address(this));
        facts = new MockPinnedFacts();
        sale = new MockSale();
        terms = new MockTerms();
        MockRenderer renderer = new MockRenderer();
        address[] memory minters = new address[](1);
        minters[0] = address(sale);
        stream = new Stream(
            address(manager),
            address(facts),
            address(0xA),
            address(renderer),
            address(terms),
            address(0),
            minters
        );
        stream.createCollection("Genesis", 0);
        MintFacts memory f;
        f.itemHash = keccak256("item 1");
        f.contentHash = CONTENT;
        f.artistId = 1;
        f.collectionId = 1;
        sale.mint(address(stream), f); // token 1, live, in custody
    }

    /// @notice `mint` succeeds exactly when the caller is an active minter and the facts pass
    ///         every check (nonzero hashes and artist, the artist within 160 bits, the rate at
    ///         most 100,000, an existing collection, no live token with the content); a success
    ///         stores the facts under the next ID; a refusal changes no counter.
    /// @dev Bounds: any caller, item hash, content hash, artist ID, collection ID, rate.
    function check_mint_acceptsExactlyValidFacts(
        address caller,
        bytes32 itemHash,
        bytes32 contentHash,
        uint256 artistId,
        uint256 collectionId,
        uint24 rate
    ) public {
        MintFacts memory f;
        f.itemHash = itemHash;
        f.contentHash = contentHash;
        f.artistId = artistId;
        f.collectionId = collectionId;
        f.royaltyRate = rate;
        vm.prank(caller);
        (bool ok,) = address(stream).call(abi.encodeCall(IStream.mint, (TO, f)));
        bool valid = caller == address(sale) && itemHash != 0 && contentHash != 0 && artistId != 0
            && artistId <= type(uint160).max && rate <= Core.DENOMINATOR && collectionId == 1
            && contentHash != CONTENT;
        assert(ok == valid);
        if (ok) {
            assert(stream.totalMinted() == 2);
            assert(stream.ownerOf(2) == TO);
            Work memory w = stream.workOf(2);
            assert(w.itemHash == itemHash);
            assert(w.artistId == artistId);
            assert(w.royaltyRate == rate);
            assert(w.serial == 2);
            assert(w.outcome == Outcome.NONE);
            assert(stream.tokenOfContent(contentHash) == 2);
        } else {
            assert(stream.totalMinted() == 1);
            assert(stream.tokenOfContent(CONTENT) == 1);
        }
    }

    /// @notice The royalty rules: only the TERMS module sets a rate, never above 100,000; once
    ///         locked, a rate never changes (the receiver still may); a refused call changes
    ///         nothing. The amount `royaltyInfo` answers is proved by fuzzing
    ///         (`testFuzz_RoyaltyInfo_ExactForAnyPrice`, every price and rate against the
    ///         two-term formula): OpenZeppelin's 512-bit `mulDiv` times the solver out even at
    ///         64-bit prices or fixed rates.
    /// @dev Bounds: any caller, first rate, second rate, receiver; locked in between or not.
    function check_royalty_rateRules(
        address caller,
        uint24 first,
        uint24 second,
        address receiver,
        bool lockBetween
    ) public {
        vm.prank(caller);
        (bool direct,) =
            address(stream).call(abi.encodeCall(IStream.setRoyalty, (1, receiver, first)));
        assert(direct == (caller == address(terms) && first <= Core.DENOMINATOR));
        if (direct) return;
        (bool ok,) = address(terms)
            .call(abi.encodeCall(MockTerms.setRoyalty, (address(stream), 1, receiver, first)));
        assert(ok == (first <= Core.DENOMINATOR));
        Work memory w = stream.workOf(1);
        uint24 rateNow = w.royaltyRate;
        assert(rateNow == (ok ? first : 0));
        if (lockBetween) terms.lockRoyaltyRate(address(stream), 1);
        (bool again,) = address(terms)
            .call(abi.encodeCall(MockTerms.setRoyalty, (address(stream), 1, address(0xB), second)));
        assert(again == (second <= Core.DENOMINATOR && (!lockBetween || second == rateNow)));
        w = stream.workOf(1);
        assert(w.royaltyRate == (again ? second : rateNow));
        assert(w.royaltyRateLocked == lockBetween);
    }

    /// @notice `rescue` succeeds exactly when the network calls it, the holder is a removed
    ///         minter, no outcome is recorded, and the period in force has elapsed since the
    ///         removal; a success records RESCUED and moves the token to `to`, and a refusal
    ///         moves nothing.
    /// @dev Bounds: any caller, period (48 bits), wait (up to 2^40 seconds); the sale removed or
    ///      not; an outcome recorded first or not.
    function check_rescue_predicate(
        address caller,
        uint48 delay,
        uint40 wait,
        bool removed,
        bool recorded
    ) public {
        if (recorded) sale.record(address(stream), 1, false, address(0), 0);
        if (removed) stream.removeMinter(address(sale));
        stream.setRescueDelay(delay);
        vm.warp(block.timestamp + wait);
        vm.prank(caller);
        (bool ok,) = address(stream).call(abi.encodeCall(IStream.rescue, (1, TO)));
        bool allowed = caller == address(this) && removed && !recorded && wait >= delay;
        assert(ok == allowed);
        if (ok) {
            assert(stream.ownerOf(1) == TO);
            assert(stream.workOf(1).outcome == Outcome.RESCUED);
        } else {
            assert(stream.ownerOf(1) == address(sale));
        }
    }
}

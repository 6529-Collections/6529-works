// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { StdStorage, stdStorage } from "forge-std/StdStorage.sol";
import { Vm } from "forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {
    IERC721Metadata
} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Stream6529 } from "src/core/Stream6529.sol";
import {
    Collection,
    Core,
    Minter,
    MintFacts,
    Outcome,
    Slots,
    Work
} from "src/interfaces/core/CoreTypes.sol";
import { IModuleSlots, IModules } from "src/interfaces/core/IModules.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { CoreFixture } from "../mocks/core/CoreFixture.sol";
import { MockRenderer, MockSale, MockTerms } from "../mocks/core/CoreMocks.sol";
import { MockPinnedFacts, RefusingReceiver } from "../mocks/core/StreamCoreMocks.sol";

/// @notice Unit and fuzz tests of the permanent ERC-721 (`src/core/Stream6529.sol`): every
///         function, every revert by selector, every event.
contract StreamTest is CoreFixture {
    using stdStorage for StdStorage;

    function _unauthorized(address caller) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller);
    }

    function _nonexistent(uint256 id) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id);
    }

    function _notInSale(uint256 id) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IStream.NotInPrimarySale.selector, id);
    }

    function _notTerms(address caller) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IModuleSlots.NotModule.selector, Slots.TERMS, caller);
    }

    // --------------------------------------------------------------------------- constructor

    function test_Constructor_WiringAndLaunchSettings() public view {
        assertEq(stream.name(), "6529 Stream");
        assertEq(stream.symbol(), "6529STREAM");
        assertEq(stream.facts(), address(facts));
        assertEq(stream.owner(), marketOwner);
        assertEq(stream.authority(), address(manager));
        assertEq(stream.moduleOf(Slots.RENDERER), address(renderer));
        assertEq(stream.moduleOf(Slots.TERMS), address(terms));
        assertEq(stream.moduleOf(Slots.RECORDS), address(records));
        assertTrue(stream.isMinter(address(sale)));
        Minter memory m = stream.minterOf(address(sale));
        assertEq(m.activeFrom, 1_800_000_000);
        assertEq(m.removedAt, 0);
        assertEq(stream.rescueDelay(), 14 days);
        assertEq(stream.moduleDelay(), 7 days);
        assertEq(stream.totalMinted(), 0);
        assertEq(stream.totalBurned(), 0);
        assertEq(stream.totalSupply(), 0);
        assertEq(stream.collectionCount(), 1);
        assertEq(stream.contractURI(), "");
    }

    function test_Constructor_LogsOwnerGenesisModulesAndMinters() public {
        address[] memory minters = new address[](2);
        minters[0] = address(0x111);
        minters[1] = address(0x222);
        vm.recordLogs();
        Stream6529 s = new Stream6529(
            address(manager),
            address(facts),
            marketOwner,
            address(renderer),
            address(terms),
            address(records),
            minters
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // AuthorityUpdated, the two settings' launch values (ModuleDelaySet, RescueDelaySet),
        // OwnershipTransferred, three ModuleSet, two MinterAdded.
        assertEq(logs.length, 9);
        bytes32[] memory slots = new bytes32[](3);
        uint256 nSlots;
        uint256 nMinters;
        bool ownerLogged;
        uint256 nSettings;
        for (uint256 i; i < logs.length; ++i) {
            bytes32 t = logs[i].topics[0];
            if (t == IModuleSlots.ModuleDelaySet.selector) {
                assertEq(logs[i].data, abi.encode(uint48(0), uint48(7 days)), "moduleDelay launch");
                ++nSettings;
            } else if (t == IStream.RescueDelaySet.selector) {
                assertEq(logs[i].data, abi.encode(uint48(0), uint48(14 days)), "rescueDelay launch");
                ++nSettings;
            } else if (t == IStream.OwnershipTransferred.selector) {
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(marketOwner))));
                ownerLogged = true;
            } else if (t == IModuleSlots.ModuleSet.selector) {
                slots[nSlots++] = logs[i].topics[1];
            } else if (t == IModules.MinterAdded.selector) {
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(minters[nMinters++]))));
            }
        }
        assertTrue(ownerLogged);
        assertEq(nSettings, 2, "both settings' launch values are logged");
        assertEq(slots[0], Slots.RENDERER);
        assertEq(slots[1], Slots.TERMS);
        assertEq(slots[2], Slots.RECORDS);
        assertEq(nMinters, 2);
        // Genesis minters may be predicted addresses with no code yet; active at once.
        assertTrue(s.isMinter(address(0x111)));
        assertTrue(s.isMinter(address(0x222)));
    }

    // ------------------------------------------------------------------------------ mint

    function test_Mint_EmitsTransferAndWorkMintedWithEveryFact() public {
        MintFacts memory f = _facts(1);
        f.kind = 1;
        f.seedPolicy = 2;
        f.seed = keccak256("seed");
        vm.expectEmit(address(stream));
        emit IERC721.Transfer(address(0), address(sale), 1);
        vm.expectEmit(address(stream));
        emit IStream.WorkMinted(1, 1, ARTIST, address(sale), 1, f);
        assertEq(sale.mint(address(stream), f), 1);
        Work memory w = stream.workOf(1);
        assertEq(w.itemHash, f.itemHash);
        assertEq(w.artistId, ARTIST);
        assertEq(w.collectionId, 1);
        assertEq(w.serial, 1);
        assertEq(w.kind, 1);
        assertEq(w.seedPolicy, 2);
        assertEq(uint8(w.outcome), uint8(Outcome.NONE));
        assertEq(w.royaltyReceiver, address(0xFEE));
        assertEq(w.royaltyRate, 6529);
        assertFalse(w.royaltyRateLocked);
        assertEq(w.seed, f.seed);
        assertEq(stream.itemHashOf(1), f.itemHash);
        assertEq(stream.tokenOfContent(f.contentHash), 1);
        assertEq(stream.balanceOf(address(sale)), 1);
    }

    /// @dev Whatever valid facts a minter states are stored exactly.
    function testFuzz_Mint_StoresValidFactsExactly(MintFacts memory f, address to) public {
        vm.assume(to != address(0));
        f.itemHash = f.itemHash == 0 ? bytes32(uint256(1)) : f.itemHash;
        f.contentHash = f.contentHash == 0 ? bytes32(uint256(1)) : f.contentHash;
        f.artistId = bound(f.artistId, 1, type(uint160).max);
        f.collectionId = 1;
        f.royaltyRate = uint24(bound(f.royaltyRate, 0, Core.DENOMINATOR));
        uint256 id = sale.mintTo(address(stream), to, f);
        Work memory w = stream.workOf(id);
        assertEq(stream.ownerOf(id), to);
        assertEq(w.itemHash, f.itemHash);
        assertEq(w.artistId, f.artistId);
        assertEq(w.kind, f.kind);
        assertEq(w.seedPolicy, f.seedPolicy);
        assertEq(w.seed, f.seed);
        assertEq(w.royaltyReceiver, f.royaltyReceiver);
        assertEq(w.royaltyRate, f.royaltyRate);
        assertEq(stream.tokenOfContent(f.contentHash), id);
    }

    function test_Mint_IdsAreOneSequenceAndSerialsCountPerCollection() public {
        stream.createCollection("Second", bytes32(uint256(2)));
        MintFacts memory f = _facts(10);
        f.collectionId = 2;
        assertEq(_mint(1), 1);
        assertEq(sale.mint(address(stream), f), 2);
        assertEq(_mint(2), 3);
        sale.burn(address(stream), 3);
        // A burned ID is never reused.
        assertEq(_mint(3), 4);
        assertEq(stream.workOf(1).serial, 1);
        assertEq(stream.workOf(2).serial, 1);
        assertEq(stream.workOf(3).serial, 2);
        assertEq(stream.workOf(4).serial, 3);
        assertEq(stream.collectionOf(1).minted, 3);
        assertEq(stream.collectionOf(2).minted, 1);
        assertEq(stream.totalMinted(), 4);
        assertEq(stream.totalBurned(), 1);
        assertEq(stream.totalSupply(), 3);
    }

    function test_Mint_RefusedForAnyoneButAnActiveMinter() public {
        MintFacts memory f = _facts(1);
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, address(this)));
        stream.mint(address(this), f);
        // Added, still waiting.
        MockSale next = new MockSale();
        stream.addMinter(address(next));
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, address(next)));
        next.mint(address(stream), f);
        skip(7 days);
        next.mint(address(stream), f);
        // Removed.
        stream.removeMinter(address(next));
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, address(next)));
        next.mint(address(stream), _facts(2));
    }

    function test_Mint_RefusesMalformedFacts() public {
        MintFacts memory f;
        f = _facts(1);
        f.itemHash = 0;
        vm.expectRevert(IStream.InvalidMint.selector);
        sale.mint(address(stream), f);
        f = _facts(1);
        f.contentHash = 0;
        vm.expectRevert(IStream.InvalidMint.selector);
        sale.mint(address(stream), f);
        f = _facts(1);
        f.artistId = 0;
        vm.expectRevert(IStream.InvalidMint.selector);
        sale.mint(address(stream), f);
        f = _facts(1);
        f.artistId = uint256(type(uint160).max) + 1;
        vm.expectRevert(IStream.InvalidMint.selector);
        sale.mint(address(stream), f);
        f = _facts(1);
        f.royaltyRate = uint24(Core.DENOMINATOR + 1);
        vm.expectRevert(IStream.InvalidMint.selector);
        sale.mint(address(stream), f);
        // A nonzero rate with a zero receiver would send royalties nowhere.
        f = _facts(1);
        f.royaltyReceiver = address(0);
        f.royaltyRate = 1;
        vm.expectRevert(IStream.InvalidMint.selector);
        sale.mint(address(stream), f);
        // The edges are accepted.
        f = _facts(1);
        f.artistId = type(uint160).max;
        f.royaltyRate = uint24(Core.DENOMINATOR);
        assertEq(sale.mint(address(stream), f), 1);
        assertEq(stream.workOf(1).artistId, type(uint160).max);
    }

    function testFuzz_Mint_RefusesAnArtistIdOver160Bits(uint256 artistId) public {
        artistId = bound(artistId, uint256(type(uint160).max) + 1, type(uint256).max);
        MintFacts memory f = _facts(1);
        f.artistId = artistId;
        vm.expectRevert(IStream.InvalidMint.selector);
        sale.mint(address(stream), f);
    }

    function testFuzz_Mint_RefusesARateOverTheDenominator(uint24 rate) public {
        rate = uint24(bound(rate, Core.DENOMINATOR + 1, type(uint24).max));
        MintFacts memory f = _facts(1);
        f.royaltyRate = rate;
        vm.expectRevert(IStream.InvalidMint.selector);
        sale.mint(address(stream), f);
    }

    function testFuzz_Mint_RefusesAnUnknownCollection(uint256 collectionId) public {
        vm.assume(collectionId != 1);
        MintFacts memory f = _facts(1);
        f.collectionId = collectionId;
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownCollection.selector, collectionId));
        sale.mint(address(stream), f);
    }

    function test_Mint_OneLiveTokenPerContentWhoeverMints() public {
        MockSale other = new MockSale();
        stream.addMinter(address(other));
        skip(7 days);
        uint256 id = _mint(1);
        MintFacts memory f = _facts(2);
        f.contentHash = _facts(1).contentHash;
        // Another item, another minter, the same content: refused while the token lives.
        vm.expectRevert(
            abi.encodeWithSelector(IStream.ContentAlreadyMinted.selector, f.contentHash, id)
        );
        other.mint(address(stream), f);
        // Sold and delivered: still live, still refused.
        sale.record(address(stream), id, true, collector, 1);
        sale.send(address(stream), id, collector);
        vm.expectRevert(
            abi.encodeWithSelector(IStream.ContentAlreadyMinted.selector, f.contentHash, id)
        );
        other.mint(address(stream), f);
    }

    function test_Mint_ABurnedTokensContentMintsAgain() public {
        uint256 id = _mint(1);
        sale.burn(address(stream), id);
        assertEq(stream.tokenOfContent(_facts(1).contentHash), id);
        uint256 again = _mint(1);
        assertEq(again, 2);
        assertEq(stream.tokenOfContent(_facts(1).contentHash), again);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStream.ContentAlreadyMinted.selector, _facts(1).contentHash, again
            )
        );
        _mint(1);
    }

    function test_Mint_NoReceiverCallback() public {
        RefusingReceiver refusing = new RefusingReceiver();
        uint256 id = sale.mintTo(address(stream), address(refusing), _facts(1));
        assertEq(stream.ownerOf(id), address(refusing));
    }

    function test_Mint_RefusesTheZeroAddress() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0))
        );
        sale.mintTo(address(stream), address(0), _facts(1));
    }

    function test_Mint_WritesFiveNewSlotsSixWithASeed() public {
        _mint(1); // the sale's balance slot is no longer new
        assertEq(_newSlots(_facts(2)), 5);
        MintFacts memory f = _facts(3);
        f.seed = keccak256("seed");
        assertEq(_newSlots(f), 6);
    }

    function _newSlots(MintFacts memory f) internal returns (uint256 count) {
        vm.startStateDiffRecording();
        sale.mint(address(stream), f);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        bytes32[] memory seen = new bytes32[](64);
        uint256 n;
        for (uint256 i; i < accesses.length; ++i) {
            Vm.StorageAccess[] memory s = accesses[i].storageAccesses;
            for (uint256 j; j < s.length; ++j) {
                if (
                    s[j].account != address(stream) || !s[j].isWrite || s[j].reverted
                        || s[j].previousValue != 0 || s[j].newValue == 0
                ) continue;
                bool dup;
                for (uint256 k; k < n; ++k) {
                    if (seen[k] == s[j].slot) dup = true;
                }
                if (!dup) seen[n++] = s[j].slot;
            }
        }
        return n;
    }

    // ------------------------------------------------------------------- recordPrimarySale

    function testFuzz_RecordPrimarySale_SoldLogsBuyerAndPrice(address buyer, uint256 price) public {
        uint256 id = _mint(1);
        vm.expectEmit(address(stream));
        emit IStream.PrimarySale(id, Outcome.SOLD, buyer, price);
        sale.record(address(stream), id, true, buyer, price);
        assertEq(uint8(stream.workOf(id).outcome), uint8(Outcome.SOLD));
        // The sale contract still holds it until it delivers.
        assertEq(stream.ownerOf(id), address(sale));
    }

    function testFuzz_RecordPrimarySale_UnsoldLogsZeros(address buyer, uint256 price) public {
        uint256 id = _mint(1);
        vm.expectEmit(address(stream));
        emit IStream.PrimarySale(id, Outcome.UNSOLD, address(0), 0);
        sale.record(address(stream), id, false, buyer, price);
        assertEq(uint8(stream.workOf(id).outcome), uint8(Outcome.UNSOLD));
    }

    function test_RecordPrimarySale_OnceOnly() public {
        uint256 id = _mint(1);
        sale.record(address(stream), id, false, address(0), 0);
        vm.expectRevert(_notInSale(id));
        sale.record(address(stream), id, true, collector, 1);
        vm.expectRevert(_notInSale(id));
        sale.record(address(stream), id, false, address(0), 0);
    }

    function test_RecordPrimarySale_OnlyAMinterThatHoldsTheToken() public {
        uint256 id = _mint(1);
        // Not a minter.
        vm.expectRevert(_notInSale(id));
        stream.recordPrimarySale(id, true, collector, 1);
        // A minter that does not hold it.
        MockSale other = new MockSale();
        stream.addMinter(address(other));
        skip(7 days);
        vm.expectRevert(_notInSale(id));
        other.record(address(stream), id, true, collector, 1);
        // A holder that is not a minter: the collector after delivery with no outcome.
        uint256 direct = sale.mintTo(address(stream), collector, _facts(2));
        vm.prank(collector);
        vm.expectRevert(_notInSale(direct));
        stream.recordPrimarySale(direct, true, collector, 1);
        // Unminted and burned.
        vm.expectRevert(_notInSale(99));
        sale.record(address(stream), 99, true, collector, 1);
        sale.burn(address(stream), id);
        vm.expectRevert(_notInSale(id));
        sale.record(address(stream), id, true, collector, 1);
    }

    function test_RecordPrimarySale_ARemovedMinterFinishesItsSale() public {
        uint256 id = _mint(1);
        stream.removeMinter(address(sale));
        sale.record(address(stream), id, true, collector, 1 ether);
        assertEq(uint8(stream.workOf(id).outcome), uint8(Outcome.SOLD));
    }

    /// @dev A minter added again waits out its new wait before it may act as a minter, even on
    ///      a token it already holds (the rule of `Modules`).
    function test_RecordPrimarySale_AMinterAddedAgainWaitsItsNewWait() public {
        uint256 id = _mint(1);
        stream.removeMinter(address(sale));
        stream.addMinter(address(sale));
        vm.expectRevert(_notInSale(id));
        sale.record(address(stream), id, true, collector, 1);
        vm.expectRevert(_notInSale(id));
        sale.burn(address(stream), id);
        skip(7 days);
        sale.record(address(stream), id, true, collector, 1);
    }

    /// @dev A minter removed, added again and removed once more before its new wait ended is a
    ///      removed minter that was active: it still settles the tokens it holds.
    function test_RecordPrimarySale_AMinterRemovedTwiceStillSettlesItsSales() public {
        uint256 id = _mint(1);
        uint256 second = _mint(2);
        stream.removeMinter(address(sale));
        stream.addMinter(address(sale));
        skip(1 days);
        stream.removeMinter(address(sale));
        sale.record(address(stream), id, true, collector, 1 ether);
        assertEq(uint8(stream.workOf(id).outcome), uint8(Outcome.SOLD));
        sale.burn(address(stream), second);
        assertEq(stream.totalBurned(), 1);
    }

    // ------------------------------------------------------------------------------ burn

    function test_Burn_LeavesTheRecordAndTheGap() public {
        uint256 id = _mint(1);
        vm.expectEmit(address(stream));
        emit IERC721.Transfer(address(sale), address(0), id);
        sale.burn(address(stream), id);
        assertEq(stream.totalBurned(), 1);
        assertEq(stream.totalSupply(), 0);
        assertEq(stream.totalMinted(), 1);
        assertEq(stream.balanceOf(address(sale)), 0);
        assertEq(stream.workOf(id).itemHash, _facts(1).itemHash);
        assertEq(stream.tokenOfContent(_facts(1).contentHash), id);
        vm.expectRevert(_nonexistent(id));
        stream.ownerOf(id);
        vm.expectRevert(_nonexistent(id));
        stream.itemHashOf(id);
        vm.expectRevert(_nonexistent(id));
        stream.rendererOf(id);
        vm.expectRevert(_nonexistent(id));
        stream.tokenURI(id);
    }

    function test_Burn_OnlyInSaleCustodyBeforeAnOutcome() public {
        uint256 sold = _sell(1, collector);
        // After the sale: refused, whether the minter or the collector holds it.
        vm.expectRevert(_notInSale(sold));
        sale.burn(address(stream), sold);
        vm.prank(collector);
        vm.expectRevert(_notInSale(sold));
        stream.burn(sold);
        uint256 unsold = _mint(2);
        sale.record(address(stream), unsold, false, address(0), 0);
        vm.expectRevert(_notInSale(unsold));
        sale.burn(address(stream), unsold);
        // A minter that does not hold it; a holder that is not a minter.
        uint256 held = _mint(3);
        MockSale other = new MockSale();
        stream.addMinter(address(other));
        skip(7 days);
        vm.expectRevert(_notInSale(held));
        other.burn(address(stream), held);
        uint256 direct = sale.mintTo(address(stream), collector, _facts(4));
        vm.prank(collector);
        vm.expectRevert(_notInSale(direct));
        stream.burn(direct);
        vm.expectRevert(_notInSale(77));
        sale.burn(address(stream), 77);
    }

    function test_Burn_ByARemovedMinter() public {
        uint256 id = _mint(1);
        stream.removeMinter(address(sale));
        sale.burn(address(stream), id);
        assertEq(stream.totalBurned(), 1);
    }

    // ------------------------------------------------------------------------------ rescue

    function test_Rescue_RecordsMovesAndLogsInOrder() public {
        uint256 id = _mint(1);
        stream.removeMinter(address(sale));
        skip(14 days);
        vm.expectEmit(address(stream));
        emit IStream.PrimarySale(id, Outcome.RESCUED, address(0), 0);
        vm.expectEmit(address(stream));
        emit IStream.WorkRescued(id, address(sale), marketOwner);
        vm.expectEmit(address(stream));
        emit IERC721.Transfer(address(sale), marketOwner, id);
        stream.rescue(id, marketOwner);
        assertEq(stream.ownerOf(id), marketOwner);
        assertEq(uint8(stream.workOf(id).outcome), uint8(Outcome.RESCUED));
        // Never twice; the minter cannot touch it any more.
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, id));
        stream.rescue(id, collector);
    }

    function test_Rescue_NoReceiverCallback() public {
        uint256 id = _mint(1);
        stream.removeMinter(address(sale));
        skip(14 days);
        RefusingReceiver refusing = new RefusingReceiver();
        stream.rescue(id, address(refusing));
        assertEq(stream.ownerOf(id), address(refusing));
    }

    function test_Rescue_Refusals() public {
        uint256 id = _mint(1);
        stream.removeMinter(address(sale));
        skip(14 days);
        vm.expectRevert(_nonexistent(99));
        stream.rescue(99, marketOwner);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0))
        );
        stream.rescue(id, address(0));
    }

    /// @dev A token held by an account that was never a minter is never rescuable, whatever the
    ///      outcome and the time.
    function testFuzz_Rescue_NeverReachesANonMinterHolder(uint256 wait) public {
        wait = bound(wait, 0, 3650 days);
        uint256 direct = sale.mintTo(address(stream), collector, _facts(1));
        stream.removeMinter(address(sale));
        skip(wait);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, direct));
        stream.rescue(direct, marketOwner);
        assertEq(stream.ownerOf(direct), collector);
    }

    function test_Rescue_AddingTheMinterAgainClearsItsRemoval() public {
        uint256 id = _mint(1);
        stream.removeMinter(address(sale));
        skip(14 days);
        stream.addMinter(address(sale));
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, id));
        stream.rescue(id, marketOwner);
        skip(365 days);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, id));
        stream.rescue(id, marketOwner);
        // Removed again: the wait counts from the new removal.
        stream.removeMinter(address(sale));
        skip(14 days - 1);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, id));
        stream.rescue(id, marketOwner);
        skip(1);
        stream.rescue(id, marketOwner);
    }

    /// @dev For every caller and every period and time: only the network, and only once the
    ///      period in force has elapsed since the removal. The boundary second is allowed.
    function testFuzz_Rescue_PeriodInForceAndCaller(address caller, uint48 delay, uint256 wait)
        public
    {
        delay = uint48(bound(delay, 0, 3650 days));
        wait = bound(wait, 0, 3650 days);
        uint256 id = _mint(1);
        stream.setRescueDelay(delay);
        stream.removeMinter(address(sale));
        skip(wait);
        if (caller != address(this)) {
            vm.prank(caller);
            vm.expectRevert(_unauthorized(caller));
            stream.rescue(id, marketOwner);
        }
        if (wait < delay) {
            vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, id));
            stream.rescue(id, marketOwner);
            assertEq(stream.ownerOf(id), address(sale));
        } else {
            stream.rescue(id, marketOwner);
            assertEq(stream.ownerOf(id), marketOwner);
        }
    }

    /// @dev The period is read when the rescue is attempted: a change after the removal applies,
    ///      longer or shorter.
    function testFuzz_Rescue_AChangeAfterTheRemovalDecides(uint48 later, uint256 wait) public {
        later = uint48(bound(later, 1, 3650 days));
        wait = bound(wait, 0, later - 1);
        uint256 id = _mint(1);
        stream.removeMinter(address(sale));
        skip(14 days);
        stream.setRescueDelay(later);
        if (later > 14 days) {
            vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, id));
            stream.rescue(id, marketOwner);
        }
        // Back to a shorter one below what has passed: allowed at once.
        stream.setRescueDelay(uint48(bound(wait, 0, 14 days)));
        stream.rescue(id, marketOwner);
        assertEq(stream.ownerOf(id), marketOwner);
    }

    function testFuzz_SetRescueDelay_OnlyTheNetworkEventCarriesOldAndNew(
        address caller,
        uint48 first,
        uint48 second
    ) public {
        vm.assume(caller != address(this));
        vm.prank(caller);
        vm.expectRevert(_unauthorized(caller));
        stream.setRescueDelay(first);
        vm.expectEmit(address(stream));
        emit IStream.RescueDelaySet(14 days, first);
        stream.setRescueDelay(first);
        vm.expectEmit(address(stream));
        emit IStream.RescueDelaySet(first, second);
        stream.setRescueDelay(second);
        assertEq(stream.rescueDelay(), second);
    }

    function test_SetRescueDelay_ZeroAllowsARescueAtTheRemoval() public {
        uint256 id = _mint(1);
        stream.setRescueDelay(0);
        stream.removeMinter(address(sale));
        stream.rescue(id, marketOwner);
        assertEq(stream.ownerOf(id), marketOwner);
    }

    // ----------------------------------------------------------------------- admin functions

    function test_CreateCollection_IdsFromOneEventAndRecord() public {
        vm.expectEmit(address(stream));
        emit IStream.CollectionCreated(2, "Second", bytes32(uint256(7)));
        assertEq(stream.createCollection("Second", bytes32(uint256(7))), 2);
        Collection memory c = stream.collectionOf(2);
        assertTrue(c.exists);
        assertEq(c.minted, 0);
        assertEq(c.metadataHash, bytes32(uint256(7)));
        assertEq(c.name, "Second");
        assertEq(stream.collectionCount(), 2);
        assertFalse(stream.collectionOf(3).exists);
        assertFalse(stream.collectionOf(0).exists);
    }

    function testFuzz_AdminFunctions_OnlyTheNetwork(address caller) public {
        vm.assume(caller != address(this));
        vm.startPrank(caller);
        vm.expectRevert(_unauthorized(caller));
        stream.createCollection("x", 0);
        vm.expectRevert(_unauthorized(caller));
        stream.setOwner(caller);
        vm.expectRevert(_unauthorized(caller));
        stream.setContractURI("x");
        vm.expectRevert(_unauthorized(caller));
        stream.setRescueDelay(0);
        vm.expectRevert(_unauthorized(caller));
        stream.setModuleDelay(0);
        vm.expectRevert(_unauthorized(caller));
        stream.proposeModule(Slots.TERMS, address(terms));
        vm.expectRevert(_unauthorized(caller));
        stream.removeModule(Slots.TERMS);
        vm.expectRevert(_unauthorized(caller));
        stream.addMinter(address(terms));
        vm.expectRevert(_unauthorized(caller));
        stream.removeMinter(address(sale));
        vm.stopPrank();
    }

    function test_SetOwner_EventAndValue() public {
        vm.expectEmit(address(stream));
        emit IStream.OwnershipTransferred(marketOwner, collector);
        stream.setOwner(collector);
        assertEq(stream.owner(), collector);
    }

    function test_Mint_AZeroReceiverWithAZeroRateIsAccepted() public {
        MintFacts memory f = _facts(1);
        f.royaltyReceiver = address(0);
        f.royaltyRate = 0;
        uint256 id = sale.mint(address(stream), f);
        (address r, uint256 amount) = stream.royaltyInfo(id, 1 ether);
        assertEq(r, address(0));
        assertEq(amount, 0);
    }

    function test_SetContractURI_EventAndValue() public {
        vm.expectEmit(address(stream));
        emit IStream.ContractURISet("ipfs://contract");
        vm.expectEmit(address(stream));
        emit IStream.ContractURIUpdated();
        stream.setContractURI("ipfs://contract");
        assertEq(stream.contractURI(), "ipfs://contract");
    }

    // -------------------------------------------------------------------------- terms module

    function testFuzz_SetRoyalty_TermsOnly(address caller, address receiver, uint24 rate) public {
        vm.assume(caller != address(terms));
        rate = uint24(bound(rate, 0, Core.DENOMINATOR));
        // A nonzero rate needs a receiver (`InvalidRoyalty`, pinned in the refusals test).
        if (receiver == address(0)) rate = 0;
        uint256 id = _sell(1, collector);
        vm.prank(caller);
        vm.expectRevert(_notTerms(caller));
        stream.setRoyalty(id, receiver, rate);
        vm.prank(caller);
        vm.expectRevert(_notTerms(caller));
        stream.lockRoyaltyRate(id);
        vm.expectEmit(address(stream));
        emit IStream.RoyaltySet(id, receiver, rate);
        terms.setRoyalty(address(stream), id, receiver, rate);
        (address r, uint256 amount) = stream.royaltyInfo(id, 1e18);
        assertEq(r, receiver);
        assertEq(amount, 1e18 * uint256(rate) / Core.DENOMINATOR);
    }

    function test_SetRoyalty_Refusals() public {
        uint256 id = _mint(1);
        vm.expectRevert(IStream.InvalidRoyalty.selector);
        terms.setRoyalty(address(stream), id, address(1), uint24(Core.DENOMINATOR + 1));
        vm.expectRevert(IStream.InvalidRoyalty.selector);
        terms.setRoyalty(address(stream), id, address(0), 1);
        terms.setRoyalty(address(stream), id, address(0), 0);
        vm.expectRevert(_nonexistent(9));
        terms.setRoyalty(address(stream), 9, address(1), 1);
        vm.expectRevert(_nonexistent(9));
        terms.lockRoyaltyRate(address(stream), 9);
        sale.burn(address(stream), id);
        vm.expectRevert(_nonexistent(id));
        terms.setRoyalty(address(stream), id, address(1), 1);
        // With the slot empty nobody may.
        uint256 live = _mint(2);
        stream.removeModule(Slots.TERMS);
        vm.expectRevert(_notTerms(address(terms)));
        terms.setRoyalty(address(stream), live, address(1), 1);
        vm.expectRevert(_notTerms(address(terms)));
        terms.lockRoyaltyRate(address(stream), live);
    }

    function test_SetRoyalty_AcceptsARateOfExactlyTheDenominator() public {
        uint256 id = _mint(1);
        vm.expectEmit(address(stream));
        emit IStream.RoyaltySet(id, address(1), uint24(Core.DENOMINATOR));
        terms.setRoyalty(address(stream), id, address(1), uint24(Core.DENOMINATOR));
        (address receiver, uint256 amount) = stream.royaltyInfo(id, 7 ether);
        assertEq(receiver, address(1));
        assertEq(amount, 7 ether);
    }

    /// Only equal IDs are one update: a range is logged as given, descending included.
    function test_EmitMetadataUpdate_ADescendingRangeIsLoggedAsARange() public {
        vm.expectEmit(address(stream));
        emit IERC4906.BatchMetadataUpdate(9, 1);
        terms.refresh(address(stream), 9, 1);
    }

    function testFuzz_LockRoyaltyRate_TheRateNeverChangesTheReceiverStillCan(
        uint24 other,
        address receiver
    ) public {
        // A zero receiver with a rate is refused whether or not the rate is locked.
        vm.assume(receiver != address(0));
        uint256 id = _sell(1, collector);
        vm.expectEmit(address(stream));
        emit IStream.RoyaltyRateLocked(id);
        terms.lockRoyaltyRate(address(stream), id);
        assertTrue(stream.workOf(id).royaltyRateLocked);
        if (other != 6529) {
            vm.expectRevert(IStream.InvalidRoyalty.selector);
            terms.setRoyalty(address(stream), id, receiver, other);
        }
        terms.setRoyalty(address(stream), id, receiver, 6529);
        assertEq(stream.workOf(id).royaltyReceiver, receiver);
        assertEq(stream.workOf(id).royaltyRate, 6529);
        // Locking again changes nothing.
        terms.lockRoyaltyRate(address(stream), id);
        assertTrue(stream.workOf(id).royaltyRateLocked);
    }

    function test_EmitMetadataUpdate_FactsRecordsAndTermsOnly() public {
        vm.expectEmit(address(stream));
        emit IERC4906.MetadataUpdate(3);
        terms.refresh(address(stream), 3, 3);
        vm.expectEmit(address(stream));
        emit IERC4906.BatchMetadataUpdate(1, 9);
        vm.prank(address(records));
        stream.emitMetadataUpdate(1, 9);
        vm.expectEmit(address(stream));
        emit IERC4906.MetadataUpdate(5);
        vm.prank(address(facts));
        stream.emitMetadataUpdate(5, 5);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotMetadataSource.selector, collector));
        vm.prank(collector);
        stream.emitMetadataUpdate(1, 1);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotMetadataSource.selector, address(sale)));
        vm.prank(address(sale));
        stream.emitMetadataUpdate(1, 1);
        // A removed module may no longer.
        stream.removeModule(Slots.TERMS);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotMetadataSource.selector, address(terms)));
        terms.refresh(address(stream), 1, 1);
    }

    // ------------------------------------------------------------------------------ views

    function test_WorkOf_UnmintedIsEmptyItemHashOfReverts() public {
        Work memory w = stream.workOf(5);
        assertEq(w.itemHash, 0);
        assertEq(w.artistId, 0);
        vm.expectRevert(_nonexistent(5));
        stream.itemHashOf(5);
    }

    /// @dev Exact for any price: equal to the full-precision floor, and to the old two-term
    ///      formula, which never overflows.
    function testFuzz_RoyaltyInfo_ExactForAnyPrice(uint256 price, uint24 rate) public {
        rate = uint24(bound(rate, 0, Core.DENOMINATOR));
        MintFacts memory f = _facts(1);
        f.royaltyRate = rate;
        uint256 id = sale.mint(address(stream), f);
        (address receiver, uint256 amount) = stream.royaltyInfo(id, price);
        assertEq(receiver, address(0xFEE));
        uint256 expected = (price / Core.DENOMINATOR) * rate + ((price % Core.DENOMINATOR) * rate)
            / Core.DENOMINATOR;
        assertEq(amount, expected);
        if (price < 2 ** 200) assertEq(amount, price * rate / Core.DENOMINATOR);
        assertLe(amount, price);
    }

    function test_RoyaltyInfo_EdgesAndUnminted() public {
        MintFacts memory f = _facts(1);
        f.royaltyRate = uint24(Core.DENOMINATOR);
        uint256 id = sale.mint(address(stream), f);
        (, uint256 all) = stream.royaltyInfo(id, type(uint256).max);
        assertEq(all, type(uint256).max);
        (address none, uint256 zero) = stream.royaltyInfo(42, 1 ether);
        assertEq(none, address(0));
        assertEq(zero, 0);
        // A burned token answers its last values.
        sale.burn(address(stream), id);
        (address last, uint256 still) = stream.royaltyInfo(id, 100);
        assertEq(last, address(0xFEE));
        assertEq(still, 100);
    }

    /// @dev `royaltyInfo` reads only storage: it answers with every module removed.
    function test_RoyaltyInfo_NeedsNoModule() public {
        uint256 id = _sell(1, collector);
        stream.removeModule(Slots.TERMS);
        stream.removeModule(Slots.RENDERER);
        stream.removeModule(Slots.RECORDS);
        (address receiver, uint256 amount) = stream.royaltyInfo(id, 100_000);
        assertEq(receiver, address(0xFEE));
        assertEq(amount, 6529);
    }

    function test_RendererOf_PinnedThenModuleThenNone() public {
        MockPinnedFacts pinned = new MockPinnedFacts();
        Stream6529 s = _streamWithFacts(address(pinned));
        uint256 id = sale.mint(address(s), _facts(1));
        assertEq(s.rendererOf(id), address(renderer));
        assertEq(s.tokenURI(id), "data:,mock");
        MockRenderer pin = new MockRenderer();
        pinned.pin(address(s), id, address(pin));
        assertEq(s.rendererOf(id), address(pin));
        // A pinned renderer is used even with the module removed; the facts contract's revert
        // (code changed) is never replaced by the module.
        s.removeModule(Slots.RENDERER);
        assertEq(s.rendererOf(id), address(pin));
        pinned.setFails(true);
        vm.expectRevert(MockPinnedFacts.PinnedCodeChanged.selector);
        s.rendererOf(id);
        vm.expectRevert(MockPinnedFacts.PinnedCodeChanged.selector);
        s.tokenURI(id);
        pinned.setFails(false);
        pinned.pin(address(s), id, address(0));
        assertEq(s.rendererOf(id), address(0));
        vm.expectRevert();
        s.tokenURI(id);
        // Transfers and royalties do not care.
        assertEq(s.ownerOf(id), address(sale));
    }

    function test_TokenURI_UsesTheRealFactsForAnUnfinalizedWork() public {
        uint256 id = _mint(1);
        assertEq(stream.rendererOf(id), address(renderer));
        assertEq(stream.tokenURI(id), "data:,mock");
        vm.expectRevert(_nonexistent(2));
        stream.tokenURI(2);
    }

    function _streamWithFacts(address factsAddress) internal returns (Stream6529 s) {
        address[] memory minters = new address[](1);
        minters[0] = address(sale);
        s = new Stream6529(
            address(manager),
            factsAddress,
            marketOwner,
            address(renderer),
            address(terms),
            address(records),
            minters
        );
        s.createCollection("Genesis", 0);
    }

    function test_SupportsInterface() public view {
        assertTrue(stream.supportsInterface(type(IERC165).interfaceId));
        assertTrue(stream.supportsInterface(type(IERC721).interfaceId));
        assertTrue(stream.supportsInterface(type(IERC721Metadata).interfaceId));
        assertTrue(stream.supportsInterface(type(IERC2981).interfaceId));
        assertTrue(stream.supportsInterface(bytes4(0x49064906)));
        assertTrue(stream.supportsInterface(type(IStream).interfaceId));
        assertTrue(stream.supportsInterface(type(IModules).interfaceId));
        assertTrue(stream.supportsInterface(type(IModuleSlots).interfaceId));
        assertFalse(stream.supportsInterface(0xffffffff));
        assertFalse(stream.supportsInterface(0x00000000));
    }

    function testFuzz_SupportsInterface_NothingElse(bytes4 id) public view {
        vm.assume(
            id != type(IERC165).interfaceId && id != type(IERC721).interfaceId
                && id != type(IERC721Metadata).interfaceId && id != type(IERC2981).interfaceId
                && id != bytes4(0x49064906) && id != type(IStream).interfaceId
                && id != type(IModules).interfaceId && id != type(IModuleSlots).interfaceId
        );
        assertFalse(stream.supportsInterface(id));
    }

    // ------------------------------------------------------------------------- transfers

    /// @dev Transfers are standard and call nothing outside the token: they work with every
    ///      module and every minter removed.
    function test_Transfers_NeedNoModuleNoMinter() public {
        uint256 id = _sell(1, collector);
        stream.removeModule(Slots.TERMS);
        stream.removeModule(Slots.RENDERER);
        stream.removeModule(Slots.RECORDS);
        stream.removeMinter(address(sale));
        vm.prank(collector);
        stream.approve(address(0xA), id);
        vm.prank(address(0xA));
        stream.transferFrom(collector, address(0xB0B), id);
        vm.prank(address(0xB0B));
        stream.safeTransferFrom(address(0xB0B), collector, id);
        assertEq(stream.ownerOf(id), collector);
        assertEq(stream.balanceOf(collector), 1);
        // A transfer records nothing.
        assertEq(uint8(stream.workOf(id).outcome), uint8(Outcome.SOLD));
    }

    function test_Transfers_DoNotRecordAnOutcome() public {
        uint256 id = _mint(1);
        sale.send(address(stream), id, collector);
        assertEq(uint8(stream.workOf(id).outcome), uint8(Outcome.NONE));
    }

    /// @dev No state-changing function accepts ETH.
    function test_NonPayable() public {
        bytes[] memory calls = new bytes[](12);
        calls[0] = abi.encodeCall(IStream.mint, (address(this), _facts(1)));
        calls[1] = abi.encodeCall(IStream.recordPrimarySale, (1, true, address(1), 1));
        calls[2] = abi.encodeCall(IStream.burn, (1));
        calls[3] = abi.encodeCall(IStream.rescue, (1, address(1)));
        calls[4] = abi.encodeCall(IStream.setRescueDelay, (1));
        calls[5] = abi.encodeCall(IStream.createCollection, ("x", 0));
        calls[6] = abi.encodeCall(IStream.setOwner, (address(1)));
        calls[7] = abi.encodeCall(IStream.setContractURI, ("x"));
        calls[8] = abi.encodeCall(IStream.setRoyalty, (1, address(1), 1));
        calls[9] = abi.encodeCall(IStream.lockRoyaltyRate, (1));
        calls[10] = abi.encodeCall(IStream.emitMetadataUpdate, (1, 1));
        calls[11] = abi.encodeCall(IModules.addMinter, (address(terms)));
        vm.deal(address(this), 1 ether);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(stream).call{ value: 1 }(calls[i]);
            assertFalse(ok);
        }
        (bool sent,) = address(stream).call{ value: 1 }("");
        assertFalse(sent);
    }

    /// @dev A collection ID always fits the 32 bits a work stores: the 2^32-th is refused.
    function test_CreateCollection_IdsFitThirtyTwoBits() public {
        stdstore.target(address(stream)).sig("collectionCount()")
            .checked_write(uint256(type(uint32).max) - 1);
        assertEq(stream.createCollection("last", 0), type(uint32).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeCast.SafeCastOverflowedUintDowncast.selector, 32, uint256(type(uint32).max) + 1
            )
        );
        stream.createCollection("one too many", 0);
        MintFacts memory f = _facts(1);
        f.collectionId = type(uint32).max;
        uint256 id = sale.mint(address(stream), f);
        assertEq(stream.workOf(id).collectionId, type(uint32).max);
    }
}

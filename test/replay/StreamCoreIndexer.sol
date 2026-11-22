// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { Directory } from "src/core/Directory.sol";
import { Stream } from "src/core/Stream.sol";
import {
    Collection,
    Minter,
    MintFacts,
    Outcome,
    PendingModule,
    Slots,
    Work
} from "src/interfaces/core/CoreTypes.sol";
import { IDirectory } from "src/interfaces/core/IDirectory.sol";
import { IModuleSlots, IModules } from "src/interfaces/core/IModules.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { ReplayIndexer } from "./ReplayIndexer.sol";

/// @notice Rebuilds every getter of the permanent ERC-721 (`src/core/Stream.sol`) from its own
///         logs alone: owners, balances and approvals, each work, each collection,
///         `tokenOfContent`, the counters, the minters, the module slots and announcements, the
///         marketplace owner and the two waiting-period settings. It never calls the contract
///         while applying logs; `assertMatches` then compares every value with the live getter.
/// @dev `contractURI` is the one value no log carries (ERC-7572's `ContractURIUpdated` has no
///      argument): an indexer reads the getter when it sees the event. A `MinterRemoved` log
///      carries no time; the removal time is the block's timestamp, as a real indexer reads it.
contract StreamCoreIndexer is ReplayIndexer {
    // Rebuilt state.
    mapping(uint256 id => address) public ownerOf;
    mapping(address account => uint256) public balanceOf;
    mapping(uint256 id => address) public approved;
    mapping(address owner => mapping(address operator => bool)) public operator;
    mapping(uint256 id => Work) internal _works;
    mapping(uint256 id => Collection) internal _collections;
    mapping(bytes32 contentHash => uint256) public tokenOfContent;
    mapping(address minter => Minter) internal _minters;
    mapping(bytes32 slot => address) public moduleOf;
    mapping(bytes32 slot => PendingModule) internal _pending;
    uint256 public totalMinted;
    uint256 public totalBurned;
    uint256 public collectionCount;
    address public owner;
    address public authority;
    uint48 public rescueDelay = 14 days; // the constructor's value, which emits no log
    uint48 public moduleDelay = 7 days; // idem
    uint256 public metadataUpdates;

    // What to compare.
    address[] internal _accounts;
    mapping(address => bool) internal _knownAccount;
    bytes32[] internal _contents;
    address[] internal _minterList;
    mapping(address => bool) internal _knownMinter;
    address[2][] internal _operatorPairs;

    constructor(address stream_) ReplayIndexer(stream_) { }

    function _remember(address a) internal {
        if (a != address(0) && !_knownAccount[a]) {
            _knownAccount[a] = true;
            _accounts.push(a);
        }
    }

    function _apply(Vm.Log memory log) internal override {
        bytes32 t = log.topics[0];
        if (t == IERC721.Transfer.selector) {
            address from = _addr(log.topics[1]);
            address to = _addr(log.topics[2]);
            uint256 id = uint256(log.topics[3]);
            if (from != address(0)) --balanceOf[from];
            if (to != address(0)) ++balanceOf[to];
            else ++totalBurned;
            ownerOf[id] = to;
            delete approved[id];
            _remember(to);
        } else if (t == IERC721.Approval.selector) {
            approved[uint256(log.topics[3])] = _addr(log.topics[2]);
        } else if (t == IERC721.ApprovalForAll.selector) {
            address o = _addr(log.topics[1]);
            address op = _addr(log.topics[2]);
            operator[o][op] = abi.decode(log.data, (bool));
            _operatorPairs.push([o, op]);
        } else if (t == IStream.WorkMinted.selector) {
            uint256 id = uint256(log.topics[1]);
            (, uint32 serial, MintFacts memory f) =
                abi.decode(log.data, (address, uint32, MintFacts));
            Work storage w = _works[id];
            w.itemHash = f.itemHash;
            w.artistId = uint160(f.artistId);
            w.collectionId = uint32(f.collectionId);
            w.serial = serial;
            w.kind = f.kind;
            w.seedPolicy = f.seedPolicy;
            w.royaltyReceiver = f.royaltyReceiver;
            w.royaltyRate = f.royaltyRate;
            w.seed = f.seed;
            tokenOfContent[f.contentHash] = id;
            _contents.push(f.contentHash);
            _collections[f.collectionId].minted = serial;
            totalMinted = id;
        } else if (t == IStream.PrimarySale.selector) {
            (Outcome o,) = abi.decode(log.data, (Outcome, uint256));
            _works[uint256(log.topics[1])].outcome = o;
        } else if (t == IStream.WorkRescued.selector) {
            // The outcome comes with PrimarySale and the move with Transfer.
        } else if (t == IStream.RoyaltySet.selector) {
            (address receiver, uint24 rate) = abi.decode(log.data, (address, uint24));
            Work storage w = _works[uint256(log.topics[1])];
            (w.royaltyReceiver, w.royaltyRate) = (receiver, rate);
        } else if (t == IStream.RoyaltyRateLocked.selector) {
            _works[uint256(log.topics[1])].royaltyRateLocked = true;
        } else if (t == IStream.CollectionCreated.selector) {
            uint256 id = uint256(log.topics[1]);
            (string memory name, bytes32 metadataHash) = abi.decode(log.data, (string, bytes32));
            Collection storage c = _collections[id];
            (c.exists, c.name, c.metadataHash) = (true, name, metadataHash);
            collectionCount = id;
        } else if (t == IStream.OwnershipTransferred.selector) {
            owner = _addr(log.topics[2]);
        } else if (t == IStream.ContractURIUpdated.selector) {
            // No value in the log (ERC-7572).
        } else if (t == IStream.RescueDelaySet.selector) {
            (, rescueDelay) = abi.decode(log.data, (uint48, uint48));
        } else if (t == IModuleSlots.ModuleDelaySet.selector) {
            (, moduleDelay) = abi.decode(log.data, (uint48, uint48));
        } else if (t == IModuleSlots.ModuleProposed.selector) {
            (address module, uint48 readyAt) = abi.decode(log.data, (address, uint48));
            _pending[log.topics[1]] = PendingModule(module, readyAt);
        } else if (t == IModuleSlots.ModuleSet.selector) {
            (, address module) = abi.decode(log.data, (address, address));
            moduleOf[log.topics[1]] = module;
            delete _pending[log.topics[1]];
        } else if (t == IModules.MinterAdded.selector) {
            address m = _addr(log.topics[1]);
            _minters[m] = Minter(abi.decode(log.data, (uint48)), 0);
            if (!_knownMinter[m]) {
                _knownMinter[m] = true;
                _minterList.push(m);
            }
        } else if (t == IModules.MinterRemoved.selector) {
            _minters[_addr(log.topics[1])].removedAt = uint48(_now);
        } else if (
            t == IERC4906.MetadataUpdate.selector || t == IERC4906.BatchMetadataUpdate.selector
        ) {
            ++metadataUpdates;
        } else if (t == IAccessManaged.AuthorityUpdated.selector) {
            authority = abi.decode(log.data, (address));
        } else {
            _unknown(t);
        }
    }

    function assertMatches() external view override {
        Stream s = Stream(target);
        assertEq(s.totalMinted(), totalMinted, "totalMinted");
        assertEq(s.totalBurned(), totalBurned, "totalBurned");
        assertEq(s.totalSupply(), totalMinted - totalBurned, "totalSupply");
        assertEq(s.collectionCount(), collectionCount, "collectionCount");
        assertEq(s.owner(), owner, "owner");
        assertEq(s.authority(), authority, "authority");
        assertEq(s.rescueDelay(), rescueDelay, "rescueDelay");
        assertEq(s.moduleDelay(), moduleDelay, "moduleDelay");
        for (uint256 id = 1; id <= totalMinted + 1; ++id) {
            (bool live, bytes memory ret) = target.staticcall(abi.encodeCall(IERC721.ownerOf, (id)));
            if (ownerOf[id] == address(0)) {
                assertFalse(live, "a token the logs burned or never minted is live");
            } else {
                assertTrue(live, "a live token reverts");
                assertEq(abi.decode(ret, (address)), ownerOf[id], "ownerOf");
                assertEq(s.getApproved(id), approved[id], "getApproved");
                assertEq(s.itemHashOf(id), _works[id].itemHash, "itemHashOf");
            }
            Work memory a = s.workOf(id);
            Work memory b = _works[id];
            assertEq(a.itemHash, b.itemHash, "work itemHash");
            assertEq(a.artistId, b.artistId, "work artistId");
            assertEq(a.collectionId, b.collectionId, "work collectionId");
            assertEq(a.serial, b.serial, "work serial");
            assertEq(a.kind, b.kind, "work kind");
            assertEq(a.seedPolicy, b.seedPolicy, "work seedPolicy");
            assertEq(uint8(a.outcome), uint8(b.outcome), "work outcome");
            assertEq(a.royaltyReceiver, b.royaltyReceiver, "work royaltyReceiver");
            assertEq(a.royaltyRate, b.royaltyRate, "work royaltyRate");
            assertEq(a.royaltyRateLocked, b.royaltyRateLocked, "work royaltyRateLocked");
            assertEq(a.seed, b.seed, "work seed");
        }
        for (uint256 c; c <= collectionCount + 1; ++c) {
            Collection memory a = s.collectionOf(c);
            Collection memory b = _collections[c];
            assertEq(a.exists, b.exists, "collection exists");
            assertEq(a.minted, b.minted, "collection minted");
            assertEq(a.metadataHash, b.metadataHash, "collection metadataHash");
            assertEq(a.name, b.name, "collection name");
        }
        for (uint256 i; i < _contents.length; ++i) {
            assertEq(s.tokenOfContent(_contents[i]), tokenOfContent[_contents[i]], "content");
        }
        for (uint256 i; i < _accounts.length; ++i) {
            assertEq(s.balanceOf(_accounts[i]), balanceOf[_accounts[i]], "balanceOf");
        }
        for (uint256 i; i < _operatorPairs.length; ++i) {
            address o = _operatorPairs[i][0];
            address op = _operatorPairs[i][1];
            assertEq(s.isApprovedForAll(o, op), operator[o][op], "isApprovedForAll");
        }
        for (uint256 i; i < _minterList.length; ++i) {
            Minter memory a = s.minterOf(_minterList[i]);
            Minter memory b = _minters[_minterList[i]];
            assertEq(a.activeFrom, b.activeFrom, "minter activeFrom");
            assertEq(a.removedAt, b.removedAt, "minter removedAt");
            assertEq(s.isMinter(_minterList[i]), _isMinter(b), "isMinter");
        }
        bytes32[3] memory slots = [Slots.TERMS, Slots.RENDERER, Slots.RECORDS];
        for (uint256 i; i < 3; ++i) {
            assertEq(s.moduleOf(slots[i]), moduleOf[slots[i]], "moduleOf");
            PendingModule memory a = s.pendingModule(slots[i]);
            PendingModule memory b = _pending[slots[i]];
            assertEq(a.module, b.module, "pending module");
            assertEq(a.readyAt, b.readyAt, "pending readyAt");
        }
    }

    function _isMinter(Minter memory m) internal view returns (bool) {
        return m.activeFrom != 0 && block.timestamp >= m.activeFrom && m.removedAt == 0;
    }
}

/// @notice Rebuilds every getter of the permanent `Directory` from its own logs alone: the four
///         module slots, their announcements, `moduleDelay` and `unclaimedPeriod`.
contract CoreDirectoryIndexer is ReplayIndexer {
    mapping(bytes32 slot => address) public moduleOf;
    mapping(bytes32 slot => PendingModule) internal _pending;
    uint48 public moduleDelay = 7 days; // the constructor's value, which emits no log
    uint48 public unclaimedPeriod = 180 days; // idem
    address public authority;

    constructor(address directory_) ReplayIndexer(directory_) { }

    function _apply(Vm.Log memory log) internal override {
        bytes32 t = log.topics[0];
        if (t == IModuleSlots.ModuleSet.selector) {
            (, address module) = abi.decode(log.data, (address, address));
            moduleOf[log.topics[1]] = module;
            delete _pending[log.topics[1]];
        } else if (t == IModuleSlots.ModuleProposed.selector) {
            (address module, uint48 readyAt) = abi.decode(log.data, (address, uint48));
            _pending[log.topics[1]] = PendingModule(module, readyAt);
        } else if (t == IModuleSlots.ModuleDelaySet.selector) {
            (, moduleDelay) = abi.decode(log.data, (uint48, uint48));
        } else if (t == IDirectory.UnclaimedPeriodSet.selector) {
            (, unclaimedPeriod) = abi.decode(log.data, (uint48, uint48));
        } else if (t == IAccessManaged.AuthorityUpdated.selector) {
            authority = abi.decode(log.data, (address));
        } else {
            _unknown(t);
        }
    }

    function assertMatches() external view override {
        Directory d = Directory(target);
        assertEq(d.moduleDelay(), moduleDelay, "moduleDelay");
        assertEq(d.unclaimedPeriod(), unclaimedPeriod, "unclaimedPeriod");
        assertEq(d.authority(), authority, "authority");
        bytes32[4] memory slots =
            [Slots.ACCOUNTS, Slots.FEDERATION, Slots.FEDERATED_TERMS, Slots.FEDERATED_RECORDS];
        for (uint256 i; i < 4; ++i) {
            assertEq(d.moduleOf(slots[i]), moduleOf[slots[i]], "moduleOf");
            PendingModule memory a = d.pendingModule(slots[i]);
            PendingModule memory b = _pending[slots[i]];
            assertEq(a.module, b.module, "pending module");
            assertEq(a.readyAt, b.readyAt, "pending readyAt");
        }
    }
}

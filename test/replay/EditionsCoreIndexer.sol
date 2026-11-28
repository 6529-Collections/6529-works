// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { EditionsBase } from "src/core/EditionsBase.sol";
import { Edition, Minter, PendingModule, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IModuleSlots, IModules } from "src/interfaces/core/IModules.sol";
import { ReplayIndexer } from "./ReplayIndexer.sol";

/// @notice Rebuilds every getter of an editions contract from its own logs alone (and each
///         block's time, as any indexer reads it): every edition (minter, maximum, count, seal,
///         royalties), every balance, every operator approval, the owner, the contract URI and
///         `rebindDelay`; for 6529 Stream Editions (`modules`) also `moduleDelay`, the TERMS slot
///         and its announcement, every minter's standing and the AccessManager. An Independent
///         Stream editions contract (`modules` false) has no minters or slots of its own: those are
///         the Independent Stream module's and the directory's, and are not compared here.
/// @dev The settings' launch values are logged at construction (`RebindDelaySet`,
///      `ModuleDelaySet`), so the replay starts from zero. A `MinterRemoved` log carries no time:
///      the removal time is the block's timestamp. `URI` is declared by ERC-1155 and never
///      emitted (the URI is the renderer's): it is an unknown event here.
contract EditionsCoreIndexer is ReplayIndexer {
    bool public immutable modules;

    mapping(uint256 id => Edition) internal _editions;
    mapping(uint256 id => mapping(address account => uint256)) public balanceOf;
    mapping(bytes32 slot => address) public moduleOf;
    mapping(bytes32 slot => PendingModule) internal _pending;
    mapping(address minter => Minter) internal _minters;
    mapping(address owner => mapping(address operator => bool)) internal _operators;
    address public owner;
    address public authority;
    string public contractURI;
    uint48 public rebindDelay;
    uint48 public moduleDelay;
    uint256 public metadataUpdates;

    uint256[] internal _ids;
    mapping(uint256 => bool) internal _knownId;
    address[] internal _holders;
    mapping(address => bool) internal _knownHolder;
    address[] internal _minterList;
    mapping(address => bool) internal _knownMinter;
    address[2][] internal _operatorPairs;

    constructor(address target_, bool modules_) ReplayIndexer(target_) {
        modules = modules_;
    }

    function editionOf(uint256 id) external view returns (Edition memory) {
        return _editions[id];
    }

    function _apply(Vm.Log memory l) internal override {
        bytes32 t = l.topics[0];
        if (t == IEditions.EditionCreated.selector) {
            (uint40 max, address receiver, uint24 rate) =
                abi.decode(l.data, (uint40, address, uint24));
            uint256 id = uint256(l.topics[1]);
            assertEq(_editions[id].minter, address(0), "indexer: edition created twice");
            Edition storage e = _editions[id];
            (e.minter, e.maxSupply, e.royaltyReceiver, e.royaltyRate) =
            (_addr(l.topics[2]), max, receiver, rate);
            _knownId[id] = true;
            _ids.push(id);
        } else if (t == IEditions.EditionMinted.selector) {
            (uint256 amount,) = abi.decode(l.data, (uint256, uint256));
            _editions[uint256(l.topics[1])].minted += uint40(amount);
            // The recipient's balance is compared even if its transfer log were missing.
            _holder(_addr(l.topics[2]));
        } else if (t == IEditions.EditionSupplySealed.selector) {
            Edition storage e = _editions[uint256(l.topics[1])];
            (e.maxSupply, e.supplySealed) = (uint40(abi.decode(l.data, (uint256))), true);
        } else if (t == IEditions.EditionRebound.selector) {
            _editions[uint256(l.topics[1])].minter = _addr(l.topics[3]);
        } else if (t == IEditions.RoyaltySet.selector) {
            (address receiver, uint24 rate) = abi.decode(l.data, (address, uint24));
            Edition storage e = _editions[uint256(l.topics[1])];
            (e.royaltyReceiver, e.royaltyRate) = (receiver, rate);
        } else if (t == IERC1155.TransferSingle.selector) {
            (uint256 id, uint256 value) = abi.decode(l.data, (uint256, uint256));
            _move(_addr(l.topics[2]), _addr(l.topics[3]), id, value);
        } else if (t == IERC1155.TransferBatch.selector) {
            (uint256[] memory ids, uint256[] memory values) =
                abi.decode(l.data, (uint256[], uint256[]));
            for (uint256 j; j < ids.length; ++j) {
                _move(_addr(l.topics[2]), _addr(l.topics[3]), ids[j], values[j]);
            }
        } else if (t == IERC1155.ApprovalForAll.selector) {
            address o = _addr(l.topics[1]);
            address op = _addr(l.topics[2]);
            _operators[o][op] = abi.decode(l.data, (bool));
            _operatorPairs.push([o, op]);
        } else if (t == IEditions.OwnershipTransferred.selector) {
            owner = _addr(l.topics[2]);
        } else if (t == IEditions.ContractURISet.selector) {
            contractURI = abi.decode(l.data, (string));
        } else if (t == IEditions.ContractURIUpdated.selector) {
            // No value in the log (ERC-7572); `ContractURISet` carries it.
        } else if (t == IEditions.RebindDelaySet.selector) {
            (, rebindDelay) = abi.decode(l.data, (uint48, uint48));
        } else if (
            t == IEditions.MetadataUpdate.selector || t == IEditions.BatchMetadataUpdate.selector
        ) {
            ++metadataUpdates;
        } else if (modules && t == IModuleSlots.ModuleDelaySet.selector) {
            (, moduleDelay) = abi.decode(l.data, (uint48, uint48));
        } else if (modules && t == IModuleSlots.ModuleProposed.selector) {
            (address module, uint48 readyAt) = abi.decode(l.data, (address, uint48));
            _pending[l.topics[1]] = PendingModule(module, readyAt);
        } else if (modules && t == IModuleSlots.ModuleSet.selector) {
            (, address module) = abi.decode(l.data, (address, address));
            moduleOf[l.topics[1]] = module;
            // An installation or a removal ends any announcement for the slot.
            delete _pending[l.topics[1]];
        } else if (modules && t == IModules.MinterAdded.selector) {
            address m = _addr(l.topics[1]);
            uint48 activeFrom = abi.decode(l.data, (uint48));
            uint48 first = _minters[m].firstActiveFrom;
            _minters[m] = Minter(activeFrom, 0, first == 0 ? activeFrom : first);
            if (!_knownMinter[m]) {
                _knownMinter[m] = true;
                _minterList.push(m);
            }
        } else if (modules && t == IModules.MinterRemoved.selector) {
            // A removal before the first activation is a cancellation: the record goes.
            Minter storage r = _minters[_addr(l.topics[1])];
            if (_now < r.firstActiveFrom) delete _minters[_addr(l.topics[1])];
            else r.removedAt = uint48(_now);
        } else if (modules && t == IAccessManaged.AuthorityUpdated.selector) {
            authority = abi.decode(l.data, (address));
        } else {
            _unknown(t);
        }
    }

    function _move(address from, address to, uint256 id, uint256 value) internal {
        if (from != address(0)) balanceOf[id][from] -= value;
        if (to != address(0)) balanceOf[id][to] += value;
        _holder(to);
    }

    function _holder(address account) internal {
        if (account != address(0) && !_knownHolder[account]) {
            _knownHolder[account] = true;
            _holders.push(account);
        }
    }

    function assertMatches() external view override {
        EditionsBase ed = EditionsBase(target);
        assertEq(ed.owner(), owner, "owner");
        assertEq(ed.contractURI(), contractURI, "contractURI");
        assertEq(ed.rebindDelay(), rebindDelay, "rebindDelay");
        for (uint256 i; i < _ids.length; ++i) {
            uint256 id = _ids[i];
            assertEq(abi.encode(ed.editionOf(id)), abi.encode(_editions[id]), "editionOf");
            // The edition after the last one the logs created is still empty.
            assertEq(abi.encode(ed.editionOf(id + 1)), abi.encode(_editions[id + 1]), "editionOf+1");
            for (uint256 a; a < _holders.length; ++a) {
                assertEq(ed.balanceOf(_holders[a], id), balanceOf[id][_holders[a]], "balanceOf");
            }
        }
        for (uint256 i; i < _operatorPairs.length; ++i) {
            address o = _operatorPairs[i][0];
            address op = _operatorPairs[i][1];
            assertEq(ed.isApprovedForAll(o, op), _operators[o][op], "isApprovedForAll");
        }
        if (!modules) return;
        IModules m = IModules(target);
        assertEq(IAccessManaged(target).authority(), authority, "authority");
        assertEq(m.moduleDelay(), moduleDelay, "moduleDelay");
        assertEq(m.moduleOf(Slots.TERMS), moduleOf[Slots.TERMS], "moduleOf TERMS");
        assertEq(
            abi.encode(m.pendingModule(Slots.TERMS)), abi.encode(_pending[Slots.TERMS]), "pending"
        );
        for (uint256 i; i < _minterList.length; ++i) {
            address minter = _minterList[i];
            Minter memory b = _minters[minter];
            assertEq(abi.encode(m.minterOf(minter)), abi.encode(b), "minterOf");
            bool active = b.activeFrom != 0 && block.timestamp >= b.activeFrom && b.removedAt == 0;
            assertEq(m.isMinter(minter), active, "isMinter");
        }
    }
}

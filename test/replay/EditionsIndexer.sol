// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { EditionTerms } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { ReplayIndexer } from "./ReplayIndexer.sol";

/// @notice Rebuilds 6529 Stream Editions from its own logs (ED-25 to ED-27, INV-ED-2,
///         INV-ED-5, INV-ED-6): every edition's terms, bound adapter, locked economics, royalty
///         rate, minted count, sealed supply and holders; the admitted adapters and the
///         marketplace fields.
/// @dev An adapter's `bindMinter` before the edition exists locks the economics silently; they
///      are logged by `EditionTermsLocked` when the edition is created, and no view shows them
///      before that, so nothing is lost to a logs-only reader.
contract EditionsIndexer is ReplayIndexer {
    struct Edition {
        bool exists;
        bytes32 contentHash;
        EditionTerms terms;
        uint64 minted;
        address minter;
        address seller;
        address feeRecipient;
        uint32 feeShare;
        address royaltyReceiver;
        uint32 royaltyRate;
        uint64 maxSupply;
        bool sealed_;
    }

    struct Minter {
        bool admitted;
        uint24 id;
    }

    uint64 private constant UNCAPPED = type(uint40).max;

    address public immutable stream;
    address public immutable ledger;
    address public authority;
    address public marketOwner;
    string public contractURI;
    address public workRecords;
    uint256[] internal _ids;
    mapping(uint256 editionId => Edition) internal _editions;
    mapping(uint256 editionId => bool) internal _knownId;
    address[] internal _adapters;
    mapping(address adapter => Minter) internal _minters;
    address[] internal _holders;
    mapping(address holder => bool) internal _isHolder;
    mapping(uint256 id => mapping(address holder => uint256)) internal _balances;
    address[] internal _opOwners;
    address[] internal _opOperators;
    mapping(address owner => mapping(address operator => bool)) internal _operators;

    constructor(address editions_, address stream_, address ledger_) ReplayIndexer(editions_) {
        stream = stream_;
        ledger = ledger_;
    }

    function _apply(Vm.Log memory log) internal override {
        bytes32 sig = log.topics[0];
        uint256 id = log.topics.length > 1 ? uint256(log.topics[1]) : 0;
        if (sig == IEditions.EditionCreated.selector) {
            Edition storage e = _edition(id);
            e.exists = true;
            e.contentHash = log.topics[2];
            EditionTerms memory t = abi.decode(log.data, (EditionTerms));
            if (t.saleKind == 0) t.saleKind = SaleKind.UNIFORM_AUCTION;
            e.terms = t;
            if (!e.sealed_) e.maxSupply = t.maxCount == 0 ? UNCAPPED : t.maxCount;
        } else if (sig == IEditions.EditionTermsLocked.selector) {
            Edition storage e = _editions[id];
            (e.seller, e.royaltyReceiver, e.royaltyRate, e.feeRecipient, e.feeShare) =
                abi.decode(log.data, (address, address, uint32, address, uint32));
        } else if (sig == IEditions.EditionMinterBound.selector) {
            Edition storage e = _edition(id);
            assertEq(e.minter, address(0), "indexer: edition bound twice");
            e.minter = _addr(log.topics[2]);
        } else if (sig == IEditions.EditionPrimaryMint.selector) {
            (uint256 amount,,) = abi.decode(log.data, (uint256, address, uint256));
            Edition storage e = _editions[id];
            e.minted += uint64(amount);
            assertLe(e.minted, e.maxSupply, "indexer: minted past the supply");
        } else if (sig == IEditions.EditionSupplySealed.selector) {
            Edition storage e = _edition(id);
            assertFalse(e.sealed_, "indexer: sealed twice");
            e.sealed_ = true;
            e.maxSupply = uint64(abi.decode(log.data, (uint256)));
        } else if (sig == IEditions.RoyaltyRateChanged.selector) {
            (uint32 previous, uint32 next) = abi.decode(log.data, (uint32, uint32));
            assertEq(previous, _editions[id].royaltyRate, "indexer: previous rate");
            _editions[id].royaltyRate = next;
        } else if (sig == IEditions.EditionFeeShareLowered.selector) {
            Edition storage e = _editions[id];
            (uint32 previous, uint32 share) = abi.decode(log.data, (uint32, uint32));
            assertEq(previous, e.feeShare, "indexer: previous fee share");
            e.feeShare = share;
            e.royaltyReceiver = _royaltyReceiver(ledger, e.seller, e.feeRecipient, share);
        } else if (sig == IERC1155.TransferSingle.selector) {
            (uint256 tokenId, uint256 value) = abi.decode(log.data, (uint256, uint256));
            _move(_addr(log.topics[2]), _addr(log.topics[3]), tokenId, value);
        } else if (sig == IERC1155.TransferBatch.selector) {
            (uint256[] memory ids, uint256[] memory values) =
                abi.decode(log.data, (uint256[], uint256[]));
            for (uint256 i; i < ids.length; ++i) {
                _move(_addr(log.topics[2]), _addr(log.topics[3]), ids[i], values[i]);
            }
        } else if (sig == IERC1155.ApprovalForAll.selector) {
            address owner = _addr(log.topics[1]);
            address operator = _addr(log.topics[2]);
            _opOwners.push(owner);
            _opOperators.push(operator);
            _operators[owner][operator] = abi.decode(log.data, (bool));
        } else if (sig == IMintTarget.AdmittedMinterSet.selector) {
            address adapter = _addr(log.topics[1]);
            if (_minters[adapter].id == 0) _adapters.push(adapter);
            _minters[adapter].id = uint24(uint256(log.topics[2]));
            (_minters[adapter].admitted,) = abi.decode(log.data, (bool, bytes32));
        } else if (sig == IEditions.Bound.selector) {
            require(log.topics[1] == bytes32("WORK_RECORDS"), "indexer: unknown binding");
            workRecords = abi.decode(log.data, (address));
        } else if (sig == IEditions.OwnershipTransferred.selector) {
            marketOwner = _addr(log.topics[2]);
        } else if (sig == IEditions.ContractURISet.selector) {
            (, contractURI) = abi.decode(log.data, (string, string));
        } else if (sig == IAccessManaged.AuthorityUpdated.selector) {
            authority = abi.decode(log.data, (address));
        } else if (sig == IERC4906.BatchMetadataUpdate.selector) {
            (uint256 from, uint256 to) = abi.decode(log.data, (uint256, uint256));
            assertEq(from, 0, "indexer: batch refresh from 0");
            assertEq(to, type(uint256).max, "indexer: batch refresh to max");
        } else if (sig == IERC4906.MetadataUpdate.selector) {
            assertTrue(
                _editions[abi.decode(log.data, (uint256))].exists, "indexer: refresh of none"
            );
        } else if (sig != IEditions.ContractURIUpdated.selector) {
            _unknown(sig);
        }
    }

    function _edition(uint256 id) private returns (Edition storage) {
        if (!_knownId[id]) {
            _knownId[id] = true;
            _ids.push(id);
        }
        return _editions[id];
    }

    function _move(address from, address to, uint256 id, uint256 value) private {
        if (from != address(0)) _balances[id][from] -= value;
        if (to == address(0)) return;
        if (!_isHolder[to]) {
            _isHolder[to] = true;
            _holders.push(to);
        }
        _balances[id][to] += value;
    }

    function assertMatches() external view override {
        IEditions ed = IEditions(target);
        assertEq(IAccessManaged(target).authority(), authority, "authority");
        assertEq(ed.owner(), marketOwner, "owner");
        assertEq(ed.contractURI(), contractURI, "contractURI");
        assertEq(ed.workRecords(), workRecords, "workRecords");
        for (uint256 i; i < _adapters.length; ++i) {
            assertEq(ed.isAdmittedMinter(_adapters[i]), _minters[_adapters[i]].admitted, "admitted");
        }
        for (uint256 i; i < _ids.length; ++i) {
            uint256 id = _ids[i];
            Edition storage e = _editions[id];
            assertEq(ed.exists(id), e.exists, "exists");
            if (!e.exists) continue;
            _checkEdition(ed, id, e);
            for (uint256 h; h < _holders.length; ++h) {
                assertEq(
                    IERC1155(target).balanceOf(_holders[h], id),
                    _balances[id][_holders[h]],
                    "balanceOf"
                );
            }
        }
        for (uint256 i; i < _opOwners.length; ++i) {
            assertEq(
                IERC1155(target).isApprovedForAll(_opOwners[i], _opOperators[i]),
                _operators[_opOwners[i]][_opOperators[i]],
                "isApprovedForAll"
            );
        }
    }

    function _checkEdition(IEditions ed, uint256 id, Edition storage e) private view {
        IEditions.Edition memory live = ed.edition(id);
        assertEq(live.contentHash, e.contentHash, "contentHash");
        assertEq(live.terms.maxCount, e.terms.maxCount, "terms maxCount");
        assertEq(live.terms.currency, e.terms.currency, "terms currency");
        assertEq(live.terms.saleKind, e.terms.saleKind, "terms saleKind");
        assertEq(live.terms.params, e.terms.params, "terms params");
        assertEq(live.minted, e.minted, "minted");
        assertEq(live.minter, e.minter, "minter");
        assertEq(live.seller, e.seller, "seller");
        assertEq(live.feeRecipient, e.feeRecipient, "feeRecipient");
        assertEq(live.feeShare, e.feeShare, "feeShare");
        assertEq(live.royaltyReceiver, e.royaltyReceiver, "royaltyReceiver");
        assertEq(live.royaltyRate, e.royaltyRate, "royaltyRate");
        assertEq(live.maxSupply, e.maxSupply, "maxSupply");
        assertEq(live.supplySealed, e.sealed_, "supplySealed");
        assertEq(ed.contentHashOf(id), e.contentHash, "contentHashOf");
        (address master, uint256 workId, bytes32 content) = ed.masterOf(id);
        assertEq(master, stream, "masterOf stream");
        assertEq(workId, id, "masterOf workId");
        assertEq(content, e.contentHash, "masterOf contentHash");
        (address receiver, uint256 amount) = ed.royaltyInfo(id, 1 ether);
        assertEq(receiver, e.royaltyReceiver, "royaltyInfo receiver");
        assertEq(amount, uint256(1 ether) * e.royaltyRate / 100_000, "royaltyInfo amount");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { FederationRegistry } from "src/federated/FederationRegistry.sol";
import { Accounts } from "src/identity/Accounts.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import {
    Collection,
    MintFacts,
    Outcome,
    PendingModule,
    Slots,
    Work
} from "src/interfaces/core/CoreTypes.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { IModuleSlots } from "src/interfaces/core/IModules.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { ArtistIdentity, ChangeKind, PendingChange } from "src/interfaces/types/IdentityTypes.sol";
import { ReplayIndexer } from "./ReplayIndexer.sol";

/// @notice Rebuilds the federation module (`FederationRegistry`) from its own logs: template
///         versions, listings (artist, form, deployer, share, both partners), statuses, account
///         delistings, sale contracts, item approvals and mints, content releases, barred items
///         and the entropy module; then recomputes `entry`, `isActive` and `canMint`.
/// @dev Scope: a module with no predecessor (what it inherits from one is the predecessor's).
contract FederationRegistryIndexer is ReplayIndexer {
    struct ItemKey {
        address token;
        bytes32 itemHash;
    }

    struct ReleaseKey {
        address token;
        bytes32 contentHash;
    }

    address[] internal _deployers;
    mapping(address => IFederationRegistry.Template) internal _templates;
    address[] internal _tokens;
    mapping(address => IFederationRegistry.Listing) internal _listings;
    uint256[] internal _accounts;
    mapping(uint256 => bool) internal _accountSeen;
    mapping(uint256 => bool) internal _delisted;
    address[] internal _minters;
    mapping(address => IFederationRegistry.SaleContract) internal _sale;
    mapping(address => bool) internal _minterSeen;
    ItemKey[] internal _itemKeys;
    mapping(address => mapping(bytes32 => IFederationRegistry.Item)) internal _items;
    mapping(address => mapping(bytes32 => bool)) internal _itemSeen;
    ReleaseKey[] internal _releaseKeys;
    mapping(address => mapping(bytes32 => IFederationRegistry.Release)) internal _releases;
    bytes32[] internal _barred;
    mapping(bytes32 => bool) internal _isBarred;
    address public entropyModule;
    /// @notice Extra addresses `assertMatches` probes with `canMint`.
    address[] public probes;

    constructor(address registry_) ReplayIndexer(registry_) { }

    function addProbe(address minter) external {
        probes.push(minter);
    }

    function _apply(Vm.Log memory log) internal override {
        bytes32 sig = log.topics[0];
        if (sig == IFederationRegistry.TemplateSet.selector) {
            address deployer = _addr(log.topics[1]);
            (
                ,
                uint32 version,
                IFederationRegistry.Form form,
                IFederationRegistry.TemplateStatus s
            ) = abi.decode(
                log.data,
                (bytes32, uint32, IFederationRegistry.Form, IFederationRegistry.TemplateStatus)
            );
            if (_templates[deployer].status == IFederationRegistry.TemplateStatus.NONE) {
                _deployers.push(deployer);
            }
            _templates[deployer] = IFederationRegistry.Template(version, form, s);
        } else if (sig == IFederationRegistry.Registered.selector) {
            address token = _addr(log.topics[1]);
            uint256 artistId = uint256(log.topics[2]);
            (address deployer, IFederationRegistry.Form form, address partner, uint32 share) =
                abi.decode(log.data, (address, IFederationRegistry.Form, address, uint32));
            assertEq(uint8(_listings[token].status), 0, "indexer: listed twice");
            _tokens.push(token);
            _listings[token] = IFederationRegistry.Listing(
                uint160(artistId), IFederationRegistry.Status.ACTIVE, form, share, deployer, partner
            );
            if (partner != address(0)) _listings[partner].partner = token;
        } else if (sig == IFederationRegistry.StatusSet.selector) {
            (, IFederationRegistry.Status status,) = abi.decode(
                log.data, (IFederationRegistry.Status, IFederationRegistry.Status, bytes32)
            );
            _listings[_addr(log.topics[1])].status = status;
        } else if (sig == IFederationRegistry.AccountDelistedSet.selector) {
            uint256 id = uint256(log.topics[1]);
            (bool delisted,) = abi.decode(log.data, (bool, bytes32));
            if (!_accountSeen[id]) {
                _accountSeen[id] = true;
                _accounts.push(id);
            }
            _delisted[id] = delisted;
        } else if (sig == IFederationRegistry.FeeShareLowered.selector) {
            (uint32 previous, uint32 share) = abi.decode(log.data, (uint32, uint32));
            address token = _addr(log.topics[1]);
            assertEq(_listings[token].feeShare, previous, "indexer: share history");
            _listings[token].feeShare = share;
        } else if (sig == IFederationRegistry.SaleContractSet.selector) {
            address minter = _addr(log.topics[1]);
            (uint48 addedAt, uint48 removedAt) = abi.decode(log.data, (uint48, uint48));
            if (!_minterSeen[minter]) {
                _minterSeen[minter] = true;
                _minters.push(minter);
            }
            _sale[minter] = IFederationRegistry.SaleContract(addedAt, removedAt);
        } else if (sig == IFederationRegistry.ItemApproval.selector) {
            address token = _addr(log.topics[1]);
            bytes32 itemHash = log.topics[2];
            (uint24 rate, bool approved) = abi.decode(log.data, (uint24, bool));
            _seeItem(token, itemHash);
            IFederationRegistry.Item storage it = _items[token][itemHash];
            (it.approved, it.royaltyRate) = (approved, rate);
        } else if (sig == IFederationRegistry.ItemMinted.selector) {
            address token = _addr(log.topics[1]);
            bytes32 itemHash = log.topics[2];
            _seeItem(token, itemHash);
            _items[token][itemHash].used = true;
        } else if (sig == IMintPolicy.ContentReleased.selector) {
            address token = _addr(log.topics[1]);
            uint256 tokenId = uint256(log.topics[2]);
            (bytes32 contentHash, uint256 beneficiary) = abi.decode(log.data, (bytes32, uint256));
            if (_releases[token][contentHash].tokenId == 0) {
                _releaseKeys.push(ReleaseKey(token, contentHash));
            }
            _releases[token][contentHash] = IFederationRegistry.Release(tokenId, beneficiary);
        } else if (sig == IFederationRegistry.ItemBarred.selector) {
            bytes32 itemHash = log.topics[1];
            if (!_isBarred[itemHash]) _barred.push(itemHash);
            _isBarred[itemHash] = true;
        } else if (sig == IFederationRegistry.EntropyModuleSet.selector) {
            (, entropyModule) = abi.decode(log.data, (address, address));
        } else if (sig == IAccessManaged.AuthorityUpdated.selector) {
            // The AccessManager pointer; not part of the federation state.
        } else {
            _unknown(sig);
        }
    }

    function _seeItem(address token, bytes32 itemHash) internal {
        if (_itemSeen[token][itemHash]) return;
        _itemSeen[token][itemHash] = true;
        _itemKeys.push(ItemKey(token, itemHash));
    }

    // --------------------------------------------------------------- derived answers

    function _listedActive(IFederationRegistry.Listing memory l) internal view returns (bool) {
        return l.status == IFederationRegistry.Status.ACTIVE && !_delisted[l.artistId];
    }

    function _mintable(IFederationRegistry.Listing memory l) internal view returns (bool) {
        return _listedActive(l)
            && _templates[l.deployer].status == IFederationRegistry.TemplateStatus.APPROVED;
    }

    function canMint(address token, address minter) public view returns (bool) {
        IFederationRegistry.SaleContract memory s = _sale[minter];
        if (s.addedAt == 0 || s.removedAt != 0) return false;
        IFederationRegistry.Listing memory l = _listings[token];
        if (!_mintable(l)) return false;
        return l.form != IFederationRegistry.Form.ERC1155 || _mintable(_listings[l.partner]);
    }

    function isActive(address token) public view returns (bool) {
        IFederationRegistry.Listing memory l = _listings[token];
        IFederationRegistry.TemplateStatus t = _templates[l.deployer].status;
        return _listedActive(l)
            && (t == IFederationRegistry.TemplateStatus.APPROVED
                || t == IFederationRegistry.TemplateStatus.SUSPENDED);
    }

    function assertMatches() external view override {
        FederationRegistry r = FederationRegistry(target);
        assertEq(r.entropyModule(), entropyModule, "entropy module");
        for (uint256 i; i < _deployers.length; ++i) {
            address d = _deployers[i];
            assertEq(abi.encode(r.templateOf(d)), abi.encode(_templates[d]), "template");
        }
        for (uint256 i; i < _accounts.length; ++i) {
            assertEq(r.isAccountDelisted(_accounts[i]), _delisted[_accounts[i]], "account");
        }
        for (uint256 i; i < _minters.length; ++i) {
            address m = _minters[i];
            assertEq(abi.encode(r.saleContractOf(m)), abi.encode(_sale[m]), "sale contract");
            assertEq(r.wasMinter(m), _sale[m].addedAt != 0, "wasMinter");
            assertEq(r.minterRemovedAt(m), _sale[m].removedAt, "removedAt");
        }
        for (uint256 i; i < _itemKeys.length; ++i) {
            ItemKey memory k = _itemKeys[i];
            assertEq(
                abi.encode(r.itemOf(k.token, k.itemHash)),
                abi.encode(_items[k.token][k.itemHash]),
                "item"
            );
        }
        for (uint256 i; i < _barred.length; ++i) {
            assertTrue(r.isBarred(_barred[i]), "barred");
        }
        for (uint256 i; i < _releaseKeys.length; ++i) {
            ReleaseKey memory k = _releaseKeys[i];
            IFederationRegistry.Release memory rel = _releases[k.token][k.contentHash];
            uint256 expected =
                IStream(k.token).tokenOfContent(k.contentHash) == rel.tokenId ? rel.beneficiary : 0;
            assertEq(r.releasedTo(k.token, k.contentHash), expected, "releasedTo");
        }
        for (uint256 i; i < _tokens.length; ++i) {
            address t = _tokens[i];
            IFederationRegistry.Listing memory l = _listings[t];
            assertEq(abi.encode(r.listingOf(t)), abi.encode(l), "listing");
            assertEq(r.feeShareOf(t), l.feeShare, "share");
            IFederationRegistry.Entry memory e = r.entry(t);
            assertEq(uint8(e.form), uint8(l.form), "entry form");
            assertEq(e.partner, l.partner, "entry partner");
            assertEq(e.artistId, l.artistId, "entry artist");
            assertEq(e.templateVersion, _templates[l.deployer].version, "entry version");
            assertEq(e.codeHash, t.codehash, "entry code");
            assertEq(e.feeShare, l.feeShare, "entry share");
            assertEq(
                uint8(e.status),
                uint8(
                    _listedActive(l)
                        ? IFederationRegistry.Status.ACTIVE
                        : IFederationRegistry.Status.DELISTED
                ),
                "entry status"
            );
            assertEq(r.isActive(t), isActive(t), "isActive");
            for (uint256 j; j < _minters.length; ++j) {
                assertEq(r.canMint(t, _minters[j]), canMint(t, _minters[j]), "canMint");
            }
            for (uint256 j; j < probes.length; ++j) {
                assertEq(r.canMint(t, probes[j]), canMint(t, probes[j]), "canMint probe");
            }
        }
    }
}

/// @notice Rebuilds every getter of one `FederatedStream` from its own logs: owners, approvals,
///         balances, works (facts, outcome, royalty), the one collection, `tokenOfContent` (a burn
///         does not clear it), the counters, `hasMinted`, the renderer slot and its announcement,
///         the two settings and the marketplace owner.
/// @dev The two settings start at the published deployment values (7 and 14 days), which the
///      constructor writes without an event. `contractURI` is not rebuilt: ERC-7572's
///      `ContractURIUpdated` carries no value.
contract FederatedStreamIndexer is ReplayIndexer {
    uint256 public totalMinted;
    uint256 public totalBurned;
    uint256 public collectionCount;
    address public owner;
    uint48 public moduleDelay = 7 days;
    uint48 public rescueDelay = 14 days;
    address public renderer;
    PendingModule internal _pending;
    mapping(uint256 => Work) internal _works;
    mapping(uint256 => address) internal _owners;
    mapping(uint256 => address) internal _approved;
    mapping(address => uint256) internal _balances;
    address[] internal _holders;
    mapping(address => bool) internal _holderSeen;
    mapping(uint256 => Collection) internal _collections;
    mapping(uint256 => bytes32) internal _content;
    mapping(bytes32 => uint256) internal _tokenOfContent;
    address[] internal _minters;
    mapping(address => bool) internal _hasMinted;
    address[2][] internal _operatorPairs;
    mapping(address => mapping(address => bool)) internal _operators;
    mapping(address => mapping(address => bool)) internal _pairSeen;

    constructor(address token_) ReplayIndexer(token_) { }

    function _seeHolder(address a) internal {
        if (a == address(0) || _holderSeen[a]) return;
        _holderSeen[a] = true;
        _holders.push(a);
    }

    function _apply(Vm.Log memory log) internal override {
        bytes32 sig = log.topics[0];
        if (sig == IERC721.Transfer.selector) {
            address from = _addr(log.topics[1]);
            address to = _addr(log.topics[2]);
            uint256 id = uint256(log.topics[3]);
            if (from != address(0)) --_balances[from];
            if (to == address(0)) ++totalBurned;
            else ++_balances[to];
            _seeHolder(to);
            _owners[id] = to;
            delete _approved[id];
        } else if (sig == IERC721.Approval.selector) {
            _approved[uint256(log.topics[3])] = _addr(log.topics[2]);
        } else if (sig == IERC721.ApprovalForAll.selector) {
            address o = _addr(log.topics[1]);
            address op = _addr(log.topics[2]);
            if (!_pairSeen[o][op]) {
                _pairSeen[o][op] = true;
                _operatorPairs.push([o, op]);
            }
            _operators[o][op] = abi.decode(log.data, (bool));
        } else if (sig == IStream.WorkMinted.selector) {
            uint256 id = uint256(log.topics[1]);
            (address minter, uint32 serial, MintFacts memory f) =
                abi.decode(log.data, (address, uint32, MintFacts));
            assertEq(id, ++totalMinted, "indexer: token ID sequence");
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
            ++_collections[f.collectionId].minted;
            _content[id] = f.contentHash;
            _tokenOfContent[f.contentHash] = id;
            if (!_hasMinted[minter]) {
                _hasMinted[minter] = true;
                _minters.push(minter);
            }
        } else if (sig == IStream.PrimarySale.selector) {
            (Outcome outcome,) = abi.decode(log.data, (Outcome, uint256));
            _works[uint256(log.topics[1])].outcome = outcome;
        } else if (sig == IStream.WorkRescued.selector) {
            // The move is the Transfer; the outcome is the PrimarySale beside it.
        } else if (sig == IStream.RoyaltySet.selector) {
            (address receiver, uint24 rate) = abi.decode(log.data, (address, uint24));
            Work storage w = _works[uint256(log.topics[1])];
            (w.royaltyReceiver, w.royaltyRate) = (receiver, rate);
        } else if (sig == IStream.RoyaltyRateLocked.selector) {
            _works[uint256(log.topics[1])].royaltyRateLocked = true;
        } else if (sig == IStream.CollectionCreated.selector) {
            uint256 id = uint256(log.topics[1]);
            (string memory name, bytes32 metadataHash) = abi.decode(log.data, (string, bytes32));
            ++collectionCount;
            Collection storage c = _collections[id];
            (c.exists, c.name, c.metadataHash) = (true, name, metadataHash);
        } else if (sig == IStream.OwnershipTransferred.selector) {
            owner = _addr(log.topics[2]);
        } else if (sig == IStream.RescueDelaySet.selector) {
            (, rescueDelay) = abi.decode(log.data, (uint48, uint48));
        } else if (sig == IModuleSlots.ModuleDelaySet.selector) {
            (, moduleDelay) = abi.decode(log.data, (uint48, uint48));
        } else if (sig == IModuleSlots.ModuleProposed.selector) {
            assertEq(log.topics[1], Slots.RENDERER, "indexer: a slot not held here");
            (address module, uint48 readyAt) = abi.decode(log.data, (address, uint48));
            _pending = PendingModule(module, readyAt);
        } else if (sig == IModuleSlots.ModuleSet.selector) {
            assertEq(log.topics[1], Slots.RENDERER, "indexer: a slot not held here");
            (, renderer) = abi.decode(log.data, (address, address));
            delete _pending;
        } else if (
            sig == IStream.ContractURIUpdated.selector || sig == IStream.ContractURISet.selector
                || sig == IERC4906.MetadataUpdate.selector
                || sig == IERC4906.BatchMetadataUpdate.selector
        ) {
            // No state.
        } else {
            _unknown(sig);
        }
    }

    function hasMinted(address a) external view returns (bool) {
        return _hasMinted[a];
    }

    function assertMatches() external view override {
        FederatedStream t = FederatedStream(target);
        assertEq(t.totalMinted(), totalMinted, "totalMinted");
        assertEq(t.totalBurned(), totalBurned, "totalBurned");
        assertEq(t.totalSupply(), totalMinted - totalBurned, "supply");
        assertEq(t.collectionCount(), collectionCount, "collections");
        assertEq(t.owner(), owner, "owner");
        assertEq(t.moduleDelay(), moduleDelay, "moduleDelay");
        assertEq(t.rescueDelay(), rescueDelay, "rescueDelay");
        assertEq(t.moduleOf(Slots.RENDERER), renderer, "renderer");
        assertEq(abi.encode(t.pendingModule(Slots.RENDERER)), abi.encode(_pending), "pending");
        for (uint256 c = 1; c <= collectionCount; ++c) {
            assertEq(abi.encode(t.collectionOf(c)), abi.encode(_collections[c]), "collection");
        }
        for (uint256 id = 1; id <= totalMinted; ++id) {
            assertEq(abi.encode(t.workOf(id)), abi.encode(_works[id]), "work");
            assertEq(t.tokenOfContent(_content[id]), _tokenOfContent[_content[id]], "content");
            address o = _owners[id];
            (bool live, bytes memory ret) = target.staticcall(abi.encodeCall(IERC721.ownerOf, (id)));
            assertEq(live, o != address(0), "live");
            if (live) {
                assertEq(abi.decode(ret, (address)), o, "ownerOf");
                assertEq(t.getApproved(id), _approved[id], "approved");
            }
        }
        for (uint256 i; i < _holders.length; ++i) {
            assertEq(t.balanceOf(_holders[i]), _balances[_holders[i]], "balance");
            assertFalse(t.hasMinted(_holders[i]) && !_hasMinted[_holders[i]], "hasMinted holder");
        }
        for (uint256 i; i < _minters.length; ++i) {
            assertTrue(t.hasMinted(_minters[i]), "hasMinted");
        }
        for (uint256 i; i < _operatorPairs.length; ++i) {
            address[2] memory p = _operatorPairs[i];
            assertEq(t.isApprovedForAll(p[0], p[1]), _operators[p[0]][p[1]], "operator");
        }
    }
}

/// @notice Rebuilds the accounts module's accounts from its own logs: identities, roots ever
///         held, reservations, the pending change (contests included), nonces, freezes, the
///         package registry and the consolidation source.
contract AccountsIndexer is ReplayIndexer {
    struct Acct {
        ArtistIdentity identity;
        uint48 frozenUntil;
        uint256 nonce;
        bool replacing;
    }

    uint256[] internal _ids;
    mapping(uint256 => Acct) internal _accounts;
    mapping(uint256 => PendingChange) internal _pending;
    address[] internal _roots;
    mapping(address => uint256) internal _artistIdOf;
    mapping(address => uint256) internal _reservedFor;
    mapping(address => bool) internal _rootSeen;
    address public packageRegistry;
    address public consolidationSource;
    bytes32 public consolidationSourceCodeHash;

    constructor(address accounts_) ReplayIndexer(accounts_) { }

    function _see(address a) internal {
        if (a == address(0) || _rootSeen[a]) return;
        _rootSeen[a] = true;
        _roots.push(a);
    }

    function _clear(uint256 id) internal {
        delete _reservedFor[_pending[id].next.root];
        delete _pending[id];
        _accounts[id].replacing = false;
    }

    function _apply(Vm.Log memory log) internal override {
        bytes32 sig = log.topics[0];
        if (sig == IArtistRegistry.ArtistRegistered.selector) {
            uint256 id = uint256(log.topics[1]);
            ArtistIdentity memory identity = abi.decode(log.data, (ArtistIdentity));
            _ids.push(id);
            _accounts[id].identity = identity;
            _artistIdOf[identity.root] = id;
            _see(identity.root);
        } else if (sig == IArtistRegistry.ChangeStaged.selector) {
            uint256 id = uint256(log.topics[1]);
            PendingChange memory p = abi.decode(log.data, (PendingChange));
            Acct storage a = _accounts[id];
            ++a.nonce;
            if (p.kind == ChangeKind.REPLACEMENT) a.replacing = true;
            _pending[id] = p;
            if (p.next.root != a.identity.root) _reservedFor[p.next.root] = id;
            _see(p.next.root);
        } else if (sig == IArtistRegistry.ChangeCancelled.selector) {
            _clear(uint256(log.topics[1]));
        } else if (sig == IArtistRegistry.ChangeExecuted.selector) {
            uint256 id = uint256(log.topics[1]);
            (, ArtistIdentity memory next) = abi.decode(log.data, (ArtistIdentity, ArtistIdentity));
            Acct storage a = _accounts[id];
            _artistIdOf[next.root] = id;
            a.identity = next;
            a.replacing = false;
            delete _reservedFor[next.root];
            delete _pending[id];
        } else if (sig == IArtistRegistry.ChangeContested.selector) {
            uint256 id = uint256(log.topics[1]);
            PendingChange storage p = _pending[id];
            p.contestedAt = uint48(_now);
            p.priorOutcome = abi.decode(log.data, (bytes32));
        } else if (sig == IArtistRegistry.NonceRevoked.selector) {
            uint256 id = uint256(log.topics[1]);
            assertEq(abi.decode(log.data, (uint256)), _accounts[id].nonce, "indexer: nonce");
            ++_accounts[id].nonce;
        } else if (sig == IArtistRegistry.AccountFrozen.selector) {
            _accounts[uint256(log.topics[1])].frozenUntil = abi.decode(log.data, (uint48));
        } else if (sig == IArtistRegistry.AccountUnfrozen.selector) {
            _accounts[uint256(log.topics[1])].frozenUntil = 0;
        } else if (sig == IArtistRegistry.PackageRegistrySet.selector) {
            (, packageRegistry) = abi.decode(log.data, (address, address));
        } else if (sig == IArtistRegistry.ConsolidationSourceSet.selector) {
            (, consolidationSource, consolidationSourceCodeHash) =
                abi.decode(log.data, (address, address, bytes32));
        } else if (
            sig == IArtistRegistry.ReplacementAcceptanceConsumed.selector
                || sig == IArtistRegistry.ContestResolved.selector
                || sig == IArtistRegistry.ContestExpired.selector
                || sig == IAccessManaged.AuthorityUpdated.selector
        ) {
            // The state change is the ChangeCancelled or ChangeExecuted beside it.
        } else {
            _unknown(sig);
        }
    }

    function assertMatches() external view override {
        Accounts acc = Accounts(target);
        assertEq(acc.packageRegistry(), packageRegistry, "package registry");
        assertEq(address(acc.consolidationSource()), consolidationSource, "source");
        assertEq(acc.consolidationSourceCodeHash(), consolidationSourceCodeHash, "source hash");
        for (uint256 i; i < _ids.length; ++i) {
            uint256 id = _ids[i];
            Acct storage a = _accounts[id];
            (ArtistIdentity memory identity, uint48 frozenUntil) = acc.artist(id);
            assertEq(abi.encode(identity), abi.encode(a.identity), "identity");
            assertEq(frozenUntil, a.frozenUntil, "frozen");
            assertEq(acc.frozenUntil(id), a.frozenUntil, "frozenUntil");
            assertEq(acc.changeNonce(id), a.nonce, "nonce");
            assertEq(abi.encode(acc.pendingChange(id)), abi.encode(_pending[id]), "pending");
            assertEq(acc.authorityOf(id), a.identity.root, "authority");
        }
        for (uint256 i; i < _roots.length; ++i) {
            address r = _roots[i];
            assertEq(acc.artistIdOf(r), _artistIdOf[r], "artistIdOf");
            assertEq(acc.reservedFor(r), _reservedFor[r], "reservedFor");
        }
    }
}

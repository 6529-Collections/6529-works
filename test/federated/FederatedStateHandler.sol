// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { Test } from "forge-std/Test.sol";
import { FederatedEditions } from "src/federated/FederatedEditions.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { FederationRegistry } from "src/federated/FederationRegistry.sol";
import { IFederatedEditions } from "src/interfaces/IFederatedEditions.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { PrimaryOutcome, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";

/// @notice A sale adapter stand-in the federation registry can admit: it mints federated works
///         into its own custody, settles them (delivering a sold one to its buyer), binds,
///         mints and seals editions, exactly as told.
contract FedAdapterMock {
    bytes32 public immutable saleKind;

    constructor(bytes32 kind) {
        saleKind = kind;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(ISaleAdapter).interfaceId || id == 0x01ffc9a7;
    }

    function mint(address token, bytes calldata data) external returns (uint256 id) {
        (id,) = IMintTarget(token).mint(address(this), 0, 1, data);
    }

    function settle(address token, uint256 id, PrimaryOutcome outcome, address buyer) external {
        uint256 price = outcome == PrimaryOutcome.SOLD ? 1 ether : 0;
        IMintTarget(token).settlePrimary(id, outcome, buyer, address(0), price);
        if (outcome == PrimaryOutcome.SOLD) IERC721(token).transferFrom(address(this), buyer, id);
    }

    function bind(address editions, uint256 id, PackageItem calldata item) external {
        IFederatedEditions(editions).bindMinter(id, item);
    }

    function mintCopies(address editions, uint256 id, address to, uint256 amount) external {
        IMintTarget(editions).mint(to, id, amount, abi.encode(address(0), uint256(1 ether)));
    }

    function seal(address editions, uint256 id, uint256 count) external {
        IFederatedEditions(editions).sealSupply(id, count);
    }
}

/// @notice Drives one artist's federated pair (a `FederatedStream` and its `FederatedEditions`)
///         and a copy that never joined, on the real federation registry, through three
///         adapters (an admitted English-auction stand-in, an admitted edition-auction
///         stand-in, one never admitted): mints and restarts of approved items, settlements by
///         the minting adapter and by others, royalty changes, item approvals, edition binding,
///         creation, copies and seals, delistings and adapter removals by governance. Keeps an
///         exact model; each action predicts its outcome and a wrong prediction is counted.
contract FederatedStateHandler is Test {
    uint8 internal constant IN_SALE = 1;
    uint8 internal constant SOLD = 2;
    uint8 internal constant UNBID = 3;
    uint8 internal constant FROZEN_OUT = 4;
    uint40 internal constant UNCAPPED = type(uint40).max;

    struct Item {
        bytes data;
        bytes32 hash;
        bool master;
        uint32 maxCount;
        bool approved;
        uint32 approvedRate;
        uint256 workId;
        uint256 liveToken;
    }

    struct Edition {
        address minter;
        bool created;
        uint40 limit;
        uint40 minted;
        bool sealed_;
    }

    FederatedStream public immutable stream;
    FederatedEditions public immutable editions;
    FederatedStream public immutable neverJoined;
    FederationRegistry internal immutable registry;
    AccessManager internal immutable manager;
    address internal immutable admin;
    address public immutable artist;
    FedAdapterMock public immutable english;
    FedAdapterMock public immutable uniform;
    FedAdapterMock public immutable outsider;

    Item[] internal _items;
    address[3] public buyers =
        [makeAddr("fedBuyerA"), makeAddr("fedBuyerB"), makeAddr("fedBuyerC")];

    uint256 public tokenCount;
    uint256 public workCount;
    mapping(uint256 token => uint256) public itemOf;
    mapping(uint256 token => address) public adapterOf;
    mapping(uint256 token => uint8) public stateOf;
    mapping(uint256 token => address) public ownerOf;
    mapping(uint256 token => bool) public burned;
    mapping(uint256 workId => uint32) public rateOf;
    mapping(uint256 workId => uint256) public firstTokenOf;
    mapping(uint256 editionId => Edition) internal _editions;
    uint256[] public masterTokens;
    mapping(address token => bool) public listed;
    mapping(address adapter => bool) public admitted;

    uint256 public violations;
    uint256 public mints;
    uint256 public restarts;
    uint256 public refusedMints;
    uint256 public settlements;
    uint256 public refusedSettlements;
    uint256 public rateCuts;
    /// @notice Royalty changes that succeeded without lowering the rate.
    uint256 public rateRises;
    uint256 public copiesMinted;
    uint256 public seals;
    uint256 public delistedRefusals;

    constructor(
        FederatedStream stream_,
        FederatedEditions editions_,
        FederatedStream neverJoined_,
        FederationRegistry registry_,
        AccessManager manager_,
        address admin_,
        address artist_,
        FedAdapterMock english_,
        FedAdapterMock uniform_,
        FedAdapterMock outsider_
    ) {
        (stream, editions, neverJoined) = (stream_, editions_, neverJoined_);
        (registry, manager, admin, artist) = (registry_, manager_, admin_, artist_);
        (english, uniform, outsider) = (english_, uniform_, outsider_);
        listed[address(stream_)] = true;
        listed[address(editions_)] = true;
        admitted[address(english_)] = true;
        admitted[address(uniform_)] = true;
    }

    /// @dev A ready work (its media registered), approved by the artist at `rate`.
    function addItem(PackageItem calldata item, bytes calldata data, uint32 rate) external {
        bytes32 hash = WorksHashing.itemHash(item);
        _items.push(Item(data, hash, item.kind == 1, item.edition.maxCount, true, rate, 0, 0));
    }

    function itemCount() external view returns (uint256) {
        return _items.length;
    }

    function masterCount() external view returns (uint256) {
        return masterTokens.length;
    }

    function edition(uint256 id)
        external
        view
        returns (address minter, bool created, uint40 limit, uint40 minted, bool sealed_)
    {
        Edition storage e = _editions[id];
        return (e.minter, e.created, e.limit, e.minted, e.sealed_);
    }

    // ------------------------------------------------------------------------------- actions

    /// @dev An adapter mints an item on the pair's 1/1 contract, or (one time in eight) on the
    ///      copy that never joined. Allowed: an admitted adapter, the contract listed, the item
    ///      approved, a master's editions contract listed, and either a first mint or a restart
    ///      of an unsold work in the template's custody (a master only while its edition is
    ///      unbound).
    function mint(uint256 itemSeed, uint8 adapterSeed) external {
        uint256 i = itemSeed % _items.length;
        Item storage it = _items[i];
        FedAdapterMock adapter = _adapter(adapterSeed);
        if (adapterSeed % 8 == 7) {
            try adapter.mint(address(neverJoined), it.data) {
                ++violations;
            } catch {
                ++refusedMints;
            }
            return;
        }
        bool restart = it.workId != 0;
        bool restartable = !restart || _restartable(it);
        // A master also needs its editions contract listed (FED-13, FED-67).
        bool expected = admitted[address(adapter)] && listed[address(stream)] && it.approved
            && restartable && (!it.master || listed[address(editions)]);
        try adapter.mint(address(stream), it.data) returns (uint256 id) {
            if (!expected || id != tokenCount + 1) ++violations;
            if (restart) {
                burned[it.liveToken] = true;
                ownerOf[it.liveToken] = address(0);
                ++restarts;
            } else {
                it.workId = ++workCount;
                rateOf[it.workId] = it.approvedRate;
                firstTokenOf[it.workId] = id;
            }
            tokenCount = id;
            it.liveToken = id;
            it.approved = false;
            itemOf[id] = i;
            adapterOf[id] = address(adapter);
            stateOf[id] = IN_SALE;
            ownerOf[id] = address(adapter);
            if (it.master) masterTokens.push(id);
            ++mints;
        } catch {
            if (expected) ++violations;
            if (!listed[address(stream)] && admitted[address(adapter)] && it.approved) {
                ++delistedRefusals;
            }
            ++refusedMints;
        }
    }

    /// @dev The minting adapter or another settles a token: sold to a buyer, unbid, frozen out,
    ///      or an invalid outcome (sold to no one). Only the minting adapter, once, with a valid
    ///      outcome, succeeds.
    function settle(uint256 tokenSeed, uint8 outcomeSeed, uint8 adapterSeed) external {
        if (tokenCount == 0) return;
        uint256 id = tokenSeed % tokenCount + 1;
        FedAdapterMock adapter =
            adapterSeed % 3 == 0 ? _adapter(adapterSeed >> 2) : FedAdapterMock(adapterOf[id]);
        uint256 o = outcomeSeed % 4;
        PrimaryOutcome outcome = o == 0
            ? PrimaryOutcome.SOLD
            : o == 1
                ? PrimaryOutcome.UNBID
                : o == 2 ? PrimaryOutcome.FROZEN_OUT : PrimaryOutcome.SOLD;
        // A sale to a buyer; unbid and frozen out name none; the invalid case is a sale to no one.
        address buyer = o == 0 ? buyers[outcomeSeed % 3] : address(0);
        bool expected = address(adapter) == adapterOf[id] && stateOf[id] == IN_SALE && o != 3;
        try adapter.settle(address(stream), id, outcome, buyer) {
            if (!expected) ++violations;
            if (outcome == PrimaryOutcome.SOLD) {
                stateOf[id] = SOLD;
                ownerOf[id] = buyer;
            } else {
                stateOf[id] = outcome == PrimaryOutcome.UNBID ? UNBID : FROZEN_OUT;
                ownerOf[id] = address(stream);
            }
            ++settlements;
        } catch {
            if (expected) ++violations;
            ++refusedSettlements;
        }
    }

    /// @dev The artist (or, one time in four, a buyer) changes a live token's royalty rate: only
    ///      the artist, only lower.
    function setRoyaltyRate(uint256 tokenSeed, uint32 rate, uint8 who) external {
        if (tokenCount == 0) return;
        uint256 id = tokenSeed % tokenCount + 1;
        uint256 workId = _items[itemOf[id]].workId;
        rate = uint32(bound(rate, 0, 100_000));
        address caller = who % 4 == 0 ? buyers[0] : artist;
        bool expected = caller == artist && !burned[id] && rate < rateOf[workId];
        vm.prank(caller);
        try stream.setRoyaltyRate(id, rate) {
            if (!expected) ++violations;
            if (rate >= rateOf[workId]) ++rateRises;
            rateOf[workId] = rate;
            ++rateCuts;
        } catch {
            if (expected) ++violations;
        }
    }

    /// @dev The artist approves an item again (needed for a restart), at a new rate that only
    ///      the first mint of the item uses.
    function approve(uint256 itemSeed, uint32 rate) external {
        Item storage it = _items[itemSeed % _items.length];
        rate = uint32(bound(rate, 0, 100_000));
        vm.prank(artist);
        stream.approveItem(it.hash, rate);
        it.approved = true;
        if (it.workId == 0) it.approvedRate = rate;
    }

    /// @dev An adapter binds a live master's edition: admitted, both contracts listed, an
    ///      edition-auction adapter for a new binding, the bound one again; any other refused.
    function bind(uint256 masterSeed, uint8 adapterSeed) external {
        (bool ok, uint256 id, Item storage it) = _master(masterSeed);
        if (!ok) return;
        // Mostly the edition-auction stand-in; one time in four any adapter.
        FedAdapterMock adapter = adapterSeed % 4 == 0 ? _adapter(adapterSeed >> 2) : uniform;
        Edition storage e = _editions[id];
        bool gate =
            admitted[address(adapter)] && listed[address(editions)] && listed[address(stream)];
        bool expected = gate
            && (e.minter == address(adapter)
                || (e.minter == address(0)
                    && (e.created || adapter.saleKind() == SaleKind.UNIFORM_AUCTION)));
        try adapter.bind(address(editions), id, _item(it)) {
            if (!expected) ++violations;
            e.minter = address(adapter);
        } catch {
            if (expected) ++violations;
        }
    }

    /// @dev Anyone creates a settled master's edition (an unbound one only after a sale).
    function create(uint256 masterSeed) external {
        (bool ok, uint256 id, Item storage it) = _master(masterSeed);
        if (!ok) return;
        Edition storage e = _editions[id];
        uint8 s = stateOf[id];
        bool expected =
            !e.created && s >= SOLD && s <= FROZEN_OUT && (e.minter != address(0) || s == SOLD);
        try editions.createEdition(id, _item(it)) {
            if (!expected) ++violations;
            e.created = true;
            if (!e.sealed_) e.limit = it.maxCount == 0 ? UNCAPPED : it.maxCount;
        } catch {
            if (expected) ++violations;
        }
    }

    /// @dev An adapter mints copies to a buyer: the bound one, of a created edition, within
    ///      its maximum, while admitted and listed unless it sealed the edition.
    function mintCopies(uint256 masterSeed, uint8 adapterSeed, uint256 amount) external {
        (bool ok, uint256 id,) = _master(masterSeed);
        if (!ok) return;
        FedAdapterMock adapter = adapterSeed % 4 == 0 ? _adapter(adapterSeed >> 2) : uniform;
        Edition storage e = _editions[id];
        amount = bound(amount, 0, 40);
        bool gate =
            admitted[address(adapter)] && listed[address(editions)] && listed[address(stream)];
        bool expected = e.created && e.minter == address(adapter) && (e.sealed_ || gate)
            && amount != 0 && amount <= e.limit - e.minted;
        try adapter.mintCopies(address(editions), id, buyers[amount % 3], amount) {
            if (!expected) ++violations;
            // Safe: within the 40-bit limit.
            e.minted += uint40(amount);
            copiesMinted += amount;
        } catch {
            if (expected) ++violations;
        }
    }

    /// @dev The bound adapter (or another) seals an edition at a count between what it minted
    ///      and its maximum (zero before the edition exists), once.
    function seal(uint256 masterSeed, uint8 adapterSeed, uint256 count) external {
        (bool ok, uint256 id,) = _master(masterSeed);
        if (!ok) return;
        FedAdapterMock adapter = adapterSeed % 4 == 0 ? _adapter(adapterSeed >> 2) : uniform;
        Edition storage e = _editions[id];
        uint256 top = e.limit == UNCAPPED ? uint256(e.minted) + 50 : e.limit;
        count = bound(count, e.minted == 0 ? 0 : e.minted - 1, top + 1);
        bool expected =
            e.minter == address(adapter) && !e.sealed_ && count >= e.minted && count <= e.limit;
        try adapter.seal(address(editions), id, count) {
            if (!expected) ++violations;
            e.sealed_ = true;
            // Safe: at most the 40-bit limit.
            e.limit = uint40(count);
            ++seals;
        } catch {
            if (expected) ++violations;
        }
    }

    /// @dev The network delists or re-lists the 1/1 contract or the editions contract.
    function toggleListing(bool editionsHalf) external {
        address token = editionsHalf ? address(editions) : address(stream);
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        IFederationRegistry.Status next =
            listed[token] ? IFederationRegistry.Status.DELISTED : IFederationRegistry.Status.ACTIVE;
        _govern(abi.encodeCall(registry.setStatus, (tokens, next, bytes32("vote"))));
        listed[token] = !listed[token];
    }

    /// @dev Governance removes or re-admits one of the two admitted adapters.
    function toggleAdapter(bool uniformOne) external {
        address adapter = uniformOne ? address(uniform) : address(english);
        _govern(abi.encodeCall(registry.setAdapter, (adapter, !admitted[adapter])));
        admitted[adapter] = !admitted[adapter];
    }

    // ------------------------------------------------------------------------------ helpers

    function _adapter(uint256 seed) internal view returns (FedAdapterMock) {
        uint256 k = seed % 4;
        return k == 0 ? uniform : k == 3 ? outsider : english;
    }

    function _restartable(Item storage it) internal view returns (bool) {
        uint256 old = it.liveToken;
        if (burned[old] || ownerOf[old] != address(stream)) return false;
        if (stateOf[old] < UNBID) return false;
        if (!it.master) return true;
        Edition storage e = _editions[old];
        return e.minter == address(0) && !e.created && listed[address(editions)];
    }

    function _master(uint256 seed) internal view returns (bool, uint256, Item storage it) {
        if (masterTokens.length == 0) return (false, 0, _items[0]);
        uint256 id = masterTokens[seed % masterTokens.length];
        it = _items[itemOf[id]];
        return (!burned[id], id, it);
    }

    function _item(Item storage it) internal view returns (PackageItem memory) {
        return abi.decode(it.data, (IFederatedStream.FederatedMint)).item;
    }

    function _govern(bytes memory call) internal {
        (bool immediate, uint32 delay) = manager.canCall(admin, address(registry), bytes4(call));
        if (immediate) {
            vm.prank(admin);
            (bool ok,) = address(registry).call(call);
            if (!ok) ++violations;
            return;
        }
        vm.prank(admin);
        manager.schedule(address(registry), call, 0);
        vm.warp(block.timestamp + delay);
        vm.prank(admin);
        manager.execute(address(registry), call);
    }
}

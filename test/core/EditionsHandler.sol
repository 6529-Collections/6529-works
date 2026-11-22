// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { Editions } from "src/core/Editions.sol";
import { Stream } from "src/core/Stream.sol";
import { Edition, MintFacts } from "src/interfaces/core/CoreTypes.sol";
import { MockSale } from "../mocks/core/CoreMocks.sol";

/// @notice Drives 6529 Stream Editions through every path that changes an edition or a balance,
///         with two sale contracts, the network's minter and wait settings, holder transfers and
///         burns. The ghosts record what each guarantee says the state must be; the handler never
///         reverts (failed calls are expected and ignored).
contract EditionsHandler is CommonBase, StdCheats, StdUtils {
    Editions public immutable editions;
    Stream public immutable stream;
    MockSale[2] public sales;
    /// @dev The network (the AccessManager's admin), allowed every restricted call.
    address public immutable network;
    address[3] public holders;

    uint256[] public ids;
    mapping(uint256 id => address) public ghostMinter;
    mapping(uint256 id => bool) public ghostSealed;
    mapping(uint256 id => uint256) public ghostSealedMax;
    mapping(uint256 id => uint256) public ghostBurned;
    uint256 public rebinds;

    constructor(Editions editions_, Stream stream_, MockSale streamSale, address network_) {
        editions = editions_;
        stream = stream_;
        network = network_;
        sales[0] = new MockSale();
        sales[1] = new MockSale();
        holders = [address(0xA1), address(0xA2), address(0xA3)];
        // Masters to make editions of: minted and sold through the fixture's Stream minter.
        for (uint256 i; i < 6; ++i) {
            MintFacts memory f;
            f.itemHash = keccak256(abi.encode("handler item", i));
            f.contentHash = keccak256(abi.encode("handler content", i));
            f.artistId = 1;
            f.collectionId = 1;
            f.kind = 1;
            uint256 id = streamSale.mint(address(stream), f);
            streamSale.record(address(stream), id, true, holders[0], 1);
            streamSale.send(address(stream), id, holders[0]);
            ids.push(id);
        }
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function _id(uint256 seed) internal view returns (uint256) {
        return ids[seed % ids.length];
    }

    function _sale(uint256 seed) internal view returns (MockSale) {
        return sales[seed % 2];
    }

    // ------------------------------------------------------------------ the network

    function addMinter(uint256 s) external {
        vm.prank(network);
        (bool ok,) = address(editions).call(abi.encodeCall(editions.addMinter, (address(_sale(s)))));
        ok;
    }

    function removeMinter(uint256 s) external {
        vm.prank(network);
        (bool ok,) =
            address(editions).call(abi.encodeCall(editions.removeMinter, (address(_sale(s)))));
        ok;
    }

    function setRebindDelay(uint48 next) external {
        next = uint48(bound(next, 0, 30 days));
        vm.prank(network);
        editions.setRebindDelay(next);
    }

    function setModuleDelay(uint48 next) external {
        next = uint48(bound(next, 0, 10 days));
        vm.prank(network);
        editions.setModuleDelay(next);
    }

    function warp(uint256 by) external {
        skip(bound(by, 0, 20 days));
    }

    /// @dev Records the rebind only when it succeeds, after checking that every condition the
    ///      guarantee states held before it.
    function rebind(uint256 idSeed, uint256 s) external {
        uint256 id = _id(idSeed);
        address next = address(_sale(s));
        Edition memory e = editions.editionOf(id);
        uint256 removedAt = editions.minterOf(e.minter).removedAt;
        bool allowed = e.minter != address(0) && !e.supplySealed && e.minted == 0
            && removedAt != 0 && block.timestamp >= removedAt + editions.rebindDelay()
            && editions.isMinter(next);
        vm.prank(network);
        (bool ok,) = address(editions).call(abi.encodeCall(editions.rebind, (id, next)));
        require(ok == allowed, "rebind outcome differs from its rule");
        if (ok) {
            ghostMinter[id] = next;
            ++rebinds;
        }
    }

    // ------------------------------------------------------------------ the sale contracts

    function create(uint256 idSeed, uint256 s, uint40 cap) external {
        uint256 id = _id(idSeed);
        cap = uint40(bound(cap, 0, 50));
        MockSale sale = _sale(s);
        try sale.createEdition(address(editions), id, cap, address(0xFEE), 5000) {
            ghostMinter[id] = address(sale);
        } catch { }
    }

    function mint(uint256 idSeed, uint256 s, uint256 holderSeed, uint256 amount) external {
        uint256 id = _id(idSeed);
        amount = bound(amount, 0, 30);
        try _sale(s).mintEdition(address(editions), holders[holderSeed % 3], id, amount, 1) { }
            catch { }
    }

    function seal(uint256 idSeed, uint256 s, uint40 supply) external {
        uint256 id = _id(idSeed);
        Edition memory e = editions.editionOf(id);
        supply = uint40(bound(supply, e.minted, e.minted + 20));
        try _sale(s).seal(address(editions), id, supply) {
            ghostSealed[id] = true;
            ghostSealedMax[id] = supply;
        } catch { }
    }

    // ------------------------------------------------------------------ holders

    function transfer(uint256 idSeed, uint256 from, uint256 to, uint256 amount) external {
        uint256 id = _id(idSeed);
        address a = holders[from % 3];
        amount = bound(amount, 0, editions.balanceOf(a, id));
        vm.prank(a);
        editions.safeTransferFrom(a, holders[to % 3], id, amount, "");
    }

    function burn(uint256 idSeed, uint256 holderSeed, uint256 amount) external {
        uint256 id = _id(idSeed);
        address a = holders[holderSeed % 3];
        amount = bound(amount, 0, editions.balanceOf(a, id));
        vm.prank(a);
        editions.burn(id, amount);
        ghostBurned[id] += amount;
    }
}

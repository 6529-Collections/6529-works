// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Editions } from "src/editions/Editions.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { EditionFormat, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { EditionsAdapterMock, EditionsStreamMock } from "../mocks/editions/EditionsMocks.sol";

/// @notice Drives 6529 Editions with purchases through the right and the wrong adapter, mints by
///         a non-minter, burns from adapter custody, transfers between holders, time warps,
///         master burns and repeated `createEdition` calls. Before each mint it predicts the
///         outcome from the edition's terms (size, OPEN window from the first mint, master
///         alive); any accepted call the model rejects, or rejected call it accepts, is counted
///         in `unexpected`. Ghost counters mirror minted, burned and window starts.
contract EditionsHandler is Test {
    Editions internal immutable editions;
    EditionsStreamMock internal immutable stream;
    EditionsAdapterMock internal immutable fixedAdapter;
    EditionsAdapterMock internal immutable dutchAdapter;

    uint256[] internal _ids;
    bytes[] internal _items;
    address[] internal _holders;

    mapping(uint256 => uint256) public ghostMinted;
    mapping(uint256 => uint256) public ghostBurned;
    mapping(uint256 => uint64) public ghostWindowStart;
    mapping(uint256 => bool) public masterBurned;
    /// @notice Calls whose outcome differed from the model.
    uint256 public unexpected;
    /// @notice Copies accepted at or after an OPEN window's end.
    uint256 public lateMints;
    /// @notice Copies accepted beyond an edition's size.
    uint256 public overCapMints;
    /// @notice Successful mints, for coverage.
    uint256 public mints;

    constructor(
        Editions editions_,
        EditionsStreamMock stream_,
        EditionsAdapterMock fixedAdapter_,
        EditionsAdapterMock dutchAdapter_,
        uint256[] memory ids_,
        PackageItem[] memory items
    ) {
        editions = editions_;
        stream = stream_;
        fixedAdapter = fixedAdapter_;
        dutchAdapter = dutchAdapter_;
        _ids = ids_;
        for (uint256 i; i < items.length; ++i) {
            _items.push(abi.encode(items[i]));
        }
        _holders.push(makeAddr("holderA"));
        _holders.push(makeAddr("holderB"));
        _holders.push(makeAddr("holderC"));
        _holders.push(address(fixedAdapter_));
        _holders.push(address(dutchAdapter_));
    }

    // ------------------------------------------------------------------ actions

    function buy(uint256 editionSeed, uint256 holderSeed, uint256 amount) external {
        uint256 i = editionSeed % _ids.length;
        uint256 id = _ids[i];
        IEditions.Edition memory e = editions.edition(id);
        amount = bound(amount, 1, e.terms.size == 0 ? 5_000 : uint256(e.terms.size) + 2);
        address to = _holders[holderSeed % _holders.length];
        bool open = e.terms.format == EditionFormat.OPEN;
        uint256 start = e.windowStart == 0 ? block.timestamp : e.windowStart;
        bool inWindow = !open || block.timestamp < start + e.terms.window;
        uint256 cap = e.terms.size == 0 ? type(uint64).max : e.terms.size;
        bool expectOk = inWindow && amount <= cap - e.minted && !masterBurned[id];

        try _adapterFor(e.terms.saleKind).buy(editions, id, to, amount) {
            if (!expectOk) ++unexpected;
            if (!inWindow) lateMints += amount;
            if (e.minted + amount > cap) overCapMints += amount;
            if (open && ghostWindowStart[id] == 0) ghostWindowStart[id] = uint64(block.timestamp);
            ghostMinted[id] += amount;
            ++mints;
        } catch (bytes memory reason) {
            if (expectOk || !_is(reason, IEditions.EditionUnavailable.selector)) ++unexpected;
        }
    }

    function buyWithWrongAdapter(uint256 editionSeed, uint256 amount) external {
        uint256 id = _ids[editionSeed % _ids.length];
        bytes32 kind = editions.edition(id).terms.saleKind;
        EditionsAdapterMock wrong = kind == SaleKind.DUTCH ? fixedAdapter : dutchAdapter;
        amount = bound(amount, 1, 10);
        try wrong.buy(editions, id, _holders[0], amount) {
            ++unexpected;
        } catch (bytes memory reason) {
            if (!_is(reason, Editions.SaleKindMismatch.selector)) ++unexpected;
        }
    }

    function mintAsOutsider(uint256 editionSeed, uint256 amount) external {
        uint256 id = _ids[editionSeed % _ids.length];
        amount = bound(amount, 1, 10);
        vm.prank(_holders[1]);
        try editions.mint(_holders[1], id, amount, "") {
            ++unexpected;
        } catch (bytes memory reason) {
            if (!_is(reason, IAccessManaged.AccessManagedUnauthorized.selector)) ++unexpected;
        }
    }

    function burnFromCustody(uint256 editionSeed, bool dutch, uint256 amount) external {
        uint256 id = _ids[editionSeed % _ids.length];
        EditionsAdapterMock adapter = dutch ? dutchAdapter : fixedAdapter;
        uint256 held = editions.balanceOf(address(adapter), id);
        if (held == 0) return;
        amount = bound(amount, 1, held);
        try adapter.burnHeld(editions, id, amount) {
            ghostBurned[id] += amount;
        } catch {
            ++unexpected;
        }
    }

    function transfer(uint256 editionSeed, uint256 fromSeed, uint256 toSeed, uint256 amount)
        external
    {
        uint256 id = _ids[editionSeed % _ids.length];
        address from = _holders[fromSeed % _holders.length];
        address to = _holders[toSeed % _holders.length];
        uint256 held = editions.balanceOf(from, id);
        if (held == 0) return;
        amount = bound(amount, 1, held);
        vm.prank(from);
        try editions.safeTransferFrom(from, to, id, amount, "") { }
        catch {
            ++unexpected;
        }
    }

    function warp(uint256 secondsAhead) external {
        vm.warp(block.timestamp + bound(secondsAhead, 0, 18 hours));
    }

    function recreate(uint256 editionSeed) external {
        uint256 i = editionSeed % _ids.length;
        PackageItem memory item = abi.decode(_items[i], (PackageItem));
        try editions.createEdition(_ids[i], item) {
            ++unexpected;
        } catch (bytes memory reason) {
            // The existence check comes first, so a repeat fails with EditionExists even after
            // the master is burned.
            if (!_is(reason, IEditions.EditionExists.selector)) ++unexpected;
        }
    }

    /// @dev Rare: an upheld dispute burns a master (one call in 32 does).
    function burnMaster(uint256 editionSeed) external {
        if (editionSeed % 32 != 0) return;
        uint256 id = _ids[(editionSeed / 32) % _ids.length];
        stream.burnMaster(id);
        masterBurned[id] = true;
    }

    // ------------------------------------------------------------------ views for invariants

    function ids() external view returns (uint256[] memory) {
        return _ids;
    }

    function holders() external view returns (address[] memory) {
        return _holders;
    }

    function _adapterFor(bytes32 kind) internal view returns (EditionsAdapterMock) {
        return kind == SaleKind.DUTCH ? dutchAdapter : fixedAdapter;
    }

    function _is(bytes memory reason, bytes4 selector) internal pure returns (bool) {
        return reason.length >= 4 && bytes4(reason) == selector;
    }
}

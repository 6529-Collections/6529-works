// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Editions } from "src/editions/Editions.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import {
    EditionsAdapterMock,
    EditionsPackages,
    EditionsStreamMock
} from "../mocks/editions/EditionsMocks.sol";

/// @notice Drives 6529 Stream Editions with mints through either of two admitted uniform-auction
///         adapters, an admitted adapter of the wrong sale kind and a non-minter, burns from
///         adapter custody, transfers between holders, time warps, secondary sales of the master
///         and repeated `createEdition` calls. Before each mint it predicts the outcome from the
///         edition's creator cap and its binding to the first adapter that minted it; any
///         accepted call the model rejects, or rejected call it accepts, is counted in
///         `unexpected`. Ghost counters mirror minted, burned and the bound adapter.
contract EditionsHandler is Test {
    Editions internal immutable editions;
    EditionsStreamMock internal immutable stream;
    EditionsAdapterMock internal immutable adapterA;
    EditionsAdapterMock internal immutable adapterB;
    EditionsAdapterMock internal immutable wrongKind;

    uint256[] internal _ids;
    bytes[] internal _items;
    address[] internal _holders;

    mapping(uint256 => uint256) public ghostMinted;
    mapping(uint256 => uint256) public ghostBurned;
    mapping(uint256 => address) public ghostMinter;
    /// @notice Calls whose outcome differed from the model.
    uint256 public unexpected;
    /// @notice Copies accepted beyond an edition's creator cap.
    uint256 public overCapMints;
    /// @notice Copies accepted from an adapter other than the edition's bound one.
    uint256 public unboundMints;
    /// @notice Successful mints, for coverage.
    uint256 public mints;

    constructor(
        Editions editions_,
        EditionsStreamMock stream_,
        EditionsAdapterMock adapterA_,
        EditionsAdapterMock adapterB_,
        EditionsAdapterMock wrongKind_,
        uint256[] memory ids_,
        PackageItem[] memory items
    ) {
        editions = editions_;
        stream = stream_;
        adapterA = adapterA_;
        adapterB = adapterB_;
        wrongKind = wrongKind_;
        _ids = ids_;
        for (uint256 i; i < items.length; ++i) {
            _items.push(abi.encode(items[i]));
        }
        _holders.push(makeAddr("holderA"));
        _holders.push(makeAddr("holderB"));
        _holders.push(makeAddr("holderC"));
        _holders.push(address(adapterA_));
        _holders.push(address(adapterB_));
    }

    // ------------------------------------------------------------------ actions

    function buy(uint256 editionSeed, bool second, uint256 holderSeed, uint256 amount) external {
        uint256 id = _ids[editionSeed % _ids.length];
        IEditions.Edition memory e = editions.edition(id);
        uint256 cap = e.terms.maxCount == 0 ? type(uint48).max : e.terms.maxCount;
        amount = bound(amount, 1, e.terms.maxCount == 0 ? 5_000 : uint256(e.terms.maxCount) + 2);
        EditionsAdapterMock adapter = second ? adapterB : adapterA;
        address to = _holders[holderSeed % _holders.length];
        bool bound_ = e.minter == address(0) || e.minter == address(adapter);
        bool withinCap = amount <= cap - e.minted;

        try adapter.buy(editions, id, to, amount) {
            if (!bound_ || !withinCap) ++unexpected;
            if (!bound_) unboundMints += amount;
            if (e.minted + amount > cap) overCapMints += amount;
            if (ghostMinter[id] == address(0)) ghostMinter[id] = address(adapter);
            ghostMinted[id] += amount;
            ++mints;
        } catch (bytes memory reason) {
            if (!bound_) {
                if (!_is(reason, IEditions.MinterMismatch.selector)) ++unexpected;
            } else if (withinCap || !_is(reason, IEditions.EditionUnavailable.selector)) {
                ++unexpected;
            }
        }
    }

    function buyWithWrongKind(uint256 editionSeed, uint256 amount) external {
        uint256 id = _ids[editionSeed % _ids.length];
        amount = bound(amount, 1, 10);
        try wrongKind.buy(editions, id, _holders[0], amount) {
            ++unexpected;
        } catch (bytes memory reason) {
            if (!_is(reason, IMintTarget.SaleKindMismatch.selector)) ++unexpected;
        }
    }

    function mintAsOutsider(uint256 editionSeed, uint256 amount) external {
        uint256 id = _ids[editionSeed % _ids.length];
        amount = bound(amount, 1, 10);
        vm.prank(_holders[1]);
        try editions.mint(_holders[1], id, amount, "") {
            ++unexpected;
        } catch (bytes memory reason) {
            if (!_is(reason, IMintTarget.NotAdmittedMinter.selector)) ++unexpected;
        }
    }

    function burnFromCustody(uint256 editionSeed, bool second, uint256 amount) external {
        uint256 id = _ids[editionSeed % _ids.length];
        EditionsAdapterMock adapter = second ? adapterB : adapterA;
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
        (bytes32 root, bytes32[] memory proof) = EditionsPackages.packageOf(item, 0);
        try editions.createEdition(_ids[i], item, root, proof) {
            ++unexpected;
        } catch (bytes memory reason) {
            if (!_is(reason, IEditions.EditionExists.selector)) ++unexpected;
        }
    }

    /// @dev The settled master changes hands on the secondary market; editions are unaffected.
    function moveMaster(uint256 editionSeed, uint256 holderSeed) external {
        stream.settle(_ids[editionSeed % _ids.length], _holders[holderSeed % _holders.length]);
    }

    // ------------------------------------------------------------------ views for invariants

    function ids() external view returns (uint256[] memory) {
        return _ids;
    }

    function holders() external view returns (address[] memory) {
        return _holders;
    }

    function _is(bytes memory reason, bytes4 selector) internal pure returns (bool) {
        return reason.length >= 4 && bytes4(reason) == selector;
    }
}

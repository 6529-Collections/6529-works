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

/// @notice Drives 6529 Stream Editions with mints through either of two uniform-auction
///         adapters (each removed and re-admitted by governance at random), seals by either of
///         them, an admitted adapter of the wrong sale kind and a non-minter, burns from
///         adapter custody, transfers between holders, time warps, secondary sales of the master
///         and repeated `createEdition` calls. Before each mint it predicts the outcome from the
///         edition's maximum (the creator's cap, then the sealed count), its binding to the first
///         adapter that minted it and the adapter's admission (a removed adapter mints only a
///         sealed edition); any
///         accepted call the model rejects, or rejected call it accepts, is counted in
///         `unexpected`. Ghost counters mirror minted, burned and the bound adapter.
contract EditionsHandler is Test {
    Editions internal immutable editions;
    EditionsStreamMock internal immutable stream;
    EditionsAdapterMock internal immutable adapterA;
    EditionsAdapterMock internal immutable adapterB;
    EditionsAdapterMock internal immutable wrongKind;
    address internal immutable governor;

    uint256[] internal _ids;
    bytes[] internal _items;
    address[] internal _holders;

    mapping(uint256 => uint256) public ghostMinted;
    mapping(uint256 => uint256) public ghostBurned;
    mapping(uint256 => address) public ghostMinter;
    mapping(uint256 => bool) public ghostSealed;
    mapping(uint256 => uint256) public ghostSealCount;
    mapping(address => bool) public ghostRemoved;
    /// @notice Copies accepted past a sealed count.
    uint256 public overSealMints;
    /// @notice Copies accepted from a removed adapter whose edition was not sealed.
    uint256 public removedUnsealedMints;
    /// @notice Successful seals, for coverage.
    uint256 public seals;
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
        address governor_,
        uint256[] memory ids_,
        PackageItem[] memory items
    ) {
        editions = editions_;
        stream = stream_;
        adapterA = adapterA_;
        adapterB = adapterB_;
        wrongKind = wrongKind_;
        governor = governor_;
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
        uint256 cap = e.maxSupply;
        amount = bound(amount, 1, e.terms.maxCount == 0 ? 5_000 : uint256(e.terms.maxCount) + 2);
        EditionsAdapterMock adapter = second ? adapterB : adapterA;
        address to = _holders[holderSeed % _holders.length];
        bool removed = ghostRemoved[address(adapter)];
        bool bound_ = e.minter == address(0) || e.minter == address(adapter);
        // A removed adapter binds nothing, and mints only an edition it sealed.
        bool admittedFor = !removed || (e.minter == address(adapter) && e.supplySealed);
        bool withinCap = amount <= cap - e.minted;

        try adapter.buy(editions, id, to, amount) {
            if (!bound_ || !admittedFor || !withinCap) ++unexpected;
            if (!bound_) unboundMints += amount;
            if (!admittedFor) removedUnsealedMints += amount;
            if (e.minted + amount > cap) overCapMints += amount;
            if (ghostSealed[id] && e.minted + amount > ghostSealCount[id]) overSealMints += amount;
            if (ghostMinter[id] == address(0)) ghostMinter[id] = address(adapter);
            ghostMinted[id] += amount;
            ++mints;
        } catch (bytes memory reason) {
            if (!bound_ && !removed) {
                if (!_is(reason, IEditions.MinterMismatch.selector)) ++unexpected;
            } else if (!bound_ || !admittedFor) {
                // Removed: an unbound or unsealed edition refuses it as not admitted, and
                // another adapter's edition as a mismatch.
                if (
                    !_is(reason, IMintTarget.NotAdmittedMinter.selector)
                        && !_is(reason, IEditions.MinterMismatch.selector)
                ) ++unexpected;
            } else if (withinCap || !_is(reason, IEditions.EditionUnavailable.selector)) {
                ++unexpected;
            }
        }
    }

    /// @dev The bound adapter's settlement: seals at a count between the copies minted and the
    ///      maximum when `valid`, or at an out-of-range count otherwise; any other adapter, an
    ///      unbound edition or a second seal is refused.
    function seal(uint256 editionSeed, bool second, uint256 count, bool valid) external {
        uint256 id = _ids[editionSeed % _ids.length];
        IEditions.Edition memory e = editions.edition(id);
        EditionsAdapterMock adapter = second ? adapterB : adapterA;
        uint256 headroom = e.maxSupply - e.minted;
        count = valid
            ? e.minted + bound(count, 0, headroom < 10_000 ? headroom : 10_000)
            : (e.minted != 0 && count % 2 == 0 ? e.minted - 1 : e.maxSupply + 1);
        bool expectOk = e.minter == address(adapter) && !e.supplySealed && valid;
        try adapter.seal(editions, id, count) {
            if (!expectOk) ++unexpected;
            ghostSealed[id] = true;
            ghostSealCount[id] = count;
            ++seals;
        } catch {
            if (expectOk) ++unexpected;
        }
    }

    /// @dev Governance removes or re-admits an adapter (the 30-day class in deployment).
    function toggleAdmission(bool second) external {
        EditionsAdapterMock adapter = second ? adapterB : adapterA;
        bool removed = ghostRemoved[address(adapter)];
        vm.prank(governor);
        editions.setAdmittedMinter(address(adapter), removed);
        ghostRemoved[address(adapter)] = !removed;
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
        try editions.mint(_holders[1], id, amount, abi.encode(address(0), uint256(1))) {
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
        try editions.createEdition(_ids[i], item) {
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Editions } from "src/editions/Editions.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import {
    EditionTerms,
    ItemKind,
    License,
    PackageItem,
    Party,
    PartyRole,
    SaleTerms,
    SeedPolicy
} from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { EditionsBase } from "../editions/EditionsBase.sol";

/// @notice Halmos proofs of the edition supply rules on the real `Editions`, with the unit
///         suite's mocks for Stream and its neighbours (`EditionsBase`) (docs/testing/README.md,
///         "Symbolic").
/// @dev The fixture's named accounts are fixed addresses here: `makeAddr` would give Halmos
///      symbolic ones, which the canonical payee order then branches on.
contract EditionsSymbolicTest is EditionsBase {
    address internal constant HOLDER = address(0xB0B0);

    uint256 internal id;
    /// @dev The master's item, ABI-encoded (a struct with arrays cannot be copied to storage).
    bytes internal masterItem;

    function setUp() public override {
        admin = address(0xAD);
        governor = address(0x6060);
        marketOwner = address(0x3A12);
        artist = address(0xA471);
        collaborator = address(0xC011AB);
        feeRecipient = address(0xFEE);
        buyer = address(0xB1);
        outsider = address(0x0715);
        super.setUp();
    }

    /// @dev Creates an edition with creator cap `cap` (zero: uncapped, the uint40 maximum).
    function _edition(uint32 cap) internal {
        PackageItem memory master = _masterItem(cap);
        masterItem = abi.encode(master);
        id = _create(master);
    }

    /// @dev `EditionsBase._item` with a keccak256 content hash: Halmos 0.3.3 fails on the
    ///      SHA-256 precompile over that input (a sort mismatch in its model), and the mocks do
    ///      not check that the content hash is a SHA-256.
    function _masterItem(uint32 maxCount) internal returns (PackageItem memory item) {
        item.kind = uint8(ItemKind.EDITION_MASTER);
        item.collectionId = 1;
        item.contentHash = keccak256(abi.encode("content", ++_contentNonce));
        item.mediaHash = keccak256(abi.encode("media", _contentNonce));
        item.recordFileId = keccak256(abi.encode("record", _contentNonce));
        item.parties = new Party[](2);
        item.parties[0] = Party(artist, uint8(PartyRole.ARTIST));
        item.parties[1] = Party(collaborator, uint8(PartyRole.COLLABORATOR));
        item.payees = new ISplitWallet.Payee[](2);
        item.payees[0] = ISplitWallet.Payee(0, collaborator, 20_000);
        item.payees[1] = ISplitWallet.Payee(uint256(uint160(artist)), address(0), 80_000);
        item.license = License("CC0-1.0", keccak256("CC0 1.0 legal code"));
        item.seedPolicy = uint8(SeedPolicy.NONE);
        item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_ETH, "");
        item.edition = EditionTerms(maxCount, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
    }

    function _buy(address via, uint256 amount) internal returns (bool ok) {
        (ok,) = via.call(
            abi.encodeCall(adapter.buy, (IMintTarget(address(editions)), id, HOLDER, amount))
        );
    }

    // ---------------------------------------------------------------------------------------
    // INV-ED-2, INV-ED-5, INV-ED-6, ED-25
    // ---------------------------------------------------------------------------------------

    /// @notice INV-ED-2: whatever two mints ask for, `minted` counts every copy minted, never
    ///         passes a nonzero cap, and equals the holder's balance; a mint that would pass the
    ///         cap reverts and mints nothing.
    /// @dev Bounds: any cap below 2**32 (zero: uncapped), any two amounts below 2**64.
    function check_mint_neverPassesTheCap(uint32 cap, uint64 a1, uint64 a2) public {
        _edition(cap);
        bool ok1 = _buy(address(adapter), a1);
        uint256 after1 = editions.edition(id).minted;
        bool ok2 = _buy(address(adapter), a2);
        uint256 minted = editions.edition(id).minted;
        uint256 limit = cap == 0 ? type(uint40).max : cap;
        assert(minted <= limit);
        assert(minted == _pick(ok1, a1, 0) + _pick(ok2, a2, 0));
        assert(editions.balanceOf(HOLDER, id) == minted);
        assert(ok1 == (a1 != 0 && a1 <= limit));
        assert(ok2 == (a2 != 0 && uint256(a2) <= limit - after1));
    }

    /// @notice INV-ED-6, ED-25: the bound adapter seals once, at a count between the copies
    ///         minted and the maximum; afterwards no mint passes the sealed count and a second
    ///         seal reverts; a removed adapter mints only an edition it sealed.
    /// @dev Bounds: cap 100; any amounts below 2**64 before and after; any seal count; the
    ///      adapter removed before the last mint or not, and sealed or not.
    function check_seal_isOnceAndBoundsMints(
        uint64 before,
        uint256 count,
        uint64 later,
        uint256 count2,
        bool seal,
        bool remove
    ) public {
        _edition(100);
        // The sale binds its adapter when it opens, so the seal is the bound adapter's even
        // when nothing was minted.
        adapter.bind(IEditions(address(editions)), id, abi.decode(masterItem, (PackageItem)));
        _buy(address(adapter), before);
        uint256 minted = editions.edition(id).minted;
        if (seal) {
            (bool didSeal,) = address(adapter)
                .call(abi.encodeCall(adapter.seal, (IEditions(address(editions)), id, count)));
            assert(didSeal == (count >= minted && count <= 100));
            vm.assume(didSeal);
            (bool again,) = address(adapter)
                .call(abi.encodeCall(adapter.seal, (IEditions(address(editions)), id, count2)));
            assert(!again);
        }
        if (remove) {
            vm.prank(governor);
            editions.setAdmittedMinter(address(adapter), false);
        }
        bool ok = _buy(address(adapter), later);
        uint256 limit = seal ? count : 100;
        assert(editions.edition(id).minted <= limit);
        if (_and(remove, !seal)) assert(!ok);
        assert(editions.edition(id).supplySealed == seal);
    }

    /// @notice INV-ED-5: an edition stays bound to the adapter that first minted it; another
    ///         admitted adapter of the same kind can neither mint, seal nor rebind it, and no
    ///         other caller mints at all.
    /// @dev Bounds: any caller; the second admitted adapter's mint, seal and bind; any amount.
    function check_boundAdapter_neverRebinds(address caller, uint8 action, uint64 amount) public {
        _edition(0);
        _buy(address(adapter), 1);
        uint256 minted = editions.edition(id).minted;
        bool ok;
        if (action == 0) {
            ok = _buy(address(secondAdapter), amount);
        } else if (action == 1) {
            (ok,) = address(secondAdapter)
                .call(abi.encodeCall(adapter.seal, (IEditions(address(editions)), id, minted)));
        } else if (action == 2) {
            (ok,) = address(secondAdapter)
                .call(
                    abi.encodeCall(
                        adapter.bind,
                        (IEditions(address(editions)), id, abi.decode(masterItem, (PackageItem)))
                    )
                );
        } else {
            vm.assume(caller != address(adapter));
            vm.prank(caller);
            (ok,) = address(editions)
                .call(
                    abi.encodeCall(editions.mint, (HOLDER, id, amount, abi.encode(address(0), 0)))
                );
        }
        assert(!ok);
        assert(editions.edition(id).minted == minted);
        assert(!editions.edition(id).supplySealed);
    }

    function _and(bool a, bool b) internal pure returns (bool r) {
        assembly ("memory-safe") {
            r := and(a, b)
        }
    }

    function _pick(bool flag, uint256 whenTrue, uint256 whenFalse)
        internal
        pure
        returns (uint256 r)
    {
        assembly ("memory-safe") {
            r := xor(whenFalse, mul(xor(whenTrue, whenFalse), flag))
        }
    }
}

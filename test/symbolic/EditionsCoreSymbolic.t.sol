// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { EditionsBase } from "src/core/EditionsBase.sol";
import { Edition } from "src/interfaces/core/CoreTypes.sol";

/// @notice A master that exists for every ID, with no renderer and no modules.
contract SymbolicMaster {
    function ownerOf(uint256) external pure returns (address) {
        return address(0xC0FFEE);
    }

    function moduleOf(bytes32) external pure returns (address) {
        return address(0);
    }
}

/// @notice `EditionsBase` with the simplest hooks: minters and removal times the test sets, the
///         test as the network and admin. The base's own rules are what the proofs cover; the
///         hooks of `Editions` and `FederatedEditions` only answer who may mint and when a
///         minter was removed.
contract EditionsHarness is EditionsBase {
    address public immutable network;
    mapping(address account => bool) public minter;
    mapping(address account => uint256) public removedAt;

    constructor(address stream_) EditionsBase(stream_, msg.sender) {
        network = msg.sender;
    }

    function setMinter(address account, bool ok) external {
        minter[account] = ok;
    }

    function setRemovedAt(address account, uint256 at) external {
        removedAt[account] = at;
    }

    function _moduleOf(bytes32) internal pure override returns (address) {
        return address(0);
    }

    function _isMinter(address account) internal view override returns (bool) {
        return minter[account];
    }

    function _minterRemovedAt(address account) internal view override returns (uint256) {
        return removedAt[account];
    }

    function _checkAdmin() internal view override {
        require(msg.sender == network, "admin");
    }

    function _checkNetwork() internal view override {
        require(msg.sender == network, "network");
    }
}

/// @notice Halmos proofs of the permanent edition rules on `EditionsBase` (docs/testing/README.md,
///         "Symbolic"): copies minted never pass the maximum; the seal happens once, between the
///         copies minted and the maximum, and a sealed maximum never grows; only the edition's
///         own minter mints it, and a removed one only once it has sealed; the rebind
///         predicate; and royalty arithmetic exact for any price. Each proof is over symbolic
///         caps, amounts, times and callers.
contract EditionsCoreSymbolicTest is Test {
    uint256 internal constant ID = 7;
    address internal constant SALE = address(0x5A1E);
    address internal constant NEXT = address(0x4E87);
    address internal constant HOLDER = address(0xB0B0);

    EditionsHarness internal editions;

    function setUp() public {
        editions = new EditionsHarness(address(new SymbolicMaster()));
        editions.setMinter(SALE, true);
        editions.setMinter(NEXT, true);
    }

    function _create(uint40 cap) internal {
        vm.prank(SALE);
        editions.create(ID, cap, address(0xFEE), 5000);
    }

    function _mint(address caller, uint256 amount) internal returns (bool ok) {
        vm.prank(caller);
        (ok,) = address(editions).call(abi.encodeCall(editions.mint, (HOLDER, ID, amount, 0)));
    }

    function _seal(address caller, uint40 supply) internal returns (bool ok) {
        vm.prank(caller);
        (ok,) = address(editions).call(abi.encodeCall(editions.seal, (ID, supply)));
    }

    /// @dev Two mints of any amounts: each succeeds exactly when it fits under the maximum, and
    ///      the count equals the holder's balance and never passes the maximum.
    function check_MintNeverPassesTheMaximum(uint40 cap, uint256 a, uint256 b) public {
        _create(cap);
        uint256 max = cap == 0 ? type(uint40).max : cap;
        bool okA = _mint(SALE, a);
        assert(okA == (a <= max));
        uint256 minted = okA ? a : 0;
        bool okB = _mint(SALE, b);
        assert(okB == (b <= max - minted));
        if (okB) minted += b;
        Edition memory e = editions.editionOf(ID);
        assert(e.minted == minted);
        assert(e.minted <= e.maxSupply);
        assert(editions.balanceOf(HOLDER, ID) == minted);
    }

    /// @dev The seal succeeds only between the count minted and the maximum, once; afterwards
    ///      the maximum is the seal and never grows.
    function check_SealIsOnceAndBounded(uint40 cap, uint40 minted, uint40 s1, uint40 s2) public {
        vm.assume(cap != 0 && minted <= cap);
        _create(cap);
        assert(_mint(SALE, minted));
        bool ok1 = _seal(SALE, s1);
        assert(ok1 == (s1 >= minted && s1 <= cap));
        if (!ok1) return;
        assert(!_seal(SALE, s2));
        Edition memory e = editions.editionOf(ID);
        assert(e.supplySealed && e.maxSupply == s1);
        assert(!_mint(SALE, uint256(s1) - minted + 1));
    }

    /// @dev Only the edition's own minter mints it; a removed one (no longer a minter) only once
    ///      it has sealed, and never another minter.
    function check_OnlyTheEditionsMinterMints(address caller, bool removed, bool sealed_)
        public
    {
        _create(100);
        if (sealed_) assert(_seal(SALE, 50));
        if (removed) editions.setMinter(SALE, false);
        vm.assume(caller != SALE);
        assert(!_mint(caller, 1));
        assert(_mint(SALE, 1) == (!removed || sealed_));
    }

    /// @dev `rebind` succeeds exactly when the edition exists with no copies and no seal, its
    ///      minter was removed, the rebind wait in force has passed since the removal, and the
    ///      new minter is active; the minter then is the new one, and nothing else changed.
    function check_RebindPredicate(
        bool minted,
        bool sealed_,
        uint256 removedAt,
        uint48 delay,
        uint32 wait,
        bool nextActive
    ) public {
        vm.assume(removedAt <= block.timestamp);
        _create(100);
        if (minted) assert(_mint(SALE, 1));
        if (sealed_) assert(_seal(SALE, minted ? 1 : 0));
        editions.setRemovedAt(SALE, removedAt);
        editions.setRebindDelay(delay);
        editions.setMinter(NEXT, nextActive);
        vm.warp(block.timestamp + wait);
        (bool ok,) = address(editions).call(abi.encodeCall(editions.rebind, (ID, NEXT)));
        bool expected = !minted && !sealed_ && removedAt != 0
            && block.timestamp >= removedAt + delay && nextActive;
        assert(ok == expected);
        Edition memory e = editions.editionOf(ID);
        assert(e.minter == (ok ? NEXT : SALE));
        assert(e.maxSupply == (sealed_ ? (minted ? 1 : 0) : 100));
    }

    /// @dev Royalties come from the edition's stored receiver and rate only: for any rate, a sale
    ///      at the denominator pays exactly the rate and a sale at zero nothing; an edition that
    ///      does not exist answers nothing. BOUNDED: two prices (a symbolic price through
    ///      `Math.mulDiv`'s 512-bit path timed out, even below 2^64); the unit suite fuzzes
    ///      every price against `Math.mulDiv`.
    function check_RoyaltyInfoFromStorage(uint24 rate) public {
        vm.assume(rate <= 100_000);
        vm.prank(SALE);
        editions.create(ID, 1, address(0xFEE), rate);
        (address receiver, uint256 amount) = editions.royaltyInfo(ID, 100_000);
        assert(receiver == address(0xFEE) && amount == rate);
        (, amount) = editions.royaltyInfo(ID, 0);
        assert(amount == 0);
        (receiver, amount) = editions.royaltyInfo(ID + 1, 100_000);
        assert(receiver == address(0) && amount == 0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { AssetAllowlist } from "src/economics/AssetAllowlist.sol";
import { ClaimRouter } from "src/economics/ClaimRouter.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { ReleaseVerifier } from "src/economics/ReleaseVerifier.sol";
import { RevenuePayment } from "src/economics/RevenuePayment.sol";
import { SplitFactory } from "src/economics/SplitFactory.sol";
import { SplitWallet } from "src/economics/SplitWallet.sol";
import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { MockArtistResolver, MockERC20 } from "../mocks/economics/EconomicsMocks.sol";

/// @dev Exposes the internal `RevenuePayment` library the way a sale adapter compiles it in.
contract PaymentHarness {
    IRevenueEscrow public immutable escrow;

    constructor(IRevenueEscrow escrow_) {
        escrow = escrow_;
    }

    receive() external payable { }

    function payETH(address wallet, uint256 amount, uint256 gasLimit) external returns (bool) {
        return RevenuePayment.payETH(escrow, wallet, amount, gasLimit);
    }

    function payERC20(address wallet, address asset, uint256 amount) external returns (bool) {
        return RevenuePayment.payERC20(escrow, wallet, asset, amount);
    }
}

/// @dev Shared deployment and helpers for the economics tests.
abstract contract EconomicsBase is Test {
    uint32 internal constant D = 100_000;
    uint256 internal constant ARTIST = 7;
    uint256 internal constant ETH_FLOOR = 0.001 ether;
    address internal constant ETH = address(0);

    AccessManager internal manager;
    AssetAllowlist internal allowlist;
    MockArtistResolver internal resolver;
    ReleaseVerifier internal verifier;
    SplitFactory internal factory;
    RevenueEscrow internal escrow;
    ClaimRouter internal router;
    PaymentHarness internal payer;
    MockERC20 internal token;

    uint256 internal alicePk = 0xA11CE;
    uint256 internal bobPk = 0xB0B;
    uint256 internal artistPk = 0xA27;
    address internal alice;
    address internal bob;
    address internal artistPayout;

    function setUp() public virtual {
        alice = vm.addr(alicePk);
        bob = vm.addr(bobPk);
        artistPayout = vm.addr(artistPk);
        manager = new AccessManager(address(this));
        allowlist = new AssetAllowlist(address(manager), ETH_FLOOR);
        resolver = new MockArtistResolver();
        resolver.set(ARTIST, artistPayout);
        verifier = new ReleaseVerifier();
        factory = new SplitFactory(resolver, verifier);
        escrow = new RevenueEscrow(address(manager), factory);
        router = new ClaimRouter();
        payer = new PaymentHarness(escrow);
        token = new MockERC20("Token", "TKN");
    }

    function _fixed(address account, uint32 share)
        internal
        pure
        returns (ISplitWallet.Payee memory)
    {
        return ISplitWallet.Payee(0, account, share);
    }

    function _artist(uint256 artistId, uint32 share)
        internal
        pure
        returns (ISplitWallet.Payee memory)
    {
        return ISplitWallet.Payee(artistId, address(0), share);
    }

    /// @dev Sorts into canonical `(artistId, account)` order.
    function _sorted(ISplitWallet.Payee[] memory payees)
        internal
        pure
        returns (ISplitWallet.Payee[] memory)
    {
        for (uint256 i = 1; i < payees.length; ++i) {
            ISplitWallet.Payee memory current = payees[i];
            uint256 j = i;
            while (
                j > 0
                    && (payees[j - 1].artistId > current.artistId
                        || (payees[j - 1].artistId == current.artistId
                            && payees[j - 1].account > current.account))
            ) {
                payees[j] = payees[j - 1];
                --j;
            }
            payees[j] = current;
        }
        return payees;
    }

    function _list(ISplitWallet.Payee memory a)
        internal
        pure
        returns (ISplitWallet.Payee[] memory l)
    {
        l = new ISplitWallet.Payee[](1);
        l[0] = a;
    }

    function _list(ISplitWallet.Payee memory a, ISplitWallet.Payee memory b)
        internal
        pure
        returns (ISplitWallet.Payee[] memory l)
    {
        l = new ISplitWallet.Payee[](2);
        l[0] = a;
        l[1] = b;
        _sorted(l);
    }

    function _list(
        ISplitWallet.Payee memory a,
        ISplitWallet.Payee memory b,
        ISplitWallet.Payee memory c
    ) internal pure returns (ISplitWallet.Payee[] memory l) {
        l = new ISplitWallet.Payee[](3);
        l[0] = a;
        l[1] = b;
        l[2] = c;
        _sorted(l);
    }

    function _wallet(ISplitWallet.Payee[] memory payees) internal returns (SplitWallet) {
        return SplitWallet(payable(factory.createWallet(payees, bytes32(0))));
    }

    /// @dev A one-payee wallet paying `account` everything.
    function _solo(address account) internal returns (SplitWallet) {
        return _wallet(_list(_fixed(account, D)));
    }

    /// @dev The standard three-payee wallet: alice 50%, bob 30%, artist 7 (resolved) 20%.
    function _trio() internal returns (SplitWallet) {
        return _wallet(_list(_fixed(alice, 50_000), _fixed(bob, 30_000), _artist(ARTIST, 20_000)));
    }

    /// @dev The index of fixed payee `account` in `wallet`.
    function _indexOf(SplitWallet wallet, address account) internal view returns (uint256) {
        ISplitWallet.Payee[] memory list = wallet.payees();
        for (uint256 i; i < list.length; ++i) {
            if (list[i].artistId == 0 && list[i].account == account) return i;
        }
        revert("no such payee");
    }

    function _artistIndex(SplitWallet wallet, uint256 artistId) internal view returns (uint256) {
        ISplitWallet.Payee[] memory list = wallet.payees();
        for (uint256 i; i < list.length; ++i) {
            if (list[i].artistId == artistId) return i;
        }
        revert("no such artist");
    }

    /// @dev An authorization for payee `index` of `wallet`, valid for an hour.
    function _auth(
        SplitWallet wallet,
        address asset,
        uint256 index,
        address account,
        address recipient,
        uint256 amount,
        uint256 nonce
    ) internal view returns (IReleaseVerifier.Authorization memory) {
        return IReleaseVerifier.Authorization(
            address(wallet),
            asset,
            index,
            account,
            recipient,
            amount,
            nonce,
            block.timestamp + 1 hours
        );
    }

    function _sign(uint256 pk, IReleaseVerifier.Authorization memory a)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, verifier.releaseDigest(a));
        return abi.encodePacked(r, s, v);
    }
}

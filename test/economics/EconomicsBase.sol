// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { AssetAllowlist } from "src/economics/AssetAllowlist.sol";
import { ClaimRouter } from "src/economics/ClaimRouter.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { RevenuePayment } from "src/economics/RevenuePayment.sol";
import { SplitLedger } from "src/economics/SplitLedger.sol";
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
    /// @dev The split ledger. `factory` and `verifier` name the same contract, for the tests
    ///      written when the factory, the wallets and the release verifier were separate.
    SplitLedger internal ledger;
    SplitLedger internal factory;
    SplitLedger internal verifier;
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
        ledger = new SplitLedger(resolver);
        factory = ledger;
        verifier = ledger;
        escrow = new RevenueEscrow(address(manager), ledger);
        router = new ClaimRouter(ledger);
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

    /// @dev The payee list and salt of every wallet a test deployed or registered, keyed by
    ///      wallet: the ledger stores neither, and every release names its wallet by both.
    mapping(address wallet => ISplitWallet.Payee[]) internal _payeeLists;
    mapping(address wallet => bytes32) internal _salts;

    /// @dev Deploys the salt-zero wallet for `payees` and remembers its list.
    function _wallet(ISplitWallet.Payee[] memory payees) internal returns (address wallet) {
        return _wallet(payees, bytes32(0));
    }

    function _wallet(ISplitWallet.Payee[] memory payees, bytes32 salt)
        internal
        returns (address wallet)
    {
        wallet = ledger.createWallet(payees, salt);
        _remember(payees, salt);
    }

    /// @dev Records the wallet of `payees` and `salt` without deploying anything; returns it.
    function _remember(ISplitWallet.Payee[] memory payees, bytes32 salt)
        internal
        returns (address wallet)
    {
        wallet = ledger.walletFor(payees, salt);
        _salts[wallet] = salt;
        delete _payeeLists[wallet];
        for (uint256 i; i < payees.length; ++i) {
            _payeeLists[wallet].push(payees[i]);
        }
    }

    function _payeesOf(address wallet) internal view returns (ISplitWallet.Payee[] memory) {
        return _payeeLists[wallet];
    }

    /// @dev `ledger.release` with the remembered list: one external call, so `vm.prank` and
    ///      `vm.expectRevert` apply to it.
    function _release(address wallet, address asset, uint256 index) internal returns (uint256) {
        return ledger.release(_payeesOf(wallet), _salts[wallet], asset, index);
    }

    function _releaseTo(address wallet, address asset, uint256 index, address recipient)
        internal
        returns (uint256)
    {
        return ledger.releaseTo(_payeesOf(wallet), _salts[wallet], asset, index, recipient);
    }

    function _releasable(address wallet, address asset, uint256 index)
        internal
        view
        returns (uint256)
    {
        return ledger.releasable(_payeesOf(wallet), _salts[wallet], asset, index);
    }

    /// @dev Where payee `index` of `wallet` is paid now: its account, or the resolver's answer.
    function _payoutAddress(address wallet, uint256 index) internal view returns (address) {
        ISplitWallet.Payee memory p = _payeesOf(wallet)[index];
        return p.artistId == 0 ? p.account : resolver.payoutAddress(p.artistId);
    }

    /// @dev `ledger.releaseWithAuthorization` with the list of the wallet the authorization names.
    function _releaseSigned(IReleaseVerifier.Authorization memory a, bytes memory signature)
        internal
        returns (uint256)
    {
        return ledger.releaseWithAuthorization(_payeesOf(a.wallet), _salts[a.wallet], a, signature);
    }

    /// @dev A one-payee wallet paying `account` everything.
    function _solo(address account) internal returns (address) {
        return _wallet(_list(_fixed(account, D)));
    }

    /// @dev The standard three-payee wallet: alice 50%, bob 30%, artist 7 (resolved) 20%.
    function _trio() internal returns (address) {
        return _wallet(_list(_fixed(alice, 50_000), _fixed(bob, 30_000), _artist(ARTIST, 20_000)));
    }

    /// @dev The index of fixed payee `account` in `wallet`.
    function _indexOf(address wallet, address account) internal view returns (uint256) {
        ISplitWallet.Payee[] memory list = _payeesOf(wallet);
        for (uint256 i; i < list.length; ++i) {
            if (list[i].artistId == 0 && list[i].account == account) return i;
        }
        revert("no such payee");
    }

    function _artistIndex(address wallet, uint256 artistId) internal view returns (uint256) {
        ISplitWallet.Payee[] memory list = _payeesOf(wallet);
        for (uint256 i; i < list.length; ++i) {
            if (list[i].artistId == artistId) return i;
        }
        revert("no such artist");
    }

    /// @dev An authorization for payee `index` of `wallet`, valid for an hour.
    function _auth(
        address wallet,
        address asset,
        uint256 index,
        address account,
        address recipient,
        uint256 amount,
        uint256 nonce
    ) internal view returns (IReleaseVerifier.Authorization memory) {
        return IReleaseVerifier.Authorization(
            wallet, asset, index, account, recipient, amount, nonce, block.timestamp + 1 hours
        );
    }

    function _sign(uint256 pk, IReleaseVerifier.Authorization memory a)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ledger.releaseDigest(a));
        return abi.encodePacked(r, s, v);
    }
}

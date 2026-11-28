// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { SplitLedger } from "src/economics/SplitLedger.sol";
import { Mock1271Account, RejectingRecipient } from "../mocks/economics/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";

contract ReleaseVerifierTest is EconomicsBase {
    address internal wallet;
    uint256 internal iAlice;
    uint256 internal iArtist;
    address internal relayer = makeAddr("relayer");
    address internal recipient = makeAddr("recipient");

    function setUp() public override {
        super.setUp();
        wallet = _trio();
        iAlice = _indexOf(wallet, alice);
        iArtist = _artistIndex(wallet, ARTIST);
        vm.deal(address(wallet), 10 ether);
        token.mint(address(wallet), 1000);
    }

    function _a(uint256 payeeIndex, address account, uint256 amount, uint256 nonce)
        internal
        view
        returns (IReleaseVerifier.Authorization memory)
    {
        return _auth(wallet, ETH, payeeIndex, account, recipient, amount, nonce);
    }

    function test_GoldenTypehashDomainAndDigest() public view {
        assertEq(
            verifier.RELEASE_TYPEHASH(),
            keccak256(
                "ReleaseAuthorization(address wallet,address asset,uint256 payee,address account,address recipient,uint256 amount,uint256 nonce,uint256 deadline)"
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("6529 Stream Release Verifier"),
                keccak256("1"),
                block.chainid,
                address(verifier)
            )
        );
        assertEq(verifier.domainSeparator(), domain);
        IReleaseVerifier.Authorization memory a = _a(iAlice, alice, 1 ether, 1);
        bytes32 structHash = keccak256(
            abi.encode(
                verifier.RELEASE_TYPEHASH(),
                a.wallet,
                a.asset,
                a.payee,
                a.account,
                a.recipient,
                a.amount,
                a.nonce,
                a.deadline
            )
        );
        assertEq(
            verifier.releaseDigest(a), keccak256(abi.encodePacked(hex"1901", domain, structHash))
        );
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = verifier.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "6529 Stream Release Verifier");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(verifier));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    /// @dev Ported from the review's EIP-712 cross-check: the digest matches forge's independent
    ///      typed-data implementation for any field values and chain.
    function testFuzz_DigestMatchesForgeEIP712(
        IReleaseVerifier.Authorization memory a,
        uint64 chainId
    ) public {
        vm.assume(chainId != 0);
        vm.chainId(chainId);
        assertEq(
            verifier.RELEASE_TYPEHASH(),
            vm.eip712HashType(
                "ReleaseAuthorization(address wallet,address asset,uint256 payee,address account,address recipient,uint256 amount,uint256 nonce,uint256 deadline)"
            )
        );
        assertEq(verifier.releaseDigest(a), vm.eip712HashTypedData(_json(a)));
    }

    function test_RelayerExecutesSignedReleaseOfExactAmount() public {
        IReleaseVerifier.Authorization memory a = _a(iAlice, alice, 2 ether, 1);
        bytes memory sig = _sign(alicePk, a);
        vm.expectEmit(true, true, false, true, address(verifier));
        emit IReleaseVerifier.NonceUsed(alice, 1, false);
        vm.expectEmit(true, true, true, true, address(ledger));
        emit ISplitWallet.Released(wallet, ETH, recipient, iAlice, alice, 2 ether, 10 ether);
        vm.prank(relayer);
        assertEq(_releaseSigned(a, sig), 2 ether);
        assertEq(recipient.balance, 2 ether);
        assertEq(_releasable(wallet, ETH, iAlice), 3 ether);
        assertTrue(verifier.nonceUsed(alice, 1));
    }

    function test_ArtistPullsBySignature() public {
        IReleaseVerifier.Authorization memory a = _a(iArtist, artistPayout, 2 ether, 1);
        vm.prank(relayer);
        assertEq(_releaseSigned(a, _sign(artistPk, a)), 2 ether);
        assertEq(recipient.balance, 2 ether);
    }

    function test_MaxAmountReleasesEverythingAndERC20Works() public {
        IReleaseVerifier.Authorization memory a = _a(iAlice, alice, type(uint256).max, 7);
        a.asset = address(token);
        assertEq(_releaseSigned(a, _sign(alicePk, a)), 500);
        assertEq(token.balanceOf(recipient), 500);
    }

    function test_ReplayAndRevokedNoncesRevert() public {
        IReleaseVerifier.Authorization memory a = _a(iAlice, alice, 1 ether, 1);
        bytes memory sig = _sign(alicePk, a);
        _releaseSigned(a, sig);
        vm.expectRevert(
            abi.encodeWithSelector(IReleaseVerifier.NonceAlreadyUsed.selector, alice, 1)
        );
        _releaseSigned(a, sig);

        IReleaseVerifier.Authorization memory b = _a(iAlice, alice, 1 ether, 2);
        bytes memory sigB = _sign(alicePk, b);
        vm.expectEmit(true, true, false, true, address(verifier));
        emit IReleaseVerifier.NonceUsed(alice, 2, true);
        vm.prank(alice);
        verifier.revokeNonce(2);
        vm.expectRevert(
            abi.encodeWithSelector(IReleaseVerifier.NonceAlreadyUsed.selector, alice, 2)
        );
        _releaseSigned(b, sigB);
        vm.expectRevert(
            abi.encodeWithSelector(IReleaseVerifier.NonceAlreadyUsed.selector, alice, 2)
        );
        vm.prank(alice);
        verifier.revokeNonce(2);
        assertEq(recipient.balance, 1 ether);
    }

    /// @dev Nonces live in a bitmap, 256 to a word: each nonce is independent of its neighbours
    ///      in the same word, and the word boundaries (255/256) and the extremes work.
    function test_NonceBitmapKeepsEveryNonceIndependent() public {
        uint256[6] memory nonces = [uint256(0), 1, 255, 256, 257, type(uint256).max];
        for (uint256 i; i < nonces.length; ++i) {
            assertFalse(verifier.nonceUsed(alice, nonces[i]));
            vm.expectEmit(true, true, false, true, address(verifier));
            emit IReleaseVerifier.NonceUsed(alice, nonces[i], true);
            vm.prank(alice);
            verifier.revokeNonce(nonces[i]);
            for (uint256 j; j < nonces.length; ++j) {
                assertEq(verifier.nonceUsed(alice, nonces[j]), j <= i, "only the used nonces");
            }
            assertFalse(verifier.nonceUsed(bob, nonces[i]), "per account");
        }
        assertFalse(verifier.nonceUsed(alice, 2));
        assertFalse(verifier.nonceUsed(alice, 254));
        assertFalse(verifier.nonceUsed(alice, 258));
        assertFalse(verifier.nonceUsed(alice, type(uint256).max - 1));

        // A signed release with the next nonce in a used word still works, and only once.
        IReleaseVerifier.Authorization memory a = _a(iAlice, alice, 1 ether, 2);
        bytes memory sig = _sign(alicePk, a);
        _releaseSigned(a, sig);
        assertTrue(verifier.nonceUsed(alice, 2));
        vm.expectRevert(
            abi.encodeWithSelector(IReleaseVerifier.NonceAlreadyUsed.selector, alice, 2)
        );
        _releaseSigned(a, sig);
        assertEq(recipient.balance, 1 ether);
    }

    /// @dev From the review of PR 54: a wrong bit mask (`& 0x7f`) would collide nonce `n` with
    ///      `n + 128` inside a word. Using 0 and 255 never marks 128 or 127, and a whole word used
    ///      leaves its neighbours untouched.
    function test_NonceBitmapNoAliasingWithinAWord() public {
        vm.startPrank(alice);
        verifier.revokeNonce(0);
        verifier.revokeNonce(255);
        vm.stopPrank();
        assertFalse(verifier.nonceUsed(alice, 128));
        assertFalse(verifier.nonceUsed(alice, 127));
        assertFalse(verifier.nonceUsed(alice, 256));
        assertFalse(verifier.nonceUsed(alice, 511));
        vm.startPrank(bob);
        for (uint256 n = 256; n < 512; ++n) {
            verifier.revokeNonce(n);
        }
        vm.stopPrank();
        for (uint256 n = 256; n < 512; ++n) {
            assertTrue(verifier.nonceUsed(bob, n));
        }
        assertFalse(verifier.nonceUsed(bob, 255));
        assertFalse(verifier.nonceUsed(bob, 512));
    }

    /// @dev Sequential nonces share a word: only the first in each 256 writes a new slot.
    function test_SequentialNoncesShareAStorageWord() public {
        vm.startPrank(alice);
        vm.record();
        verifier.revokeNonce(0);
        (, bytes32[] memory first) = vm.accesses(address(verifier));
        vm.record();
        verifier.revokeNonce(1);
        (, bytes32[] memory second) = vm.accesses(address(verifier));
        vm.record();
        verifier.revokeNonce(256);
        (, bytes32[] memory third) = vm.accesses(address(verifier));
        vm.stopPrank();
        assertEq(first.length, 1);
        assertEq(second.length, 1);
        assertEq(third.length, 1);
        assertEq(first[0], second[0], "nonces 0 and 1 share a word");
        assertTrue(first[0] != third[0], "nonce 256 starts the next word");
    }

    function test_OneRevocationCoversEveryWallet() public {
        address other = _wallet(_list(_fixed(alice, 50_000), _fixed(bob, 50_000)));
        vm.deal(address(other), 10 ether);
        IReleaseVerifier.Authorization memory a =
            _auth(other, ETH, _indexOf(other, alice), alice, recipient, 1 ether, 9);
        bytes memory sig = _sign(alicePk, a);
        vm.prank(alice);
        verifier.revokeNonce(9);
        vm.expectRevert(
            abi.encodeWithSelector(IReleaseVerifier.NonceAlreadyUsed.selector, alice, 9)
        );
        _releaseSigned(a, sig);
    }

    function test_ReplayIsKeyedOnTheNonceNotTheSignatureBytes() public {
        IReleaseVerifier.Authorization memory a = _a(iAlice, alice, 1 ether, 1);
        bytes32 digest = verifier.releaseDigest(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);
        (, bytes32 vs) = vm.signCompact(alicePk, digest);
        _releaseSigned(a, abi.encodePacked(r, s, v));
        // The ERC-2098 encoding of the same signature is different bytes, but the same nonce.
        vm.expectRevert(
            abi.encodeWithSelector(IReleaseVerifier.NonceAlreadyUsed.selector, alice, 1)
        );
        _releaseSigned(a, abi.encodePacked(r, vs));
        assertEq(recipient.balance, 1 ether);
    }

    function test_ExpiredAuthorizationReverts() public {
        IReleaseVerifier.Authorization memory a = _a(iAlice, alice, 1 ether, 1);
        bytes memory sig = _sign(alicePk, a);
        vm.warp(a.deadline);
        _releaseSigned(a, sig);
        IReleaseVerifier.Authorization memory b = _a(iAlice, alice, 1 ether, 2);
        b.deadline = block.timestamp - 1;
        bytes memory sigB = _sign(alicePk, b);
        vm.expectRevert(
            abi.encodeWithSelector(SignatureVerifier.SignatureExpired.selector, b.deadline)
        );
        _releaseSigned(b, sigB);
    }

    function test_WrongSignerOrTamperedFieldReverts() public {
        IReleaseVerifier.Authorization memory a = _a(iAlice, alice, 1 ether, 1);
        bytes memory bobSig = _sign(bobPk, a);
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, alice));
        _releaseSigned(a, bobSig);

        bytes memory sig = _sign(alicePk, a);
        a.recipient = relayer;
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, alice));
        _releaseSigned(a, sig);
        a.recipient = recipient;
        a.amount = 2 ether;
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, alice));
        _releaseSigned(a, sig);
        a.amount = 1 ether;
        a.asset = address(token);
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, alice));
        _releaseSigned(a, sig);
        assertFalse(verifier.nonceUsed(alice, 1));
    }

    function test_AccountMustBeThePayeesCurrentPayoutAddress() public {
        IReleaseVerifier.Authorization memory a = _a(iAlice, bob, 1 ether, 1);
        bytes memory sig = _sign(bobPk, a);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, bob, alice));
        _releaseSigned(a, sig);
    }

    function test_ArtistSignatureFromReplacedKeyStopsWorking() public {
        IReleaseVerifier.Authorization memory a = _a(iArtist, artistPayout, 1 ether, 1);
        bytes memory sig = _sign(artistPk, a);
        address recovered = makeAddr("recovered");
        resolver.set(ARTIST, recovered);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, artistPayout, recovered)
        );
        _releaseSigned(a, sig);
        resolver.set(ARTIST, artistPayout);
        assertEq(_releaseSigned(a, sig), 1 ether);
    }

    /// @dev Documents a review nit, ported from `test_R2_H1_OldSignatureDiesOnChangeAndRevivesOnReturn`:
    ///      rotating the payout away does not revoke a signature; A -> B -> A revives it, so an
    ///      artist revokes outstanding nonces explicitly.
    function test_RotatingThePayoutAwayDoesNotRevokeSignatures() public {
        IReleaseVerifier.Authorization memory a = _a(iArtist, artistPayout, type(uint256).max, 42);
        bytes memory sig = _sign(artistPk, a);
        address b = makeAddr("B");
        resolver.set(ARTIST, b);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, artistPayout, b)
        );
        _releaseSigned(a, sig);

        resolver.set(ARTIST, artistPayout);
        uint256 snap = vm.snapshotState();
        assertEq(_releaseSigned(a, sig), 2 ether, "revived on return");
        vm.revertToState(snap);

        // The mitigation: revoke the nonce explicitly.
        vm.prank(artistPayout);
        verifier.revokeNonce(42);
        vm.expectRevert(
            abi.encodeWithSelector(IReleaseVerifier.NonceAlreadyUsed.selector, artistPayout, 42)
        );
        _releaseSigned(a, sig);
    }

    /// @dev Documents a review nit: anyone may push a fixed payee's balance to its own account
    ///      first; the payee's signed exact-amount release then reverts without consuming its
    ///      nonce, and the funds already sit in the payee's account. A max-amount signature takes
    ///      whatever is due instead.
    function test_PushCanPreemptAFixedPayeesSignedRelease() public {
        IReleaseVerifier.Authorization memory a = _a(iAlice, alice, 5 ether, 1);
        bytes memory sig = _sign(alicePk, a);
        vm.prank(makeAddr("anyone"));
        _release(wallet, ETH, iAlice);
        assertEq(alice.balance, 5 ether);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.AmountExceedsReleasable.selector, 5 ether, 0)
        );
        _releaseSigned(a, sig);
        assertFalse(verifier.nonceUsed(alice, 1));

        vm.deal(address(wallet), address(wallet).balance + 2 ether);
        IReleaseVerifier.Authorization memory all = _a(iAlice, alice, type(uint256).max, 2);
        assertEq(_releaseSigned(all, _sign(alicePk, all)), 1 ether);
    }

    /// @dev An authorization names its wallet, and the ledger derives the wallet from the payee
    ///      list and salt submitted with it: submitted with another wallet's configuration, or
    ///      with this wallet's payees under another salt, it reverts with `WrongWallet` before
    ///      any signature check, and its nonce stays unused. There is no other entry point that
    ///      consumes a nonce without executing the release (the old `consume` is gone).
    function test_OnlyTheNamedWalletConsumesAnAuthorization() public {
        address other = _wallet(_list(_fixed(alice, 50_000), _fixed(bob, 50_000)));
        vm.deal(address(other), 10 ether);
        IReleaseVerifier.Authorization memory a = _a(_indexOf(other, alice), alice, 1 ether, 1);
        bytes memory sig = _sign(alicePk, a);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.WrongWallet.selector, address(wallet), other)
        );
        vm.prank(relayer);
        ledger.releaseWithAuthorization(_payeesOf(other), _salts[other], a, sig);

        bytes32 salt = bytes32(uint256(1));
        address sibling = ledger.walletFor(_payeesOf(wallet), salt);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.WrongWallet.selector, address(wallet), sibling)
        );
        ledger.releaseWithAuthorization(_payeesOf(wallet), salt, a, sig);
        assertFalse(verifier.nonceUsed(alice, 1));
        assertEq(alice.balance + recipient.balance, 0);
    }

    /// @dev A signed release from a wallet that is not deployed yet moves nothing and consumes
    ///      nothing: the ledger checks the outcome of the move (the balance fell by exactly the
    ///      amount), so a call to an address without code cannot be counted as a release.
    function test_SignedReleaseFromAnUndeployedWalletRevertsWithoutConsumingNonce() public {
        ISplitWallet.Payee[] memory payees = _list(_fixed(alice, D));
        address predicted = _remember(payees, bytes32(0));
        vm.deal(predicted, 1 ether);
        IReleaseVerifier.Authorization memory a =
            _auth(predicted, ETH, 0, alice, recipient, 1 ether, 4);
        bytes memory sig = _sign(alicePk, a);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.WalletNotDeployed.selector, predicted));
        _releaseSigned(a, sig);
        assertFalse(verifier.nonceUsed(alice, 4));
        assertEq(predicted.balance, 1 ether);
        assertEq(ledger.totalReleased(predicted, ETH), 0);

        // Once anyone deploys it, the same signature works.
        ledger.createWallet(payees, bytes32(0));
        assertEq(_releaseSigned(a, sig), 1 ether);
        assertEq(recipient.balance, 1 ether);
    }

    function test_SignatureDoesNotReplayOnAnotherChainOrVerifier() public {
        IReleaseVerifier.Authorization memory a = _a(iAlice, alice, 1 ether, 2);
        bytes memory sig = _sign(alicePk, a);
        uint256 chain = block.chainid;
        vm.chainId(chain + 1);
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, alice));
        _releaseSigned(a, sig);
        vm.chainId(chain);
        SplitLedger other = new SplitLedger(resolver, address(feeVault));
        assertTrue(other.releaseDigest(a) != verifier.releaseDigest(a));
    }

    function test_AmountAboveReleasableRevertsWithoutConsumingNonce() public {
        IReleaseVerifier.Authorization memory a = _a(iAlice, alice, 6 ether, 1);
        bytes memory sig = _sign(alicePk, a);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.AmountExceedsReleasable.selector, 6 ether, 5 ether)
        );
        _releaseSigned(a, sig);
        assertFalse(verifier.nonceUsed(alice, 1));
        // New receipts make the same signature usable: amounts are bounds, not snapshots.
        vm.deal(address(wallet), 12 ether);
        assertEq(_releaseSigned(a, sig), 6 ether);
    }

    function test_FailedPaymentRollsBackNonce() public {
        IReleaseVerifier.Authorization memory a = _a(iAlice, alice, 1 ether, 1);
        a.recipient = address(new RejectingRecipient());
        bytes memory sig = _sign(alicePk, a);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.ETHTransferFailed.selector, a.recipient, 1 ether)
        );
        _releaseSigned(a, sig);
        assertFalse(verifier.nonceUsed(alice, 1));
        assertEq(ledger.totalReleased(wallet, ETH), 0);
    }

    function test_CompactERC2098SignatureIsAccepted() public {
        IReleaseVerifier.Authorization memory a = _a(iAlice, alice, 1 ether, 1);
        (bytes32 r, bytes32 vs) = vm.signCompact(alicePk, verifier.releaseDigest(a));
        assertEq(_releaseSigned(a, abi.encodePacked(r, vs)), 1 ether);
    }

    function test_ContractPayeeSignsWithERC1271() public {
        Mock1271Account safe = new Mock1271Account();
        address w = _solo(address(safe));
        vm.deal(address(w), 1 ether);
        IReleaseVerifier.Authorization memory a =
            _auth(w, ETH, 0, address(safe), recipient, 1 ether, 1);
        vm.expectRevert(
            abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, address(safe))
        );
        _releaseSigned(a, "");
        safe.accept(verifier.releaseDigest(a));
        assertEq(_releaseSigned(a, ""), 1 ether);
        assertEq(recipient.balance, 1 ether);
    }

    function testFuzz_SignedPartialReleasesNeverExceedEntitlement(uint256 first, uint256 second)
        public
    {
        first = bound(first, 1, 5 ether);
        second = bound(second, 1, 10 ether);
        IReleaseVerifier.Authorization memory a = _a(iAlice, alice, first, 1);
        _releaseSigned(a, _sign(alicePk, a));
        IReleaseVerifier.Authorization memory b = _a(iAlice, alice, second, 2);
        bytes memory sigB = _sign(alicePk, b);
        if (first + second > 5 ether) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    ISplitWallet.AmountExceedsReleasable.selector, second, 5 ether - first
                )
            );
        }
        _releaseSigned(b, sigB);
        assertLe(ledger.released(wallet, ETH, iAlice), 5 ether);
        assertEq(recipient.balance, ledger.released(wallet, ETH, iAlice));
    }

    function _json(IReleaseVerifier.Authorization memory a) internal view returns (string memory) {
        string memory types = string.concat(
            '{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},',
            '{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],',
            '"ReleaseAuthorization":[{"name":"wallet","type":"address"},{"name":"asset","type":"address"},',
            '{"name":"payee","type":"uint256"},{"name":"account","type":"address"},',
            '{"name":"recipient","type":"address"},{"name":"amount","type":"uint256"},',
            '{"name":"nonce","type":"uint256"},{"name":"deadline","type":"uint256"}]},'
        );
        string memory domain = string.concat(
            '"primaryType":"ReleaseAuthorization","domain":{"name":"6529 Stream Release Verifier",',
            '"version":"1","chainId":"',
            vm.toString(block.chainid),
            '","verifyingContract":"',
            vm.toString(address(verifier)),
            '"},'
        );
        string memory message = string.concat(
            '"message":{"wallet":"',
            vm.toString(a.wallet),
            '","asset":"',
            vm.toString(a.asset),
            '","payee":"',
            vm.toString(a.payee),
            '","account":"',
            vm.toString(a.account),
            '","recipient":"',
            vm.toString(a.recipient),
            '","amount":"',
            vm.toString(a.amount),
            '","nonce":"',
            vm.toString(a.nonce),
            '","deadline":"',
            vm.toString(a.deadline),
            '"}}'
        );
        return string.concat(types, domain, message);
    }
}

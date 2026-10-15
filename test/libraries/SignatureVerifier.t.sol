// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import {
    ReturnDataMock,
    GasBurnerMock,
    ReturnBombMock,
    ERC1271WalletMock,
    Delegate1271Mock
} from "../mocks/libraries/AdversarialTargets.sol";

contract SignatureVerifierHarness {
    function isValid(address signer, bytes32 digest, bytes calldata signature)
        external
        view
        returns (bool)
    {
        return SignatureVerifier.isValid(signer, digest, signature);
    }

    /// @dev OpenZeppelin's checker, for documenting where the two deliberately differ.
    function ozIsValid(address signer, bytes32 digest, bytes calldata signature)
        external
        view
        returns (bool)
    {
        return SignatureChecker.isValidSignatureNow(signer, digest, signature);
    }
}

/// @dev Burns `burn` gas inside `isValidSignature`, then returns the magic value.
contract SlowWalletMock {
    uint256 internal immutable burn;

    constructor(uint256 burn_) {
        burn = burn_;
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        uint256 stop = gasleft() - burn;
        while (gasleft() > stop) { }
        return 0x1626ba7e;
    }
}

contract SignatureVerifierTest is Test {
    uint256 internal constant N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant CAP = SignatureVerifier.ERC1271_GAS_LIMIT;
    bytes32 internal constant MAGIC = bytes32(bytes4(0x1626ba7e));

    SignatureVerifierHarness internal harness;
    uint256 internal key = 0xA11CE;
    address internal signer;
    bytes32 internal digest = keccak256("6529 Stream v1");

    function setUp() public {
        harness = new SignatureVerifierHarness();
        signer = vm.addr(key);
    }

    function _sign(uint256 k, bytes32 d)
        internal
        pure
        returns (bytes memory full, bytes memory compact)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(k, d);
        full = abi.encodePacked(r, s, v);
        compact = abi.encodePacked(r, bytes32(uint256(s) | (uint256(v - 27) << 255)));
    }

    // ---------------------------------------------------------------- ECDSA

    function test_EOA_65And64ByteSignatures() public view {
        (bytes memory full, bytes memory compact) = _sign(key, digest);
        assertEq(full.length, 65);
        assertEq(compact.length, 64);
        assertTrue(harness.isValid(signer, digest, full));
        assertTrue(harness.isValid(signer, digest, compact));
        // OpenZeppelin's bytes overload rejects ERC-2098; this library accepts it.
        assertFalse(harness.ozIsValid(signer, digest, compact));
    }

    function test_EOA_CompactFormCoversBothRecoveryIds() public view {
        bool[2] memory seen;
        for (uint256 i; i < 64 && !(seen[0] && seen[1]); ++i) {
            bytes32 d = keccak256(abi.encode(i));
            (uint8 v,,) = vm.sign(key, d);
            (, bytes memory compact) = _sign(key, d);
            assertTrue(harness.isValid(signer, d, compact));
            seen[v - 27] = true;
        }
        assertTrue(seen[0] && seen[1], "both v values exercised");
    }

    function test_EOA_HighSRejected() public view {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        bytes32 highS = bytes32(N - uint256(s));
        uint8 flipped = v == 27 ? 28 : 27;
        // The malleable twin really recovers the signer at the precompile level...
        assertEq(ecrecover(digest, flipped, r, highS), signer);
        // ...and is rejected.
        assertFalse(harness.isValid(signer, digest, abi.encodePacked(r, highS, flipped)));
    }

    function test_EOA_RecoveryIdOutsideRangeRejected() public view {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        uint8[5] memory bad = [0, 1, 26, 29, 255];
        for (uint256 i; i < bad.length; ++i) {
            assertFalse(harness.isValid(signer, digest, abi.encodePacked(r, s, bad[i])));
        }
        assertFalse(harness.isValid(signer, digest, abi.encodePacked(r, s, v - 27)));
    }

    function test_EOA_WrongSignerOrDigestRejected() public view {
        (bytes memory full, bytes memory compact) = _sign(key, digest);
        assertFalse(harness.isValid(vm.addr(0xB0B), digest, full));
        assertFalse(harness.isValid(signer, keccak256("other"), full));
        assertFalse(harness.isValid(signer, keccak256("other"), compact));
    }

    function test_EOA_OtherLengthsRejected() public view {
        (bytes memory full,) = _sign(key, digest);
        uint256[6] memory lengths = [uint256(0), 1, 32, 63, 66, 130];
        for (uint256 i; i < lengths.length; ++i) {
            bytes memory sig = new bytes(lengths[i]);
            for (uint256 j; j < sig.length && j < full.length; ++j) {
                sig[j] = full[j];
            }
            assertFalse(harness.isValid(signer, digest, sig));
        }
    }

    function test_ZeroSignerNeverValid() public view {
        // r = 0 makes ecrecover return the zero address.
        bytes memory zeroR = abi.encodePacked(bytes32(0), bytes32(uint256(1)), uint8(27));
        assertEq(ecrecover(digest, 27, 0, bytes32(uint256(1))), address(0));
        assertFalse(harness.isValid(address(0), digest, zeroR));
        assertFalse(harness.isValid(address(0), digest, ""));
    }

    function testFuzz_ECDSAForms(uint256 k, bytes32 d, bytes32 other) public view {
        k = bound(k, 1, N - 1);
        vm.assume(other != d);
        address who = vm.addr(k);
        (bytes memory full, bytes memory compact) = _sign(k, d);
        assertTrue(harness.isValid(who, d, full));
        assertTrue(harness.isValid(who, d, compact));
        assertFalse(harness.isValid(who, other, full));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(k, d);
        assertFalse(
            harness.isValid(who, d, abi.encodePacked(r, bytes32(N - uint256(s)), v == 27 ? 28 : 27))
        );
    }

    // ---------------------------------------------------------------- size cap

    function test_SignatureLengthCapAppliesBeforeAnyCall() public {
        ReturnDataMock acceptAll = new ReturnDataMock();
        acceptAll.configure(abi.encodePacked(MAGIC), false);
        bytes memory atCap = new bytes(SignatureVerifier.MAX_SIGNATURE_LENGTH);
        bytes memory overCap = new bytes(SignatureVerifier.MAX_SIGNATURE_LENGTH + 1);
        assertTrue(harness.isValid(address(acceptAll), digest, atCap));
        assertFalse(harness.isValid(address(acceptAll), digest, overCap));
    }

    // ---------------------------------------------------------------- EIP-7702

    function test_7702_DelegatedEOAVerifiedByEcrecover() public {
        vm.signAndAttachDelegation(address(new Delegate1271Mock()), key);
        assertEq(signer.code.length, 23);
        (bytes memory full, bytes memory compact) = _sign(key, digest);
        assertTrue(harness.isValid(signer, digest, full));
        assertTrue(harness.isValid(signer, digest, compact));
        // OpenZeppelin only asks the delegate, which does not know the ECDSA key.
        assertFalse(harness.ozIsValid(signer, digest, full));
    }

    function test_7702_FallsBackToDelegateERC1271() public {
        vm.signAndAttachDelegation(address(new Delegate1271Mock()), key);
        assertTrue(harness.isValid(signer, digest, abi.encode(digest, "7702")));
        assertFalse(harness.isValid(signer, digest, abi.encode(digest, "other")));
        // A 64-byte non-ECDSA blob fails ecrecover and then the delegate.
        assertFalse(harness.isValid(signer, digest, abi.encode(digest, digest)));
    }

    function test_7702_DelegateWithoutERC1271StillAcceptsOwnKey() public {
        vm.signAndAttachDelegation(address(new GasBurnerMock()), key);
        (bytes memory full,) = _sign(key, digest);
        assertTrue(harness.isValid(signer, digest, full));
        (bytes memory foreign,) = _sign(0xB0B, digest);
        assertFalse(harness.isValid(signer, digest, foreign));
    }

    // ---------------------------------------------------------------- ERC-1271

    function test_1271_Success() public {
        ERC1271WalletMock wallet = new ERC1271WalletMock(signer);
        (bytes memory full,) = _sign(key, digest);
        assertTrue(harness.isValid(address(wallet), digest, full));
        (bytes memory foreign,) = _sign(0xB0B, digest);
        assertFalse(harness.isValid(address(wallet), digest, foreign));
    }

    function test_1271_WrongMagicValues() public {
        ReturnDataMock wallet = new ReturnDataMock();
        bytes[8] memory answers = [
            abi.encode(bytes4(0xffffffff)),
            abi.encode(uint256(0x1626ba7e)), // right-aligned
            abi.encodePacked(bytes32(uint256(MAGIC) | 1)), // dirty low bytes
            abi.encodePacked(bytes4(0x1626ba7e)), // 4 bytes only
            abi.encodePacked(bytes31(MAGIC)), // 31 bytes
            abi.encodePacked(MAGIC, bytes1(0)), // 33 bytes
            abi.encodePacked(MAGIC, bytes32(0)), // 64 bytes
            bytes("")
        ];
        for (uint256 i; i < answers.length; ++i) {
            wallet.configure(answers[i], false);
            assertFalse(harness.isValid(address(wallet), digest, hex"01"), vm.toString(i));
        }
        wallet.configure(abi.encodePacked(MAGIC), false);
        assertTrue(harness.isValid(address(wallet), digest, hex"01"));
        // Reverting with the magic value is still a rejection.
        wallet.configure(abi.encodePacked(MAGIC), true);
        assertFalse(harness.isValid(address(wallet), digest, hex"01"));
    }

    function test_1271_LongerReturnAcceptedByOZButNotHere() public {
        ReturnDataMock wallet = new ReturnDataMock();
        wallet.configure(abi.encodePacked(MAGIC, bytes32(0)), false);
        assertTrue(harness.ozIsValid(address(wallet), digest, hex"01"));
        assertFalse(harness.isValid(address(wallet), digest, hex"01"));
    }

    function test_1271_GasStarvedCallReverts() public {
        ERC1271WalletMock wallet = new ERC1271WalletMock(signer);
        (bytes memory full,) = _sign(key, digest);
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallInsufficientGas.selector, CAP)
        );
        harness.isValid{ gas: CAP }(address(wallet), digest, full);
    }

    function test_1271_WalletGetsTheFullCap() public {
        // Needs most of the cap: succeeds, because the cap is forwarded in full.
        SlowWalletMock slow = new SlowWalletMock(CAP - 10_000);
        assertTrue(harness.isValid(address(slow), digest, hex"01"));
        // Needs more than the cap: rejected, not reverted.
        SlowWalletMock slower = new SlowWalletMock(CAP + 1_000);
        assertFalse(harness.isValid(address(slower), digest, hex"01"));
    }

    function test_1271_GasBombCostsAtMostTheCap() public {
        GasBurnerMock burner = new GasBurnerMock();
        uint256 before = gasleft();
        assertFalse(harness.isValid(address(burner), digest, hex"01"));
        uint256 used = before - gasleft();
        assertGe(used, CAP);
        assertLe(used, CAP + 25_000);
    }

    function test_1271_ReturnDataBomb() public {
        // 96 KB of return data whose first word is the magic value.
        ReturnBombMock bomb = new ReturnBombMock(96 * 1024, MAGIC);
        uint256 before = gasleft();
        assertFalse(harness.isValid(address(bomb), digest, hex"01"));
        uint256 used = before - gasleft();
        // The bomb's own memory is paid from the cap; nothing is copied back.
        assertLe(used, CAP + 25_000);
        // OpenZeppelin accepts the same answer.
        assertTrue(harness.ozIsValid(address(bomb), digest, hex"01"));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { ProtocolContracts } from "src/libraries/ProtocolContracts.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { Burner, GasRuleAssertions } from "../helpers/GasRule.sol";
import { ERC1271WalletMock, Erc165Shapes } from "../mocks/libraries/AdversarialTargets.sol";

/// @dev The library functions that call out, as external views. Uses only interfaces that
///      predate the forward-all family, so this suite also runs against earlier libraries.
contract LibraryUsersHarness {
    function isInstallable(address dependency, bytes4 id) external view returns (bool) {
        return Dependency.isInstallable(dependency, id);
    }

    function isProtocolContract(address account) external view returns (bool) {
        return ProtocolContracts.isProtocolContract(account);
    }

    function isValidSignature(address signer, bytes32 digest, bytes calldata signature)
        external
        view
        returns (bool)
    {
        return SignatureVerifier.isValid(signer, digest, signature);
    }
}

/// @notice The gas rule for every library function that calls another contract: the ERC-1271
///         check (`SignatureVerifier`), the install check's ERC-165 probe (`Dependency`) and the
///         protocol-contract probe (`ProtocolContracts`). Each dependency is wrapped in a
///         `Burner` costing 1x, 2x, 4x, 10x and 100x its base: the answer never changes, and a
///         shortfall reverts with `BoundedCall.BoundedCallShortfall`, never yielding an answer.
contract GasRuleLibrariesTest is GasRuleAssertions {
    LibraryUsersHarness internal harness;

    function setUp() public {
        harness = new LibraryUsersHarness();
    }

    /// @dev ERC-1271 through a wallet costing 1x to 100x its base: always valid with enough gas;
    ///      short of gas, never "invalid".
    function test_GasRule_Erc1271_SameAnswerAtEveryMultipleAndShortfallReverts() public {
        uint256 key = 0xA11CE;
        bytes32 digest = keccak256("6529 Stream v1");
        Burner wallet = new Burner(address(new ERC1271WalletMock(vm.addr(key))), 10_000);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        bytes memory call = abi.encodeCall(
            LibraryUsersHarness.isValidSignature,
            (address(wallet), digest, abi.encodePacked(r, s, v))
        );
        Outcome memory o = _assertSameAtEveryMultiple(wallet, address(this), address(harness), call);
        assertEq(o.data, abi.encode(true));
        wallet.burnerSetMultiple(10);
        _assertShortfallNeverAnswers(wallet, address(this), address(harness), call);

        // A signature from another key: "invalid" at every multiple, and short of gas never
        // anything else but the shortfall.
        (v, r, s) = vm.sign(0xB0B, digest);
        call = abi.encodeCall(
            LibraryUsersHarness.isValidSignature,
            (address(wallet), digest, abi.encodePacked(r, s, v))
        );
        o = _assertSameAtEveryMultiple(wallet, address(this), address(harness), call);
        assertEq(o.data, abi.encode(false));
        wallet.burnerSetMultiple(10);
        _assertShortfallNeverAnswers(wallet, address(this), address(harness), call);
    }

    /// @dev `Dependency`'s install check: installable at every multiple; short of gas, the
    ///      shortfall error, never "refused".
    function test_GasRule_Dependency_SameAnswerAtEveryMultipleAndShortfallReverts() public {
        bytes4 id = 0x12345678;
        Burner dependency =
            new Burner(address(new Erc165Shapes(Erc165Shapes.Shape.COMPLIANT, id)), 10_000);
        bytes memory call =
            abi.encodeCall(LibraryUsersHarness.isInstallable, (address(dependency), id));
        Outcome memory o =
            _assertSameAtEveryMultiple(dependency, address(this), address(harness), call);
        assertEq(o.data, abi.encode(true));
        dependency.burnerSetMultiple(10);
        _assertShortfallNeverAnswers(dependency, address(this), address(harness), call);
    }

    /// @dev `ProtocolContracts`: a protocol contract is recognised at every multiple, and short
    ///      of gas the check reverts, never answering "not a protocol contract" (which would
    ///      accept it as a payout). A plain contract is "not one" at every multiple.
    function test_GasRule_ProtocolContracts_SameAnswerAtEveryMultipleAndShortfallReverts() public {
        bytes4[2] memory ids = [type(IMintTarget).interfaceId, type(IWorkRecords).interfaceId];
        for (uint256 i; i < ids.length; ++i) {
            Burner protocol = new Burner(
                address(new Erc165Shapes(Erc165Shapes.Shape.COMPLIANT, ids[i])), 10_000
            );
            bytes memory call =
                abi.encodeCall(LibraryUsersHarness.isProtocolContract, (address(protocol)));
            Outcome memory o =
                _assertSameAtEveryMultiple(protocol, address(this), address(harness), call);
            assertEq(o.data, abi.encode(true));
            protocol.burnerSetMultiple(10);
            _assertShortfallNeverAnswers(protocol, address(this), address(harness), call);
        }
        Burner plain = new Burner(
            address(new Erc165Shapes(Erc165Shapes.Shape.COMPLIANT, 0x12345678)), 10_000
        );
        bytes memory plainCall =
            abi.encodeCall(LibraryUsersHarness.isProtocolContract, (address(plain)));
        Outcome memory none =
            _assertSameAtEveryMultiple(plain, address(this), address(harness), plainCall);
        assertEq(none.data, abi.encode(false));
        plain.burnerSetMultiple(10);
        _assertShortfallNeverAnswers(plain, address(this), address(harness), plainCall);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { ConsolidationAdapter, IDelegationManagement } from "src/identity/ConsolidationAdapter.sol";
import { IAccounts } from "src/interfaces/core/IAccounts.sol";
import { IConsolidationSource } from "src/interfaces/IArtistRegistry.sol";
import { Burner, GasRuleAssertions } from "../helpers/GasRule.sol";
import { ConsolidationSourceMock } from "../mocks/identity/IdentityWorksMocks.sol";
import { AccountsFixture } from "./AccountsFixture.sol";

/// @notice The gas rule on the registry's one live read: whether a wallet is consolidated with
///         an account's root. With the source costing 1x to 100x its base, the answer is the
///         same; run short, the call reverts with `BoundedCallShortfall`, never "not a wallet".
contract AccountsGasRuleTest is AccountsFixture, GasRuleAssertions {
    Burner internal burner;

    function setUp() public override {
        super.setUp();
        ConsolidationSourceMock source = new ConsolidationSourceMock();
        source.set(artist, wallet, true);
        burner = new Burner(address(source), 20_000);
        vm.prank(network);
        registry.setConsolidationSource(
            adapter, IConsolidationSource(address(burner)), address(burner).codehash
        );
    }

    function test_GasRule_RequireSignedNeverAnswersForGas() public {
        bytes32 digest = keccak256("message");
        bytes memory data =
            abi.encodeCall(IAccounts.requireSigned, (artistId, digest, _proof(walletKey, digest)));
        Outcome memory o = _assertSameAtEveryMultiple(burner, stranger, address(registry), data);
        assertTrue(o.ok);
        assertEq(abi.decode(o.data, (address)), wallet);
        burner.burnerSetMultiple(10);
        _assertShortfallNeverAnswers(burner, stranger, address(registry), data);
    }

    function test_GasRule_IsWalletNeverAnswersForGas() public {
        bytes memory data = abi.encodeCall(IAccounts.isWallet, (artistId, wallet));
        Outcome memory o = _assertSameAtEveryMultiple(burner, stranger, address(registry), data);
        assertTrue(abi.decode(o.data, (bool)));
        for (uint256 i = 1; i < gasRuleMultiples.length - 1; ++i) {
            burner.burnerSetMultiple(gasRuleMultiples[i]);
            _assertShortfallNeverAnswers(burner, stranger, address(registry), data);
        }
    }

    /// @dev A wallet-signed own change: the staging reads the source twice (new root, signer).
    function test_GasRule_StageChangeNeverAnswersForGas() public {
        bytes memory data = _changeCall(walletKey, _identity(artist, payout));
        Outcome memory o = _assertSameAtEveryMultiple(burner, stranger, address(registry), data);
        assertTrue(o.ok);
        burner.burnerSetMultiple(4);
        _assertShortfallNeverAnswers(burner, stranger, address(registry), data);
    }

    /// @dev The root never reads the source, whatever it costs.
    function test_GasRule_TheRootNeverReadsTheSource() public {
        burner.burnerSetBase(30_000_000);
        bytes32 digest = keccak256("message");
        assertEq(registry.requireSigned(artistId, digest, _proof(artistKey, digest)), artist);
        assertTrue(registry.isWallet(artistId, artist));
    }

    /// @dev The v1 adapter forwards all gas to the delegation contract too: a delegation read
    ///      that runs short is a shortfall, never "not consolidated".
    function test_GasRule_AdapterNeverAnswersForGas() public {
        Burner slow = new Burner(address(delegation), 20_000);
        ConsolidationAdapter a = new ConsolidationAdapter(IDelegationManagement(address(slow)));
        bytes memory data = abi.encodeCall(IConsolidationSource.isConsolidated, (artist, wallet));
        Outcome memory o = _assertSameAtEveryMultiple(slow, stranger, address(a), data);
        assertTrue(abi.decode(o.data, (bool)));
        slow.burnerSetMultiple(4);
        _assertShortfallNeverAnswers(slow, stranger, address(a), data);
    }
}

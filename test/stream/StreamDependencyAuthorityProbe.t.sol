// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IStream } from "src/interfaces/IStream.sol";
import { MockEntropy } from "../mocks/stream/StreamMocks.sol";
import { StreamFixture } from "./StreamFixture.sol";

/// @dev An entropy module governed by another manager, whose `authority()` reverts cheaply when it
///      is given little gas, as a fixed-gas guard does: a refusal to the forward-all probe.
contract GasGatedAuthorityEntropy is MockEntropy {
    address internal immutable _other;
    uint256 internal immutable _threshold;

    constructor(address other, uint256 threshold) {
        _other = other;
        _threshold = threshold;
    }

    function authority() external view returns (address) {
        require(gasleft() >= _threshold, "short");
        return _other;
    }
}

/// @notice `Stream.setDependency`'s `authority()` probe reads a refusal as "no authority to
///         check" and installs the replacement. The probe catches a replacement that answers
///         another manager; it does not catch one that refuses, whatever the reason.
contract StreamDependencyAuthorityProbeTest is StreamFixture {
    /// @dev A replacement that answers another manager is refused; the same replacement, given
    ///      an execution gas at which its `authority()` refuses, is installed. Only the network
    ///      (SUCCESSOR_SETTER, 7 days) executes `setDependency`, and it picks the gas.
    function test_setDependency_aReplacementWhoseAuthorityRefusesIsInstalled() public {
        address otherManager = makeAddr("otherManager");
        GasGatedAuthorityEntropy next = new GasGatedAuthorityEntropy(otherManager, 1_000_000);
        bytes memory call = abi.encodeCall(
            stream.setDependency, ("ENTROPY_MODULE", address(entropy), address(next))
        );

        vm.prank(governor);
        (bool ok, bytes memory reason) = address(stream).call{ gas: 5_000_000 }(call);
        assertFalse(ok, "answers another manager: refused");
        assertEq(bytes4(reason), IStream.InvalidBinding.selector);

        // Enough gas for the call, not enough for `authority()` to answer: read as a refusal.
        vm.prank(governor);
        (ok,) = address(stream).call{ gas: 900_000 }(call);
        assertTrue(ok, "installed without its authority checked");
        assertEq(stream.entropyModule(), address(next));
    }
}

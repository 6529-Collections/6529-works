// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Deploy } from "script/Deploy.s.sol";

/// @notice The deploy script's off-anvil guards: a public-network run must name its own genesis
///         configuration, and no holder in it may be a placeholder.
contract DeployScriptTest is Test {
    string internal constant EXAMPLE = "config/genesis.example.json";
    string internal constant SEPOLIA = "config/genesis.sepolia.json";
    /// The example's holders are `0x…b0xx`; filled holders keep the suffix behind a high digit.
    string internal constant PLACEHOLDER_PREFIX = "0x000000000000000000000000000000000000b0";
    string internal constant FILLED_PREFIX = "0x100000000000000000000000000000000000b0";

    Deploy internal script;
    string internal example;

    function setUp() public {
        script = new Deploy();
        example = vm.readFile(EXAMPLE);
    }

    /// @dev The example with every `0x…b0xx` holder moved to a non-placeholder address.
    function _filled() internal view returns (string memory) {
        return vm.replace(example, PLACEHOLDER_PREFIX, FILLED_PREFIX);
    }

    function test_AnvilAcceptsTheExample() public view {
        script.checkGenesis(EXAMPLE, example, true);
    }

    function test_OffAnvilTheExampleIsRefused() public {
        vm.expectRevert(Deploy.ExampleGenesisOffAnvil.selector);
        script.checkGenesis(EXAMPLE, example, false);
    }

    function test_OffAnvilACopiedExampleWithPlaceholderHoldersIsRefused() public {
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.PlaceholderHolder.selector, "ADMIN", address(0xB001))
        );
        script.checkGenesis(SEPOLIA, example, false);
    }

    function test_OffAnvilOneRemainingPlaceholderIsRefused() public {
        // Fill every holder, then put the curator back on its placeholder.
        string memory json = vm.replace(
            _filled(), string.concat(FILLED_PREFIX, "61"), string.concat(PLACEHOLDER_PREFIX, "61")
        );
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.PlaceholderHolder.selector, "CURATOR", address(0xB061))
        );
        script.checkGenesis(SEPOLIA, json, false);
    }

    function test_OffAnvilRealHoldersPass() public view {
        script.checkGenesis(SEPOLIA, _filled(), false);
    }
}

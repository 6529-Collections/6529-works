// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { CoreNetworkFlows } from "./CoreNetworkFlows.sol";

/// @notice The network's waiting-period flows with the network as one key. The same flows run
///         through a real Safe in `test/fork/SafeCoreNetwork.t.sol`.
contract CoreNetworkTest is CoreNetworkFlows {
    function _networkAccount() internal override returns (address) {
        return makeAddr("network");
    }
}

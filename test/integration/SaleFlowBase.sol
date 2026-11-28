// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { PRODUCT_STREAM, WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import { Party, PartyRole } from "src/interfaces/types/PackageTypes.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice A contract wallet with no ERC-721 receiver: it bids and claims through `exec`, and a
///         safe transfer of a token to it fails.
contract ContractWallet {
    function exec(address target, uint256 value, bytes calldata data)
        external
        returns (bytes memory)
    {
        (bool ok, bytes memory ret) = target.call{ value: value }(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    receive() external payable { }
}

/// @notice Helpers shared by the sale, museum, dispute, VRF and release suites: a collaboration
///         with a canonical (sorted) payee list, the terms a work locks, its royalty vault's
///         payees and payee lookups.
abstract contract SaleFlowBase is IntegrationBase {
    uint256 internal constant DENOMINATOR = 100_000;

    /// @dev `w` with `collaborator` as a second party and an artist-resolved payee with `share`;
    ///      the payee list sorted by artist ID, as the registry requires.
    function _collab(Work memory w, address collaborator, uint32 share)
        internal
        pure
        returns (Work memory)
    {
        address lead = w.item.parties[0].account;
        Party[] memory parties = new Party[](2);
        parties[0] = Party(lead, uint8(PartyRole.ARTIST));
        parties[1] = Party(collaborator, uint8(PartyRole.COLLABORATOR));
        w.item.parties = parties;
        ISplitWallet.Payee memory a =
            ISplitWallet.Payee(uint256(uint160(lead)), address(0), 100_000 - share);
        ISplitWallet.Payee memory b =
            ISplitWallet.Payee(uint256(uint160(collaborator)), address(0), share);
        ISplitWallet.Payee[] memory payees = new ISplitWallet.Payee[](2);
        (payees[0], payees[1]) = uint160(lead) < uint160(collaborator) ? (a, b) : (b, a);
        w.item.payees = payees;
        return w;
    }

    /// @dev The 6529 Stream terms a work with `w`'s payees locks if it starts now.
    function _terms(Work memory w) internal view returns (WorkTerms memory) {
        return economics.newWorkTerms(PRODUCT_STREAM, w.item.payees);
    }

    /// @dev The payees of the royalty vault of terms `t`: the seller vault and the fee vault.
    function _royaltyPayees(WorkTerms memory t)
        internal
        pure
        returns (ISplitWallet.Payee[] memory)
    {
        return Splits.royaltyPayees(t.seller, t.feeRecipient, t.feeShare);
    }

    /// @dev The index of the payee paid to `account` (fixed) or resolved from `account`'s artist
    ///      ID.
    function _indexOf(ISplitWallet.Payee[] memory payees, address account)
        internal
        pure
        returns (uint256)
    {
        for (uint256 i; i < payees.length; ++i) {
            if (payees[i].account == account || payees[i].artistId == uint256(uint160(account))) {
                return i;
            }
        }
        revert("no such payee");
    }

    /// @dev The network's part of `price` at `feeShare`: the seller's part rounds down.
    function _fee(uint256 price, uint256 feeShare) internal pure returns (uint256) {
        return price - price * (DENOMINATOR - feeShare) / DENOMINATOR;
    }

    /// @dev Bids `amount` from a contract wallet.
    function _walletBid(ContractWallet wallet, uint256 saleId, uint256 amount) internal {
        vm.deal(address(wallet), address(wallet).balance + amount);
        wallet.exec(address(auction), amount, abi.encodeCall(auction.bid, (saleId, address(0))));
    }
}

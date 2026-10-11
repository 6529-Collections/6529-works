// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice A faithful reduction of the 6529 delegation contract at
///         `0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d` (NFTDelegation.com management contract
///         5.20.15, vendored in 6529Stream RC1 as `smart-contracts/integrations/delegation/
///         NFTdelegation.sol`). It keeps the same three storage mappings, the same
///         `abi.encodePacked` keys, the same `GlobalData` struct, the same public getters (which
///         revert past the end of an array and expose no lengths), and the same register, revoke
///         and update semantics: a registration pushes an entry stamped with `block.timestamp`, a
///         revocation removes every matching delegate by swap-and-pop in descending index order
///         and deletes the pair's whole registration array. `checkConsolidationStatus` is copied
///         as vendored, including that it ignores registration age and expiry. Locks,
///         sub-delegation and batch helpers are omitted; the adapter does not read them.
contract DelegationManagementMock {
    address public constant ALL_COLLECTIONS = 0x8888888888888888888888888888888888888888;
    uint256 public constant USE_CASE_CONSOLIDATION = 999;

    struct GlobalData {
        address delegatorAddress;
        address delegationAddress;
        uint256 registeredDate;
        uint256 expiryDate;
        bool allTokens;
        uint256 tokens;
    }

    mapping(bytes32 => address[]) public delegatorHashes;
    mapping(bytes32 => address[]) public delegationAddressHashes;
    mapping(bytes32 => GlobalData[]) public globalDelegationHashes;

    function registerDelegationAddress(
        address collection,
        address delegate,
        uint256 expiryDate,
        uint256 useCase,
        bool allTokens,
        uint256 tokenId
    ) public {
        require(useCase > 0 && useCase <= 999);
        delegatorHashes[keccak256(abi.encodePacked(msg.sender, collection, useCase))].push(delegate);
        delegationAddressHashes[keccak256(
                abi.encodePacked(delegate, collection, useCase)
            )].push(msg.sender);
        globalDelegationHashes[keccak256(
                abi.encodePacked(msg.sender, collection, delegate, useCase)
            )].push(
            GlobalData(
                msg.sender,
                delegate,
                block.timestamp,
                expiryDate,
                allTokens,
                allTokens ? 0 : tokenId
            )
        );
    }

    function revokeDelegationAddress(address collection, address delegate, uint256 useCase) public {
        bytes32 delegatorHash = keccak256(abi.encodePacked(msg.sender, collection, useCase));
        if (delegatorHashes[delegatorHash].length == 0) return;
        _removeAll(delegatorHashes[delegatorHash], delegate);
        _removeAll(
            delegationAddressHashes[keccak256(abi.encodePacked(delegate, collection, useCase))],
            msg.sender
        );
        delete globalDelegationHashes[
            keccak256(abi.encodePacked(msg.sender, collection, delegate, useCase))
        ];
    }

    function updateDelegationAddress(
        address collection,
        address oldDelegate,
        address newDelegate,
        uint256 expiryDate,
        uint256 useCase,
        bool allTokens,
        uint256 tokenId
    ) public {
        revokeDelegationAddress(collection, oldDelegate, useCase);
        registerDelegationAddress(collection, newDelegate, expiryDate, useCase, allTokens, tokenId);
    }

    function retrieveDelegationAddresses(address delegator, address collection, uint256 useCase)
        public
        view
        returns (address[] memory)
    {
        return delegatorHashes[keccak256(abi.encodePacked(delegator, collection, useCase))];
    }

    function retrieveGlobalStatusOfDelegation(
        address delegator,
        address collection,
        address delegate,
        uint256 useCase
    ) public view returns (bool) {
        return globalDelegationHashes[keccak256(
                abi.encodePacked(delegator, collection, delegate, useCase)
            )].length > 0;
    }

    /// @dev As vendored: presence in both directions, for the collection or all collections.
    function checkConsolidationStatus(address wallet1, address wallet2, address collection)
        public
        view
        returns (bool)
    {
        bool a = retrieveGlobalStatusOfDelegation(
            wallet1, collection, wallet2, USE_CASE_CONSOLIDATION
        );
        bool b = retrieveGlobalStatusOfDelegation(
            wallet2, collection, wallet1, USE_CASE_CONSOLIDATION
        );
        bool aAll = retrieveGlobalStatusOfDelegation(
            wallet1, ALL_COLLECTIONS, wallet2, USE_CASE_CONSOLIDATION
        );
        bool bAll = retrieveGlobalStatusOfDelegation(
            wallet2, ALL_COLLECTIONS, wallet1, USE_CASE_CONSOLIDATION
        );
        return (a && b) || (a && bAll) || (b && aAll) || (aAll && bAll);
    }

    /// @dev Equivalent to the original's two-pass removal: matches are swapped with the current
    ///      last element and popped, from the highest index down.
    function _removeAll(address[] storage list, address value) private {
        for (uint256 i = list.length; i > 0; --i) {
            if (list[i - 1] == value) {
                list[i - 1] = list[list.length - 1];
                list.pop();
            }
        }
    }
}

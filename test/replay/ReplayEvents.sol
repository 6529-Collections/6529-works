// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The events each permanent contract's compiled ABI declares, by canonical signature,
///         as the replay suites require them: every one must be replayed at least once, or be
///         named by the suite as declared but never emitted. The lists were read from Foundry's
///         `out/` with the same rule `tools/make_vectors.py` applies (`event_signatures`), and
///         `LogReplayTopicsTest` holds them equal to the generated `event-topics.json`, so an
///         event added to a contract fails a suite until it is replayed.
library ReplayEvents {
    function stream() internal pure returns (string[] memory e) {
        e = new string[](21);
        e[0] = "Approval(address,address,uint256)";
        e[1] = "ApprovalForAll(address,address,bool)";
        e[2] = "AuthorityUpdated(address)";
        e[3] = "BatchMetadataUpdate(uint256,uint256)";
        e[4] = "CollectionCreated(uint256,string,bytes32)";
        e[5] = "ContractURISet(string)";
        e[6] = "ContractURIUpdated()";
        e[7] = "MetadataUpdate(uint256)";
        e[8] = "MinterAdded(address,uint48)";
        e[9] = "MinterRemoved(address)";
        e[10] = "ModuleDelaySet(uint48,uint48)";
        e[11] = "ModuleProposed(bytes32,address,uint48)";
        e[12] = "ModuleSet(bytes32,address,address)";
        e[13] = "OwnershipTransferred(address,address)";
        e[14] = "PrimarySale(uint256,uint8,address,uint256)";
        e[15] = "RescueDelaySet(uint48,uint48)";
        e[16] = "RoyaltyRateLocked(uint256)";
        e[17] = "RoyaltySet(uint256,address,uint24)";
        e[18] = "Transfer(address,address,uint256)";
        e[19] =
            "WorkMinted(uint256,uint256,uint256,address,uint32,(bytes32,bytes32,uint256,uint256,uint8,uint8,bytes32,address,uint24,bytes32,bytes32,bytes32,address))";
        e[20] = "WorkRescued(uint256,address,address)";
    }

    function editions() internal pure returns (string[] memory e) {
        e = new string[](21);
        e[0] = "ApprovalForAll(address,address,bool)";
        e[1] = "AuthorityUpdated(address)";
        e[2] = "BatchMetadataUpdate(uint256,uint256)";
        e[3] = "ContractURISet(string)";
        e[4] = "ContractURIUpdated()";
        e[5] = "EditionCreated(uint256,address,uint40,address,uint24)";
        e[6] = "EditionMinted(uint256,address,uint256,uint256)";
        e[7] = "EditionRebound(uint256,address,address)";
        e[8] = "EditionSupplySealed(uint256,uint256)";
        e[9] = "MetadataUpdate(uint256)";
        e[10] = "MinterAdded(address,uint48)";
        e[11] = "MinterRemoved(address)";
        e[12] = "ModuleDelaySet(uint48,uint48)";
        e[13] = "ModuleProposed(bytes32,address,uint48)";
        e[14] = "ModuleSet(bytes32,address,address)";
        e[15] = "OwnershipTransferred(address,address)";
        e[16] = "RebindDelaySet(uint48,uint48)";
        e[17] = "RoyaltySet(uint256,address,uint24)";
        e[18] = "TransferBatch(address,address,address,uint256[],uint256[])";
        e[19] = "TransferSingle(address,address,address,uint256,uint256)";
        e[20] = "URI(string,uint256)";
    }

    function workFacts() internal pure returns (string[] memory e) {
        e = new string[](7);
        e[0] = "Finalized(address,uint256,address,bytes32)";
        e[1] = "LicenseSet(address,uint256,(string,bytes32))";
        e[2] = "Locked(address,uint256,bool,bool)";
        e[3] = "OnChainComplete(address,uint256)";
        e[4] =
            "RecordOpened(address,uint256,(uint8,uint256,bytes32,bytes32,bytes32,(address,uint8)[],(uint256,address,uint32)[],(string,bytes32),uint8,bytes32,(bytes32,address,bytes),(uint32,address,bytes32,bytes)),(bytes32,bytes32,uint8)[])";
        e[5] = "RecordSet(address,uint256,bytes32)";
        e[6] = "RendererRepinned(address,uint256,address,bytes32)";
    }

    function directory() internal pure returns (string[] memory e) {
        e = new string[](5);
        e[0] = "AuthorityUpdated(address)";
        e[1] = "ModuleDelaySet(uint48,uint48)";
        e[2] = "ModuleProposed(bytes32,address,uint48)";
        e[3] = "ModuleSet(bytes32,address,address)";
        e[4] = "UnclaimedPeriodSet(uint48,uint48)";
    }

    function federatedStream() internal pure returns (string[] memory e) {
        e = new string[](18);
        e[0] = "Approval(address,address,uint256)";
        e[1] = "ApprovalForAll(address,address,bool)";
        e[2] = "BatchMetadataUpdate(uint256,uint256)";
        e[3] = "CollectionCreated(uint256,string,bytes32)";
        e[4] = "ContractURISet(string)";
        e[5] = "ContractURIUpdated()";
        e[6] = "MetadataUpdate(uint256)";
        e[7] = "ModuleDelaySet(uint48,uint48)";
        e[8] = "ModuleProposed(bytes32,address,uint48)";
        e[9] = "ModuleSet(bytes32,address,address)";
        e[10] = "OwnershipTransferred(address,address)";
        e[11] = "PrimarySale(uint256,uint8,address,uint256)";
        e[12] = "RescueDelaySet(uint48,uint48)";
        e[13] = "RoyaltyRateLocked(uint256)";
        e[14] = "RoyaltySet(uint256,address,uint24)";
        e[15] = "Transfer(address,address,uint256)";
        e[16] =
            "WorkMinted(uint256,uint256,uint256,address,uint32,(bytes32,bytes32,uint256,uint256,uint8,uint8,bytes32,address,uint24,bytes32,bytes32,bytes32,address))";
        e[17] = "WorkRescued(uint256,address,address)";
    }

    function federatedEditions() internal pure returns (string[] memory e) {
        e = new string[](15);
        e[0] = "ApprovalForAll(address,address,bool)";
        e[1] = "BatchMetadataUpdate(uint256,uint256)";
        e[2] = "ContractURISet(string)";
        e[3] = "ContractURIUpdated()";
        e[4] = "EditionCreated(uint256,address,uint40,address,uint24)";
        e[5] = "EditionMinted(uint256,address,uint256,uint256)";
        e[6] = "EditionRebound(uint256,address,address)";
        e[7] = "EditionSupplySealed(uint256,uint256)";
        e[8] = "MetadataUpdate(uint256)";
        e[9] = "OwnershipTransferred(address,address)";
        e[10] = "RebindDelaySet(uint48,uint48)";
        e[11] = "RoyaltySet(uint256,address,uint24)";
        e[12] = "TransferBatch(address,address,address,uint256[],uint256[])";
        e[13] = "TransferSingle(address,address,address,uint256,uint256)";
        e[14] = "URI(string,uint256)";
    }

    function splitLedger() internal pure returns (string[] memory e) {
        e = new string[](6);
        e[0] = "EIP712DomainChanged()";
        e[1] = "Forfeited(address,address,uint256,uint256)";
        e[2] = "Marked(address,address,uint256,uint256,uint256)";
        e[3] = "NonceUsed(address,uint256,bool)";
        e[4] = "Released(address,address,address,uint256,address,uint256,uint256)";
        e[5] = "WalletCreated(address,bytes32,bytes32,(uint256,address,uint32)[])";
    }

    function revenueEscrow() internal pure returns (string[] memory e) {
        e = new string[](7);
        e[0] = "AuthorityUpdated(address)";
        e[1] = "Credited(address,address,address,uint256,uint256)";
        e[2] = "ExcessSwept(address,address,uint256)";
        e[3] = "Expired(address,address,address,uint256,uint256)";
        e[4] = "Flushed(address,address,address,uint256)";
        e[5] = "Recovered(address,address,address,uint256,uint256,bool)";
        e[6] = "RecoveryConsentSet(address,address)";
    }

    function contentStore() internal pure returns (string[] memory e) {
        e = new string[](7);
        e[0] = "Base64Attested(bytes32)";
        e[1] = "Base64Progress(bytes32,uint256)";
        e[2] = "ChunkLinked(bytes32,bytes32[],uint256)";
        e[3] = "ChunkWritten(bytes32,address,uint256)";
        e[4] = "CompletenessAttested(bytes32)";
        e[5] = "CompletenessProgress(bytes32,uint256)";
        e[6] = "ManifestRegistered(bytes32,uint256,uint8,uint8,bytes32,string,bytes32[])";
    }

    function statementLog() internal pure returns (string[] memory e) {
        e = new string[](6);
        e[0] = "ArtistResolverSet(address,address,bytes32)";
        e[1] = "AuthorityUpdated(address)";
        e[2] = "EIP712DomainChanged()";
        e[3] = "NonceRevoked(address,uint256)";
        e[4] =
            "StatementAppended(bytes32,bytes32,address,uint8,address,uint64,uint64,bytes32,bytes32,(address,uint256,bytes32,bytes32,(uint16,bytes32),string,bytes32,bytes32))";
        e[5] = "StatementRelayed(bytes32,address,uint256)";
    }
}

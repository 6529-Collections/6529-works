// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

/// @title CoreFactory
/// @notice Creates each contract of one deployment at an address that depends only on this
///         factory and a salt, in a single call that only the factory's owner may make.
/// @dev Every contract is created through a one-use proxy: `create` makes the proxy with CREATE2
///      (salt and the fixed proxy code) and, in the same call, sends it the contract's creation
///      code, which the proxy creates with CREATE at its first nonce. So the address does not
///      depend on the creation code, and genesis modules and minters can be constructor
///      arguments of contracts created before them. The proxy's code stays on chain after the
///      call, and anyone may call it afterwards. That is harmless: the predicted address is the
///      proxy's CREATE address at its first nonce, that nonce is spent inside the same `create`
///      call that made the proxy, and only the owner can call `create`. A later call to the
///      proxy creates at a later nonce, which is a different address. So nobody else can create
///      anything at a predicted address. A creation that fails reverts the whole call, proxy
///      included.
///
///      The factory itself is created with CREATE2 from a salt and creation code that includes
///      the owner, so its address commits to the owner: anyone who creates it first creates the
///      same contract with the same owner.
contract CoreFactory {
    /// @notice The proxy's creation code: its runtime creates a contract from the calldata.
    bytes internal constant PROXY_INITCODE = hex"67363d3d37363d34f03d5260086018f3";

    /// @notice The only account that may call `create`.
    address public immutable owner;

    /// @notice `caller` is not the owner.
    error NotOwner(address caller);
    /// @notice No contract could be created for `salt` (used before, or its constructor reverted).
    error CreateFailed(bytes32 salt);

    /// @param owner_ The only account that may call `create`.
    constructor(address owner_) {
        owner = owner_;
    }

    /// @notice Creates `code` (creation code with constructor arguments) at `addressOf(salt)`.
    /// @param salt The contract's salt.
    /// @param code The creation code and constructor arguments.
    /// @return created The new contract's address.
    function create(bytes32 salt, bytes calldata code) external returns (address created) {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        bytes memory proxyCode = PROXY_INITCODE;
        address proxy;
        assembly ("memory-safe") {
            proxy := create2(0, add(proxyCode, 0x20), mload(proxyCode), salt)
        }
        if (proxy == address(0)) revert CreateFailed(salt);
        (bool ok,) = proxy.call(code);
        created = addressOf(salt);
        if (!ok || created.code.length == 0) revert CreateFailed(salt);
    }

    /// @notice The address `create(salt, ...)` creates.
    /// @param salt The contract's salt.
    /// @return The proxy's first CREATE address.
    function addressOf(bytes32 salt) public view returns (address) {
        address proxy = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(this), salt, keccak256(PROXY_INITCODE)
                        )
                    )
                )
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", proxy, hex"01")))));
    }
}

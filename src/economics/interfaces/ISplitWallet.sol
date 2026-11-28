// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

/// @title ISplitWallet
/// @notice The split-wallet operations the split ledger serves for every wallet (ADR 0001 section
///         7). A split wallet is a minimal vault at a CREATE2 address that holds ETH and ERC-20s and
///         moves them only when the ledger instructs it; the ledger keeps the accounting. Each
///         payee is entitled to `floor(observed * share / 100,000)` of every asset, where
///         `observed` is the wallet's balance plus everything already released. ETH is
///         `address(0)`.
/// @dev Fixed payees may be paid by anyone (push to their own account). Artist-resolved payees
///      are pull-only: only their current payout address may release, directly or by signature,
///      so a lost key cannot be paid before recovery redirects it (ADR 0001 section 11). A split
///      wallet therefore cannot serve as an artist's payout address, because it cannot pull;
///      nest a wallet as a fixed payee instead.
///      A wallet is named by its configuration, the payee list and the salt, from which the
///      ledger derives its address: the ledger stores no payee list, so every call that needs
///      one takes it in calldata (read it from the wallet's `WalletCreated` event, or from the
///      work's terms). A list that is not the wallet's names another address, where nothing is
///      deployed, and its release reverts. Because fixed payees are push, anyone may release a fixed
///      payee's whole balance to its own account just before that payee's signed release of an
///      exact amount; the signed release then reverts (nothing or too little left) without
///      consuming its nonce, and the funds are in the payee's account. Sign `type(uint256).max`
///      to take whatever is due.
interface ISplitWallet {
    /// @notice One share holder. Exactly one of `artistId` and `account` is non-zero. A fixed payee
    ///         names its `account`. An artist-resolved payee names its `artistId` and is paid at
    ///         the address the resolver returns when funds are released (ADR 0001 section 11).
    struct Payee {
        uint256 artistId;
        address account;
        uint32 share;
    }

    /// @notice `amount` of `asset` owed to payee `payee` of `wallet` (payout address `account`)
    ///         was paid to `recipient`; `observed` is the wallet's cumulative receipts of `asset`
    ///         at that time.
    /// @param wallet The split wallet the funds left.
    /// @param asset The asset released (ETH is `address(0)`).
    /// @param recipient The account that received the funds.
    /// @param payee The payee's index in the wallet's payee list.
    /// @param account The payee's payout address: its fixed account, or its artist's resolved
    ///        payout address.
    /// @param amount The amount released, in the asset's base units.
    /// @param observed The wallet's cumulative receipts of the asset (balance plus everything
    ///        released) that the release was computed from.
    event Released(
        address indexed wallet,
        address indexed asset,
        address indexed recipient,
        uint256 payee,
        address account,
        uint256 amount,
        uint256 observed
    );

    /// @notice The payee list is empty or longer than the maximum.
    error PayeeCountOutOfRange(uint256 count);
    /// @notice The payee at `index` has a zero share or is neither exactly fixed nor
    ///         artist-resolved.
    error InvalidPayee(uint256 index);
    /// @notice The payee at `index` does not sort strictly after its predecessor by
    ///         `(artistId, account)`, so the list is not canonical or has a duplicate.
    error PayeesNotCanonical(uint256 index);
    /// @notice The shares add up to `total` instead of 100,000.
    error SharesDoNotSum(uint256 total);
    /// @notice No wallet is deployed at `wallet`, the address of the payee list and salt given,
    ///         so nothing can move from it yet (anyone may deploy it with `createWallet`).
    error WalletNotDeployed(address wallet);
    /// @notice The signed release names `named`, but the payee list and salt given are those of
    ///         `wallet`.
    error WrongWallet(address named, address wallet);
    /// @notice There is no payee at index `payee`.
    error UnknownPayee(uint256 payee);
    /// @notice The resolver returned no payout address for `artistId`.
    error PayoutUnresolved(uint256 artistId);
    /// @notice `recipient` is zero, the wallet itself or the ledger.
    error InvalidRecipient(address recipient);
    /// @notice `caller` is not the payee's current payout address `payoutAddress`.
    error NotPayoutAddress(address caller, address payoutAddress);
    /// @notice Payee `payee` has nothing releasable in `asset`.
    error NothingToRelease(address asset, uint256 payee);
    /// @notice `amount` exceeds the `releasable` amount.
    error AmountExceedsReleasable(uint256 amount, uint256 releasable);
    /// @notice ERC-20 `asset` receipts fell below the recorded high-water mark, as a negative
    ///         rebase or a hostile token would cause. Releases of that asset fail closed until it
    ///         recovers.
    error ObservedDecreased(address asset, uint256 recorded, uint256 current);
    /// @notice Sending `amount` wei to `recipient` failed.
    error ETHTransferFailed(address recipient, uint256 amount);
    /// @notice A release of the same wallet is already in progress; its accounting is not read
    ///         or changed until it ends. (OpenZeppelin's `ReentrancyGuardReentrantCall` selector.)
    error ReentrancyGuardReentrantCall();

    /// @notice Cumulative receipts of `asset` in `wallet`: its balance plus everything released.
    /// @param wallet The split wallet, deployed or not.
    /// @param asset The asset to look up (ETH is `address(0)`).
    /// @return The cumulative receipts, in the asset's base units.
    function observed(address wallet, address asset) external view returns (uint256);

    /// @notice The highest cumulative receipts of ERC-20 `asset` in `wallet` recorded by a
    ///         release. Always zero for ETH (`address(0)`), whose receipts can never fall:
    ///         nothing but a release takes ETH out of a wallet, and a release counts it as
    ///         released first.
    /// @param wallet The split wallet.
    /// @param asset The asset to look up.
    /// @return The recorded high-water mark, in the asset's base units; zero until a release of
    ///        the asset.
    function recordedObserved(address wallet, address asset) external view returns (uint256);

    /// @notice The amount of `asset` released for payee `index` of `wallet`.
    /// @param wallet The split wallet.
    /// @param asset The asset to look up (ETH is `address(0)`).
    /// @param index The payee's index.
    /// @return The cumulative amount released for the payee, in the asset's base units.
    /// @dev A raw counter. Inside a release (a token's or recipient's callback during the move)
    ///      it may not yet agree with the wallet's balance; {observed} and {releasable} revert
    ///      while a release of the wallet is in progress, so read those for derived amounts.
    function released(address wallet, address asset, uint256 index) external view returns (uint256);

    /// @notice The amount of `asset` released from `wallet` for all payees.
    /// @param wallet The split wallet.
    /// @param asset The asset to look up (ETH is `address(0)`).
    /// @return The cumulative amount released, in the asset's base units.
    /// @dev A raw counter. Inside a release (a token's or recipient's callback during the move)
    ///      it may not yet agree with the wallet's balance; {observed} and {releasable} revert
    ///      while a release of the wallet is in progress, so read those for derived amounts.
    function totalReleased(address wallet, address asset) external view returns (uint256);

    /// @notice The amount of `asset` payee `index` of the wallet for `payees` and `salt` can
    ///         release now.
    /// @param payees The wallet's payee list.
    /// @param salt The wallet's salt (zero for the wallets sale adapters pay).
    /// @param asset The asset to look up (ETH is `address(0)`).
    /// @param index The payee's index.
    /// @return The payee's entitlement minus what it has already released, in the asset's base
    ///        units.
    function releasable(Payee[] calldata payees, bytes32 salt, address asset, uint256 index)
        external
        view
        returns (uint256);

    /// @notice Pays payee `index` of the wallet for `payees` and `salt` everything releasable in
    ///         `asset`, at its payout address. Anyone may call for a fixed payee; only the current
    ///         payout address may call for an artist-resolved payee.
    /// @dev For a payee named by artist ID the caller must be the account's payout address
    ///      itself. The account's root and its other wallets are refused unless they are that
    ///      address (at registration the root is the payout address). Any other wallet, a
    ///      relayer included, releases with the payout address's signature through
    ///      `ISplitLedger.releaseWithAuthorization`.
    /// @param payees The wallet's payee list.
    /// @param salt The wallet's salt (zero for the wallets sale adapters pay).
    /// @param asset The asset to release (ETH is `address(0)`).
    /// @param index The payee's index.
    /// @return amount The amount released.
    function release(Payee[] calldata payees, bytes32 salt, address asset, uint256 index)
        external
        returns (uint256 amount);

    /// @notice Pays payee `index` of the wallet for `payees` and `salt` everything releasable in
    ///         `asset` to `recipient`. Only the payee's current payout address may call.
    /// @param payees The wallet's payee list.
    /// @param salt The wallet's salt (zero for the wallets sale adapters pay).
    /// @param asset The asset to release (ETH is `address(0)`).
    /// @param index The payee's index.
    /// @param recipient The account to pay; not zero, the wallet or the ledger.
    /// @return amount The amount released.
    function releaseTo(
        Payee[] calldata payees,
        bytes32 salt,
        address asset,
        uint256 index,
        address recipient
    ) external returns (uint256 amount);
}

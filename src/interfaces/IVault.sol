// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IVault {
    struct WithdrawRequest {
        uint256 shares;
        uint256 wadOwed;
        uint256 reservedAmount;
        address asset;
        uint64 unlockBlock;
        bool claimed;
    }

    event AssetAdded(address indexed asset, uint8 decimals);
    event AssetRemoved(address indexed asset);
    event Deposited(
        address indexed user, address indexed asset, uint256 amount, uint256 sharesMinted, address indexed receiver
    );
    event WithdrawRequested(
        address indexed user, uint256 sharesBurned, uint256 wadOwed, address indexed asset, uint64 unlockBlock
    );
    event WithdrawClaimed(address indexed user, address indexed asset, uint256 amountOut);
    event WithdrawCancelled(address indexed user, uint256 sharesReturned);
    event FeesAccrued(uint256 mgmtFeeShares, uint256 perfFeeShares, uint256 newHighWaterMarkPPS);
    event YieldReported(address indexed asset, uint256 amount, uint256 newTotalManagedWad);
    event FeeParamsUpdated(uint256 perfBps, uint256 mgmtBps);
    event TimelockUpdated(uint256 blocks);
    event FeeRecipientUpdated(address recipient);

    error AssetNotWhitelisted(address asset);
    error AssetAlreadyWhitelisted(address asset);
    error AssetStillHeld(address asset, uint256 balance);
    error ZeroAmount();
    error ZeroAddress();
    error NoActiveShares();
    error InsufficientShares(uint256 requested, uint256 available);
    error PendingWithdrawExists(address user);
    error NoPendingWithdraw(address user);
    error TimelockActive(uint64 unlockBlock, uint64 currentBlock);
    error FeeTooHigh(uint256 requested, uint256 max);
    error TimelockTooLong(uint256 requested, uint256 max);
    error InitialDepositTooSmall(uint256 amount, uint256 min);
    error UnsupportedToken(address token); // fee-on-transfer detected
    error InsufficientAssetLiquidity(address asset, uint256 needed, uint256 available);
    error ShareAssetMismatch(address user, address expected, address actual);
    error FeeRecipientAssetMismatch(address expected, address actual);
    error UnauthorizedReceiverBinding(address receiver);
    error AssetHasOutstandingShares(address asset, uint256 shares);

    function deposit(address asset, uint256 amount, address receiver) external returns (uint256 sharesMinted);
    function requestWithdraw(uint256 shares, address asset) external returns (uint64 unlockBlock);
    function claimWithdraw() external returns (uint256 amountOut);
    function cancelWithdraw() external;

    function totalAssets() external view returns (uint256);
    function convertToShares(uint256 amountWad) external view returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 amountWad);
    function previewDeposit(address asset, uint256 amount) external view returns (uint256 shares);
    function previewWithdraw(uint256 shares) external view returns (uint256 amountWad);
    function getAssetList() external view returns (address[] memory assets);
    function getPendingWithdraw(address user) external view returns (WithdrawRequest memory request);

    function addAsset(address asset) external;
    function removeAsset(address asset) external;
    function setPerformanceFee(uint256 bps) external;
    function setManagementFee(uint256 bps) external;
    function setTimelockBlocks(uint256 blocks_) external;
    function setFeeRecipient(address recipient) external;
    function reportYield(address asset, uint256 amount) external;
    function accrueFees() external;
    function pause() external;
    function unpause() external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IiBTC {
    // Deposit XBTC to mint iBTC 1:1 ratio
    function deposit(uint256 amount) external;

    // Request withdrawal of XBTC by burning iBTC
    function requestWithdraw(uint256 amount) external;

    // Finalize unlocked withdrawal requests for XBTC
    function withdraw() external;

    // Claim the pending XSAT reward
    function claimReward() external;

    // Prepare for reward distribution (trigger reward claiming from stakeHelper)
    function prepareRewardDistribution() external;

    // Finalize the reward distribution and update reward share for all users
    function finalizeRewardDistribution() external;

    // Get the pending reward for a specific user
    function getPendingReward(address userAddress) external view returns (uint256);

    // Get the user's withdrawal requests (for UI or frontend display)
    function getUserWithdrawals(address user) external view returns (WithdrawalRequest[] memory);

    // Structure for a withdrawal request (used in getUserWithdrawals function)
    struct WithdrawalRequest {
        uint256 amount;
        uint256 unlockTimestamp;
    }
}

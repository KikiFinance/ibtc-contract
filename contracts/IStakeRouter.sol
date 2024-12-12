// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IStakeRouter {

    function addValidator(
        address _validator,
        uint256 _minStakePerTx,
        uint256 _maxStake,
        uint256 _priority
    ) external;

    function lockTime() external view returns (uint256);

    function deposit(uint256 _amount) external;

    function withdraw(uint256 _amount) external;

    function prepareRewardDistribution() external;

    function finalizeRewardDistribution() external;

    function claimPendingFunds() external;

    function executeStakeTransfer(address _user, address _fromValidator, uint256 _amount) external;

}

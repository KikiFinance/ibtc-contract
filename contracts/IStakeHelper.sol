// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IStakeHelper {
    function lockTime() external view returns (uint256);
    function deposit(address _target, uint256 _amount) external payable;
    function restake(address _from, address _to, uint256 _amount) external;
    function claim(address _target) external;
    function withdraw(address _target, uint256 _amount) external;
    function claimPendingFunds(address _target) external;
    function claimPendingFunds() external;
}
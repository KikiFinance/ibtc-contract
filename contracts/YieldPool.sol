// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IiBTC.sol";

contract YieldPool is OwnableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    IiBTC public iBTC;
    IERC20 public iBTCErc20;
    IERC20 public xsat; // The reward token (XSAT)
    uint256 public totalStaked;
    uint256 public minDeposit;
    uint256 private constant PRECISION = 1e12;
    uint256 public accRewardPerShare; // Accumulated reward per iBTC share

    struct RedemptionRequest {
        uint256 amount;
        bool approved;
    }

    mapping(address => uint256) public userStakes;
    mapping(address => uint256) public rewardDebt; // Tracks reward debt for each user
    mapping(address => RedemptionRequest) public userRedemptionRequests; // Single active request per user

    event Deposit(address indexed user, uint256 amount);
    event RedemptionRequested(address indexed user, uint256 amount);
    event RedemptionApproved(address indexed user);
    event Redeemed(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event RewardDistributed(uint256 amount);

    modifier onlyAdmin() {
        require(owner() == msg.sender, "Only admin can perform this action");
        _;
    }

    function initialize(address _iBTC, address _xsat) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        iBTC = IiBTC(_iBTC);
        iBTCErc20 = IERC20(_iBTC);
        xsat = IERC20(_xsat);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // Calculate the pending reward for a user
    function getPendingReward(address user) public view returns (uint256) {
        uint256 userBalance = userStakes[user];
        uint256 accumulatedReward = (userBalance * accRewardPerShare) / PRECISION;
        if (accumulatedReward > rewardDebt[user]) {
            return accumulatedReward - rewardDebt[user];
        }
        return 0;
    }

    // Function to retrieve a user's active redemption request
    function getRedemptionRequest(address user) external view returns (uint256 amount, bool approved) {
        RedemptionRequest storage request = userRedemptionRequests[user];
        return (request.amount, request.approved);
    }

    // Claim the pending reward for the user
    function claimReward() external nonReentrant {
        uint256 pendingReward = getPendingReward(msg.sender);
        require(pendingReward > 0, "No rewards to claim");

        // Update reward debt for the user
        rewardDebt[msg.sender] = (userStakes[msg.sender] * accRewardPerShare) / PRECISION;

        // Transfer the reward (XSAT) to the user
        xsat.transfer(msg.sender, pendingReward);

        emit RewardClaimed(msg.sender, pendingReward);
    }

    function deposit(uint256 amount) external nonReentrant {
        require(amount > minDeposit, "Deposit amount must be greater than the minimum deposit");
        iBTCErc20.transferFrom(msg.sender, address(this), amount);

        userStakes[msg.sender] += amount;
        totalStaked += amount;

        emit Deposit(msg.sender, amount);

        // Update the user's reward debt to reflect the most recent accRewardPerShare
        rewardDebt[msg.sender] = (userStakes[msg.sender] * accRewardPerShare) / PRECISION;
    }

    // Function to request redemption with single active request restriction
    function requestRedemption(uint256 amount) external nonReentrant {
        require(amount > 0 && userStakes[msg.sender] >= amount, "Invalid redemption request");
        require(userRedemptionRequests[msg.sender].amount == 0, "Existing redemption request must be processed or canceled first");

        // Create and store the redemption request for the user
        userRedemptionRequests[msg.sender] = RedemptionRequest({
            amount: amount,
            approved: false
        });

        emit RedemptionRequested(msg.sender, amount);
    }

    // Function for admin to approve redemption requests
    function approveRedemption(address user) external onlyAdmin {
        RedemptionRequest storage request = userRedemptionRequests[user];
        require(request.amount > 0, "No active redemption request");
        require(!request.approved, "Already approved");

        // Approve the redemption request
        request.approved = true;
        emit RedemptionApproved(user);
    }

    // Function for user to redeem approved requests
    function redeem() external nonReentrant {
        RedemptionRequest storage request = userRedemptionRequests[msg.sender];
        require(request.amount > 0, "No active redemption request");
        require(request.approved, "Redemption not approved");

        // Perform redemption logic
        userStakes[msg.sender] -= request.amount;
        totalStaked -= request.amount;
        iBTCErc20.transfer(msg.sender, request.amount);

        // Emit event for redemption completion
        emit Redeemed(msg.sender, request.amount);

        // Remove the redemption request after processing
        delete userRedemptionRequests[msg.sender];
    }

    function distributeRewards() external nonReentrant {
        require(totalStaked > 0, "No staked tokens to distribute rewards");

        uint256 balanceBefore = xsat.balanceOf(address(this));
        iBTC.claimReward();
        uint256 balanceAfter = xsat.balanceOf(address(this));

        // Calculate the reward amount distributed
        uint256 amount = balanceAfter - balanceBefore;
        require(amount > 0, "No rewards to distribute");

        // Calculate reward per share
        uint256 rewardPerShare = (amount * PRECISION) / totalStaked;

        // Update accumulated reward per share
        accRewardPerShare += rewardPerShare;

        // Emit event to notify about the reward distribution
        emit RewardDistributed(amount);
    }
}

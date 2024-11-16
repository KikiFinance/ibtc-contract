// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./IStakeRouter.sol";
import "./IiBTC.sol";

contract iBTC is IiBTC, ERC20Upgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public xbtc; // XBTC token interface
    IERC20 public xsat; // XSAT token interface
    IStakeRouter public stakeRouter; // Reference to the stake router contract

    uint256 private constant PRECISION = 1e18; // Precision for reward calculations
    uint256 public accRewardPerShare; // Accumulated reward per iBTC share, scaled by PRECISION
    uint256 public xsatBalanceBefore; // Previous XSAT balance for reward distribution calculations
    mapping(address => uint256) public rewardDebt; // Tracks reward debt for each user
    mapping(address => WithdrawalRequest[]) public userWithdrawals; // Tracks user-specific withdrawal requests

    event Deposit(address indexed user, uint256 amount); // Emitted when a deposit occurs
    event WithdrawRequested(address indexed user, uint256 amount, uint256 timestamp); // Emitted when a withdrawal is requested
    event Withdraw(address indexed user, uint256 amount); // Emitted upon a successful withdrawal
    event ClaimReward(address indexed user, uint256 amount); // Emitted when a reward is claimed
    event RewardDistributed(uint256 amount); // Emitted when rewards are distributed

    function initialize(address _xbtc, address _xsat, address _stakeRouter) public initializer {
        __ERC20_init("iBTC", "iBTC");
        __Ownable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        xbtc = IERC20(_xbtc);
        xsat = IERC20(_xsat);
        stakeRouter = IStakeRouter(_stakeRouter);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // Calculates the pending reward for a user based on their balance
    function _pendingReward(address userAddress) internal view returns (uint256) {
        uint256 userBalance = balanceOf(userAddress);
        uint256 accumulatedReward = (userBalance * accRewardPerShare) / PRECISION;
        if (accumulatedReward > rewardDebt[userAddress]) {
            return accumulatedReward - rewardDebt[userAddress];
        }
        return 0;
    }

    // Handles reward settlement for a user
    function _settleReward(address userAddress) internal {
        require(xsatBalanceBefore == 0, "distributed rewards not yet finish");
        uint256 pending = _pendingReward(userAddress);
        if (pending > 0) {
            xsat.safeTransfer(userAddress, pending); // Transfer pending XSAT reward
            emit ClaimReward(userAddress, pending);
        }
        // Update the user's reward debt to reflect the latest accumulated reward per share
        rewardDebt[userAddress] = (balanceOf(userAddress) * accRewardPerShare) / PRECISION;
    }

    // Override token transfer function to ensure reward settlement on any transfer, mint, or burn operation
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        if (from != address(0)) {
            _settleReward(from);
        }
        if (to != address(0)) {
            _settleReward(to);
        }
        super._beforeTokenTransfer(from, to, amount);
    }

    // Prepares for reward distribution by updating XSAT balance and initiating a claim
    function _prepareRewardDistribution() internal {
        require(totalSupply() > 0, "No staked XBTC to distribute rewards");
        require(xsatBalanceBefore == 0, "Previous rewards not yet distributed");

        // Record XSAT balance before claiming rewards
        xsatBalanceBefore = xsat.balanceOf(address(this));

        // Trigger reward distribution through the StakeRouter
        stakeRouter.prepareRewardDistribution();
    }

    // Returns the pending reward for a specific user
    function getPendingReward(address userAddress) public view returns (uint256) {
        return _pendingReward(userAddress);
    }

    // Returns all withdrawal requests for a user
    function getUserWithdrawals(address user) external view returns (WithdrawalRequest[] memory) {
        return userWithdrawals[user];
    }

    // Allows users to stake XBTC and mint an equivalent amount of iBTC tokens
    function deposit(uint256 amount) external nonReentrant {
        _settleReward(msg.sender);

        require(amount > 0, "Amount must be greater than 0");
        xbtc.safeTransferFrom(msg.sender, address(this), amount);

        // Approve and stake the deposited XBTC with the StakeRouter
        xbtc.safeApprove(address(stakeRouter), amount);
        stakeRouter.deposit(amount);

        // Mint iBTC tokens at a 1:1 ratio with XBTC
        _mint(msg.sender, amount);

        // Update user's reward debt based on their new balance
        rewardDebt[msg.sender] = (balanceOf(msg.sender) * accRewardPerShare) / PRECISION;
        emit Deposit(msg.sender, amount);
    }

    // Allows users to request the withdrawal of XBTC by burning iBTC tokens
    function requestWithdraw(uint256 amount) external nonReentrant {
        uint256 userBalance = balanceOf(msg.sender);
        require(userBalance >= amount, "Insufficient iBTC balance");
        require(amount > 0, "Amount must be greater than zero");

        _settleReward(msg.sender);

        // Burn the corresponding amount of iBTC tokens
        _burn(msg.sender, amount);

        // Update user's reward debt to reflect their new balance
        rewardDebt[msg.sender] = (balanceOf(msg.sender) * accRewardPerShare) / PRECISION;

        // Create a new withdrawal request with an unlock timestamp determined by the StakeRouter
        uint256 unlockTimestamp = block.timestamp + stakeRouter.lockTime();
        userWithdrawals[msg.sender].push(WithdrawalRequest({
            amount: amount,
            unlockTimestamp: unlockTimestamp
        }));

        // Initiate withdrawal with the StakeRouter
        stakeRouter.withdraw(amount);

        emit WithdrawRequested(msg.sender, amount, unlockTimestamp);
    }

    // Processes and finalizes any unlocked withdrawal requests for XBTC
    function withdraw() external nonReentrant {
        uint256 totalAmount = 0;
        uint256 index = 0;

        // Iterate through user's withdrawal requests and process unlocked ones
        while (index < userWithdrawals[msg.sender].length) {
            WithdrawalRequest storage request = userWithdrawals[msg.sender][index];
            if (request.unlockTimestamp <= block.timestamp) {
                // Add to total withdrawal amount and remove the request
                totalAmount += request.amount;

                // Remove processed request by swapping with the last element and removing
                userWithdrawals[msg.sender][index] = userWithdrawals[msg.sender][userWithdrawals[msg.sender].length - 1];
                userWithdrawals[msg.sender].pop();
            } else {
                // Increment index if no swap occurred
                index++;
            }
        }

        require(totalAmount > 0, "No unlocked withdrawal requests available");

        // Finalize pending withdrawal with the StakeRouter
        stakeRouter.claimPendingFunds();

        // Transfer the accumulated amount of XBTC to the user
        xbtc.safeTransfer(msg.sender, totalAmount);

        emit Withdraw(msg.sender, totalAmount);
    }

    // Allows users to manually claim accumulated XSAT rewards
    function claimReward() external nonReentrant {
        _settleReward(msg.sender);
    }

    // External function to trigger preparation for reward distribution
    function prepareRewardDistribution() external nonReentrant {
        _prepareRewardDistribution();
    }

    // Finalizes reward distribution by updating accumulated rewards and recalculating rewards per share
    function finalizeRewardDistribution() external nonReentrant {
        uint256 supply = totalSupply();
        require(supply > 0, "No iBTC in circulation for reward distribution");
        stakeRouter.finalizeRewardDistribution();

        // Get the updated XSAT balance after reward distribution
        uint256 xsatBalanceAfter = xsat.balanceOf(address(this));
        require(xsatBalanceAfter >= xsatBalanceBefore, "Balance error: Insufficient XSAT");

        // Calculate the newly received rewards and reset the balance tracker
        uint256 amount = xsatBalanceAfter - xsatBalanceBefore;
        xsatBalanceBefore = 0;

        // Update the accumulated reward per share for iBTC holders
        accRewardPerShare += (amount * PRECISION) / supply;

        emit RewardDistributed(amount);
    }

    // Storage gap for upgradeable contracts
    uint256[50] private __gap;
}

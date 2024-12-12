// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./IStakeRouter.sol";
import "./IiBTC.sol";
import "./IXBTC.sol";

contract iBTC is IiBTC, ERC20Upgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public xbtc; // XBTC token interface
    IERC20 public xsat; // XSAT token interface
    IXBTC public ixbtc; // XBTC token interface
    IStakeRouter public stakeRouter; // Reference to the stake router contract

    uint256 private constant PRECISION = 1e18; // Precision for reward calculations
    uint256 public accRewardPerShare; // Accumulated reward per iBTC share, scaled by PRECISION
    mapping(address => uint256) public userLastRewardPerShare; // Tracks the last accRewardPerShare for each user
    mapping(address => WithdrawalRequest[]) public userWithdrawals; // Tracks user-specific withdrawal requests


    event Deposit(address indexed user, uint256 amount); // Emitted when a deposit occurs
    event WithdrawRequested(address indexed user, uint256 amount, uint256 timestamp); // Emitted when a withdrawal is requested
    event Withdraw(address indexed user, uint256 amount); // Emitted upon a successful withdrawal
    event ClaimReward(address indexed user, uint256 amount); // Emitted when a reward is claimed
    event RewardDistributed(uint256 amount); // Emitted when rewards are distributed
    event StakeTransferred(address indexed user, address fromValidator, uint256 amount);

    function initialize(address _xbtc, address _xsat, address _stakeRouter) public initializer {
        __ERC20_init("iBTC", "iBTC");
        __Ownable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        xbtc = IERC20(_xbtc);
        xsat = IERC20(_xsat);
        ixbtc = IXBTC(_xbtc);
        stakeRouter = IStakeRouter(_stakeRouter);
    }

    receive() external payable {
        if (msg.sender != address(ixbtc)) {
            depositBTC();
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // Calculates the pending reward for a user based on their balance
    function _pendingReward(address userAddress) internal view returns (uint256) {
        uint256 userBalance = balanceOf(userAddress);
        uint256 accumulatedReward = (userBalance * (accRewardPerShare - userLastRewardPerShare[userAddress])) / PRECISION;
        return accumulatedReward;
    }

    // Handles reward settlement for a user
    function _settleReward(address userAddress) internal {
        uint256 pending = _pendingReward(userAddress);
        if (pending > 0) {
            xsat.safeTransfer(userAddress, pending); // Transfer pending XSAT reward
            emit ClaimReward(userAddress, pending);
        }
        // Update user's last reward per share
        userLastRewardPerShare[userAddress] = accRewardPerShare;
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
    function deposit(uint256 amount) public nonReentrant {

        require(amount > 0, "Amount must be greater than 0");
        xbtc.safeTransferFrom(msg.sender, address(this), amount);

        // Approve and stake the deposited XBTC with the StakeRouter
        xbtc.safeApprove(address(stakeRouter), amount);
        stakeRouter.deposit(amount);

        // Mint iBTC tokens at a 1:1 ratio with XBTC
        _mint(msg.sender, amount);

        emit Deposit(msg.sender, amount);
    }

    function depositBTC() public payable nonReentrant {
        uint256 amount = msg.value;
        require(amount > 0, "Amount must be greater than 0");
        ixbtc.deposit{value: amount}();

        // Approve and stake the deposited XBTC with the StakeRouter
        xbtc.safeApprove(address(stakeRouter), amount);
        stakeRouter.deposit(amount);

        // Mint iBTC tokens at a 1:1 ratio with XBTC
        _mint(msg.sender, amount);

        emit Deposit(msg.sender, amount);
    }

    // Allows users to request the withdrawal of XBTC by burning iBTC tokens
    function requestWithdraw(uint256 amount) external nonReentrant {
        uint256 userBalance = balanceOf(msg.sender);
        require(userBalance >= amount, "Insufficient iBTC balance");
        require(amount > 0, "Amount must be greater than zero");

        // Burn the corresponding amount of iBTC tokens
        _burn(msg.sender, amount);

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

    function _processWithdrawals() internal returns (uint256 totalAmount) {
        totalAmount = 0; // Explicitly initialize totalAmount
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
    }

    function withdraw() external nonReentrant {
        uint256 totalAmount = _processWithdrawals();

        // Transfer the accumulated amount of XBTC to the user
        xbtc.safeTransfer(msg.sender, totalAmount);

        emit Withdraw(msg.sender, totalAmount);
    }

    function withdrawBTC() external nonReentrant {
        uint256 totalAmount = _processWithdrawals();

        // Convert the XBTC to BTC using the XBTC contract's `withdraw` method
        ixbtc.withdraw(totalAmount);

        // Transfer the BTC to the user
        Address.sendValue(payable(msg.sender), totalAmount);

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
        // Record XSAT balance before claiming rewards
        uint256 xsatBalanceBefore = xsat.balanceOf(address(this));
        stakeRouter.finalizeRewardDistribution();
        // Get the updated XSAT balance after reward distribution
        uint256 xsatBalanceAfter = xsat.balanceOf(address(this));
        require(xsatBalanceAfter >= xsatBalanceBefore, "Balance error: Insufficient XSAT");

        // Calculate the newly received rewards and reset the balance tracker
        uint256 amount = xsatBalanceAfter - xsatBalanceBefore;

        // Update the accumulated reward per share for iBTC holders
        accRewardPerShare += (amount * PRECISION) / supply;

        emit RewardDistributed(amount);
    }

    // Transfer stake to StakeRouter
    function transferStake(address _fromValidator, uint256 _amount) external nonReentrant {
        require(_amount > 0, "Amount must be greater than 0");

        // Call StakeRouter to perform the transfer
        stakeRouter.executeStakeTransfer(msg.sender, _fromValidator, _amount);

        // Mint new iBTC tokens to the user
        _mint(msg.sender, _amount);
        emit StakeTransferred(msg.sender, _fromValidator, _amount);
    }

    // Storage gap for upgradeable contracts
    uint256[50] private __gap;
}

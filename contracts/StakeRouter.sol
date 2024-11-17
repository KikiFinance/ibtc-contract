// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./IStakeHelper.sol";
import "./IStakeRouter.sol";

contract StakeRouter is IStakeRouter, OwnableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    struct Validator {
        address validatorAddress;
        uint256 minStakePerTx;
        uint256 maxStake;
        uint256 priority;
        uint256 currentStake;
    }

    IERC20 public xbtc;
    IERC20 public xsat;
    address public iBTC;
    IStakeHelper public stakeHelper;
    Validator[] public validators;

    event ValidatorAdded(address indexed validator, uint256 minStakePerTx, uint256 maxStake, uint256 priority);
    event ValidatorUpdated(address indexed validator, uint256 minStakePerTx, uint256 maxStake, uint256 priority);
    event Stake(address indexed validator, uint256 amount);
    event UnStake(address indexed validator, uint256 amount);
    event Withdraw(uint256 amount);
    event RewardDistributedPrepare(address indexed validator);
    event RewardDistributed(uint256 amount);
    event Restake(address indexed from, address indexed to, uint256 amount);


    modifier onlyIBTC() {
        require(msg.sender == iBTC, "Only the iBTC contract can call this function");
        _;
    }

    function initialize(address _xbtc, address _xsat, address _stakeHelper) external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        xbtc = IERC20(_xbtc);
        xsat = IERC20(_xsat);
        stakeHelper = IStakeHelper(_stakeHelper);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // One-Time Initialization
    function setIBTC(address _iBTC) external onlyOwner {
        if (iBTC == address(0)) {
            iBTC = _iBTC;
        }
    }

    function _sortValidatorsByPriority(uint256 startIndex) internal {
        // Sort validators array based on priority, starting from startIndex
        for (uint256 i = startIndex; i > 0; i--) {
            if (validators[i].priority > validators[i - 1].priority) {
                // Swap elements
                Validator memory temp = validators[i];
                validators[i] = validators[i - 1];
                validators[i - 1] = temp;
            } else {
                break; // Break early if the list is already sorted
            }
        }
    }

    function addValidator(
        address _validator,
        uint256 _minStakePerTx,
        uint256 _maxStake,
        uint256 _priority
    ) external onlyOwner {
        require(_minStakePerTx <= _maxStake, "Minimum stake must be less than maximum stake");

        // Check if the validator already exists
        for (uint256 i = 0; i < validators.length; i++) {
            require(validators[i].validatorAddress != _validator, "Validator already exists");
        }

        validators.push(Validator(_validator, _minStakePerTx, _maxStake, _priority, 0));
        emit ValidatorAdded(_validator, _minStakePerTx, _maxStake, _priority);

        // Sort validators based on priority
        _sortValidatorsByPriority(validators.length - 1);
    }

    function updateValidator(
        address _validator,
        uint256 _minStakePerTx,
        uint256 _maxStake,
        uint256 _priority
    ) external onlyOwner {
        require(_minStakePerTx <= _maxStake, "Minimum stake must be less than maximum stake");

        int256 index = getValidatorIndex(_validator);
        require(index >= 0, "Validator not found");

        Validator storage validator = validators[uint256(index)];

        // If currentStake is greater than 0, ensure it falls within the new range
        if (validator.currentStake > 0) {
            require(
                validator.currentStake <= _maxStake,
                "Current stake must be less than or equal to the maximum stake"
            );
        }

        // Update validator properties
        validator.minStakePerTx = _minStakePerTx;
        validator.maxStake = _maxStake;
        validator.priority = _priority;
        emit ValidatorUpdated(_validator, _minStakePerTx, _maxStake, _priority);

        // Sort validators based on priority after the update
        _sortValidatorsByPriority(uint256(index));
    }

    function removeValidator(address _validator) external onlyOwner {
        int256 index = getValidatorIndex(_validator);
        require(index >= 0, "Validator not found");

        uint256 validatorIndex = uint256(index);
        Validator storage validatorToRemove = validators[validatorIndex];

        // Ensure the validator's current stake is zero before removal
        require(
            validatorToRemove.currentStake == 0,
            "Cannot remove a validator with an active stake"
        );

        // Move the last element into the place of the element to be removed
        validators[validatorIndex] = validators[validators.length - 1];
        validators.pop(); // Remove the last element

        emit ValidatorUpdated(_validator, 0, 0, 0); // Optionally emit an event to signal removal
    }


    function deposit(uint256 _amount) external onlyIBTC nonReentrant {
        require(_amount > 0, "Amount must be greater than 0");
        xbtc.safeTransferFrom(address(iBTC), address(this), _amount);
        // Stake to stakeHelper
        xbtc.safeApprove(address(stakeHelper), _amount);

        uint256 remainingAmount = _amount;
        for (uint256 i = 0; i < validators.length; i++) {
            if (
                remainingAmount > 0 &&
                validators[i].currentStake < validators[i].maxStake &&
                remainingAmount >= validators[i].minStakePerTx
            ) {
                uint256 stakeAmount = remainingAmount;
                if (validators[i].currentStake + remainingAmount > validators[i].maxStake) {
                    stakeAmount = validators[i].maxStake - validators[i].currentStake;
                }
                stakeHelper.deposit(validators[i].validatorAddress, stakeAmount);
                validators[i].currentStake += stakeAmount;
                remainingAmount -= stakeAmount;
                emit Stake(validators[i].validatorAddress, stakeAmount);
            }
        }
        require(remainingAmount == 0, "Not enough validator capacity for stake");
    }

    function withdraw(uint256 _amount) external onlyIBTC nonReentrant {
        require(_amount > 0, "Amount must be greater than zero");
        uint256 remainingAmount = _amount;
        for (uint256 j = validators.length; j > 0; j--) {
            uint256 i = j - 1; // Adjusting for zero-based index
            if (remainingAmount > 0 && validators[i].currentStake > 0) {
                uint256 withdrawAmount = remainingAmount;

                // Ensure we do not withdraw more than available in currentStake
                if (withdrawAmount > validators[i].currentStake) {
                    withdrawAmount = validators[i].currentStake;
                }

                stakeHelper.withdraw(validators[i].validatorAddress, withdrawAmount);
                validators[i].currentStake -= withdrawAmount;
                remainingAmount -= withdrawAmount;
                emit UnStake(validators[i].validatorAddress, withdrawAmount);
            }
        }
        require(remainingAmount == 0, "Unable to fulfill the entire withdrawal amount");
    }

    function claimPendingFunds() external onlyIBTC nonReentrant {
        stakeHelper.claimPendingFunds();
        uint256 amount = xbtc.balanceOf(address(this));
        xbtc.safeTransfer(address(iBTC), amount);
        emit Withdraw(amount);
    }

    function _prepareRewardDistribution() internal {
        // Claim rewards from staking helper
        for (uint256 i = 0; i < validators.length; i++) {
            stakeHelper.claim(validators[i].validatorAddress);
            emit RewardDistributedPrepare(validators[i].validatorAddress);
        }
    }

    function prepareRewardDistribution() external onlyIBTC nonReentrant {
        _prepareRewardDistribution();
    }

    function finalizeRewardDistribution() external onlyIBTC nonReentrant {
        // transfer all xsat reward to iBTC
        uint256 amount = xsat.balanceOf(address(this));
        require(amount > 0, "Balance error: Insufficient XSAT");

        xsat.safeTransfer(address(iBTC), amount);
        emit RewardDistributed(amount);
    }

    function restake(address _from, address _to, uint256 _amount) external onlyOwner nonReentrant {
        require(_amount > 0, "Amount must be greater than zero");

        // Get the indexes of the _from and _to validators
        int256 fromIndex = getValidatorIndex(_from);
        int256 toIndex = getValidatorIndex(_to);

        require(fromIndex >= 0 && toIndex >= 0, "Invalid validator address");

        Validator storage fromValidator = validators[uint256(fromIndex)];
        Validator storage toValidator = validators[uint256(toIndex)];

        // Ensure _from has enough staked amount to restake
        require(fromValidator.currentStake >= _amount, "Insufficient stake in _from validator");

        // Ensure _to's stake does not exceed its maximum
        require(toValidator.currentStake + _amount <= toValidator.maxStake, "Exceeds max stake for _to validator");

        // Perform the restake through stakeHelper
        stakeHelper.restake(_from, _to, _amount);

        // Update validator stakes
        fromValidator.currentStake -= _amount;
        toValidator.currentStake += _amount;

        emit Restake(_from, _to, _amount);
    }

    function getValidatorIndex(address _validator) internal view returns (int256) {
        for (uint256 i = 0; i < validators.length; i++) {
            if (validators[i].validatorAddress == _validator) {
                return int256(i);
            }
        }
        return -1; // Not found
    }

    function lockTime() external view returns (uint256){
        return stakeHelper.lockTime();
    }

    // Storage gap for upgradeable contracts
    uint256[50] private __gap;
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "./IStakeHelper.sol";
import "./IStakeRouter.sol";
import "./PausableUpgradeable.sol";

contract StakeRouter is IStakeRouter, OwnableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");

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
    uint256 private constant PRECISION = 1e5; // Precision for reward calculations
    uint256 public serviceFeePercentage; // Service fee percentage (scaled by 1e5 for precision, e.g., 1% = 1e3)
    address public serviceFeeRecipient; // Address to receive the service fee
    uint256 public pendingWithdrawAmount; // Accumulated withdrawal amount waiting to be processed
    address public defaultValidator; // Default validator for transferStake


    event ValidatorAdded(address indexed validator, uint256 minStakePerTx, uint256 maxStake, uint256 priority);
    event ValidatorUpdated(address indexed validator, uint256 minStakePerTx, uint256 maxStake, uint256 priority);
    event ValidatorRemoved(address indexed validator);
    event Stake(address indexed validator, uint256 amount);
    event UnStake(address indexed validator, uint256 amount);
    event Withdraw(uint256 amount);
    event RewardDistributedPrepare(address indexed validator);
    event RewardDistributed(uint256 amount);
    event Restake(address indexed from, address indexed to, uint256 amount);
    event StakeTransferred(address indexed user, address fromValidator, address toValidator, uint256 amount);
    event ServiceFeePercentageUpdated(uint256 oldServiceFeePercentage, uint256 newServiceFeePercentage);
    event ServiceFeeRecipientUpdated(address oldServiceFeeRecipient, address newServiceFeeRecipient);
    event PendingWithdrawAmountChanged(uint256 oldAmount, uint256 newAmount); // Emitted when the pending withdrawal amount changes
    event DefaultValidatorUpdated(address oldValidator, address newValidator);


    modifier onlyIBTC() {
        require(msg.sender == iBTC, "Only the iBTC contract can call this function");
        _;
    }

    modifier onlyOperator() {
        require(hasRole(OPERATOR_ROLE, msg.sender), "Caller is not an operator");
        _;
    }

    modifier onlyPauseOperator() {
        require(hasRole(PAUSE_ROLE, msg.sender), "Only Pause Operator can perform this action");
        _;
    }

    function pause() public onlyPauseOperator {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }


    function initialize(address _xbtc, address _xsat, address _stakeHelper) external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __AccessControl_init();

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(OPERATOR_ROLE, msg.sender);

        xbtc = IERC20(_xbtc);
        xsat = IERC20(_xsat);
        stakeHelper = IStakeHelper(_stakeHelper);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function setIBTC(address _iBTC) external onlyOwner {
        if (iBTC == address(0)) {
            iBTC = _iBTC;
        }
    }

    // Partial Insertion Sort
    function _sortAddedValidatorsByPriority(uint256 startIndex) internal {
        for (uint256 i = startIndex; i > 0; i--) {
            if (validators[i].priority > validators[i - 1].priority) {
                Validator memory temp = validators[i];
                validators[i] = validators[i - 1];
                validators[i - 1] = temp;
            } else {
                break;
            }
        }
    }

    // Half-Side Insertion Sort
    function _sortUpdatedValidatorsByPriority(uint256 index) internal {
        uint256 n = validators.length;
        Validator memory updated = validators[index];

        if (index > 0 && updated.priority > validators[index - 1].priority) {
            uint256 j = index;

            while (j > 0 && updated.priority > validators[j - 1].priority) {
                validators[j] = validators[j - 1];
                j--;
            }

            validators[j] = updated;

        } else if (index < n - 1 && updated.priority < validators[index + 1].priority) {
            uint256 j = index;

            while (j < n - 1 && updated.priority < validators[j + 1].priority) {
                validators[j] = validators[j + 1];
                j++;
            }

            validators[j] = updated;
        }
    }


    function addValidator(
        address _validator,
        uint256 _minStakePerTx,
        uint256 _maxStake,
        uint256 _priority
    ) external onlyOperator whenNotPaused {
        require(_minStakePerTx <= _maxStake, "Minimum stake must be less than maximum stake");

        for (uint256 i = 0; i < validators.length; i++) {
            require(validators[i].validatorAddress != _validator, "Validator already exists");
        }

        validators.push(Validator(_validator, _minStakePerTx, _maxStake, _priority, 0));
        emit ValidatorAdded(_validator, _minStakePerTx, _maxStake, _priority);
        _sortAddedValidatorsByPriority(validators.length - 1);
    }

    function updateValidator(
        address _validator,
        uint256 _minStakePerTx,
        uint256 _maxStake,
        uint256 _priority
    ) external onlyOperator whenNotPaused {
        require(_minStakePerTx <= _maxStake, "Minimum stake must be less than maximum stake");

        int256 index = getValidatorIndex(_validator);
        require(index >= 0, "Validator not found");

        Validator storage validator = validators[uint256(index)];

        if (validator.currentStake > 0) {
            require(
                validator.currentStake <= _maxStake,
                "Current stake must be less than or equal to the maximum stake"
            );
        }

        validator.minStakePerTx = _minStakePerTx;
        validator.maxStake = _maxStake;
        validator.priority = _priority;

        emit ValidatorUpdated(_validator, _minStakePerTx, _maxStake, _priority);
        _sortUpdatedValidatorsByPriority(uint256(index));
    }


    function removeValidator(address _validator) external onlyOperator whenNotPaused {
        int256 index = getValidatorIndex(_validator);
        require(index >= 0, "Validator not found");

        uint256 validatorIndex = uint256(index);
        Validator storage validatorToRemove = validators[validatorIndex];

        require(
            validatorToRemove.currentStake == 0,
            "Cannot remove a validator with an active stake"
        );

        // Shift elements to the left to maintain order
        for (uint256 i = validatorIndex; i < validators.length - 1; i++) {
            validators[i] = validators[i + 1];
        }

        // Remove the last element
        validators.pop();
        emit ValidatorRemoved(_validator);
    }


    function deposit(uint256 _amount) external onlyIBTC nonReentrant whenNotPaused {
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
                validators[i].currentStake = stakeHelper.stakeInfo(validators[i].validatorAddress,address(this));
                remainingAmount -= stakeAmount;
                emit Stake(validators[i].validatorAddress, stakeAmount);
            }
        }
        require(remainingAmount == 0, "Not enough validator capacity for stake");
    }

    function withdraw(uint256 _amount) external onlyIBTC nonReentrant whenNotPaused {
        require(_amount > 0, "Amount must be greater than zero");
        uint256 oldAmount = pendingWithdrawAmount;
        pendingWithdrawAmount += _amount;
        emit PendingWithdrawAmountChanged(oldAmount, pendingWithdrawAmount);
    }

    function processBatchWithdrawals() external whenNotPaused {
        require(pendingWithdrawAmount > 0, "No pending withdrawals");

        uint256 remainingAmount = pendingWithdrawAmount;
        for (uint256 j = validators.length; j > 0; j--) {
            uint256 i = j - 1; // Adjusting for zero-based index
            if (remainingAmount > 0 && validators[i].currentStake > 0) {
                uint256 withdrawAmount = remainingAmount;

                // Ensure we do not withdraw more than available in currentStake
                if (withdrawAmount > validators[i].currentStake) {
                    withdrawAmount = validators[i].currentStake;
                }

                stakeHelper.withdraw(validators[i].validatorAddress, withdrawAmount);
                validators[i].currentStake = stakeHelper.stakeInfo(validators[i].validatorAddress,address(this));
                remainingAmount -= withdrawAmount;
                emit UnStake(validators[i].validatorAddress, withdrawAmount);
            }
        }
        require(remainingAmount == 0, "Unable to fulfill the entire withdrawal amount");
        uint256 oldAmount = pendingWithdrawAmount;
        pendingWithdrawAmount = 0;
        emit PendingWithdrawAmountChanged(oldAmount, pendingWithdrawAmount);
    }


    function claimPendingFunds() external whenNotPaused {
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

    function prepareRewardDistribution() external onlyIBTC nonReentrant whenNotPaused {
        _prepareRewardDistribution();
    }

    function finalizeRewardDistribution() external onlyIBTC nonReentrant whenNotPaused {
        // Get the XSAT balance of the contract
        uint256 amount = xsat.balanceOf(address(this));
        require(amount > 0, "Balance error: Insufficient XSAT");

        // Calculate the service fee if it's not zero
        uint256 serviceFee = 0;
        if (serviceFeePercentage > 0) {
            // Check if serviceFeeRecipient is set
            require(serviceFeeRecipient != address(0), "Service fee recipient not set");

            serviceFee = (amount * serviceFeePercentage) / PRECISION;
            // Transfer the service fee to the recipient (e.g., contract owner)
            xsat.safeTransfer(serviceFeeRecipient, serviceFee);
        }

        // Subtract the service fee from the total amount to be transferred to iBTC
        uint256 remainingAmount = amount - serviceFee;

        // Transfer the remaining XSAT reward to the iBTC contract
        xsat.safeTransfer(address(iBTC), remainingAmount);

        emit RewardDistributed(remainingAmount);
    }


    function restake(address _from, address _to, uint256 _amount) external onlyOperator nonReentrant whenNotPaused {
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
        fromValidator.currentStake = stakeHelper.stakeInfo(fromValidator.validatorAddress,address(this));
        toValidator.currentStake = stakeHelper.stakeInfo(toValidator.validatorAddress,address(this));

        emit Restake(_from, _to, _amount);
    }

    function getValidatorIndex(address _validator) internal view returns (int256) {
        for (uint256 i = validators.length; i > 0; i--) {
            if (validators[i - 1].validatorAddress == _validator) {
                return int256(i - 1);
            }
        }
        return -1; // Not found
    }

    function lockTime() external view returns (uint256){
        return stakeHelper.lockTime();
    }

    function setServiceFeePercentage(uint256 _serviceFeePercentage) external onlyOperator whenNotPaused {
        emit ServiceFeePercentageUpdated(serviceFeePercentage, _serviceFeePercentage);
        serviceFeePercentage = _serviceFeePercentage;
    }

    function setServiceFeeRecipient(address _serviceFeeRecipient) external onlyOperator whenNotPaused {
        require(_serviceFeeRecipient != address(0), "Service fee recipient cannot be the zero address");
        emit ServiceFeeRecipientUpdated(serviceFeeRecipient, _serviceFeeRecipient);
        serviceFeeRecipient = _serviceFeeRecipient;
    }

    function setDefaultValidator(address _defaultValidator) external onlyOperator whenNotPaused {
        require(_defaultValidator != address(0), "Default validator cannot be the zero address");
        emit DefaultValidatorUpdated(defaultValidator, _defaultValidator);
        defaultValidator = _defaultValidator;
    }

    function executeStakeTransfer(address _user, address _fromValidator, uint256 _amount) external onlyIBTC nonReentrant whenNotPaused {
        require(_amount > 0, "Amount must be greater than zero");

        // Ensure there's at least one validator
        require(defaultValidator != address(0), "Default validator not set");

        address _toValidator = defaultValidator;

        uint256 beforeAmount = stakeHelper.stakeInfo(_toValidator,address(this));

        // Call stakeHelper to perform the transfer
        stakeHelper.performTransfer(_user, _fromValidator, _toValidator, _amount);

        uint256 afterAmount = stakeHelper.stakeInfo(_toValidator,address(this));

        uint256 actualTransferAmount = afterAmount - beforeAmount;

        require(actualTransferAmount == _amount, "The actual transfer amount does not match the expected amount.");

        int256 index = getValidatorIndex(defaultValidator);
        require(index >= 0, "Validator not found");

        Validator storage validator = validators[uint256(index)];
        validator.currentStake = afterAmount;

        emit StakeTransferred(_user, _fromValidator, _toValidator, _amount);
    }


    // Storage gap for upgradeable contracts
    uint256[46] private __gap;
}
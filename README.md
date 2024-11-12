# ibtc-contract

## 1. iBTC Contract
### Functionality:

- The iBTC contract represents staked XBTC in a tokenized form. Users can deposit XBTC to receive iBTC on a 1:1 basis, representing their stake in the system.
- Key functions include:
	- Deposit: Users deposit XBTC in exchange for iBTC. The deposited XBTC is then staked through the StakeRouter.
	- Request Withdraw: Users can request to withdraw XBTC by burning an equivalent amount of iBTC, which triggers a lockup period determined by the StakeRouter.
	- Withdraw: After the lockup period ends, users can finalize their withdrawal and receive their XBTC.
	- Claim Rewards: Users can claim accumulated rewards (typically XSAT) from the staking process.
	- Reward Distribution Management: iBTC interacts with StakeRouter to prepare and finalize reward distributions based on accrued rewards.

### Dependencies:

- iBTC depends on the StakeRouter to manage staking and withdrawal of XBTC.
- It uses XSAT tokens to distribute rewards to users.


## 2. StakeRouter Contract
### Functionality:

- The StakeRouter acts as an intermediary layer that manages the delegation and distribution of staked XBTC among multiple validators.
- Key responsibilities include:
	- Adding Validators: The contract owner can add validators with specified minimum/maximum stake amounts and priorities.
	- Staking Management: When iBTC deposits XBTC, StakeRouter allocates the tokens across validators based on priority and capacity constraints.
	- Withdrawal Management: When iBTC requests a withdrawal, StakeRouter manages un-delegation of tokens from the appropriate validators.
	- Reward Distribution: The StakeRouter interacts with stakeHelper to claim rewards from validators and passes these rewards back to the iBTC contract for distribution.

### Dependencies:

- StakeRouter relies on the stakeHelper contract to handle lower-level staking and un-staking operations with individual validators.
- It directly interacts with the iBTC contract to ensure only iBTC can trigger certain operations (e.g., staking and withdrawal).

## 3. YieldPool Contract
### Functionality:

- The YieldPool functions as a deposit vault for iBTC, managing and storing user deposits securely.
- iBTC stored in the YieldPool cannot be moved and can only be redeemed by the users themselves.
- It manages the staking and yield distribution processes for iBTC deposits, ensuring controlled operations for deposits, withdrawals, and yield allocations.
- The YieldPool may include mechanisms for partner locks and other features to ensure security and transparency in deposit handling.

### Dependencies:

- YieldPool interacts with iBTC for managing staking and yield distribution.
- It operates independently of the StakeRouter and has no direct relationship with it.

## Summary of Relationships and Dependencies:
- iBTC <--> StakeRouter: iBTC leverages StakeRouter to manage staking operations. All XBTC deposit and withdrawal requests are routed through StakeRouter.
- StakeRouter <--> StakeHelper(exsat official): StakeRouter interacts with multiple validators through stakeHelper to manage the delegation and un-delegation of XBTC.
- YieldPool <--> iBTC: YieldPool serves as a vault for iBTC deposits, with all deposits, withdrawals, and yield distributions handled solely through iBTC. iBTC in the YieldPool can only be redeemed by users themselves.


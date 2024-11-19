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

## Summary of Relationships and Dependencies:
- iBTC <--> StakeRouter: iBTC leverages StakeRouter to manage staking operations. All XBTC deposit and withdrawal requests are routed through StakeRouter.
- StakeRouter <--> StakeHelper(exsat official): StakeRouter interacts with multiple validators through stakeHelper to manage the delegation and un-delegation of XBTC.


## 3.Bridge Contract
### Functionality:

- The Bridge contract facilitates cross-chain transfers of iBTC tokens between the exSat network and other networks (e.g., Ethereum).
- Key functions include:
  - Deposit: Users can deposit iBTC to the Bridge contract on one network. This triggers an event monitored by oracles, initiating a cross-chain minting process.
  - Withdraw: Users can withdraw iBTC from the Bridge contract by burning the corresponding iBTC amount on another supported network. Oracles validate the transaction to confirm its legitimacy.
  - Guardian Signature Verification: The Bridge relies on a quorum of guardians to verify cross-chain transactions. This ensures security and prevents unauthorized transfers.
  - Mint: When a user deposits iBTC to the Bridge on one network, the contract on the other network mints the equivalent iBTC amount, maintaining a 1:1 peg across chains.
  - Cross-Chain Burn: For withdrawals, the iBTC tokens are burned on one network, reducing the total supply to maintain the peg consistency across chains.

### Dependencies:

- Oracles: The Bridge relies on oracles to monitor events and relay information between the exSat network and other networks. They play a critical role in ensuring transactions are legitimate and correctly processed across different chains.
- Guardian Signatures: The Bridge contract requires a set number of valid guardian signatures (a quorum) for certain sensitive operations, such as minting iBTC on the target network. This helps ensure security and decentralization.
- On the exSat network, cross-chain transfers of iBTC are achieved through locking and unlocking operations. When users deposit iBTC on the exSat side, the tokens are locked in the contract rather than being minted or burned. This ensures that the iBTC supply on the exSat network remains constant while cross-chain transfers are handled.
- On other EVM-compatible chains, the Bridge contract is responsible for minting and burning iBTC. This ensures a 1:1 peg with the iBTC tokens locked on the exSat network. When users deposit or withdraw iBTC on these chains, the Bridge contract handles minting or burning the tokens to maintain consistency.

## Summary of Relationships and Dependencies for the Bridge:
- iBTC <--> Bridge (Lock and Mint Mechanism): The iBTC contract interacts with the Bridge contract to facilitate cross-chain transfers of iBTC. On the exSat network, iBTC tokens are locked when initiating a cross-chain transfer, while on other EVM-compatible chains, the Bridge contract mints the equivalent amount of iBTC tokens. Similarly, when iBTC is transferred back, the process involves burning the iBTC on the EVM-compatible chain and unlocking it on the exSat network, maintaining a consistent 1:1 peg across networks.
- Bridge <--> Oracles: Oracles monitor events on the Bridge contract to facilitate cross-chain communication and ensure legitimate cross-chain transfers.
- Bridge <--> Guardians: The Bridge relies on a set of trusted guardians to verify sensitive transactions through signature validation, enhancing security and decentralization.

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

contract iBTCOriginBridge is Initializable, OwnableUpgradeable, PausableUpgradeable, UUPSUpgradeable, AccessControlUpgradeable {
    using ECDSA for bytes32;

    ERC20 public ibtcToken; // ERC-20 iBTC token on exSat
    ERC20 public xSATToken; // ERC-20 XSAT token on exSat
    mapping(bytes32 => bool) public processedTransactions; // Track processed transactions
    address[] private guardians;
    mapping(address => uint256) private guardianIndicesOneBased;
    uint256 public quorum;
    bytes32 public WITHDRAW_MESSAGE_PREFIX;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    struct Signature {
        bytes32 r;
        bytes32 vs;
    }

    event Deposit(address indexed user, bytes32 indexed txHash, uint256 amount);
    event Withdraw(bytes32 indexed msgHash, bytes32 indexed burnTxHash, address indexed destAddr, uint256 amount);
    event GuardianAdded(address indexed guardian);
    event GuardianRemoved(address indexed guardian);
    event GuardianQuorumChanged(uint256 newQuorum);
    event XSATTransferred(address indexed to, uint256 amount);

    function initialize(address _ibtcToken, address _xSATToken, uint256 _quorum) public initializer {
        require(_quorum > 1, "Quorum must be greater than 1");
        quorum = _quorum;

        __Ownable_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __AccessControl_init();

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender); // Grant owner default admin role
        _setupRole(OPERATOR_ROLE, msg.sender); // Grant owner initial operator role

        ibtcToken = ERC20(_ibtcToken);
        xSATToken = ERC20(_xSATToken);

        WITHDRAW_MESSAGE_PREFIX = keccak256(abi.encodePacked(keccak256("CrossChainWithdraw"), block.chainid, address(this)));
    }

    // Required by UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // Manage guardians
    function addGuardian(address addr) external onlyOwner {
        require(addr != address(0), "Invalid address");
        require(!_isGuardian(addr), "Already a guardian");
        guardians.push(addr);
        guardianIndicesOneBased[addr] = guardians.length;
        emit GuardianAdded(addr);
    }

    function removeGuardian(address addr) external onlyOwner {
        uint256 indexOneBased = guardianIndicesOneBased[addr];
        require(indexOneBased > 0, "Not a guardian");

        uint256 totalGuardians = guardians.length;
        if (indexOneBased != totalGuardians) {
            address lastGuardian = guardians[totalGuardians - 1];
            guardians[indexOneBased - 1] = lastGuardian;
            guardianIndicesOneBased[lastGuardian] = indexOneBased;
        }

        guardians.pop();
        guardianIndicesOneBased[addr] = 0;
        emit GuardianRemoved(addr);
    }

    function setQuorum(uint256 newQuorum) external onlyOwner {
        require(newQuorum > 1, "Quorum must be greater than 1");
        quorum = newQuorum;
        emit GuardianQuorumChanged(newQuorum);
    }

    function isGuardian(address addr) external view returns (bool) {
        return _isGuardian(addr);
    }

    function _isGuardian(address addr) internal view returns (bool) {
        return guardianIndicesOneBased[addr] > 0;
    }

    // User deposits iBTC for cross-chain transfer
    function deposit(uint256 amount) external whenNotPaused {
        require(ibtcToken.balanceOf(msg.sender) >= amount, "Insufficient iBTC balance");
        ibtcToken.transferFrom(msg.sender, address(this), amount);
        bytes32 txHash = keccak256(abi.encodePacked(msg.sender, amount, block.timestamp));
        emit Deposit(msg.sender, txHash, amount);
    }

    // Oracle calls this function to release iBTC to the user, verified by guardians
    function withdraw(
        bytes32 burnTxHash,
        uint256 amount,
        Signature[] calldata sortedGuardianSignatures
    ) external whenNotPaused {
        require(!processedTransactions[burnTxHash], "Transaction already processed");
        require(sortedGuardianSignatures.length >= quorum, "Insufficient guardian signatures count");

        bytes32 msgHash = _verifySignatures(burnTxHash, msg.sender, amount, sortedGuardianSignatures);
        processedTransactions[msgHash] = true;
        ibtcToken.transfer(msg.sender, amount);
        emit Withdraw(msgHash, burnTxHash, msg.sender, amount);
    }

    // Transfer xSAT tokens with operator role
    function transferXSAT(address to, uint256 amount) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        require(xSATToken.balanceOf(address(this)) >= amount, "Insufficient xSAT balance");
        xSATToken.transfer(to, amount);
        emit XSATTransferred(to, amount);
    }

    function _verifySignatures(
        bytes32 txHash,
        address destAddr,
        uint256 amount,
        Signature[] memory sigs
    ) internal view returns (bytes32) {
        bytes memory prefix = "\x19Ethereum Signed Message:\n32";
        bytes32 msgHash = calcMsgHash(txHash, destAddr, amount);
        bytes32 prefixedHash = keccak256(abi.encodePacked(prefix, msgHash));

        address prevSigner = address(0);
        for (uint256 i = 0; i < sigs.length; ++i) {
            address signer = ECDSA.recover(prefixedHash, sigs[i].r, sigs[i].vs);
            require(_isGuardian(signer), "Invalid guardian signature");
            require(signer > prevSigner, "Signatures not in order");
            prevSigner = signer;
        }
        return msgHash;
    }

    function calcMsgHash(
        bytes32 txHash,
        address destAddr,
        uint256 amount
    ) public view returns (bytes32 msgHash) {
        msgHash = keccak256(
            abi.encodePacked(
                WITHDRAW_MESSAGE_PREFIX, txHash, destAddr, amount
            )
        );
        return msgHash;
    }

    // Pause bridge operations
    function pause() external onlyOwner {
        _pause();
    }

    // Unpause bridge operations
    function unpause() external onlyOwner {
        _unpause();
    }
}

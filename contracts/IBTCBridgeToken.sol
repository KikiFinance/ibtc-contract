// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract IBTCBridgeToken is Initializable, ERC20Upgradeable, OwnableUpgradeable, PausableUpgradeable, UUPSUpgradeable
{
    using ECDSA for bytes32;

    struct Signature {
        bytes32 r;
        bytes32 vs;
    }

    bytes32 public MINT_MESSAGE_PREFIX;
    uint256 public quorum;
    address[] private guardians;
    mapping(address => uint256) private guardianIndicesOneBased;
    mapping(bytes32 => bool) public processedTransactions;

    event GuardianAdded(address indexed guardian);
    event GuardianRemoved(address indexed guardian);
    event GuardianQuorumChanged(uint256 newQuorum);
    event TokenMinted(
        bytes32 indexed msgHash,
        bytes32 indexed txHash,
        address indexed destAddr,
        uint256 amount
    );

    event TokenBurned(
        address indexed user,
        bytes32 indexed txHash,
        uint256 amount
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    function initialize(uint256 _quorum) public initializer {
        require(_quorum > 1, "Quorum must be greater than 1");
        quorum = _quorum;

        __ERC20_init("iBTC", "iBTC");
        __Ownable_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        MINT_MESSAGE_PREFIX = keccak256(abi.encodePacked(keccak256("CrossChainMint"), block.chainid, address(this)));
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

    function mint(
        bytes32 depositTxHash,
        uint256 amount,
        Signature[] calldata sortedGuardianSignatures
    ) external whenNotPaused {
        require(quorum > 1, "Quorum not set");
        require(sortedGuardianSignatures.length >= quorum, "Insufficient guardian signatures");

        bytes32 msgHash = _verifySignatures(depositTxHash, msg.sender, amount, sortedGuardianSignatures);
        require(!processedTransactions[msgHash], "Transaction already processed");

        processedTransactions[msgHash] = true;
        _mint(msg.sender, amount);
        emit TokenMinted(msgHash, depositTxHash, msg.sender, amount);
    }

    function burn(uint256 amount) external whenNotPaused {
        require(amount > 0, "Amount must be greater than 0");

        // Burn tokens from the user's balance
        _burn(msg.sender, amount);

        // Emit an event to signal the burn operation
        bytes32 txHash = keccak256(abi.encodePacked(msg.sender, amount, block.timestamp));
        emit TokenBurned(msg.sender, txHash, amount);

        // Note: After burning, the user can redeem the equivalent amount of iBTC on the exSat network.
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
                MINT_MESSAGE_PREFIX, txHash, destAddr, amount
            )
        );
        return msgHash;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}

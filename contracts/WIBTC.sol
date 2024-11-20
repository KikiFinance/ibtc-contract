// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IiBTC {
    function claimReward() external;
}

contract WIBTC is ERC20, Ownable {
    using SafeERC20 for IERC20;

    IiBTC public immutable iBTC;
    IERC20 public immutable iBTCToken;
    IERC20 public immutable XSAT;

    event Deposit(address indexed user, uint256 amountIn, uint256 amountOut);
    event Withdraw(address indexed user, uint256 amountIn, uint256 amountOut);
    event XSATTransferred(address indexed to, uint256 amount);

    constructor(address _iBTC,  address _XSAT) ERC20("Wrapped iBTC", "WIBTC") {
        iBTC = IiBTC(_iBTC);
        iBTCToken = IERC20(_iBTC);
        XSAT = IERC20(_XSAT);
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        iBTCToken.safeTransferFrom(msg.sender, address(this), amount);

        _mint(msg.sender, amount);
        emit Deposit(msg.sender, amount, amount);
    }

    function withdraw(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");

        _burn(msg.sender, amount);

        iBTCToken.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount, amount);
    }

    function collectYield() external {
        iBTC.claimReward();
    }

    function transferXSAT(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid address");
        require(amount > 0, "Amount must be greater than 0");
        require(XSAT.balanceOf(address(this)) >= amount, "Insufficient XSAT balance");

        XSAT.safeTransfer(to, amount);
        emit XSATTransferred(to, amount);
    }
}

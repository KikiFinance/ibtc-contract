pragma solidity >=0.4.18;

interface IXBTC {

    function deposit() external payable;

    function withdraw(uint wad) external;
}
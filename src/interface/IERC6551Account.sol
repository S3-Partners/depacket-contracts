// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IERC6551Account {
    receive() external payable;

    function token() external view returns (uint256 chainId, address tokenContract, uint256 tokenId);
    function state() external view returns (uint256);
    function owner() external view returns (address);
    function isValidSigner(address signer, bytes calldata context) external view returns (bytes4 magicValue);
    function execute(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        returns (bytes memory);

    event OpenRedPacket(address indexed recipient, address indexed erc20, uint256 amount, uint256 value);
}

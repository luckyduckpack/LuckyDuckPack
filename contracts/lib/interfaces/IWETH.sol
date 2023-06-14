// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

/**
 * @dev Interface to wrap/unwrap ETH.
 */
interface IWETH {

    /**
     * @dev Wrap (ETH -> WETH).
     */
    function deposit() external payable;

    /**
     * @dev Unwrap (WETH -> ETH).
     */
    function withdraw(uint256 value) external;

    /**
     * @dev WETH balance.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Send `value` WETH to `address`.
     */
    function transfer(address to, uint value) external returns (bool);
}
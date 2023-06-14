// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "../interfaces/IWETH.sol";

/**
 * @dev Workaround to embed WETH unwraps in more complex logics without running out of gas.
 */
contract WethUnwrapper{
    // WETH contract
    IWETH public WETH;
    // Creator's address - only Creator is allowed to interact
    address public creator;

    // Error returned if caller is not the contract Creator
    error CallerIsNotDeployer();

    /**
     * @dev Store Creator address and initialize WETH contract instance.
     */
    constructor(address _wethContract){
        creator=msg.sender;
        WETH = IWETH(_wethContract);
    }

    /**
     * @dev Ensures only Creator can interact.
     */
    modifier onlyCreator{
        if(msg.sender!=creator) revert CallerIsNotDeployer();
        _;
    }

    /**
     * @dev Calls WETH contract to unwrap WETH balance.
     */
    function unwrap_aof(uint256 amount) external onlyCreator {
        WETH.withdraw(amount);
    }

    /**
     * @dev Allows to send ETH balance to Creator.
     */
    function withdraw_wdp() external onlyCreator{
        (bool success, ) = msg.sender.call{value: address(this).balance}("");
        require(success);
    }

    /**
     * @dev Ensures WETH contract is able to send ETH to this.
     */
    receive() external payable{}
}
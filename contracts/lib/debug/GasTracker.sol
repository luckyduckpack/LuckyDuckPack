// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

abstract contract GasTracker{

    event GasUsed(uint256 indexed amount);

    modifier TrackGas(){
        uint256 __gasBefore__ = gasleft();
        _;
        uint256 __gasCost__ = __gasBefore__-gasleft();
        emit GasUsed(__gasCost__);
    }
}
// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

interface IFactory {
    function collateralTroveManager(address collateral) external view returns (address);
}

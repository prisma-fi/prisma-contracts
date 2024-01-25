// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

struct ReedemedTrove {
    address account;
    uint256 debtLot;
    uint256 collateralLot;
}

interface ITroveRedemptionsCallback {
    /**
     * @notice Function called after redemptions are executed in a Trove Manager
     * @dev This functions should be called EXCLUSIVELY by a registered Trove Manger
     * @param redemptions Values related to redeemed troves
     */
    function onRedemptions(ReedemedTrove[] memory redemptions) external returns (bool);
}

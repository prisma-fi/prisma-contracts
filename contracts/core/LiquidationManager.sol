// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IStabilityPool.sol";
import "../interfaces/ISortedTroves.sol";
import "../interfaces/ITroveManager.sol";
import "../dependencies/PrismaMath.sol";
import "../dependencies/PrismaBase.sol";

/**
    @title Prisma Liquidation Manager
    @notice Based on Liquity's `TroveManager`
            https://github.com/liquity/dev/blob/main/packages/contracts/contracts/TroveManager.sol

            This contract has a 1:n relationship with `TroveManager`, handling liquidations
            for every active collateral within the system.
 */
contract LiquidationManager is PrismaBase {
    IStabilityPool public immutable stabilityPool;
    address public immutable factory;

    mapping(IERC20 => ITroveManager) internal _trovesContracts;

    /*
     * --- Variable container structs for liquidations ---
     *
     * These structs are used to hold, return and assign variables inside the liquidation functions,
     * in order to avoid the error: "CompilerError: Stack too deep".
     **/

    struct LocalVariables_OuterLiquidationFunction {
        uint256 price;
        uint256 debtInStabPool;
        bool recoveryModeAtStart;
        uint256 liquidatedDebt;
        uint256 liquidatedColl;
    }

    struct LocalVariables_InnerSingleLiquidateFunction {
        uint256 collToLiquidate;
        uint256 pendingDebtReward;
        uint256 pendingCollReward;
    }

    struct LocalVariables_LiquidationSequence {
        uint256 remainingDebtInStabPool;
        uint256 i;
        uint256 ICR;
        address user;
        bool backToNormalMode;
        uint256 entireSystemDebt;
        uint256 entireSystemColl;
    }

    struct LiquidationValues {
        uint256 entireTroveDebt;
        uint256 entireTroveColl;
        uint256 collGasCompensation;
        uint256 debtGasCompensation;
        uint256 debtToOffset;
        uint256 collToSendToSP;
        uint256 debtToRedistribute;
        uint256 collToRedistribute;
        uint256 collSurplus;
    }

    struct LiquidationTotals {
        uint256 totalCollInSequence;
        uint256 totalDebtInSequence;
        uint256 totalCollGasCompensation;
        uint256 totalDebtGasCompensation;
        uint256 totalDebtToOffset;
        uint256 totalCollToSendToSP;
        uint256 totalDebtToRedistribute;
        uint256 totalCollToRedistribute;
        uint256 totalCollSurplus;
    }

    event TroveUpdated(
        address indexed _borrower,
        uint256 _debt,
        uint256 _coll,
        uint256 _stake,
        TroveManagerOperation _operation
    );
    event TroveLiquidated(address indexed _borrower, uint256 _debt, uint256 _coll, TroveManagerOperation _operation);
    event Liquidation(
        uint256 _liquidatedDebt,
        uint256 _liquidatedColl,
        uint256 _collGasCompensation,
        uint256 _debtGasCompensation
    );
    event TroveUpdated(address indexed _borrower, uint256 _debt, uint256 _coll, uint256 stake, uint8 operation);
    event TroveLiquidated(address indexed _borrower, uint256 _debt, uint256 _coll, uint8 operation);

    enum TroveManagerOperation {
        applyPendingRewards,
        liquidateInNormalMode,
        liquidateInRecoveryMode,
        redeemCollateral
    }

    constructor(
        IStabilityPool _stabilityPoolAddress,
        address _factory,
        uint256 _gasCompensation
    ) PrismaBase(_gasCompensation) {
        stabilityPool = _stabilityPoolAddress;
        factory = _factory;
    }

    function enableCollateral(address _troveManager, IERC20 _collateral) external {
        require(msg.sender == factory, "Not factory");
        _trovesContracts[_collateral] = ITroveManager(_troveManager);
    }

    // --- Trove Liquidation functions ---

    // Single liquidation function. Closes the trove if its ICR is lower than the minimum collateral ratio.
    function liquidate(IERC20 collateral, address _borrower) external {
        ITroveManager troveManager = _trovesContracts[collateral];

        require(troveManager.getTroveStatus(_borrower) == 1, "TroveManager: Trove does not exist or is closed");

        address[] memory borrowers = new address[](1);
        borrowers[0] = _borrower;
        batchLiquidateTroves(collateral, borrowers);
    }

    /*
     * Liquidate a sequence of troves. Closes a maximum number of n under-collateralized Troves,
     * starting from the one with the lowest collateral ratio in the system, and moving upwards
     */
    function liquidateTroves(IERC20 collateral, uint256 _n) external {
        ITroveManager troveManager = _trovesContracts[collateral];

        troveManager.updateBalances();
        IStabilityPool stabilityPoolCached = stabilityPool;

        LocalVariables_OuterLiquidationFunction memory vars;

        LiquidationTotals memory totals;

        vars.price = troveManager.fetchPrice();
        vars.debtInStabPool = stabilityPoolCached.getTotalDebtTokenDeposits();
        vars.recoveryModeAtStart = troveManager.checkRecoveryMode(vars.price);

        // Perform the appropriate liquidation sequence - tally the values, and obtain their totals
        if (vars.recoveryModeAtStart) {
            totals = _getTotalsFromLiquidateTrovesSequence_RecoveryMode(
                troveManager,
                vars.price,
                vars.debtInStabPool,
                _n
            );
        } else {
            // if !vars.recoveryModeAtStart
            totals = _getTotalsFromLiquidateTrovesSequence_NormalMode(
                troveManager,
                vars.price,
                vars.debtInStabPool,
                _n
            );
        }

        require(totals.totalDebtInSequence > 0, "TroveManager: nothing to liquidate");
        if (totals.totalDebtToOffset > 0 || totals.totalCollToSendToSP > 0) {
            // Move liquidated collateral and Debt to the appropriate pools
            stabilityPoolCached.offset(address(collateral), totals.totalDebtToOffset, totals.totalCollToSendToSP);
            troveManager.decreaseDebtAndSendCollateral(
                address(stabilityPoolCached),
                totals.totalDebtToOffset,
                totals.totalCollToSendToSP
            );
        }
        troveManager.finalizeLiquidation(
            msg.sender,
            totals.totalDebtToRedistribute,
            totals.totalCollToRedistribute,
            totals.totalCollSurplus,
            totals.totalDebtGasCompensation,
            totals.totalCollGasCompensation
        );

        vars.liquidatedDebt = totals.totalDebtInSequence;
        vars.liquidatedColl = totals.totalCollInSequence - totals.totalCollGasCompensation - totals.totalCollSurplus;
        emit Liquidation(
            vars.liquidatedDebt,
            vars.liquidatedColl,
            totals.totalCollGasCompensation,
            totals.totalDebtGasCompensation
        );
    }

    /*
     * Attempt to liquidate a custom list of troves provided by the caller.
     */
    function batchLiquidateTroves(IERC20 collateral, address[] memory _troveArray) public {
        ITroveManager troveManager = _trovesContracts[collateral];
        require(_troveArray.length != 0, "TroveManager: Calldata address array must not be empty");
        troveManager.updateBalances();
        IStabilityPool stabilityPoolCached = stabilityPool;

        LocalVariables_OuterLiquidationFunction memory vars;
        LiquidationTotals memory totals;

        vars.price = troveManager.fetchPrice();
        vars.debtInStabPool = stabilityPoolCached.getTotalDebtTokenDeposits();
        vars.recoveryModeAtStart = troveManager.checkRecoveryMode(vars.price);
        // Perform the appropriate liquidation sequence - tally values and obtain their totals.
        if (vars.recoveryModeAtStart) {
            totals = _getTotalFromBatchLiquidate_RecoveryMode(
                troveManager,
                vars.price,
                vars.debtInStabPool,
                _troveArray
            );
        } else {
            //  if !vars.recoveryModeAtStart
            totals = _getTotalsFromBatchLiquidate_NormalMode(
                troveManager,
                vars.price,
                vars.debtInStabPool,
                _troveArray
            );
        }

        require(totals.totalDebtInSequence > 0, "TroveManager: nothing to liquidate");

        if (totals.totalDebtToOffset > 0 || totals.totalCollToSendToSP > 0) {
            // Move liquidated collateral and Debt to the appropriate pools
            stabilityPoolCached.offset(address(collateral), totals.totalDebtToOffset, totals.totalCollToSendToSP);
            troveManager.decreaseDebtAndSendCollateral(
                address(stabilityPoolCached),
                totals.totalDebtToOffset,
                totals.totalCollToSendToSP
            );
        }
        troveManager.finalizeLiquidation(
            msg.sender,
            totals.totalDebtToRedistribute,
            totals.totalCollToRedistribute,
            totals.totalCollSurplus,
            totals.totalDebtGasCompensation,
            totals.totalCollGasCompensation
        );

        vars.liquidatedDebt = totals.totalDebtInSequence;
        vars.liquidatedColl = totals.totalCollInSequence - totals.totalCollGasCompensation - totals.totalCollSurplus;
        emit Liquidation(
            vars.liquidatedDebt,
            vars.liquidatedColl,
            totals.totalCollGasCompensation,
            totals.totalDebtGasCompensation
        );
    }

    // --- Inner single liquidation functions ---

    /*
     * This function is used when the liquidateTroves sequence starts during Recovery Mode. However, it
     * handle the case where the system *leaves* Recovery Mode, part way through the liquidation sequence
     */
    function _getTotalsFromLiquidateTrovesSequence_RecoveryMode(
        ITroveManager troveManager,
        uint256 _price,
        uint256 _debtInStabPool,
        uint256 _n
    ) internal returns (LiquidationTotals memory totals) {
        LocalVariables_LiquidationSequence memory vars;
        LiquidationValues memory singleLiquidation;

        vars.remainingDebtInStabPool = _debtInStabPool;
        vars.backToNormalMode = false;
        vars.entireSystemDebt = troveManager.getEntireSystemDebt();
        vars.entireSystemColl = troveManager.getEntireSystemColl();
        ISortedTroves sortedTroves = ISortedTroves(troveManager.sortedTroves());
        vars.user = sortedTroves.getLast();
        address firstUser = sortedTroves.getFirst();
        for (vars.i = 0; vars.i < _n && vars.user != firstUser; vars.i++) {
            // we need to cache it, because current user is likely going to be deleted
            address nextUser = sortedTroves.getPrev(vars.user);

            vars.ICR = troveManager.getCurrentICR(vars.user, _price);

            if (!vars.backToNormalMode) {
                // Break the loop if ICR is greater than MCR and Stability Pool is empty
                if (vars.ICR >= MCR && vars.remainingDebtInStabPool == 0) {
                    break;
                }

                uint256 TCR = PrismaMath._computeCR(vars.entireSystemColl, vars.entireSystemDebt, _price);

                singleLiquidation = _liquidateRecoveryMode(
                    troveManager,
                    vars.user,
                    vars.ICR,
                    vars.remainingDebtInStabPool,
                    TCR,
                    _price
                );

                // Update aggregate trackers
                vars.remainingDebtInStabPool = vars.remainingDebtInStabPool - singleLiquidation.debtToOffset;
                vars.entireSystemDebt = vars.entireSystemDebt - singleLiquidation.debtToOffset;
                vars.entireSystemColl =
                    vars.entireSystemColl -
                    singleLiquidation.collToSendToSP -
                    singleLiquidation.collSurplus;

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);

                vars.backToNormalMode = !_checkPotentialRecoveryMode(
                    vars.entireSystemColl,
                    vars.entireSystemDebt,
                    _price
                );
            } else if (vars.backToNormalMode && vars.ICR < MCR) {
                singleLiquidation = _liquidateNormalMode(troveManager, vars.user, vars.remainingDebtInStabPool);

                vars.remainingDebtInStabPool = vars.remainingDebtInStabPool - singleLiquidation.debtToOffset;

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);
            } else break; // break if the loop reaches a Trove with ICR >= MCR

            vars.user = nextUser;
        }
    }

    function _getTotalsFromLiquidateTrovesSequence_NormalMode(
        ITroveManager troveManager,
        uint256 _price,
        uint256 _debtInStabPool,
        uint256 _n
    ) internal returns (LiquidationTotals memory totals) {
        LocalVariables_LiquidationSequence memory vars;
        LiquidationValues memory singleLiquidation;
        ISortedTroves sortedTrovesCached = ISortedTroves(troveManager.sortedTroves());
        vars.remainingDebtInStabPool = _debtInStabPool;

        for (vars.i = 0; vars.i < _n; vars.i++) {
            vars.user = sortedTrovesCached.getLast();
            vars.ICR = troveManager.getCurrentICR(vars.user, _price);
            if (vars.ICR < MCR) {
                singleLiquidation = _liquidateNormalMode(troveManager, vars.user, vars.remainingDebtInStabPool);

                vars.remainingDebtInStabPool = vars.remainingDebtInStabPool - singleLiquidation.debtToOffset;

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);
            } else break; // break if the loop reaches a Trove with ICR >= MCR
        }
    }

    /*
     * This function is used when the batch liquidation sequence starts during Recovery Mode. However, it
     * handle the case where the system *leaves* Recovery Mode, part way through the liquidation sequence
     */
    function _getTotalFromBatchLiquidate_RecoveryMode(
        ITroveManager troveManager,
        uint256 _price,
        uint256 _debtInStabPool,
        address[] memory _troveArray
    ) internal returns (LiquidationTotals memory totals) {
        LocalVariables_LiquidationSequence memory vars;
        LiquidationValues memory singleLiquidation;

        vars.remainingDebtInStabPool = _debtInStabPool;
        vars.backToNormalMode = false;
        vars.entireSystemDebt = troveManager.getEntireSystemDebt();
        vars.entireSystemColl = troveManager.getEntireSystemColl();

        for (vars.i = 0; vars.i < _troveArray.length; vars.i++) {
            vars.user = _troveArray[vars.i];
            // Skip non-active troves
            if (troveManager.getTroveStatus(vars.user) != 1) {
                continue;
            }
            vars.ICR = troveManager.getCurrentICR(vars.user, _price);
            if (!vars.backToNormalMode) {
                // Skip this trove if ICR is greater than MCR and Stability Pool is empty
                if (vars.ICR >= MCR && vars.remainingDebtInStabPool == 0) {
                    continue;
                }

                uint256 TCR = PrismaMath._computeCR(vars.entireSystemColl, vars.entireSystemDebt, _price);

                singleLiquidation = _liquidateRecoveryMode(
                    troveManager,
                    vars.user,
                    vars.ICR,
                    vars.remainingDebtInStabPool,
                    TCR,
                    _price
                );

                // Update aggregate trackers
                vars.remainingDebtInStabPool = vars.remainingDebtInStabPool - singleLiquidation.debtToOffset;
                vars.entireSystemDebt = vars.entireSystemDebt - singleLiquidation.debtToOffset;
                vars.entireSystemColl = vars.entireSystemColl - singleLiquidation.collToSendToSP;

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);

                vars.backToNormalMode = !_checkPotentialRecoveryMode(
                    vars.entireSystemColl,
                    vars.entireSystemDebt,
                    _price
                );
            } else if (vars.backToNormalMode && vars.ICR < MCR) {
                singleLiquidation = _liquidateNormalMode(troveManager, vars.user, vars.remainingDebtInStabPool);
                vars.remainingDebtInStabPool = vars.remainingDebtInStabPool - singleLiquidation.debtToOffset;

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);
            } else continue; // In Normal Mode skip troves with ICR >= MCR
        }
    }

    function _getTotalsFromBatchLiquidate_NormalMode(
        ITroveManager troveManager,
        uint256 _price,
        uint256 _debtInStabPool,
        address[] memory _troveArray
    ) internal returns (LiquidationTotals memory totals) {
        LocalVariables_LiquidationSequence memory vars;
        LiquidationValues memory singleLiquidation;

        vars.remainingDebtInStabPool = _debtInStabPool;

        for (vars.i = 0; vars.i < _troveArray.length; vars.i++) {
            vars.user = _troveArray[vars.i];
            vars.ICR = troveManager.getCurrentICR(vars.user, _price);
            if (vars.ICR < MCR) {
                singleLiquidation = _liquidateNormalMode(troveManager, vars.user, vars.remainingDebtInStabPool);
                vars.remainingDebtInStabPool = vars.remainingDebtInStabPool - singleLiquidation.debtToOffset;

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);
            }
        }
    }

    // Liquidate one trove, in Normal Mode.
    function _liquidateNormalMode(
        ITroveManager troveManager,
        address _borrower,
        uint256 _debtInStabPool
    ) internal returns (LiquidationValues memory singleLiquidation) {
        LocalVariables_InnerSingleLiquidateFunction memory vars;

        (
            singleLiquidation.entireTroveDebt,
            singleLiquidation.entireTroveColl,
            vars.pendingDebtReward,
            vars.pendingCollReward
        ) = troveManager.getEntireDebtAndColl(_borrower);

        troveManager.movePendingTroveRewardsToActiveBalances(vars.pendingDebtReward, vars.pendingCollReward);

        singleLiquidation.collGasCompensation = _getCollGasCompensation(singleLiquidation.entireTroveColl);
        singleLiquidation.debtGasCompensation = DEBT_GAS_COMPENSATION;
        uint256 collToLiquidate = singleLiquidation.entireTroveColl - singleLiquidation.collGasCompensation;

        (
            singleLiquidation.debtToOffset,
            singleLiquidation.collToSendToSP,
            singleLiquidation.debtToRedistribute,
            singleLiquidation.collToRedistribute
        ) = _getOffsetAndRedistributionVals(
            singleLiquidation.entireTroveDebt,
            collToLiquidate,
            _debtInStabPool,
            troveManager.sunsetting()
        );

        troveManager.closeTroveByLiquidation(_borrower);
        emit TroveLiquidated(
            _borrower,
            singleLiquidation.entireTroveDebt,
            singleLiquidation.entireTroveColl,
            TroveManagerOperation.liquidateInNormalMode
        );
        emit TroveUpdated(_borrower, 0, 0, 0, TroveManagerOperation.liquidateInNormalMode);
        return singleLiquidation;
    }

    // Liquidate one trove, in Recovery Mode.
    function _liquidateRecoveryMode(
        ITroveManager troveManager,
        address _borrower,
        uint256 _ICR,
        uint256 _debtInStabPool,
        uint256 _TCR,
        uint256 _price
    ) internal returns (LiquidationValues memory singleLiquidation) {
        LocalVariables_InnerSingleLiquidateFunction memory vars;
        if (troveManager.getTroveOwnersCount() == 1) {
            return singleLiquidation;
        } // don't liquidate if last trove
        (
            singleLiquidation.entireTroveDebt,
            singleLiquidation.entireTroveColl,
            vars.pendingDebtReward,
            vars.pendingCollReward
        ) = troveManager.getEntireDebtAndColl(_borrower);

        singleLiquidation.collGasCompensation = _getCollGasCompensation(singleLiquidation.entireTroveColl);
        singleLiquidation.debtGasCompensation = DEBT_GAS_COMPENSATION;
        vars.collToLiquidate = singleLiquidation.entireTroveColl - singleLiquidation.collGasCompensation;
        // If ICR <= 100%, purely redistribute the Trove across all active Troves
        if (_ICR <= _100pct) {
            troveManager.movePendingTroveRewardsToActiveBalances(vars.pendingDebtReward, vars.pendingCollReward);

            singleLiquidation.debtToOffset = 0;
            singleLiquidation.collToSendToSP = 0;
            singleLiquidation.debtToRedistribute = singleLiquidation.entireTroveDebt;
            singleLiquidation.collToRedistribute = vars.collToLiquidate;

            troveManager.closeTroveByLiquidation(_borrower);
            emit TroveLiquidated(
                _borrower,
                singleLiquidation.entireTroveDebt,
                singleLiquidation.entireTroveColl,
                TroveManagerOperation.liquidateInRecoveryMode
            );
            emit TroveUpdated(_borrower, 0, 0, 0, TroveManagerOperation.liquidateInRecoveryMode);

            // If 100% < ICR < MCR, offset as much as possible, and redistribute the remainder
        } else if ((_ICR > _100pct) && (_ICR < MCR)) {
            troveManager.movePendingTroveRewardsToActiveBalances(vars.pendingDebtReward, vars.pendingCollReward);

            (
                singleLiquidation.debtToOffset,
                singleLiquidation.collToSendToSP,
                singleLiquidation.debtToRedistribute,
                singleLiquidation.collToRedistribute
            ) = _getOffsetAndRedistributionVals(
                singleLiquidation.entireTroveDebt,
                vars.collToLiquidate,
                _debtInStabPool,
                troveManager.sunsetting()
            );

            troveManager.closeTroveByLiquidation(_borrower);
            emit TroveLiquidated(
                _borrower,
                singleLiquidation.entireTroveDebt,
                singleLiquidation.entireTroveColl,
                TroveManagerOperation.liquidateInRecoveryMode
            );
            emit TroveUpdated(_borrower, 0, 0, 0, TroveManagerOperation.liquidateInRecoveryMode);
            /*
             * If 110% <= ICR < current TCR (accounting for the preceding liquidations in the current sequence)
             * and there is Debt in the Stability Pool, only offset, with no redistribution,
             * but at a capped rate of 1.1 and only if the whole debt can be liquidated.
             * The remainder due to the capped rate will be claimable as collateral surplus.
             */
        } else if (
            (_ICR >= MCR) &&
            (_ICR < _TCR) &&
            (singleLiquidation.entireTroveDebt <= _debtInStabPool) &&
            !troveManager.sunsetting()
        ) {
            troveManager.movePendingTroveRewardsToActiveBalances(vars.pendingDebtReward, vars.pendingCollReward);

            singleLiquidation = _getCappedOffsetVals(
                singleLiquidation.entireTroveDebt,
                singleLiquidation.entireTroveColl,
                _price
            );

            troveManager.closeTroveByLiquidation(_borrower);
            if (singleLiquidation.collSurplus > 0) {
                troveManager.addCollateralSurplus(_borrower, singleLiquidation.collSurplus);
            }

            emit TroveLiquidated(
                _borrower,
                singleLiquidation.entireTroveDebt,
                singleLiquidation.collToSendToSP,
                TroveManagerOperation.liquidateInRecoveryMode
            );
            emit TroveUpdated(_borrower, 0, 0, 0, TroveManagerOperation.liquidateInRecoveryMode);
        } else {
            // if (_ICR >= MCR && ( _ICR >= _TCR || singleLiquidation.entireTroveDebt > _debtInStabPool))
            LiquidationValues memory zeroVals;
            return zeroVals;
        }

        return singleLiquidation;
    }

    /* In a full liquidation, returns the values for a trove's coll and debt to be offset, and coll and debt to be
     * redistributed to active troves.
     */
    function _getOffsetAndRedistributionVals(
        uint256 _debt,
        uint256 _coll,
        uint256 _debtInStabPool,
        bool sunsetting
    )
        internal
        pure
        returns (uint256 debtToOffset, uint256 collToSendToSP, uint256 debtToRedistribute, uint256 collToRedistribute)
    {
        if (_debtInStabPool > 0 && !sunsetting) {
            /*
             * Offset as much debt & collateral as possible against the Stability Pool, and redistribute the remainder
             * between all active troves.
             *
             *  If the trove's debt is larger than the deposited Debt in the Stability Pool:
             *
             *  - Offset an amount of the trove's debt equal to the Debt in the Stability Pool
             *  - Send a fraction of the trove's collateral to the Stability Pool, equal to the fraction of its offset debt
             *
             */
            debtToOffset = PrismaMath._min(_debt, _debtInStabPool);
            collToSendToSP = (_coll * debtToOffset) / _debt;
            debtToRedistribute = _debt - debtToOffset;
            collToRedistribute = _coll - collToSendToSP;
        } else {
            debtToOffset = 0;
            collToSendToSP = 0;
            debtToRedistribute = _debt;
            collToRedistribute = _coll;
        }
    }

    /*
     *  Get its offset coll/debt and collateral gas comp, and close the trove.
     */
    function _getCappedOffsetVals(
        uint256 _entireTroveDebt,
        uint256 _entireTroveColl,
        uint256 _price
    ) internal view returns (LiquidationValues memory singleLiquidation) {
        singleLiquidation.entireTroveDebt = _entireTroveDebt;
        singleLiquidation.entireTroveColl = _entireTroveColl;
        uint256 collToOffset = (_entireTroveDebt * MCR) / _price;

        singleLiquidation.collGasCompensation = _getCollGasCompensation(collToOffset);
        singleLiquidation.debtGasCompensation = DEBT_GAS_COMPENSATION;

        singleLiquidation.debtToOffset = _entireTroveDebt;
        singleLiquidation.collToSendToSP = collToOffset - singleLiquidation.collGasCompensation;
        singleLiquidation.collSurplus = _entireTroveColl - collToOffset;
        singleLiquidation.debtToRedistribute = 0;
        singleLiquidation.collToRedistribute = 0;
    }

    function _addLiquidationValuesToTotals(
        LiquidationTotals memory oldTotals,
        LiquidationValues memory singleLiquidation
    ) internal pure returns (LiquidationTotals memory newTotals) {
        // Tally all the values with their respective running totals
        newTotals.totalCollGasCompensation = oldTotals.totalCollGasCompensation + singleLiquidation.collGasCompensation;
        newTotals.totalDebtGasCompensation = oldTotals.totalDebtGasCompensation + singleLiquidation.debtGasCompensation;
        newTotals.totalDebtInSequence = oldTotals.totalDebtInSequence + singleLiquidation.entireTroveDebt;
        newTotals.totalCollInSequence = oldTotals.totalCollInSequence + singleLiquidation.entireTroveColl;
        newTotals.totalDebtToOffset = oldTotals.totalDebtToOffset + singleLiquidation.debtToOffset;
        newTotals.totalCollToSendToSP = oldTotals.totalCollToSendToSP + singleLiquidation.collToSendToSP;
        newTotals.totalDebtToRedistribute = oldTotals.totalDebtToRedistribute + singleLiquidation.debtToRedistribute;
        newTotals.totalCollToRedistribute = oldTotals.totalCollToRedistribute + singleLiquidation.collToRedistribute;
        newTotals.totalCollSurplus = oldTotals.totalCollSurplus + singleLiquidation.collSurplus;

        return newTotals;
    }

    // Check whether or not the system *would be* in Recovery Mode, given a collateral:USD price, and the entire system coll and debt.
    function _checkPotentialRecoveryMode(
        uint256 _entireSystemColl,
        uint256 _entireSystemDebt,
        uint256 _price
    ) internal pure returns (bool) {
        uint256 TCR = PrismaMath._computeCR(_entireSystemColl, _entireSystemDebt, _price);

        return TCR < CCR;
    }
}

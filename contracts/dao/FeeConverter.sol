// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../dependencies/PrismaOwnable.sol";
import "../dependencies/SystemStart.sol";
import "../interfaces/IPriceFeed.sol";
import "../interfaces/ITroveManager.sol";
import "../interfaces/IFactory.sol";

interface IFeeDistributor {
    function depositFeeToken(address token, uint256 amount) external returns (bool);
}

interface ICryptoSwap {
    function add_liquidity(
        uint256[2] memory amounts,
        uint256 min_mint_amount,
        bool use_eth,
        address receiver
    ) external returns (uint256);

    function price_oracle() external view returns (uint256);

    function price_scale() external view returns (uint256);

    function token() external view returns (address);
}

contract FeeConverter is PrismaOwnable, SystemStart {
    using SafeERC20 for IERC20;

    IFeeDistributor public immutable feeDistributor;
    IERC20 public immutable debtToken;
    IERC20 public immutable prismaToken;
    IFactory public immutable factory;

    ICryptoSwap public immutable curvePool;
    IERC20 public immutable curvePoolLp;

    uint256 public constant MAX_PCT = 10000;

    ITroveManager[] public troveManagers;

    uint16 public updatedWeek;

    // maximum amount of `debtToken` distributed in a week, as an absolute value.
    uint88 public maxWeeklyDebtAmount;
    // maximum percentage of `debtToken` distrubted in a week, relative to the
    // amount within the fee receiver.
    uint16 public maxWeeklyDebtPct;

    // target percent of liquidity within `curvePool` that the protocol should
    // own. if the actual owned percent is less than this, a portion of the
    // week's fees are used to add liquidity.
    uint16 public targetPOLPct;
    // percentage of weekly debt amount used to add liquidity, if protocol owned
    // liquidity is below the target percent.
    uint16 public weeklyDebtPOLPct;

    // maximum deviation percent between `price_oracle` and `price_scale` when
    // adding liquidity on `curvePool`. protects against sandwich attacks.
    uint16 public maxLpDeviation;

    // amount of `debtToken` send to caller each week for processing fees
    uint88 public callerIncentive;

    // collateral -> is for sale via `swapCollateralForDebt`?
    mapping(address collateral => bool isForSale) public isSellingCollateral;

    event WeeklyDebtParamsSet(uint256 maxWeeklyDebtAmount, uint256 maxWeeklyDebtPct);
    event POLParamsSet(uint256 targetPOLPct, uint256 weeklyDebtPOLPct, uint256 maxLpDeviation);
    event CallerIncentiveSet(uint256 callerIncentive);
    event IsSellingCollateralSet(address[] collaterals, bool isSelling);

    event CollateralSold(
        address indexed buyer,
        address indexed collateral,
        uint256 price,
        uint256 amountSold,
        uint256 amountReceived
    );

    event LiquidityAdded(
        uint256 priceOracle,
        uint256 priceScale,
        uint256 debtAmount,
        uint256 prismaAmount,
        uint256 lpAmountReceived
    );

    event TroveManagersSynced();
    event InterestCollected();
    event FeeTokenDeposited(uint256 amount);
    event CallerIncentivePaid(address indexed caller, uint256 amount);

    struct InitialParams {
        uint88 maxWeeklyDebtAmount;
        uint16 maxWeeklyDebtPct;
        uint16 targetPOLPct;
        uint16 weeklyDebtPOLPct;
        uint16 maxLpDeviation;
        uint88 callerIncentive;
        address[] sellCollaterals;
    }

    constructor(
        address _prismaCore,
        address _feeDistributor,
        IERC20 _debtToken,
        IERC20 _prismaToken,
        IFactory _factory,
        ICryptoSwap _curvePool,
        InitialParams memory initialParams
    ) PrismaOwnable(_prismaCore) SystemStart(_prismaCore) {
        feeDistributor = IFeeDistributor(_feeDistributor);
        debtToken = _debtToken;
        prismaToken = _prismaToken;
        factory = _factory;
        curvePool = _curvePool;
        curvePoolLp = IERC20(_curvePool.token());

        _debtToken.approve(_feeDistributor, type(uint256).max);
        _debtToken.approve(address(_curvePool), type(uint256).max);
        _prismaToken.approve(address(_curvePool), type(uint256).max);

        setWeeklyDebtParams(initialParams.maxWeeklyDebtAmount, initialParams.maxWeeklyDebtPct);
        setPOLParams(initialParams.targetPOLPct, initialParams.weeklyDebtPOLPct, initialParams.maxLpDeviation);
        setCallerIncentive(initialParams.callerIncentive);
        setIsSellingCollateral(initialParams.sellCollaterals, true);

        syncTroveManagers();
    }

    function setWeeklyDebtParams(uint256 _maxWeeklyDebtAmount, uint256 _maxWeeklyDebtPct) public onlyOwner {
        require(_maxWeeklyDebtPct <= MAX_PCT, "Invalid maxWeeklyDebtPct");
        maxWeeklyDebtAmount = uint88(_maxWeeklyDebtAmount);
        maxWeeklyDebtPct = uint16(_maxWeeklyDebtPct);

        emit WeeklyDebtParamsSet(_maxWeeklyDebtAmount, _maxWeeklyDebtPct);
    }

    function setPOLParams(uint256 _targetPOLPct, uint256 _weeklyDebtPOLPct, uint256 _maxLpDeviation) public onlyOwner {
        require(_targetPOLPct <= MAX_PCT, "Invalid targetPOLPct");
        require(_weeklyDebtPOLPct <= MAX_PCT, "Invalid weeklyDebtPOLPct");
        require(_maxLpDeviation <= MAX_PCT, "Invalid maxLpDeviation");
        targetPOLPct = uint16(_targetPOLPct);
        weeklyDebtPOLPct = uint16(_weeklyDebtPOLPct);
        maxLpDeviation = uint16(_maxLpDeviation);

        emit POLParamsSet(_targetPOLPct, _weeklyDebtPOLPct, _maxLpDeviation);
    }

    function setCallerIncentive(uint256 _callerIncentive) public onlyOwner {
        callerIncentive = uint88(_callerIncentive);

        emit CallerIncentiveSet(_callerIncentive);
    }

    function setIsSellingCollateral(address[] memory collaterals, bool isSelling) public onlyOwner {
        uint256 length = collaterals.length;
        if (isSelling) {
            IPriceFeed feed = IPriceFeed(PRISMA_CORE.priceFeed());
            for (uint i = 0; i < length; i++) {
                address collateral = collaterals[i];
                // fetch price as validation that collateral can be sold
                feed.fetchPrice(collateral);
                isSellingCollateral[collateral] = true;
            }
        } else {
            for (uint i = 0; i < length; i++) {
                isSellingCollateral[collaterals[i]] = false;
            }
        }

        emit IsSellingCollateralSet(collaterals, isSelling);
    }

    /**
        @notice Swap collateral token for debt
        @dev Collateral is sold at the oracle price without discount, assuming a
             debt token value of $1. Swaps become profitable for the caller when
             the debt token price is under peg. As fees from redemptions are
             also generated only when the debt price is under peg, it is expected
             that redeemers will also call this function in the same action.
     */
    function swapDebtForColl(address collateral, uint256 debtAmount) external returns (uint256) {
        require(isSellingCollateral[collateral], "Collateral sale disabled");
        address receiver = PRISMA_CORE.feeReceiver();

        (uint256 collAmount, uint256 price) = getSwapAmountReceived(collateral, debtAmount);
        debtToken.transferFrom(msg.sender, receiver, debtAmount);
        IERC20(collateral).safeTransferFrom(receiver, msg.sender, collAmount);

        emit CollateralSold(msg.sender, collateral, price, debtAmount, collAmount);
        return collAmount;
    }

    /**
        @notice Get the amount received when swapping collateral for debt
        @dev Intended to be called as a view method
     */
    function getSwapAmountReceived(
        address collateral,
        uint256 debtAmount
    ) public returns (uint256 collAmount, uint256 price) {
        IPriceFeed feed = IPriceFeed(PRISMA_CORE.priceFeed());
        price = feed.fetchPrice(collateral);
        collAmount = (debtAmount * 1e18) / price;
        return (collAmount, price);
    }

    /**
        @notice Update the local storage array of trove managers
        @dev Should be called whenever a trove manager is added or removed
     */
    function syncTroveManagers() public returns (bool) {
        uint256 newLength = factory.troveManagerCount();

        for (uint i = troveManagers.length; i < newLength; i++) {
            ITroveManager troveManager = ITroveManager(factory.troveManagers(i));
            troveManagers.push(troveManager);
        }

        emit TroveManagersSynced();
        return true;
    }

    /**
        @notice Collect accrued interest from all trove managers
        @dev Callable by anyone at any time. Also called within `processWeeklyFees`.
     */
    function collectInterests() public returns (bool) {
        uint256 length = troveManagers.length;
        for (uint i = 0; i < length; i++) {
            ITroveManager tm = troveManagers[i];
            if (tm.interestPayable() > 0) tm.collectInterests();
        }

        emit InterestCollected();
        return true;
    }

    /**
        @notice Process weekly fees
        @dev Callable once per week. The caller is incentivized with a fixed
             amount of debt tokens.
     */
    function processWeeklyFees() external returns (bool) {
        require(getWeek() > updatedWeek, "Already called this week");
        updatedWeek = uint16(getWeek());

        // collect accrued interest this week
        collectInterests();

        // calculate amount of debtToken to distribute
        address receiver = PRISMA_CORE.feeReceiver();
        uint256 amount = debtToken.balanceOf(receiver);
        amount = (amount * maxWeeklyDebtPct) / MAX_PCT;
        uint256 maxDebt = maxWeeklyDebtAmount;
        if (amount > maxDebt) amount = maxDebt;
        debtToken.transferFrom(receiver, address(this), amount);

        // transfer `callerIncentive` to caller - thank you for your service!
        debtToken.transfer(msg.sender, callerIncentive);
        amount -= callerIncentive;
        emit CallerIncentivePaid(msg.sender, callerIncentive);

        // add liquidity to `curveLpPool`
        uint256 polPct = weeklyDebtPOLPct;
        if (polPct > 0) {
            if ((curvePoolLp.balanceOf(receiver) * MAX_PCT) / curvePoolLp.totalSupply() < targetPOLPct) {
                uint256 polAmount = (amount * polPct) / MAX_PCT;
                amount -= _addLiquidity(polAmount, receiver);
            }
        }

        // deposit to `feeDistributor`
        if (amount > 0) {
            feeDistributor.depositFeeToken(address(debtToken), amount);
            emit FeeTokenDeposited(amount);
        }

        return true;
    }

    function _addLiquidity(uint256 debtAmount, address receiver) internal returns (uint256) {
        uint256 priceOracle = curvePool.price_oracle();
        uint256 priceScale = curvePool.price_scale();

        if (priceOracle > priceScale) {
            uint256 delta = priceOracle - priceScale;
            require((delta * MAX_PCT) / priceOracle < maxLpDeviation, "LP price too volatile");
        } else {
            uint256 delta = priceScale - priceOracle;
            require((delta * MAX_PCT) / priceScale < maxLpDeviation, "LP price too volatile");
        }

        uint256 prismaAmount = (debtAmount * 1e18) / priceScale;
        uint256 prismaAvailable = prismaToken.balanceOf(receiver);

        // if insufficient PRISMA is available, adjust the amounts
        if (prismaAvailable < prismaAmount) {
            if (prismaAvailable < 1e18) return 0;
            prismaAmount = prismaAvailable;
            debtAmount = (prismaAmount * priceScale) / 1e18;
        }

        prismaToken.transferFrom(receiver, address(this), prismaAmount);
        uint256 lpAmount = curvePool.add_liquidity([debtAmount, prismaAmount], 0, false, receiver);

        emit LiquidityAdded(priceOracle, priceScale, debtAmount, prismaAmount, lpAmount);
        return debtAmount;
    }
}

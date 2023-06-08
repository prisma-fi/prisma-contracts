from brownie import accounts, chain, ZERO_ADDRESS
from brownie import (
    PrismaCore,
    BorrowerOperations,
    Factory,
    FeeReceiver,
    GasPool,
    DebtToken,
    PriceFeed,
    SortedTroves,
    StabilityPool,
    TroveManager,
    LiquidationManager,
    PrismaToken,
    TokenLocker,
    IncentiveVoting,
    PrismaTreasury,
    EmissionSchedule,
    BoostCalculator,
    AdminVoting,
    MultiCollateralHintHelpers,
    MockAggregator,
    MockTellor,
)
from brownie_tokens import ERC20


MIN_DEBT = 1800 * 10**18
GAS_COMP = 200 * 10**18
PRISMA_TOTAL_SUPPLY = 300_000_000 * 10**18

MINUTE_DECAY_FACTOR = 999037758833783000
REDEMPTION_FEE_FLOOR = int(0.005 * 10**18)
MAX_REDEMPTION_FEE = 10**18
BORROWING_FEE_FLOOR = int(0.005 * 10**18)
MAX_BORROWING_FEE = int(0.05 * 10**18)
INTEREST_RATE = 300

FACTORY_DEPLOY_PARAMS = (
    MINUTE_DECAY_FACTOR,
    REDEMPTION_FEE_FLOOR,
    MAX_REDEMPTION_FEE,
    BORROWING_FEE_FLOOR,
    MAX_BORROWING_FEE,
    INTEREST_RATE,
    2**256-1,
)


def update_chainlink(mock_chainlink, price):
    current = mock_chainlink.latestRoundData().dict()
    mock_chainlink.setPrevPrice(current['answer'])
    mock_chainlink.setPrevRoundId(current['roundId'])
    mock_chainlink.setPrevUpdateTime(current['updatedAt'])

    mock_chainlink.setUpdateTime(chain.time())
    mock_chainlink.setPrice(price * 10**8)
    mock_chainlink.setLatestRoundId(current['roundId'] + 1)
    chain.sleep(10)


def reduce_to_minimal_cr(borrower_ops, token, trove_manager, acct):
    c, d = trove_manager.getTroveCollAndDebt(acct)
    icr = trove_manager.getCurrentICR(acct, 1000 * 10**18) / 10**18
    amount = c - (c / icr * 1.15)
    borrower_ops.withdrawColl(token, acct, amount, ZERO_ADDRESS, ZERO_ADDRESS, {'from': acct})



def main():

    chain.mine(timestamp=(chain.time() // 604800 + 1) * 604800)

    deployer = accounts[0]
    mock_chainlink = MockAggregator.deploy({'from': deployer})
    for i in range(3):
        # ensure PriceFeed does not think chainlink is immediately broken
        update_chainlink(mock_chainlink, 1000)

    mock_tellor = MockTellor.deploy({'from': deployer})

    nonce = deployer.nonce

    prisma_core = deployer.get_deployment_address(nonce)
    fee_receiver = deployer.get_deployment_address(nonce + 1)
    gas_pool = deployer.get_deployment_address(nonce + 2)
    pricefeed = deployer.get_deployment_address(nonce + 3)
    factory = deployer.get_deployment_address(nonce + 4)
    liquidation_manager = deployer.get_deployment_address(nonce + 5)
    tm_impl = deployer.get_deployment_address(nonce+ 6)
    st_impl = deployer.get_deployment_address(nonce+ 7)
    locker = deployer.get_deployment_address(nonce + 8)
    voter = deployer.get_deployment_address(nonce + 9)
    prisma = deployer.get_deployment_address(nonce + 10)
    emissions = deployer.get_deployment_address(nonce + 11)
    treasury = deployer.get_deployment_address(nonce + 12)
    stability_pool = deployer.get_deployment_address(nonce + 13)
    debt = deployer.get_deployment_address(nonce + 14)
    borrower_ops = deployer.get_deployment_address(nonce + 15)
    boost = deployer.get_deployment_address(nonce + 16)

    prisma_core = PrismaCore.deploy(deployer, stability_pool, {'from': deployer})
    fee_receiver = FeeReceiver.deploy(prisma_core, {'from': deployer})
    gas_pool = GasPool.deploy({'from': deployer})
    pricefeed = PriceFeed.deploy(prisma_core, mock_chainlink, mock_tellor, {'from': deployer})
    factory = Factory.deploy(prisma_core, debt, stability_pool, borrower_ops, st_impl, tm_impl, liquidation_manager, {'from': deployer})
    liquidation_manager =  LiquidationManager.deploy(stability_pool, factory, GAS_COMP, {'from': deployer})
    tm_impl = TroveManager.deploy(prisma_core, gas_pool, debt, borrower_ops, treasury, liquidation_manager, GAS_COMP, {'from': deployer})
    st_impl = SortedTroves.deploy({'from': deployer})

    locker = TokenLocker.deploy(prisma_core, prisma, voter, 10**18, {'from': deployer})
    voter = IncentiveVoting.deploy(prisma_core, locker, treasury, {'from': deployer})
    prisma = PrismaToken.deploy(treasury, ZERO_ADDRESS, locker, PRISMA_TOTAL_SUPPLY, {'from': deployer})
    emissions = EmissionSchedule.deploy(
        prisma_core,
        voter, treasury,
        26,  # lock weeks
        2,   # lock decay rate
        100, # weeklyPct
        [(52, 50), (39, 70), (26, 80), (13, 90)],   # weeklyPct schedule
        {'from': deployer}
    )

    treasury = PrismaTreasury.deploy(
        prisma_core,
        prisma,
        locker,
        voter,
        emissions,
        boost,
        stability_pool,
        26,  # lock weeks
        [2250000 * 10**18] * 4,  # initial fixed amounts
        [(deployer, 90_000_000 * 10**18)],  # 30% of total supply to vests (TODO direct to AllocationVesting)
        {'from': deployer})

    stability_pool = StabilityPool.deploy(prisma_core, debt, treasury, factory, liquidation_manager,{'from': deployer})
    debt = DebtToken.deploy("acUSD", "acUSD", stability_pool, borrower_ops, prisma_core, ZERO_ADDRESS, factory, gas_pool, GAS_COMP, {'from': deployer})   # zero is layerzero
    borrower_ops = BorrowerOperations.deploy(prisma_core, debt, factory, MIN_DEBT, GAS_COMP, {'from': deployer})
    boost = BoostCalculator.deploy(
        prisma_core,
        locker,
        10,   # weeks of automatic max-boost (TODO reduce to test boost)
        {'from': deployer}
    )

    prisma_core.setPriceFeed(pricefeed, {'from': deployer})
    prisma_core.setFeeReceiver(fee_receiver, {'from': deployer})

    helper = MultiCollateralHintHelpers.deploy(borrower_ops, factory, GAS_COMP, {'from': deployer})

    # final transfer of ownership to DAO
    owner = AdminVoting.deploy(prisma_core, locker, 0, 30, {'from': deployer})
    prisma_core.commitTransferOwnership(owner, {'from': deployer})
    chain.sleep(86400 * 3 + 1)
    owner.acceptTransferOwnership({'from': deployer})

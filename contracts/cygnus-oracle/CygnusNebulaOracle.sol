// SPDX-License-Identifier: Unlicensed
pragma solidity >=0.8.17;

// Dependencies
import {ICygnusNebulaOracle} from "./interfaces/ICygnusNebulaOracle.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";

// Libraries
import {PRBMath, PRBMathUD60x18} from "./libraries/PRBMathUD60x18.sol";
import {PRBMathSD59x18} from "./libraries/PRBMathSD59x18.sol";

// Interfaces
import {IERC20} from "./interfaces/IERC20.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

// Balancer
import {IVault} from "./interfaces/IVault.sol";
import {IWeightedPool} from "./interfaces/IWeightedPool.sol";

/**
 *  @title  CygnusNebulaOracle
 *  @author CygnusDAO
 *  @notice Oracle used by Cygnus that returns the price of 1 BPT in the denomination token. In case need
 *          different implementation just update the denomination variable `denominationAggregator`
 *          and `denominationToken` with token.
 *  @notice modified from Revest Finance 
 *          https://revestfinance.medium.com/dev-blog-on-the-derivation-of-a-safe-price-formula-for-balancer-pool-tokens-33e8993455d0
 */
contract CygnusNebulaOracle is ICygnusNebulaOracle, ReentrancyGuard {
    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            1. LIBRARIES
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /**
     *  @custom:library PRBMathUD60x18 Smart contract library for advanced fixed-point math that works with uint256
     */
    using PRBMathUD60x18 for uint256;

    /**
     *  @custom:library PRBMathSD59x18 Smart contract library for advanced fixed-point math that works with int256
     */
    using PRBMathSD59x18 for int256;

    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            2. STORAGE
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /*  ────────────────────────────────────────────── Internal ───────────────────────────────────────────────  */

    /**
     *  @notice Internal record of all initialized oracles
     */
    mapping(address => CygnusNebula) internal nebulas;

    /*  ─────────────────────────────────────────────── Public ────────────────────────────────────────────────  */

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    address[] public override allNebulas;

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    string public constant override name = "Cygnus-Nebula: Constant-Product LP Oracle";

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    string public constant override version = "1.0.0";

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    uint256 public constant override SECONDS_PER_YEAR = 31536000;

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    uint256 public constant override AGGREGATOR_DECIMALS = 8;

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    uint256 public constant AGGREGATOR_SCALAR = 10 ** (18 - 8); // 10^(18 - AGGREGATOR_DECIMALS)

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    IERC20 public immutable override denominationToken;

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    uint8 public immutable override decimals;

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    AggregatorV3Interface public immutable override denominationAggregator;

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    address public override admin;

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    address public override pendingAdmin;

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    IVault public constant override VAULT = IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            3. CONSTRUCTOR
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /**
     *  @notice Constructs a new Oracle instance.
     *  @param denomination The token address that the oracle denominates the price of the LP in. It is used to
     *         determine the decimals for the price returned by this oracle. For example, if the denomination
     *         token is USDC, the oracle will return prices with 6 decimals. If the denomination token is DAI,
     *         the oracle will return prices with 18 decimals.
     *  @param denominationPrice The price aggregator for the denomination token.
     *        This is the token that the LP Token will be priced in.
     */
    constructor(IERC20 denomination, AggregatorV3Interface denominationPrice) {
        // Assign the admin
        admin = msg.sender;

        // Set the denomination token
        denominationToken = denomination;

        // Determine the number of decimals for the oracle based on the denomination token
        decimals = denomination.decimals();

        // Set the price aggregator for the denomination token
        denominationAggregator = AggregatorV3Interface(denominationPrice);
    }

    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            4. MODIFIERS
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /**
     *  @custom:modifier cygnusAdmin Modifier for admin control only 👽
     */
    modifier cygnusAdmin() {
        isCygnusAdmin();
        _;
    }

    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            5. CONSTANT FUNCTIONS
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /*  ────────────────────────────────────────────── Internal ───────────────────────────────────────────────  */

    /**
     *  @notice Internal check for admin control only 👽
     */
    function isCygnusAdmin() internal view {
        /// @custom:error MsgSenderNotAdmin Avoid unless caller is Cygnus Admin
        if (msg.sender != admin) {
            revert CygnusNebulaOracle__MsgSenderNotAdmin({sender: msg.sender});
        }
    }

    /**
     *  @notice Gets the price of a chainlink aggregator
     *  @param priceFeed Chainlink aggregator price feed
     *  @return price The price of the token adjusted to 18 decimals
     */
    function getPriceInternal(AggregatorV3Interface priceFeed) internal view returns (uint256 price) {
        /// @solidity memory-safe-assembly
        assembly {
            // Store the function selector of `latestRoundData()`.
            mstore(0x0, 0xfeaf968c)
            // Get second slot from round data (`price`)
            price := mul(
                mul(
                    mload(0x20),
                    and(
                        // The arguments are evaluated from right to left
                        gt(returndatasize(), 0x1f), // At least 32 bytes returned
                        staticcall(gas(), priceFeed, 0x1c, 0x4, 0x0, 0x40) // Only get `latestPrice`
                    )
                ),
                // Adjust to 18 decimals
                AGGREGATOR_SCALAR
            )
        }
    }

    /*  ─────────────────────────────────────────────── Public ────────────────────────────────────────────────  */

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    function getNebula(address lpTokenPair) public view override returns (CygnusNebula memory) {
        return nebulas[lpTokenPair];
    }

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    function nebulaSize() public view override returns (uint88) {
        // Return how many LP Tokens we are tracking
        return uint88(allNebulas.length);
    }

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    function getAnnualizedBaseRate(
        uint256 exchangeRateLast,
        uint256 exchangeRateCurrent,
        uint256 timeElapsed
    ) public pure override returns (uint256) {
        // Get the natural logarithm of last exchange rate
        uint256 logRateLast = exchangeRateLast.ln();

        // Get the natural logarithm of current exchange rate
        uint256 logRateCurrent = exchangeRateCurrent.ln();

        // Get the log rate difference between the exchange rates
        uint256 logRateDiff = logRateCurrent - logRateLast;

        // The log APR is = (lorRateDif * 1 year) / time since last update
        uint256 logAprInYear = (logRateDiff * SECONDS_PER_YEAR) / timeElapsed;

        // Get the natural exponent of the log APR and substract 1
        uint256 annualizedApr = logAprInYear.exp() - 1e18;

        // Returns the annualized APR, taking into account time since last update
        return annualizedApr;
    }

    /*  ────────────────────────────────────────────── External ───────────────────────────────────────────────  */

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    function denominationTokenPrice() external view override returns (uint256) {
        // Price of the denomination token in 18 decimals
        uint256 denomPrice = getPriceInternal(denominationAggregator);

        // Return in oracle decimals
        return denomPrice / (10 ** (18 - decimals));
    }

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    function lpTokenPriceUsd(address lpTokenPair) external view override returns (uint256 lpTokenPrice) {
        // Load to storage for gas savings (only read pool token price feeds)
        ICygnusNebulaOracle.CygnusNebula storage cygnusNebula = nebulas[lpTokenPair];

        /// @custom:error PairNotInitialized Avoid getting price unless lpTokenPair's price is being tracked
        if (!cygnusNebula.initialized) {
            revert CygnusNebulaOracle__PairNotInitialized(lpTokenPair);
        }

        // 1. weight = balance * price / invariant
        uint256[] memory weights = IWeightedPool(lpTokenPair).getNormalizedWeights();

        // 2. Loop through each prices and update `totalPi`
        int256 totalPi = PRBMathSD59x18.fromInt(1e18);

        // Use weights.length to avoid reading from storage for gas savings
        for (uint256 i = 0; i < weights.length; i++) {
            // Get the price from chainlink from cached price feeds
            uint256 assetPrice = getPriceInternal(cygnusNebula.priceFeeds[i]);

            // Value = Token Price / Token Weight
            int256 value = int256(assetPrice).div(int256(weights[i]));

            // Individual Pi = Value ** Token Weight
            int256 indivPi = value.pow(int256(weights[i]));

            // Adjust total Pi
            totalPi = totalPi.mul(indivPi);
        }

        // 3. Get invariant from the pool
        int256 invariant = int256(IWeightedPool(lpTokenPair).getLastInvariant());

        // Pool TVL in USD
        int256 numerator = totalPi.mul(invariant);

        // 4. Total Supply of BPT tokens for this pool
        int256 totalSupply = int256(IWeightedPool(lpTokenPair).totalSupply());

        // 5. BPT Price (USD) = TVL / totalSupply
        uint256 lpPrice = uint256((numerator.toInt().div(totalSupply)));

        // 6. Return price of BPT in denom token
        // Wad denom token
        uint256 denomPrice = getPriceInternal(denominationAggregator);

        // BPT Price in denom token (USDC) and adjust to denom token `decimals`
        lpTokenPrice = lpPrice.div(denomPrice * 10 ** (18 - decimals));
    }

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    function assetPricesUsd(address lpTokenPair) external view override returns (uint256[] memory) {
        // Load to storage for gas savings
        CygnusNebula storage cygnusNebula = nebulas[lpTokenPair];

        /// @custom:error PairNotInitialized Avoid getting price unless lpTokenPair's price is being tracked
        if (!cygnusNebula.initialized) {
            revert CygnusNebulaOracle__PairNotInitialized({lpTokenPair: lpTokenPair});
        }

        // Price of denom token
        uint256 denomPrice = getPriceInternal(denominationAggregator);

        // Create new array of poolTokens.length to return
        uint256[] memory prices = new uint256[](cygnusNebula.poolTokens.length);

        // Loop through each token
        for (uint256 i = 0; i < cygnusNebula.poolTokens.length; i++) {
            // Get the price from chainlink from cached price feeds
            uint256 assetPrice = getPriceInternal(cygnusNebula.priceFeeds[i]);

            // Express asset price in denom token
            prices[i] = assetPrice.div(denomPrice * 10 ** (18 - decimals));
        }

        // Return uint256[] of token prices denominated in denom token and oracle decimals
        return prices;
    }

    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            6. NON-CONSTANT FUNCTIONS
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /*  ────────────────────────────────────────────── External ───────────────────────────────────────────────  */

    /**
     *  @inheritdoc ICygnusNebulaOracle
     *  @custom:security non-reentrant only-admin
     */
    function initializeNebula(
        address lpTokenPair,
        AggregatorV3Interface[] calldata aggregators
    ) external override nonReentrant cygnusAdmin {
        // Load the CygnusNebula instance for the LP Token pair into storage
        CygnusNebula storage cygnusNebula = nebulas[lpTokenPair];

        // If the LP Token pair is already being tracked by an oracle, revert with an error message
        if (cygnusNebula.initialized) {
            revert CygnusNebulaOracle__PairAlreadyInitialized({lpTokenPair: lpTokenPair});
        }

        // Bytes32 Pool ID to identify pool in vault
        bytes32 poolId = IWeightedPool(lpTokenPair).getPoolId();

        // Get pool tokens from the vault
        (IERC20[] memory poolTokens, , ) = VAULT.getPoolTokens(poolId);

        // Decimals for each token
        uint256[] memory tokenDecimals = new uint256[](aggregators.length);

        // Create a memory array for the decimals of each price feed
        uint256[] memory priceDecimals = new uint256[](aggregators.length);

        // Loop through each one
        for (uint256 i = 0; i < aggregators.length; i++) {
            // Get the decimals for token `i`
            tokenDecimals[i] = poolTokens[i].decimals();

            // Chainlink price feed decimals
            priceDecimals[i] = aggregators[i].decimals();
        }

        // Assign an ID to the new oracle
        cygnusNebula.oracleId = nebulaSize();

        // Set the user-friendly name of the new oracle to the name of the LP Token pair
        cygnusNebula.name = IERC20(lpTokenPair).name();

        // Store the address of the LP Token pair
        cygnusNebula.underlying = lpTokenPair;

        // Store the addresses of the tokens in the LP Token pair
        cygnusNebula.poolTokens = poolTokens;

        // Store the number of decimals for each token in the LP Token pair
        cygnusNebula.poolTokensDecimals = tokenDecimals;

        // Store the price aggregator interfaces for the tokens in the LP Token pair
        cygnusNebula.priceFeeds = aggregators;

        // Store the decimals for each aggregator
        cygnusNebula.priceFeedsDecimals = priceDecimals;

        // Set the status of the new oracle to initialized
        cygnusNebula.initialized = true;

        // Add the LP Token pair to the list of all tracked LP Token pairs
        allNebulas.push(lpTokenPair);

        /// @custom:event InitializeCygnusNebula
        emit InitializeCygnusNebula(true, cygnusNebula.oracleId, lpTokenPair, poolTokens, tokenDecimals, aggregators, priceDecimals);
    }

    /**
     *  @inheritdoc ICygnusNebulaOracle
     *  @custom:security non-reentrant only-admin
     */
    function setOraclePendingAdmin(address newPendingAdmin) external override nonReentrant cygnusAdmin {
        // Pending admin initial is always zero
        /// @custom:error PendingAdminAlreadySet Avoid setting the same pending admin twice
        if (newPendingAdmin == pendingAdmin) {
            revert CygnusNebulaOracle__PendingAdminAlreadySet({pendingAdmin: newPendingAdmin});
        }

        // Assign address of the requested admin
        pendingAdmin = newPendingAdmin;

        /// @custom:event NewOraclePendingAdmin
        emit NewOraclePendingAdmin(admin, newPendingAdmin);
    }

    /**
     *  @inheritdoc ICygnusNebulaOracle
     *  @custom:security non-reentrant only-admin
     */
    function setOracleAdmin() external override nonReentrant cygnusAdmin {
        /// @custom:error AdminCantBeZero Avoid settings the admin to the zero address
        if (pendingAdmin == address(0)) {
            revert CygnusNebulaOracle__AdminCantBeZero({pendingAdmin: pendingAdmin});
        }

        // Address of the Admin up until now
        address oldAdmin = admin;

        // Assign new admin
        admin = pendingAdmin;

        // Gas refund
        delete pendingAdmin;

        // @custom:event NewOracleAdmin
        emit NewOracleAdmin(oldAdmin, admin);
    }
}
